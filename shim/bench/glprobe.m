#import <Foundation/Foundation.h>
#define GL_SILENCE_DEPRECATION 1
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#import <OpenGL/gl3ext.h>
int main(void) {
    CGLPixelFormatAttribute a[] = { kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core, kCGLPFAAccelerated, kCGLPFANoRecovery, 0 };
    CGLPixelFormatObj pf; GLint npf; CGLChoosePixelFormat(a, &pf, &npf);
    CGLContextObj ctx; CGLCreateContext(pf, NULL, &ctx); CGLSetCurrentContext(ctx);
    printf("renderer: %s\nversion: %s\nglsl: %s\n", glGetString(GL_RENDERER), glGetString(GL_VERSION), glGetString(GL_SHADING_LANGUAGE_VERSION));
    GLint n = 0; glGetIntegerv(GL_NUM_EXTENSIONS, &n);
    for (GLint i = 0; i < n; i++) printf("ext: %s\n", glGetStringi(GL_EXTENSIONS, i));
    GLint v;
#define Q(e) v = -1; glGetIntegerv(e, &v); printf("%-44s %d\n", #e, v);
    Q(GL_NUM_PROGRAM_BINARY_FORMATS) Q(GL_NUM_SHADER_BINARY_FORMATS) Q(GL_UNIFORM_BUFFER_OFFSET_ALIGNMENT)
    Q(GL_MAX_UNIFORM_BLOCK_SIZE) Q(GL_MAX_VERTEX_UNIFORM_BLOCKS) Q(GL_MAX_FRAGMENT_UNIFORM_BLOCKS) Q(GL_MAX_COMBINED_UNIFORM_BLOCKS)
    Q(GL_MAX_UNIFORM_BUFFER_BINDINGS) Q(GL_MAX_TEXTURE_IMAGE_UNITS) Q(GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS) Q(GL_MAX_COMBINED_TEXTURE_IMAGE_UNITS)
    Q(GL_MAX_TEXTURE_BUFFER_SIZE) Q(GL_MAX_VERTEX_ATTRIBS) Q(GL_MAX_VARYING_COMPONENTS) Q(GL_MAX_FRAGMENT_UNIFORM_COMPONENTS) Q(GL_MAX_VERTEX_UNIFORM_COMPONENTS)
    Q(GL_MAX_SAMPLES) Q(GL_MAX_VIEWPORTS)
    GLint mp = 0; CGLGetParameter(ctx, kCGLCPGPUVertexProcessing, &mp); printf("gpu vertex processing %d\n", mp);
    CGLGetParameter(ctx, kCGLCPGPUFragmentProcessing, &mp); printf("gpu fragment processing %d\n", mp);
    CGLError e = CGLEnable(ctx, kCGLCEMPEngine); printf("kCGLCEMPEngine enable -> %d\n", e);
    return 0;
}
