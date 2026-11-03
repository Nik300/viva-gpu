// Pure-GL floor for the "ui" workload of cpubench (2000 draws/frame, same state changes),
// to separate the driver's unavoidable cost from the shim's overhead.
//   full:    every draw re-applies everything, like TSGLRenderPass prepareDraw today
//   minimal: only the state that really changed; vertex-buffer offsets become `first`;
//            uniforms uploaded once per frame, one glBindBufferRange per draw
//   mintex:  minimal, plus identical setVertexBytes payloads deduplicated (no rebind)
#import <Foundation/Foundation.h>
#define GL_SILENCE_DEPRECATION 1
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#import <mach/mach_time.h>

static double nowUs(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return mach_absolute_time() * (double)tb.numer / tb.denom / 1e3; }
static GLuint sh(GLenum t, const char *s) { GLuint x = glCreateShader(t); glShaderSource(x, 1, &s, NULL); glCompileShader(x); return x; }
static GLuint prog(const char *fs) {
    const char *vs = "#version 410 core\nlayout(location=0) in vec2 p; layout(location=1) in vec2 uv; layout(location=2) in vec4 c;\n"
        "uniform vbuf1 { vec4 screen; }; out vec2 v_uv; out vec4 v_c;\n"
        "void main() { gl_Position = vec4(p / screen.xy * 2.0 - 1.0, 0.0, 1.0); v_uv = uv; v_c = c; }\n";
    GLuint p = glCreateProgram(); glAttachShader(p, sh(GL_VERTEX_SHADER, vs)); glAttachShader(p, sh(GL_FRAGMENT_SHADER, fs));
    glBindFragDataLocation(p, 0, "o0"); glLinkProgram(p);
    glUniformBlockBinding(p, glGetUniformBlockIndex(p, "vbuf1"), 1);
    glUseProgram(p); glUniform1i(glGetUniformLocation(p, "t"), 0);
    return p;
}

