// Compute: TSCLRuntime (src/compute) against the handoff strategies it replaces, and its correctness.
// Frame = GL pass, D CL dispatches ping-ponging two 1024² R32F textures, GL pass consuming the result,
// then the command buffer's GL fence; each pass/kernel adds 1, so after F frames B = F*(1+D), A = B + 1 exactly.
// Strategies: the same work as GL passes only (reference), one bracket + clFinish per dispatch (the
// 0.2 ms assumed by the plan), one bracket per dispatch without waiting, and the runtime (one run per frame).
// Also: buffers through transform feedback <-> CL kernels, a 10.000-dispatch stress without any CPU wait,
// and the cl_mem cache across a GL texture deleted and recreated under the same name.
// Build: make build/clruntime   Run: build/clruntime [frames] [size]   (exit status 1 on any wrong result)
#import <Foundation/Foundation.h>
#import <mach/mach_time.h>
#include "../../src/compute/TSCLRuntime.h"

static int W = 1024, H = 1024;
static const size_t kLocal[2] = {16, 16};   // 2D tiles: the driver's default (1D strips) halves image throughput

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
    "__kernel void incb(__global const float *s, __global float *d) { size_t i = get_global_id(0); d[i] = s[i] + 1.0f; }\n";

static void logLine(void *ctx, TSCLLogLevel level, const char *msg) { fprintf(stderr, "[compute] %s\n", msg); }

static GLuint compile(GLenum type, const char *src) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    GLint ok; glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) { char log[1024]; glGetShaderInfoLog(s, sizeof log, NULL, log); fprintf(stderr, "shader: %s\n", log); exit(1); }
    return s;
}

static TSCLRuntime *gRT;
static int gQuiet;
static int gEncodeDraws;   // TS_ENCODE=n: the consuming pass also issues n small draws, like a real render pass
static cl_kernel gInc, gIncB;
static GLuint gProg, gVAO, gTex[2], gFbo[2];

static GLuint newTexture(void) {
    GLuint t;
    glGenTextures(1, &t);
    glBindTexture(GL_TEXTURE_2D, t);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_R32F, W, H, 0, GL_RED, GL_FLOAT, NULL);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    return t;
}

static void attach(int i) {
    glBindFramebuffer(GL_FRAMEBUFFER, gFbo[i]);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, gTex[i], 0);
}

// GL: tex[dst] = tex[src] + 1
static void glPass(int dst) {
    glBindFramebuffer(GL_FRAMEBUFFER, gFbo[dst]);
    glViewport(0, 0, W, H);
    glUseProgram(gProg);
    glBindVertexArray(gVAO);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, gTex[1 - dst]);
    glDrawArrays(GL_TRIANGLES, 0, 3);
}

// The consuming pass: A = B + 1, plus gEncodeDraws one-pixel draws of the same (idempotent) pass for CPU encode cost.
static void consumerPass(void) {
    glPass(0);
    for (int i = 0; i < gEncodeDraws; i++) {
        glBindTexture(GL_TEXTURE_2D, gTex[1]);
        glViewport(i % 7, i % 5, 1, 1);
        glDrawArrays(GL_TRIANGLES, 0, 3);
    }
}

static void reset(void) {
    float zero[4] = {0};
    for (int i = 0; i < 2; i++) { glBindFramebuffer(GL_FRAMEBUFFER, gFbo[i]); glClearBufferfv(GL_COLOR, 0, zero); }
    glFinish();
}

static int check(int tex, float expect, const char *what) {
    float *px = malloc(sizeof(float) * W * H), mn = INFINITY, mx = -INFINITY;
    glBindTexture(GL_TEXTURE_2D, gTex[tex]);
    glGetTexImage(GL_TEXTURE_2D, 0, GL_RED, GL_FLOAT, px);
    for (int i = 0; i < W * H; i++) { mn = fminf(mn, px[i]); mx = fmaxf(mx, px[i]); }
    free(px);
    if (mn == expect && mx == expect) return 1;
    printf("   WRONG %s: [%g..%g], expected %g\n", what, mn, mx, expect);
    return 0;
}

typedef enum { GLOnly, PerDispatchFinish, PerDispatch, Runtime, RuntimeAsync, ModeCount } Mode;
static const char *kModeName[] = {"GL only (reference)", "per dispatch + clFinish", "per dispatch, no wait", "runtime: one run per frame",
                                  "runtime, asynchronous submit"};

