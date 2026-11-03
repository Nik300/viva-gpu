#import <Foundation/Foundation.h>
#define GL_SILENCE_DEPRECATION 1
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#import <mach/mach_time.h>
static double nowUs(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return mach_absolute_time() * (double)tb.numer / tb.denom / 1e3; }
int main(void) { @autoreleasepool {
    CGLPixelFormatAttribute a[] = { kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core, kCGLPFAAccelerated, kCGLPFANoRecovery, 0 };
    CGLPixelFormatObj pf; GLint npf; CGLChoosePixelFormat(a, &pf, &npf);
    CGLContextObj ctx; CGLCreateContext(pf, NULL, &ctx); CGLSetCurrentContext(ctx);
    GLuint rt; glGenTextures(1, &rt); glBindTexture(GL_TEXTURE_2D, rt);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 256, 256, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL); glBindTexture(GL_TEXTURE_2D, 0);
    const int P = 10000; float c[4] = {0, 0, 0, 1};
    for (int mode = 0; mode < 2; mode++) {
        GLuint cached = 0, cvao = 0;
        if (mode) { glGenFramebuffers(1, &cached); glBindFramebuffer(GL_DRAW_FRAMEBUFFER, cached);
            glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, rt, 0); glGenVertexArrays(1, &cvao); }
        double t0 = nowUs();
        for (int p = 0; p < P; p++) {
            if (!mode) {
                GLuint fbo, vao; glGenFramebuffers(1, &fbo); glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbo);
                glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, rt, 0);
                GLenum db = GL_COLOR_ATTACHMENT0; glDrawBuffers(1, &db);
                (void)glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER);
                glGenVertexArrays(1, &vao); glBindVertexArray(vao);
                glClearBufferfv(GL_COLOR, 0, c);
                glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0); glBindVertexArray(0);
                glDeleteVertexArrays(1, &vao); glDeleteFramebuffers(1, &fbo);
            } else {
                glBindFramebuffer(GL_DRAW_FRAMEBUFFER, cached); glBindVertexArray(cvao);
                glClearBufferfv(GL_COLOR, 0, c);
            }
            if (p % 100 == 99) glFlush();
        }
        glFinish();
        printf("%s: %.2f us/pass\n", mode ? "cached FBO + VAO      " : "create/check/delete   ", (nowUs() - t0) / P);
    }
} return 0; }