int main(int argc, char **argv) { @autoreleasepool {
    CGLPixelFormatAttribute a[] = { kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core, kCGLPFAAccelerated, kCGLPFANoRecovery, 0 };
    CGLPixelFormatObj pf; GLint npf; CGLChoosePixelFormat(a, &pf, &npf);
    CGLContextObj ctx; CGLCreateContext(pf, NULL, &ctx); CGLSetCurrentContext(ctx);
    if (argc > 1 && !strcmp(argv[1], "mt")) printf("multithreaded engine: %d\n", CGLEnable(ctx, kCGLCEMPEngine));
    GLuint p1 = prog("#version 410 core\nin vec2 v_uv; in vec4 v_c; uniform sampler2D t; out vec4 o0; void main() { o0 = v_c * texture(t, v_uv); }\n");
    GLuint p2 = prog("#version 410 core\nin vec2 v_uv; in vec4 v_c; uniform sampler2D t; out vec4 o0; void main() { o0 = v_c * texture(t, v_uv).r; }\n");
    GLuint fbo, rt; glGenFramebuffers(1, &fbo); glGenTextures(1, &rt);
    glBindTexture(GL_TEXTURE_2D, rt); glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 256, 256, 0, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, NULL);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbo); glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, rt, 0);
    GLuint tex[2]; glGenTextures(2, tex);
    for (int i = 0; i < 2; i++) { glBindTexture(GL_TEXTURE_2D, tex[i]); glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 256, 256, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL); glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0); }
    GLuint smp; glGenSamplers(1, &smp); glSamplerParameteri(smp, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    const int D = 2000, F = 200;
    GLuint vb; glGenBuffers(1, &vb); glBindBuffer(GL_ARRAY_BUFFER, vb); glBufferData(GL_ARRAY_BUFFER, D * 120, NULL, GL_DYNAMIC_DRAW);
    void *cpu = calloc(D, 120);
    GLuint ring; glGenBuffers(1, &ring); glBindBuffer(GL_UNIFORM_BUFFER, ring); glBufferData(GL_UNIFORM_BUFFER, 4 << 20, NULL, GL_STREAM_DRAW);
    GLuint vao; glGenVertexArrays(1, &vao); glBindVertexArray(vao);
    float screen[4] = { 256, 256, 0, 0 };
    const char *modes[] = { "full", "minimal", "mindedup" };
    for (int mode = 0; mode < 3; mode++) {
        double t0 = nowUs();
        for (int f = 0; f < F; f++) {
            glBindBuffer(GL_ARRAY_BUFFER, vb); glBufferData(GL_ARRAY_BUFFER, D * 120, cpu, GL_DYNAMIC_DRAW);   // per-frame vertex upload (both modes)
            glClearColor(0, 0, 0, 1); glClear(GL_COLOR_BUFFER_BIT);
            GLuint curProg = 0, curTex = 0;
            if (mode >= 1) {   // one upload for the whole frame's uniforms
                glBindBuffer(GL_UNIFORM_BUFFER, ring); glBufferData(GL_UNIFORM_BUFFER, 4 << 20, NULL, GL_STREAM_DRAW);
                void *m = glMapBufferRange(GL_UNIFORM_BUFFER, 0, D * 256, GL_MAP_WRITE_BIT | GL_MAP_INVALIDATE_BUFFER_BIT | GL_MAP_UNSYNCHRONIZED_BIT);
                for (int d = 0; d < D; d++) memcpy((char *)m + d * 256, screen, 16);
                glUnmapBuffer(GL_UNIFORM_BUFFER);
                glBindBuffer(GL_ARRAY_BUFFER, vb);
                glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 20, (void *)0); glEnableVertexAttribArray(0);
                glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 20, (void *)8); glEnableVertexAttribArray(1);
                glVertexAttribPointer(2, 4, GL_UNSIGNED_BYTE, GL_TRUE, 20, (void *)16); glEnableVertexAttribArray(2);
                for (int i = 3; i < 16; i++) glDisableVertexAttribArray(i);
                glBindSampler(0, smp); glEnable(GL_SCISSOR_TEST); glEnablei(GL_BLEND, 0); glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
                if (mode == 2) glBindBufferRange(GL_UNIFORM_BUFFER, 1, ring, 0, 16);
            }
            for (int d = 0; d < D; d++) {
                GLuint prg = (d / 10) & 1 ? p2 : p1, tx = (d & 1) ? tex[0] : tex[1];
                if (mode == 0) {
                    // what prepareDraw does today: everything, every draw
                    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbo);
                    glUseProgram(prg);
                    glBindBuffer(GL_UNIFORM_BUFFER, ring);
                    static GLintptr off; if (off + 256 > (4 << 20)) { glBufferData(GL_UNIFORM_BUFFER, 4 << 20, NULL, GL_STREAM_DRAW); off = 0; }
                    glBufferSubData(GL_UNIFORM_BUFFER, off, 16, screen);
                    glBindBufferRange(GL_UNIFORM_BUFFER, 1, ring, off, 16); off += 256;
                    glActiveTexture(GL_TEXTURE0 + 79); glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, tx); glBindSampler(0, smp); glActiveTexture(GL_TEXTURE0);
                    glBindVertexArray(vao);
                    glBindBuffer(GL_ARRAY_BUFFER, vb);
                    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 20, (void *)(intptr_t)(d * 120)); glVertexAttribDivisor(0, 0); glEnableVertexAttribArray(0);
                    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 20, (void *)(intptr_t)(d * 120 + 8)); glVertexAttribDivisor(1, 0); glEnableVertexAttribArray(1);
                    glVertexAttribPointer(2, 4, GL_UNSIGNED_BYTE, GL_TRUE, 20, (void *)(intptr_t)(d * 120 + 16)); glVertexAttribDivisor(2, 0); glEnableVertexAttribArray(2);
                    for (int i = 3; i < 16; i++) glDisableVertexAttribArray(i);
                    glViewportIndexedf(0, 0, 0, 256, 256); glDepthRange(0, 1);
                    glEnable(GL_SCISSOR_TEST); glScissor(d % 200, d % 100, 50, 50);
                    glDisable(GL_CULL_FACE); glFrontFace(GL_CCW); glPolygonMode(GL_FRONT_AND_BACK, GL_FILL);
                    glDisable(GL_POLYGON_OFFSET_FILL); glDisable(GL_POLYGON_OFFSET_LINE); glDisable(GL_DEPTH_CLAMP);
                    glDisable(GL_DEPTH_TEST); glDepthMask(GL_FALSE); glDisable(GL_STENCIL_TEST);
                    for (int i = 0; i < 8; i++) { glColorMaski(i, 1, 1, 1, 1); if (i == 0) { glEnablei(GL_BLEND, 0); glBlendEquationSeparatei(0, GL_FUNC_ADD, GL_FUNC_ADD);
                        glBlendFuncSeparatei(0, GL_ONE, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ZERO); } else glDisablei(GL_BLEND, i); }
                    glBlendColor(0, 0, 0, 0); glDisable(GL_MULTISAMPLE); glDisable(GL_SAMPLE_ALPHA_TO_COVERAGE);
                    glDrawArraysInstanced(GL_TRIANGLES, 0, 6, 1);
                } else {
                    if (prg != curProg) { glUseProgram(prg); curProg = prg; }
                    if (tx != curTex) { glBindTexture(GL_TEXTURE_2D, tx); curTex = tx; }
                    if (mode == 1) glBindBufferRange(GL_UNIFORM_BUFFER, 1, ring, d * 256, 16);
                    glScissor(d % 200, d % 100, 50, 50);
                    glDrawArrays(GL_TRIANGLES, d * 6, 6);   // offset d*120 = 6 vertices of stride 20 -> `first`
                }
            }
            glFlush();
        }
        glFinish();
        double us = nowUs() - t0;
        printf("%-9s %.2f us/draw  (%.1f ms/frame)\n", modes[mode], us / F / D, us / F / 1e3);
    }
} return 0; }
