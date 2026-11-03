// Compute C0.1: do GL buffers written by CL read back right on the GPU, the way the core reads Metal buffers?
// Round: a fragment pass reads buf0 through a texture buffer (the core's `device` path) into a R32F texture,
// which is checked; transform feedback writes buf1 = buf0 + 1 (vertex attribute read); CL writes buf0 = buf1 + 1.
// "waits": glFinish / clFinish at each step (cache/copy coherence only); "pipelined": the runtime's handoff
// (glFlush before the acquire, nothing after the release), checked every round.
// Note: a texture buffer read from the *vertex* shader during transform feedback returns stale/zero texels past
// ~16K-28K points even without CL on this driver; that is why the consumer here is a fragment pass.
// Build: make build/bufcoherence   Run: build/bufcoherence [rounds] [floats...]
#define GL_SILENCE_DEPRECATION
#define CL_SILENCE_DEPRECATION
#import <Foundation/Foundation.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#import <OpenCL/opencl.h>

static GLuint gProgFrag, gProgTF, gVAO, gVAOAttrib, gTex, gFbo;
static cl_context gCL;
static cl_command_queue gQ;
static cl_kernel gK;
enum { TW = 1024 };   // fragment pass target width; height = n / TW

static GLuint shader(GLenum type, const char *src) {
    GLuint s = glCreateShader(type);
    glShaderSource(s, 1, &src, NULL);
    glCompileShader(s);
    return s;
}

// Errors in `rounds` rounds: TBO reads in the fragment pass (core path) and final buffer value.
static void chain(int n, int pipelined, int rounds, int *tboBad, int *bufBad) {
    GLuint buf[2], tbo;
    glGenBuffers(2, buf);
    float *zero = calloc(n, 4);
    for (int i = 0; i < 2; i++) { glBindBuffer(GL_ARRAY_BUFFER, buf[i]); glBufferData(GL_ARRAY_BUFFER, n * 4, zero, GL_DYNAMIC_COPY); }
    free(zero);
    glGenTextures(1, &tbo);
    glBindTexture(GL_TEXTURE_BUFFER, tbo);
    glTexBuffer(GL_TEXTURE_BUFFER, GL_R32F, buf[0]);
    int th = n / TW;
    glBindTexture(GL_TEXTURE_2D, gTex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_R32F, TW, th, 0, GL_RED, GL_FLOAT, NULL);
    glBindFramebuffer(GL_FRAMEBUFFER, gFbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, gTex, 0);
    glFinish();
    cl_int e;
    cl_mem m[2];
    for (int i = 0; i < 2; i++) m[i] = clCreateFromGLBuffer(gCL, CL_MEM_READ_WRITE, buf[i], &e);
    size_t g = n;
    float *px = malloc(n * 4);
    *tboBad = *bufBad = 0;
    for (int r = 0; r < rounds; r++) {
        float expect = 2.0f * r;
        // GL fragment pass: tex = buf0 (texture buffer), checked below
        glUseProgram(gProgFrag);
        glBindVertexArray(gVAO);
        glViewport(0, 0, TW, th);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_BUFFER, tbo);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        // GL transform feedback: buf1 = buf0 + 1
        glUseProgram(gProgTF);
        glBindVertexArray(gVAOAttrib);
        glBindBuffer(GL_ARRAY_BUFFER, buf[0]);
        glVertexAttribPointer(0, 1, GL_FLOAT, GL_FALSE, 4, 0);
        glEnable(GL_RASTERIZER_DISCARD);
        glBindBufferBase(GL_TRANSFORM_FEEDBACK_BUFFER, 0, buf[1]);
        glBeginTransformFeedback(GL_POINTS);
        glDrawArrays(GL_POINTS, 0, n);
        glEndTransformFeedback();
        glBindBufferBase(GL_TRANSFORM_FEEDBACK_BUFFER, 0, 0);
        glDisable(GL_RASTERIZER_DISCARD);
        // Check what the fragment pass saw (blocks: done before the CL step so the CL write cannot race the read).
        glBindTexture(GL_TEXTURE_2D, gTex);
        glGetTexImage(GL_TEXTURE_2D, 0, GL_RED, GL_FLOAT, px);
        for (int i = 0; i < n; i++) if (px[i] != expect) { (*tboBad)++; break; }
        if (pipelined) glFlush(); else glFinish();
        // CL: buf0 = buf1 + 1
        clEnqueueAcquireGLObjects(gQ, 2, m, 0, NULL, NULL);
        clSetKernelArg(gK, 0, sizeof m[1], &m[1]);
        clSetKernelArg(gK, 1, sizeof m[0], &m[0]);
        clEnqueueNDRangeKernel(gQ, gK, 1, NULL, &g, NULL, 0, NULL, NULL);
        clEnqueueReleaseGLObjects(gQ, 2, m, 0, NULL, NULL);
        if (!pipelined) clFinish(gQ);
    }
    glBindBuffer(GL_COPY_READ_BUFFER, buf[0]);
    glGetBufferSubData(GL_COPY_READ_BUFFER, 0, n * 4, px);
    for (int i = 0; i < n; i++) if (px[i] != 2.0f * rounds) { (*bufBad)++; break; }
    free(px);
    clReleaseMemObject(m[0]);
    clReleaseMemObject(m[1]);
    glDeleteTextures(1, &tbo);
    glDeleteBuffers(2, buf);
}

