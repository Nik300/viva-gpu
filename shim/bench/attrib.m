// GPU-side benchmark: GLSL emitted today by the AIR translator vs. the form an optimizing
// translator would emit (structured control flow, cleaned IR, combined/wide loads).
// Times are GPU times from GL_TIME_ELAPSED queries (min of 5 runs), plus CPU compile/link
// and first-draw costs.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#define GL_SILENCE_DEPRECATION 1
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#import <mach/mach_time.h>
#import "TSMetal.h"
NSString *TSAirTranslate(NSData *, NSDictionary *, NSDictionary **, NSString **);

static id<MTLLibrary> lib;
static double nowMs(void) { static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb); return mach_absolute_time() * (double)tb.numer / tb.denom / 1e6; }

static NSString *translate(NSString *name, NSDictionary *interp, NSDictionary **q, double *ms) {
    NSData *bc = (NSData *)[(id)[lib newFunctionWithName:name] performSelector:@selector(bitcodeData)];
    NSString *err = nil;
    double t0 = nowMs();
    NSString *g = TSAirTranslate(bc, interp, q, &err);
    if (ms) *ms = nowMs() - t0;
    if (!g) { fprintf(stderr, "translate %s: %s\n", name.UTF8String, err.UTF8String); exit(1); }
    return g;
}
static NSString *wrapV(NSString *b) {
    return [NSString stringWithFormat:@"#version 410 core\n#define TS_VERTEX 1\n#define main ts_main\n%@\n#undef main\n"
            "void main() { ts_main(); gl_Position.y = -gl_Position.y; gl_Position.z = 2.0 * gl_Position.z - gl_Position.w; }\n", b];
}
static NSString *wrapF(NSString *b) { return [NSString stringWithFormat:@"#version 410 core\n#define TS_FRAGMENT 1\n%@\n", b]; }

static GLuint compile(GLenum type, NSString *src) {
    GLuint s = glCreateShader(type);
    const char *c = src.UTF8String;
    glShaderSource(s, 1, &c, NULL);
    glCompileShader(s);
    GLint ok; glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) { char log[8192]; glGetShaderInfoLog(s, sizeof log, NULL, log); fprintf(stderr, "compile:\n%s\n%s\n", src.UTF8String, log); exit(1); }
    return s;
}
typedef struct { GLuint p; double compileMs, linkMs, firstDrawMs; } Prog;
static Prog mkprog(NSString *vs, NSString *fs) {
    Prog r = {0};
    double t0 = nowMs();
    GLuint v = compile(GL_VERTEX_SHADER, vs), f = compile(GL_FRAGMENT_SHADER, fs);
    r.compileMs = nowMs() - t0;
    t0 = nowMs();
    GLuint p = glCreateProgram();
    glAttachShader(p, v); glAttachShader(p, f);
    glBindFragDataLocation(p, 0, "o0");
    glLinkProgram(p);
    GLint ok; glGetProgramiv(p, GL_LINK_STATUS, &ok);
    r.linkMs = nowMs() - t0;
    if (!ok) { char log[8192]; glGetProgramInfoLog(p, sizeof log, NULL, log); fprintf(stderr, "link: %s\n", log); exit(1); }
    // ABI bindings (same as TSMtlPipeline introspect): vbufN -> N, fbufN -> 31 + N; samplers by name.
    char name[64];
    for (int i = 0; i < 31; i++) {
        snprintf(name, sizeof name, "vbuf%d", i); GLuint b = glGetUniformBlockIndex(p, name); if (b != GL_INVALID_INDEX) glUniformBlockBinding(p, b, i);
        snprintf(name, sizeof name, "fbuf%d", i); b = glGetUniformBlockIndex(p, name); if (b != GL_INVALID_INDEX) glUniformBlockBinding(p, b, 31 + i);
    }
    glUseProgram(p);
    const char *units[][2] = { {"ftex0", "0"}, {"ftex0_s0", "0"}, {"vssbo30", "1"}, {"vssbo0", "2"}, {"vssbo1", "3"}, {"vssbo0_4", "4"}, {"vssbo1_4", "5"} };
    for (unsigned i = 0; i < sizeof units / sizeof units[0]; i++) { GLint l = glGetUniformLocation(p, units[i][0]); if (l >= 0) glUniform1i(l, atoi(units[i][1])); }
    r.p = p;
    return r;
}