// Completion as the core does it (B2): a fence after the command buffer, polled without blocking.
typedef struct { GLsync fences[64]; int head, tail; } Fences;
static void fenceFrame(Fences *f) {
    f->fences[f->tail++ % 64] = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    glFlush();
    while (f->head < f->tail && (f->tail - f->head >= 3 || glClientWaitSync(f->fences[f->head % 64], 0, 0) != GL_TIMEOUT_EXPIRED)) {
        if (f->tail - f->head >= 3) glClientWaitSync(f->fences[f->head % 64], 0, UINT64_MAX);   // 3 frames in flight, like a layer
        glDeleteSync(f->fences[f->head++ % 64]);
    }
}

// One CL dispatch tex[dst] = tex[1-dst] + 1 under the given strategy.
static void clDispatch(Mode m, int dst) {
    TSCLGLObject objs[2] = {{gTex[1 - dst], GL_TEXTURE_2D, 0}, {gTex[dst], GL_TEXTURE_2D, 0}};
    cl_mem mem[2];
    size_t g[2] = {W, H};
    TSCLRuntimeUse(gRT, objs, 2, mem);
    clSetKernelArg(gInc, 0, sizeof mem[0], &mem[0]);
    clSetKernelArg(gInc, 1, sizeof mem[1], &mem[1]);
    TSCLRuntimeDispatch(gRT, gInc, 2, NULL, g, kLocal);
    if (m == PerDispatch || m == PerDispatchFinish) TSCLRuntimeEndRun(gRT);
    if (m == PerDispatchFinish) clFinish(TSCLRuntimeQueue(gRT));
}

static int frames(Mode m, int nframes, int D, double *perFrame, double *cpuPerFrame) {
    reset();
    Fences f = {0};
    TSCLStats s0 = TSCLRuntimeGetStats(gRT);
    double t0 = now_ms(), cpu = 0;
    for (int fr = 0; fr < nframes; fr++) {
        double a = now_ms();
        glPass(0);                                   // A = B + 1
        for (int d = 0; d < D; d++) {
            int dst = d % 2 == 0 ? 1 : 0;            // B = A + 1, A = B + 1, ... (D odd: ends on B)
            if (m == GLOnly) glPass(dst); else clDispatch(m, dst);
        }
        // The next GL command ends the run: here a pass consuming the CL result, as a render pass would.
        if (m == RuntimeAsync) TSCLRuntimeEndRunAsync(gRT); else TSCLRuntimeEndRun(gRT);
        consumerPass();                              // A = B + 1
        TSCLRuntimeWaitSubmitted(gRT);               // before the command buffer's flush + fence
        fenceFrame(&f);
        cpu += now_ms() - a;
    }
    glFinish();
    double wall = now_ms() - t0;
    while (f.head < f.tail) glDeleteSync(f.fences[f.head++ % 64]);
    TSCLStats s1 = TSCLRuntimeGetStats(gRT);
    *perFrame = wall / nframes;
    *cpuPerFrame = cpu / nframes;
    int ok = check(1, (float)nframes * (1 + D), "B") & check(0, (float)nframes * (1 + D) + 1, "A");
    if (!gQuiet || !ok) printf("  %-30s %7.3f ms/frame  (issuing thread %6.3f)  submissions/frame %.1f  %s\n", kModeName[m], *perFrame, *cpuPerFrame,
           m == GLOnly ? 0.0 : (double)(s1.runs - s0.runs) / nframes, ok ? "ok" : "WRONG");
    if (!gQuiet && m == RuntimeAsync)
        printf("  %30s submission %.3f ms/frame on the submitter, GPU queue blocked %.3f ms/frame waiting for it\n", "",
               (double)(s1.submitMicros - s0.submitMicros) / 1000 / nframes, (double)(s1.blockedMicros - s0.blockedMicros) / 1000 / nframes);
    return ok;
}