int main(int argc, char **argv) { @autoreleasepool {
    int rounds = argc > 1 ? atoi(argv[1]) : 40;
    CGLPixelFormatAttribute at[] = { kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core, kCGLPFAAccelerated, 0 };
    CGLPixelFormatObj pf; GLint npf; CGLChoosePixelFormat(at, &pf, &npf);
    CGLContextObj ctx; CGLCreateContext(pf, NULL, &ctx); CGLSetCurrentContext(ctx);
    gProgFrag = glCreateProgram();
    glAttachShader(gProgFrag, shader(GL_VERTEX_SHADER, "#version 410\nvoid main(){ vec2 p = vec2((gl_VertexID<<1)&2, gl_VertexID&2);"
                                                        " gl_Position = vec4(p*2.0-1.0, 0, 1); }\n"));
    glAttachShader(gProgFrag, shader(GL_FRAGMENT_SHADER, "#version 410\nuniform samplerBuffer s; out vec4 o; void main(){"
                                                          " ivec2 g = ivec2(gl_FragCoord.xy); o = vec4(texelFetch(s, g.y * 1024 + g.x).x, 0, 0, 1); }\n"));
    glLinkProgram(gProgFrag);
    gProgTF = glCreateProgram();
    glAttachShader(gProgTF, shader(GL_VERTEX_SHADER, "#version 410\nin float a; out float v; void main(){ v = a + 1.0; }\n"));
    const char *vy[] = {"v"};
    glTransformFeedbackVaryings(gProgTF, 1, vy, GL_INTERLEAVED_ATTRIBS);
    glBindAttribLocation(gProgTF, 0, "a");
    glLinkProgram(gProgTF);
    glGenVertexArrays(1, &gVAO);
    glGenVertexArrays(1, &gVAOAttrib);
    glBindVertexArray(gVAOAttrib);
    glEnableVertexAttribArray(0);
    glGenTextures(1, &gTex);
    glGenFramebuffers(1, &gFbo);

    cl_context_properties p[] = { CL_CONTEXT_PROPERTY_USE_CGL_SHAREGROUP_APPLE, (cl_context_properties)CGLGetShareGroup(ctx), 0 };
    cl_int e;
    gCL = clCreateContext(p, 0, NULL, NULL, NULL, &e);
    cl_device_id dev; clGetContextInfo(gCL, CL_CONTEXT_DEVICES, sizeof dev, &dev, NULL);
    gQ = clCreateCommandQueue(gCL, dev, 0, &e);
    const char *src = "__kernel void incb(__global const float *s, __global float *d) { size_t i = get_global_id(0); d[i] = s[i] + 1.0f; }\n";
    cl_program pr = clCreateProgramWithSource(gCL, 1, &src, NULL, &e);
    clBuildProgram(pr, 1, &dev, "", NULL, NULL);
    gK = clCreateKernel(pr, "incb", &e);

    int sizes[] = {1024, 16 * 1024, 64 * 1024, 256 * 1024, 1024 * 1024};
    for (int i = 2; i < argc && i < 7; i++) sizes[i - 2] = atoi(argv[i]) / TW * TW;
    printf("rounds with a wrong read, of %d (texture buffer in a fragment pass / buffer at the end)\n", rounds);
    printf("%-10s", "");
    for (int s = 0; s < 5; s++) printf(" %10d", sizes[s]);
    printf("  (floats)\n");
    int fails = 0;
    for (int mode = 0; mode < 2; mode++) {
        printf("%-10s", mode ? "pipelined" : "waits");
        for (int s = 0; s < 5; s++) {
            int tb, bb;
            chain(sizes[s], mode, rounds, &tb, &bb);
            printf(" %6d / %d", tb, bb);
            fails += tb + bb;
        }
        printf("\n");
    }
    return fails ? 1 : 0;
}}