static double gpuMs(void (^draw)(void), int reps) {
    double best = 1e30;
    GLuint q; glGenQueries(1, &q);
    for (int run = 0; run < 5; run++) {
        glBeginQuery(GL_TIME_ELAPSED, q);
        for (int i = 0; i < reps; i++) draw();
        glEndQuery(GL_TIME_ELAPSED);
        GLuint64 ns = 0; glGetQueryObjectui64v(q, GL_QUERY_RESULT, &ns);
        best = MIN(best, ns / 1e6 / reps);
    }
    glDeleteQueries(1, &q);
    return best;
}

static void firstDraw(Prog *p, void (^draw)(void)) {
    glFinish();
    double t0 = nowMs();
    glUseProgram(p->p); draw(); glFinish();
    p->firstDrawMs = nowMs() - t0;
}

static GLuint ubo(const void *data, GLsizeiptr size, GLuint binding) {
    GLuint b; glGenBuffers(1, &b); glBindBuffer(GL_UNIFORM_BUFFER, b);
    glBufferData(GL_UNIFORM_BUFFER, size, data, GL_STATIC_DRAW);
    glBindBufferRange(GL_UNIFORM_BUFFER, binding, b, 0, size);
    return b;
}
static GLuint texBuffer(GLuint buffer, GLenum fmt, GLuint unit) {
    GLuint t; glGenTextures(1, &t); glActiveTexture(GL_TEXTURE0 + unit); glBindTexture(GL_TEXTURE_BUFFER, t);
    glTexBuffer(GL_TEXTURE_BUFFER, fmt, buffer); glActiveTexture(GL_TEXTURE0);
    return t;
}

static void report(const char *test, const char *variant, Prog p, double gpu, double base) {
    printf("  %-34s %-34s GPU %8.3f ms  (x%5.2f)   compile %6.1f  link %6.1f  1st draw %6.1f ms\n",
           test, variant, gpu, base / gpu, p.compileMs, p.linkMs, p.firstDrawMs);
}


#import <dlfcn.h>
typedef void *LCtx, *LBuf, *LMod, *LErr;
// AIR bitcode -> LLVM pass pipeline -> bitcode, so the unchanged translator sees cleaned IR.
static NSData *cleaned(NSData *bc, const char *pipeline) {
    static void *h; if (!h) h = dlopen("/System/Library/PrivateFrameworks/GPUCompiler.framework/Versions/32023/Libraries/libLLVM.dylib", RTLD_NOW | RTLD_LOCAL);
    LCtx (*ctxCreate)(void) = dlsym(h, "LLVMContextCreate");
    LBuf (*mkbuf)(const char *, size_t, const char *, int) = dlsym(h, "LLVMCreateMemoryBufferWithMemoryRange");
    int (*parse)(LCtx, LBuf, LMod *) = dlsym(h, "LLVMParseBitcodeInContext2");
    LErr (*run)(LMod, const char *, void *, void *) = dlsym(h, "LLVMRunPasses");
    void *(*mkopts)(void) = dlsym(h, "LLVMCreatePassBuilderOptions");
    char *(*msg)(LErr) = dlsym(h, "LLVMGetErrorMessage");
    LBuf (*write)(LMod) = dlsym(h, "LLVMWriteBitcodeToMemoryBuffer");
    const char *(*start)(LBuf) = dlsym(h, "LLVMGetBufferStart"); size_t (*size)(LBuf) = dlsym(h, "LLVMGetBufferSize");
    LMod m = NULL;
    if (parse(ctxCreate(), mkbuf(bc.bytes, bc.length, "air", 0), &m)) { fprintf(stderr, "parse failed\n"); exit(1); }
    LErr e = run(m, pipeline, NULL, mkopts());
    if (e) { fprintf(stderr, "passes: %s\n", msg(e)); exit(1); }
    LBuf out = write(m);
    return [NSData dataWithBytes:start(out) length:size(out)];
}
static NSString *translateCleaned(NSString *name, NSDictionary *interp, NSDictionary **q, double *passMs, double *trMs) {
    NSData *bc = (NSData *)[(id)[lib newFunctionWithName:name] performSelector:@selector(bitcodeData)];
    double t0 = nowMs();
    NSData *c = cleaned(bc, "inline,function(sroa,loop-unroll-full,sroa,early-cse,instcombine,dse,adce,simplifycfg,instcombine)");
    *passMs = nowMs() - t0;
    NSString *err = nil;
    t0 = nowMs();
    NSString *g = TSAirTranslate(c, interp, q, &err);
    *trMs = nowMs() - t0;
    if (!g) { fprintf(stderr, "translate cleaned %s: %s\n", name.UTF8String, err.UTF8String); return nil; }
    return g;
}
static NSString *const kMSL = @
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct FIn { float4 pos [[position]]; float2 uv [[user(loc0)]]; };\n"
    "struct BU { int taps; float step; };\n"
    "fragment float4 blur_dyn(FIn in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant BU &u [[buffer(0)]]) {\n"
    "  float4 acc = 0; float wsum = 0;\n"
    "  for (int i = 0; i < u.taps; i++) { float w = 1.0 / (1.0 + float(i)); acc += t.sample(s, in.uv + float2(float(i) * u.step, 0)) * w; wsum += w; }\n"
    "  return acc / max(wsum, 1e-6); }\n"
    "fragment float4 palette(FIn in [[stage_in]], constant float4 *pal [[buffer(0)]]) {\n"
    "  int i = int(in.uv.x * 255.0) & 255; int j = int(in.uv.y * 255.0) & 255;\n"
    "  return pal[i] * pal[j] + pal[(i + j) & 255]; }\n"
    "fragment float4 halfs(FIn in [[stage_in]], constant half4 *h [[buffer(0)]]) {\n"
    "  int i = int(in.uv.x * 255.0) & 255; return float4(h[i]) + float4(h[(i * 7) & 255]); }\n"
    "struct VO { float4 pos [[position]]; float2 uv [[user(loc0)]]; };\n"
    "vertex VO inst_vs(uint vid [[vertex_id]], uint iid [[instance_id]], device const float4 *p [[buffer(0)]], device const float4x4 *m [[buffer(1)]]) {\n"
    "  VO o; o.pos = m[iid] * p[vid]; o.uv = float2(0); return o; }\n"
    "fragment float4 inst_fs(VO in [[stage_in]]) { return float4(in.uv, 0, 1); }\n";