// Buffers: GL transform feedback (buf1 = buf0 + 1) <-> CL kernel (buf0 = buf1 + 1) on the same GL buffers.
static int buffers(int rounds, int useRuntimeRuns) {
    enum { N = 256 * 1024 };
    static GLuint prog, vao, buf[2];
    if (!prog) {
        // Transform feedback reads src as a vertex attribute: a texture buffer read from the vertex shader during
        // transform feedback returns stale texels past ~16K points on this driver even without CL (bufcoherence.m).
        GLuint vs = compile(GL_VERTEX_SHADER, "#version 410\nin float a; out float v; void main(){ v = a + 1.0; }\n");
        prog = glCreateProgram(); glAttachShader(prog, vs);
        const char *varyings[] = {"v"};
        glTransformFeedbackVaryings(prog, 1, varyings, GL_INTERLEAVED_ATTRIBS);
        glBindAttribLocation(prog, 0, "a");
        glLinkProgram(prog);
        glGenVertexArrays(1, &vao);
        glBindVertexArray(vao);
        glEnableVertexAttribArray(0);
        glGenBuffers(2, buf);
        for (int i = 0; i < 2; i++) { glBindBuffer(GL_ARRAY_BUFFER, buf[i]); glBufferData(GL_ARRAY_BUFFER, N * 4, NULL, GL_DYNAMIC_COPY); }
    }
    float *zero = calloc(N, 4);
    for (int i = 0; i < 2; i++) { glBindBuffer(GL_ARRAY_BUFFER, buf[i]); glBufferSubData(GL_ARRAY_BUFFER, 0, N * 4, zero); }
    free(zero);
    Fences f = {0};
    double t0 = now_ms();
    for (int r = 0; r < rounds; r++) {
        // GL: buf1 = buf0 + 1
        glUseProgram(prog); glBindVertexArray(vao);
        glBindBuffer(GL_ARRAY_BUFFER, buf[0]); glVertexAttribPointer(0, 1, GL_FLOAT, GL_FALSE, 4, 0);
        glEnable(GL_RASTERIZER_DISCARD);
        glBindBufferBase(GL_TRANSFORM_FEEDBACK_BUFFER, 0, buf[1]);
        glBeginTransformFeedback(GL_POINTS); glDrawArrays(GL_POINTS, 0, N); glEndTransformFeedback();
        glBindBufferBase(GL_TRANSFORM_FEEDBACK_BUFFER, 0, 0);
        glDisable(GL_RASTERIZER_DISCARD);
        // CL: buf0 = buf1 + 1, twice through the same objects in one run (second is idempotent on the values)
        TSCLGLObject objs[2] = {{buf[1], 0, 0}, {buf[0], 0, 0}};
        cl_mem mem[2];
        size_t g = N, l = 64;
        for (int k = 0; k < 2; k++) {
            TSCLRuntimeUse(gRT, objs, 2, mem);
            clSetKernelArg(gIncB, 0, sizeof mem[0], &mem[0]);
            clSetKernelArg(gIncB, 1, sizeof mem[1], &mem[1]);
            TSCLRuntimeDispatch(gRT, gIncB, 1, NULL, &g, &l);
            if (!useRuntimeRuns) TSCLRuntimeEndRun(gRT);
        }
        TSCLRuntimeEndRun(gRT);
        fenceFrame(&f);
    }
    glFinish();
    double wall = now_ms() - t0;
    while (f.head < f.tail) glDeleteSync(f.fences[f.head++ % 64]);
    float *out = malloc(N * 4), mn = INFINITY, mx = -INFINITY;
    glBindBuffer(GL_COPY_READ_BUFFER, buf[0]);
    glGetBufferSubData(GL_COPY_READ_BUFFER, 0, N * 4, out);
    for (int i = 0; i < N; i++) { mn = fminf(mn, out[i]); mx = fmaxf(mx, out[i]); }
    free(out);
    int ok = mn == 2.0f * rounds && mx == mn;
    printf("  buffers %s: %d rounds, %.3f ms/round, buf0=[%g..%g] %s\n", useRuntimeRuns ? "one run per round" : "run per dispatch",
           rounds, wall / rounds, mn, mx, ok ? "ok" : "WRONG (expected 2N)");
    return ok;
}

// The core recreates a texture: GL recycles the name, the cache must not hand out the old cl_mem.
static int recycle(void) {
    GLuint old = gTex[1];
    TSCLRuntimeForget(gRT, old, GL_TEXTURE_2D);
    glDeleteTextures(1, &gTex[1]);
    gTex[1] = newTexture();
    attach(1);
    reset();
    double pf, cpu;
    int ok = frames(Runtime, 10, 3, &pf, &cpu);
    printf("  texture recreated (name %u -> %u): %s\n", old, gTex[1], ok ? "ok" : "WRONG");
    return ok;
}

