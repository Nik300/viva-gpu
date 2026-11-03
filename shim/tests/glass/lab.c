// TeraScale Glass lab (docs/PIANO-GLASS.md): hands every CGL context of the lab process to TSGlassHookContext, the
// way the WindowServer path does from SkyLightOriginal's CARenderOGL* imports. Lab only.
// Usage: TSMTL_CONFIG_DIR=<cfg> DYLD_INSERT_LIBRARIES=build/libTSMetal.dylib:build/libTSGlassLab.dylib \
//        CAGLASS_OGL=1 <lab>/WindowServer out.png glass
#include <OpenGL/OpenGL.h>
#include <dlfcn.h>

#define INTERPOSE(rep, orig) __attribute__((used)) static struct { const void *r, *o; } _ip_##orig \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)rep, (const void *)orig }

static CGLError lab_CGLCreateContext(CGLPixelFormatObj pf, CGLContextObj share, CGLContextObj *out) {
    CGLError e = CGLCreateContext(pf, share, out);
    void (*hook)(void *) = (void (*)(void *))dlsym(RTLD_DEFAULT, "TSGlassHookContext");
    if (!e && *out && hook) hook(*out);
    return e;
}
INTERPOSE(lab_CGLCreateContext, CGLCreateContext);
