// Compute C0.1: cost and correctness of the GL -> CL -> GL handoff, per synchronisation strategy.
// A dependency chain alternates a GL fragment pass (A = B + 1) and a CL kernel (B = A + 1) on 1024² R32F
// textures shared through the CGL share group. With correct ordering, after N rounds every texel of B is 2N;
// a missing synchronisation shows up as a smaller value. Times: CPU spent issuing the CL part per round,
// wall time per round (N rounds then glFinish), and the same chain with the CL pass done in GL as reference.
// Build: make build/roundtrip   Run: build/roundtrip [rounds]
#define GL_SILENCE_DEPRECATION
#define CL_SILENCE_DEPRECATION
#import <Foundation/Foundation.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#import <OpenCL/opencl.h>
#import <mach/mach_time.h>

static int W = 1024, H = 1024;

static double now_ms(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6;
}

static const char *kSrc =
    "__kernel void inc(__read_only image2d_t a, __write_only image2d_t b) {\n"
    "  int2 g = (int2)(get_global_id(0), get_global_id(1));\n"
    "  const sampler_t s = CLK_NORMALIZED_COORDS_FALSE | CLK_ADDRESS_CLAMP_TO_EDGE | CLK_FILTER_NEAREST;\n"
    "  write_imagef(b, g, (float4)(read_imagef(a, s, g).x + 1.0f, 0, 0, 1));\n"
    "}\n"
    "__kernel void nop(__global uint *p) { if (get_global_id(0) == 0xffffffff) p[0] = 0; }\n";

static GLuint compile(GLenum type, const char *src) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    GLint ok; glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) { char log[1024]; glGetShaderInfoLog(s, sizeof log, NULL, log); fprintf(stderr, "shader: %s\n", log); exit(1); }
    return s;
}

typedef struct {
    const char *name;
    int glFlush;      // glFlush before the acquire
    int acquire;      // acquire/release around the CL work
    int clFlush;      // clFlush after the release
    int clFinish;     // clFinish after the release (CPU waits for CL)
    int glOnly;       // reference: the "CL" pass is a second GL pass
    int perDispatch;  // kernels per bracket (batching: >1 shares one acquire/release)
    int skipGL;       // CL rounds only (no GL pass in between): cost of back-to-back brackets
} Strategy;

static GLuint gProg, gVAO, gFboA, gFboB, gTexA, gTexB;
static cl_command_queue gQ;
static cl_kernel gK;
static cl_mem gMA, gMB;
static size_t gLocalSize[2], *gLocal;   // TS_LOCAL=WxH: explicit work-group size (default: the driver picks)

static void glPass(GLuint fbo, GLuint src) {
    glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glViewport(0, 0, W, H);
    glUseProgram(gProg);
    glBindVertexArray(gVAO);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, src);
    glDrawArrays(GL_TRIANGLES, 0, 3);
}

static void reset(void) {
    float zero[4] = {0};
    glBindFramebuffer(GL_FRAMEBUFFER, gFboA); glClearBufferfv(GL_COLOR, 0, zero);
    glBindFramebuffer(GL_FRAMEBUFFER, gFboB); glClearBufferfv(GL_COLOR, 0, zero);
    glFinish();
}

static void readMinMax(GLuint tex, float *mn, float *mx) {
    float *px = malloc(sizeof(float) * W * H);
    glBindTexture(GL_TEXTURE_2D, tex);
    glGetTexImage(GL_TEXTURE_2D, 0, GL_RED, GL_FLOAT, px);
    *mn = INFINITY; *mx = -INFINITY;
    for (int i = 0; i < W * H; i++) { if (px[i] < *mn) *mn = px[i]; if (px[i] > *mx) *mx = px[i]; }
    free(px);
}