int main(int argc, char **argv) { @autoreleasepool {
    int nframes = argc > 1 ? atoi(argv[1]) : 300;
    if (argc > 2) W = H = atoi(argv[2]);
    if (getenv("TS_ENCODE")) gEncodeDraws = atoi(getenv("TS_ENCODE"));
    CGLPixelFormatAttribute attrs[] = { kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core,
                                        kCGLPFAAccelerated, kCGLPFANoRecovery, 0 };
    CGLPixelFormatObj pixfmt; GLint npf; CGLChoosePixelFormat(attrs, &pixfmt, &npf);
    CGLContextObj ctx; CGLCreateContext(pixfmt, NULL, &ctx); CGLSetCurrentContext(ctx);
    printf("GL %s / %s, %dx%d R32F, %d frames, %d draws in the consuming pass%s\n", glGetString(GL_VERSION), glGetString(GL_RENDERER),
           W, H, nframes, gEncodeDraws, getenv("TSCL_RELEASE_FLUSH") ? ", TSCL_RELEASE_FLUSH" : "");

    gProg = glCreateProgram();
    glAttachShader(gProg, compile(GL_VERTEX_SHADER, "#version 410\nvoid main(){ vec2 p = vec2((gl_VertexID<<1)&2, gl_VertexID&2);"
                                                    " gl_Position = vec4(p*2.0-1.0, 0, 1); }\n"));
    glAttachShader(gProg, compile(GL_FRAGMENT_SHADER, "#version 410\nuniform sampler2D s; out vec4 o;"
                                                      " void main(){ o = vec4(texelFetch(s, ivec2(gl_FragCoord.xy), 0).x + 1.0, 0, 0, 1); }\n"));
    glLinkProgram(gProg);
    glGenVertexArrays(1, &gVAO);
    glGenFramebuffers(2, gFbo);
    for (int i = 0; i < 2; i++) { gTex[i] = newTexture(); attach(i); }
    glFinish();

    TSCLRuntimeConfig cfg = { CGLGetShareGroup(ctx), logLine, NULL };
    gRT = TSCLRuntimeCreate(&cfg);
    if (!gRT) return 1;
    cl_int e;
    cl_device_id dev = TSCLRuntimeDevice(gRT);
    cl_program pr = clCreateProgramWithSource(TSCLRuntimeContext(gRT), 1, &kSrc, NULL, &e);
    if ((e = clBuildProgram(pr, 1, &dev, "", NULL, NULL))) { printf("build %d\n", e); return 1; }
    gInc = clCreateKernel(pr, "inc", &e);
    gIncB = clCreateKernel(pr, "incb", &e);

    int ok = 1;
    double pf, cpu, ref[8], refCPU[8];
    const int Ds[] = {1, 3, 7};
    gQuiet = 1;
    for (int m = 0; m < ModeCount; m++) frames(m, 10, 3, &pf, &cpu);   // warm-up
    gQuiet = 0;
    printf("\n-- frame: GL pass, D dispatches, GL pass, fence (%d frames)\n", nframes);
    for (int di = 0; di < 3; di++) {
        int D = Ds[di];
        printf(" D = %d\n", D);
        for (int m = 0; m < ModeCount; m++) {
            ok &= frames(m, nframes, D, &pf, &cpu);
            if (m == GLOnly) { ref[di] = pf; refCPU[di] = cpu; }
            else printf("  %30s overhead vs GL: %+.3f ms/frame on the GPU timeline, %+.3f ms on the issuing thread\n", "",
                        pf - ref[di], cpu - refCPU[di]);
        }
    }

    printf("\n-- buffers (transform feedback <-> CL)\n");
    ok &= buffers(200, 0);
    ok &= buffers(200, 1);

    printf("\n-- stress: 10.000 dispatches between render passes, no CPU wait\n");
    TSCLStats s0 = TSCLRuntimeGetStats(gRT);
    ok &= frames(Runtime, 1000, 5, &pf, &cpu);
    ok &= frames(RuntimeAsync, 1000, 5, &pf, &cpu);
    ok &= buffers(2500, 1);
    TSCLStats s1 = TSCLRuntimeGetStats(gRT);
    printf("  %llu dispatches in %llu submissions, %.3f ms CPU per submission, %llu wraps total, %llu errors\n",
           s1.dispatches - s0.dispatches, s1.runs - s0.runs, (double)(s1.submitMicros - s0.submitMicros) / 1000 / (s1.runs - s0.runs),
           s1.wraps, s1.errors);
    ok &= s1.errors == 0;

    printf("\n-- cl_mem cache\n");
    ok &= recycle();

    TSCLRuntimeDestroy(gRT);
    printf("\n%s\n", ok ? "compute runtime: all ok" : "compute runtime: FAILURES");
    return ok ? 0 : 1;
}}
