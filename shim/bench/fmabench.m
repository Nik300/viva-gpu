#import <Foundation/Foundation.h>
#define GL_SILENCE_DEPRECATION 1
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
static GLuint sh(GLenum t, const char *s) { GLuint x = glCreateShader(t); glShaderSource(x, 1, &s, NULL); glCompileShader(x);
    GLint ok; glGetShaderiv(x, GL_COMPILE_STATUS, &ok); if (!ok) { char l[4096]; glGetShaderInfoLog(x, 4096, 0, l); puts(l); } return x; }
static double run(const char *body) {
    char fs[4096];
    snprintf(fs, sizeof fs, "#version 410 core\nout vec4 o0; uniform vec4 k;\nvoid main() { vec4 a = gl_FragCoord.xyxy * 0.001, b = k, c = k.wzyx;\n"
             "  for (int i = 0; i < 64; i++) { %s }\n  o0 = a; }\n", body);
    const char *vs = "#version 410 core\nvoid main() { vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2); gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0); }\n";
    GLuint p = glCreateProgram(); glAttachShader(p, sh(GL_VERTEX_SHADER, vs)); glAttachShader(p, sh(GL_FRAGMENT_SHADER, fs)); glLinkProgram(p); glUseProgram(p);
    glUniform4f(glGetUniformLocation(p, "k"), 0.999f, 0.5f, 0.25f, 1.001f);
    glDrawArrays(GL_TRIANGLES, 0, 3); glFinish();
    GLuint q; glGenQueries(1, &q); double best = 1e9;
    for (int r = 0; r < 5; r++) { glBeginQuery(GL_TIME_ELAPSED, q); for (int i = 0; i < 10; i++) glDrawArrays(GL_TRIANGLES, 0, 3);
        glEndQuery(GL_TIME_ELAPSED); GLuint64 ns; glGetQueryObjectui64v(q, GL_QUERY_RESULT, &ns); best = MIN(best, ns / 1e7); }
    return best;
}
int main(void) { @autoreleasepool {
    CGLPixelFormatAttribute a[] = { kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core, kCGLPFAAccelerated, kCGLPFANoRecovery, 0 };
    CGLPixelFormatObj pf; GLint npf; CGLChoosePixelFormat(a, &pf, &npf);
    CGLContextObj ctx; CGLCreateContext(pf, NULL, &ctx); CGLSetCurrentContext(ctx);
    GLuint fbo, rt, vao; glGenFramebuffers(1, &fbo); glGenTextures(1, &rt); glGenVertexArrays(1, &vao); glBindVertexArray(vao);
    glBindTexture(GL_TEXTURE_2D, rt); glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 1920, 1080, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo); glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, rt, 0); glViewport(0, 0, 1920, 1080);
    printf("64 x vec4 a = a*b+c        : %.3f ms\n", run("a = a * b + c;"));
    printf("64 x vec4 a = fma(a, b, c) : %.3f ms\n", run("a = fma(a, b, c);"));
    printf("64 x vec4 a = a*inversesqrt: %.3f ms\n", run("a = a * inversesqrt(b + a * a);"));
} return 0; }