static int run(const Strategy *s, int rounds, int verbose) {
    reset();
    size_t g[2] = {W, H};
    cl_mem objs[2] = {gMA, gMB};
    double cpuCL = 0, cpuGL = 0, maxCL = 0;
    double t0 = now_ms();
    for (int r = 0; r < rounds; r++) {
        double a = now_ms();
        if (!s->skipGL) glPass(gFboA, gTexB);   // A = B + 1
        double b = now_ms();
        cpuGL += b - a;
        if (s->glOnly) {
            glPass(gFboB, gTexA);               // B = A + 1
            continue;
        }
        if (s->glFlush) glFlush();
        if (s->acquire) clEnqueueAcquireGLObjects(gQ, 2, objs, 0, NULL, NULL);
        for (int k = 0; k < s->perDispatch; k++) clEnqueueNDRangeKernel(gQ, gK, 2, NULL, g, gLocal, 0, NULL, NULL);
        if (s->acquire) clEnqueueReleaseGLObjects(gQ, 2, objs, 0, NULL, NULL);
        if (s->clFlush) clFlush(gQ);
        if (s->clFinish) clFinish(gQ);
        double c = now_ms() - b;
        cpuCL += c;
        if (c > maxCL) maxCL = c;
    }
    if (!s->glOnly) clFinish(gQ);
    glFinish();
    double wall = now_ms() - t0;
    float mnB, mxB, mnA, mxA;
    readMinMax(gTexB, &mnB, &mxB);
    readMinMax(gTexA, &mnA, &mxA);
    float expectB = s->skipGL ? 1 : 2.0f * rounds, expectA = s->skipGL ? 0 : 2.0f * rounds - 1;
    int ok = mnB == expectB && mxB == expectB && mnA == expectA && mxA == expectA;
    if (verbose)
        printf("%-34s wall %7.3f ms/round  cpu GL %6.3f  cpu CL %6.3f (max %6.3f)  B=[%g..%g] A=[%g..%g] %s\n", s->name,
               wall / rounds, cpuGL / rounds, cpuCL / rounds, maxCL, mnB, mxB, mnA, mxA, ok ? "ok" : "WRONG (expected B=2N)");
    return ok;
}

// Latency of one isolated round (CPU issues, then waits for everything): what a single dispatch costs a frame.
static void latency(const Strategy *s, int reps) {
    size_t g[2] = {W, H};
    cl_mem objs[2] = {gMA, gMB};
    double best = INFINITY, sum = 0;
    for (int i = 0; i < reps; i++) {
        glFinish();
        double t = now_ms();
        glPass(gFboA, gTexB);
        if (s->glOnly) glPass(gFboB, gTexA);
        else {
            if (s->glFlush) glFlush();
            clEnqueueAcquireGLObjects(gQ, 2, objs, 0, NULL, NULL);
            for (int k = 0; k < s->perDispatch; k++) clEnqueueNDRangeKernel(gQ, gK, 2, NULL, g, gLocal, 0, NULL, NULL);
            clEnqueueReleaseGLObjects(gQ, 2, objs, 0, NULL, NULL);
            clFlush(gQ);
            glPass(gFboA, gTexB);   // GL consumes the CL result
        }
        glFinish();
        if (!s->glOnly) clFinish(gQ);
        double d = now_ms() - t;
        sum += d;
        if (d < best) best = d;
    }
    printf("%-34s isolated round: best %6.3f ms, mean %6.3f ms\n", s->name, best, sum / reps);
}

// Where the CPU time of an implicit-sync round goes, call by call.
static void breakdown(int rounds, int glPassFirst) {
    size_t g[2] = {W, H};
    cl_mem objs[2] = {gMA, gMB};
    double t[6] = {0};
    reset();
    for (int r = 0; r < rounds; r++) {
        double a = now_ms();
        if (glPassFirst) glPass(gFboA, gTexB);
        double b = now_ms(); glFlush();
        double c = now_ms(); clEnqueueAcquireGLObjects(gQ, 2, objs, 0, NULL, NULL);
        double d = now_ms(); clEnqueueNDRangeKernel(gQ, gK, 2, NULL, g, gLocal, 0, NULL, NULL);
        double e = now_ms(); clEnqueueReleaseGLObjects(gQ, 2, objs, 0, NULL, NULL);
        double f = now_ms(); clFlush(gQ);
        double h = now_ms();
        t[0] += b - a; t[1] += c - b; t[2] += d - c; t[3] += e - d; t[4] += f - e; t[5] += h - f;
    }
    clFinish(gQ); glFinish();
    printf("per call (ms, %s): glPass %.3f  glFlush %.3f  acquire %.3f  ndrange %.3f  release %.3f  clFlush %.3f\n",
           glPassFirst ? "GL pass before" : "CL only", t[0] / rounds, t[1] / rounds, t[2] / rounds, t[3] / rounds, t[4] / rounds,
           t[5] / rounds);
}