// Full-screen triangle feeding the fragment-shader tests (no wrapper: timing only).
static NSString *const kFullVS = @"#version 410 core\nout vec2 v_user_loc0_; out vec4 v_user_loc1_;\n"
    "void main() { vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2); v_user_loc0_ = p * 0.5; v_user_loc1_ = vec4(1.0); gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0); }\n";


int main(int argc, char **argv) { @autoreleasepool {
    id<MTLDevice> dev = TSMtlCreateDevice();
    NSError *e = nil;
    NSString *eguiVS = [NSString stringWithContentsOfFile:[NSHomeDirectory() stringByAppendingPathComponent:@"metal-shim/apps/msl/ArtCraft Launcher-0.metal"] encoding:NSUTF8StringEncoding error:nil];
    NSString *eguiFS = [NSString stringWithContentsOfFile:[NSHomeDirectory() stringByAppendingPathComponent:@"metal-shim/apps/msl/ArtCraft Launcher-1.metal"] encoding:NSUTF8StringEncoding error:nil];
    id<MTLLibrary> lv = [dev newLibraryWithSource:eguiVS options:nil error:&e], lf = [dev newLibraryWithSource:eguiFS options:nil error:&e];
    id<MTLLibrary> lm = [dev newLibraryWithSource:kMSL options:nil error:&e];
    CGLPixelFormatAttribute a[] = { kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core, kCGLPFAAccelerated, kCGLPFANoRecovery, 0 };
    CGLPixelFormatObj pf; GLint npf; CGLChoosePixelFormat(a, &pf, &npf);
    CGLContextObj ctx; CGLCreateContext(pf, NULL, &ctx); CGLSetCurrentContext(ctx);
    const int W = 1920, H = 1080;
    GLuint fbo, rt; glGenFramebuffers(1, &fbo); glGenTextures(1, &rt);
    glBindTexture(GL_TEXTURE_2D, rt); glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, W, H, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo); glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, rt, 0);
    glViewport(0, 0, W, H);
    GLuint vao; glGenVertexArrays(1, &vao); glBindVertexArray(vao);
    uint32_t *pix = malloc(512 * 512 * 4); for (int i = 0; i < 512 * 512; i++) pix[i] = arc4random();
    GLuint tex; glGenTextures(1, &tex); glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 512, 512, 0, GL_RGBA, GL_UNSIGNED_BYTE, pix);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);
    GLuint smp; glGenSamplers(1, &smp); glSamplerParameteri(smp, GL_TEXTURE_MIN_FILTER, GL_LINEAR); glSamplerParameteri(smp, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glBindSampler(0, smp);
    void (^fullscreen)(void) = ^{ glDrawArrays(GL_TRIANGLES, 0, 3); };
    double pm, tm;
    // egui fragment
    {
        lib = lf;
        struct { float ss[2]; uint32_t dither, predictable; } locals = { {W, H}, 1, 0 };
        ubo(&locals, 16, 31);
        NSDictionary *q;
        NSString *cur = translate(@"fs_main_gamma_framebuffer", nil, &q, &tm);
        NSString *cln = translateCleaned(@"fs_main_gamma_framebuffer", nil, &q, &pm, &tm);
        printf("[1] egui fragment: passes %.2f ms, translate %.2f ms, GLSL lines %lu -> %lu\n", pm, tm,
               (unsigned long)[cur componentsSeparatedByString:@"\n"].count, (unsigned long)[cln componentsSeparatedByString:@"\n"].count);
        if (argc > 1) printf("%s\n", cln.UTF8String);
        Prog pc = mkprog(kFullVS, wrapF(cur)), pl = mkprog(kFullVS, wrapF(cln));
        firstDraw(&pc, fullscreen); firstDraw(&pl, fullscreen);
        glUseProgram(pc.p); double gc = gpuMs(fullscreen, 20);
        glUseProgram(pl.p); double gl = gpuMs(fullscreen, 20);
        report("egui fragment (dither on)", "current", pc, gc, gc);
        report("", "LLVM cleanup + current emitter", pl, gl, gc);
    }
    // egui vertex
    {
        lib = lv;
        const int N = 3 * 1000 * 1000;
        GLuint vb; glGenBuffers(1, &vb); glBindBuffer(GL_TEXTURE_BUFFER, vb); glBufferData(GL_TEXTURE_BUFFER, (GLsizeiptr)N * 20, NULL, GL_STATIC_DRAW);
        void *z = calloc(N, 20); glBufferSubData(GL_TEXTURE_BUFFER, 0, (GLsizeiptr)N * 20, z); free(z);
        texBuffer(vb, GL_R32UI, 1);
        float ss[4] = { W, H, 0, 0 }; uint32_t sizes[4] = { (uint32_t)N * 20, 0, 0, 0 };
        ubo(ss, 16, 0); ubo(sizes, 16, 1);
        NSString *fs = @"in vec2 v_user_loc0_; in vec4 v_user_loc1_; layout(location = 0) out vec4 o0; void main() { o0 = v_user_loc1_; }\n";
        NSDictionary *q;
        NSString *cur = translate(@"vs_main", nil, &q, &tm);
        NSString *cln = translateCleaned(@"vs_main", nil, &q, &pm, &tm);
        printf("[2] egui vertex: passes %.2f ms, translate %.2f ms\n", pm, tm);
        void (^draw)(void) = ^{ glDrawArrays(GL_TRIANGLES, 0, N); };
        Prog pc = mkprog(wrapV(cur), wrapF(fs)), pl = mkprog(wrapV(cln), wrapF(fs));
        firstDraw(&pc, draw); firstDraw(&pl, draw);
        glUseProgram(pc.p); double gc = gpuMs(draw, 3);
        glUseProgram(pl.p); double gl = gpuMs(draw, 3);
        report("egui vertex (3M vertices)", "current", pc, gc, gc);
        report("", "LLVM cleanup + current emitter", pl, gl, gc);
    }
    // blur
    {
        lib = lm;
        struct { int32_t taps; float step; int32_t pad[2]; } bu = { 16, 1.0f / 512 };
        ubo(&bu, 16, 31);
        NSDictionary *q;
        NSString *cur = translate(@"blur_dyn", nil, &q, &tm);
        NSString *cln = translateCleaned(@"blur_dyn", nil, &q, &pm, &tm);
        printf("[3] blur: passes %.2f ms, translate %.2f ms\n", pm, tm);
        Prog pc = mkprog(kFullVS, wrapF(cur)), pl = mkprog(kFullVS, wrapF(cln));
        firstDraw(&pc, fullscreen); firstDraw(&pl, fullscreen);
        glUseProgram(pc.p); double gc = gpuMs(fullscreen, 10);
        glUseProgram(pl.p); double gl = gpuMs(fullscreen, 10);
        report("blur loop, 16 taps", "current", pc, gc, gc);
        report("", "LLVM cleanup + current emitter", pl, gl, gc);
    }
    printf("GL error 0x%x\n", glGetError());
} return 0; }