int main(int argc, char **argv) { @autoreleasepool {
    int rounds = argc > 1 ? atoi(argv[1]) : 500;
    if (argc > 2) W = H = atoi(argv[2]);
    if (getenv("TS_LOCAL") && sscanf(getenv("TS_LOCAL"), "%zux%zu", &gLocalSize[0], &gLocalSize[1]) == 2) gLocal = gLocalSize;
    CGLPixelFormatAttribute attrs[] = { kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core,
                                        kCGLPFAAccelerated, kCGLPFANoRecovery, 0 };
    CGLPixelFormatObj pf; GLint npf; CGLChoosePixelFormat(attrs, &pf, &npf);
    CGLContextObj ctx; CGLCreateContext(pf, NULL, &ctx); CGLSetCurrentContext(ctx);
    printf("GL %s / %s, %dx%d R32F, %d rounds\n", glGetString(GL_VERSION), glGetString(GL_RENDERER), W, H, rounds);

    GLuint vs = compile(GL_VERTEX_SHADER, "#version 410\nvoid main(){ vec2 p = vec2((gl_VertexID<<1)&2, gl_VertexID&2);"
                                          " gl_Position = vec4(p*2.0-1.0, 0, 1); }\n");
    GLuint fs = compile(GL_FRAGMENT_SHADER, "#version 410\nuniform sampler2D s; out vec4 o;"
                                            " void main(){ o = vec4(texelFetch(s, ivec2(gl_FragCoord.xy), 0).x + 1.0, 0, 0, 1); }\n");
    gProg = glCreateProgram(); glAttachShader(gProg, vs); glAttachShader(gProg, fs); glLinkProgram(gProg);
    glGenVertexArrays(1, &gVAO);
    GLuint tex[2], fbo[2];
    glGenTextures(2, tex); glGenFramebuffers(2, fbo);
    for (int i = 0; i < 2; i++) {
        glBindTexture(GL_TEXTURE_2D, tex[i]);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_R32F, W, H, 0, GL_RED, GL_FLOAT, NULL);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
        glBindFramebuffer(GL_FRAMEBUFFER, fbo[i]);
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex[i], 0);
    }
    gTexA = tex[0]; gTexB = tex[1]; gFboA = fbo[0]; gFboB = fbo[1];
    glFinish();

    cl_context_properties p[] = { CL_CONTEXT_PROPERTY_USE_CGL_SHAREGROUP_APPLE, (cl_context_properties)CGLGetShareGroup(ctx), 0 };
    cl_int e; cl_context cl = clCreateContext(p, 0, NULL, NULL, NULL, &e);
    cl_device_id dev; clGetContextInfo(cl, CL_CONTEXT_DEVICES, sizeof dev, &dev, NULL);
    gQ = clCreateCommandQueue(cl, dev, 0, &e);
    cl_program pr = clCreateProgramWithSource(cl, 1, &kSrc, NULL, &e);
    if ((e = clBuildProgram(pr, 1, &dev, "", NULL, NULL))) { printf("build %d\n", e); return 1; }
    gK = clCreateKernel(pr, "inc", &e);

    // Cost of wrapping a GL object (what a per-dispatch clCreateFromGL* would add).
    double t = now_ms();
    for (int i = 0; i < 100; i++) {
        cl_mem m = clCreateFromGLTexture(cl, CL_MEM_READ_ONLY, GL_TEXTURE_2D, 0, gTexA, &e);
        clReleaseMemObject(m);
    }
    printf("clCreateFromGLTexture+release: %.3f ms each\n", (now_ms() - t) / 100);
    gMA = clCreateFromGLTexture(cl, CL_MEM_READ_ONLY, GL_TEXTURE_2D, 0, gTexA, &e);
    if (e) { printf("clCreateFromGLTexture(R32F) %d\n", e); return 1; }
    gMB = clCreateFromGLTexture(cl, CL_MEM_WRITE_ONLY, GL_TEXTURE_2D, 0, gTexB, &e);
    clSetKernelArg(gK, 0, sizeof gMA, &gMA);
    clSetKernelArg(gK, 1, sizeof gMB, &gMB);

    // Fixed overhead of an empty CL submission (no interop): the floor for any CL dispatch.
    cl_kernel nop = clCreateKernel(pr, "nop", &e);
    cl_mem dummy = clCreateBuffer(cl, CL_MEM_READ_WRITE, 64, NULL, &e);
    clSetKernelArg(nop, 0, sizeof dummy, &dummy);
    size_t one = 64;
    for (int i = 0; i < 10; i++) { clEnqueueNDRangeKernel(gQ, nop, 1, NULL, &one, NULL, 0, NULL, NULL); clFinish(gQ); }
    t = now_ms();
    for (int i = 0; i < 200; i++) { clEnqueueNDRangeKernel(gQ, nop, 1, NULL, &one, NULL, 0, NULL, NULL); clFinish(gQ); }
    printf("empty CL kernel + clFinish: %.3f ms\n", (now_ms() - t) / 200);
    t = now_ms();
    for (int i = 0; i < 200; i++) { glFlush(); glFinish(); }
    printf("glFlush + glFinish, idle: %.3f ms\n", (now_ms() - t) / 200);

    const Strategy S[] = {
        {"GL only (reference)",               0, 0, 0, 0, 1, 1},
        {"baseline: glFlush acq rel clFinish", 1, 1, 0, 1, 0, 1},
        {"implicit: glFlush acq rel clFlush",  1, 1, 1, 0, 0, 1},
        {"implicit, no glFlush",               0, 1, 1, 0, 0, 1},
        {"implicit, no clFlush",               1, 1, 0, 0, 0, 1},
        {"no acquire/release (illegal)",       1, 0, 1, 0, 0, 1},
        {"implicit, 4 kernels/bracket",        1, 1, 1, 0, 0, 4},
        {"implicit, 4 brackets (unbatched)",   1, 1, 1, 0, 0, 1},
    };
    int n = sizeof S / sizeof S[0];
    for (int i = 0; i < n; i++) run(&S[i], 20, 0);   // warm-up
    printf("\n-- chain of %d rounds (pipelined)\n", rounds);
    int fails = 0;
    for (int i = 0; i < n; i++) {
        if (i == n - 1) {
            // 4 separate brackets per round, same kernel count as the batched row.
            Strategy u = S[i];
            u.perDispatch = 1;
            reset();
            double t1 = now_ms(), cpu = 0;
            size_t g[2] = {W, H};
            cl_mem objs[2] = {gMA, gMB};
            for (int r = 0; r < rounds; r++) {
                glPass(gFboA, gTexB);
                double a = now_ms();
                for (int k = 0; k < 4; k++) {
                    glFlush();
                    clEnqueueAcquireGLObjects(gQ, 2, objs, 0, NULL, NULL);
                    clEnqueueNDRangeKernel(gQ, gK, 2, NULL, g, gLocal, 0, NULL, NULL);
                    clEnqueueReleaseGLObjects(gQ, 2, objs, 0, NULL, NULL);
                    clFlush(gQ);
                }
                cpu += now_ms() - a;
            }
            clFinish(gQ); glFinish();
            float mn, mx; readMinMax(gTexB, &mn, &mx);
            printf("%-34s wall %7.3f ms/round  cpu CL %6.3f  B=[%g..%g] %s\n", u.name, (now_ms() - t1) / rounds, cpu / rounds,
                   mn, mx, mn == 2.0f * rounds && mx == mn ? "ok" : "WRONG");
            continue;
        }
        if (!run(&S[i], rounds, 1) && i <= 4) fails++;
    }
    printf("\n");
    breakdown(rounds, 1);
    breakdown(rounds, 0);
    printf("\n-- isolated round (issue, then wait for GL to consume the CL result)\n");
    latency(&S[0], 100);
    latency(&S[1], 100);
    latency(&S[2], 100);
    latency(&S[3], 100);
    return fails ? 1 : 0;
}}
