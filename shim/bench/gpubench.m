// GPU-side benchmark: GLSL emitted by the AIR translator (first row of each case) vs.
// hand-written target GLSL (structured control flow, cleaned IR, combined/wide loads).
// Before Phase 3b the first rows measured the while/switch state machine.
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
    lib = [dev newLibraryWithSource:kMSL options:nil error:&e];
    NSString *eguiVS = [NSString stringWithContentsOfFile:[NSHomeDirectory() stringByAppendingPathComponent:@"metal-shim/apps/msl/ArtCraft Launcher-0.metal"] encoding:NSUTF8StringEncoding error:nil];
    NSString *eguiFS = [NSString stringWithContentsOfFile:[NSHomeDirectory() stringByAppendingPathComponent:@"metal-shim/apps/msl/ArtCraft Launcher-1.metal"] encoding:NSUTF8StringEncoding error:nil];
    id<MTLLibrary> lv = [dev newLibraryWithSource:eguiVS options:nil error:&e], lf = [dev newLibraryWithSource:eguiFS options:nil error:&e];
    if (!lib || !lv || !lf) { fprintf(stderr, "%s\n", e.description.UTF8String); return 1; }

    CGLPixelFormatAttribute a[] = { kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core, kCGLPFAAccelerated, kCGLPFANoRecovery, 0 };
    CGLPixelFormatObj pf; GLint npf; CGLChoosePixelFormat(a, &pf, &npf);
    CGLContextObj ctx; CGLCreateContext(pf, NULL, &ctx); CGLSetCurrentContext(ctx);

    const int W = 1920, H = 1080;
    GLuint fbo, rt; glGenFramebuffers(1, &fbo); glGenTextures(1, &rt);
    glBindTexture(GL_TEXTURE_2D, rt); glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, W, H, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo); glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, rt, 0);
    glViewport(0, 0, W, H);
    GLuint vao; glGenVertexArrays(1, &vao); glBindVertexArray(vao);
    // 512x512 RGBA8 noise texture, linear sampler, on unit 0.
    uint32_t *pix = malloc(512 * 512 * 4); for (int i = 0; i < 512 * 512; i++) pix[i] = arc4random();
    GLuint tex; glGenTextures(1, &tex); glActiveTexture(GL_TEXTURE0); glBindTexture(GL_TEXTURE_2D, tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 512, 512, 0, GL_RGBA, GL_UNSIGNED_BYTE, pix);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAX_LEVEL, 0);
    GLuint smp; glGenSamplers(1, &smp); glSamplerParameteri(smp, GL_TEXTURE_MIN_FILTER, GL_LINEAR); glSamplerParameteri(smp, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glSamplerParameteri(smp, GL_TEXTURE_WRAP_S, GL_REPEAT); glSamplerParameteri(smp, GL_TEXTURE_WRAP_T, GL_REPEAT);
    glBindSampler(0, smp);
    void (^fullscreen)(void) = ^{ glDrawArrays(GL_TRIANGLES, 0, 3); };
    printf("GPU: %s, target %dx%d\n", glGetString(GL_RENDERER), W, H);

    // ---------------------------------------------------------------- 1. egui fragment shader
    {
        NSDictionary *q = nil; double tms;
        id<MTLLibrary> saved = lib;
        lib = lf;
        NSString *cur = translate(@"fs_main_gamma_framebuffer", nil, &q, &tms);
        (void)saved;
        printf("\n[1] egui fs_main_gamma_framebuffer, full screen, dithering on (translate %.2f ms)\n", tms);
        struct { float ss[2]; uint32_t dither, predictable; } locals = { {W, H}, 1, 0 };
        ubo(&locals, 16, 31 + 0);
        NSString *opt = @"in vec2 v_user_loc0_;\nin vec4 v_user_loc1_;\nuniform fbuf0 { uvec4 fbuf0_d[1]; };\n"
            "layout(location = 0) out vec4 o0;\nuniform sampler2D ftex0;\nuniform sampler2D ftex0_s0;\n"
            "void main() {\n  vec4 r;\n  if (fbuf0_d[0].w == 0u) {\n    r = texture(ftex0_s0, v_user_loc0_);\n  } else {\n"
            "    ivec2 ts = textureSize(ftex0, 0);\n    vec2 pc = vec2(ts) * v_user_loc0_ - 0.5;\n    vec2 fr = fract(pc);\n"
            "    ivec2 pf = ivec2(clamp(floor(pc), vec2(-2.14748365e+09), vec2(2.14748352e+09)));\n    ivec2 mx = ts - 1;\n"
            "    vec4 tl = texelFetch(ftex0, clamp(pf, ivec2(0), mx), 0), tr = texelFetch(ftex0, clamp(pf + ivec2(1, 0), ivec2(0), mx), 0);\n"
            "    vec4 bl = texelFetch(ftex0, clamp(pf + ivec2(0, 1), ivec2(0), mx), 0), br = texelFetch(ftex0, clamp(pf + ivec2(1, 1), ivec2(0), mx), 0);\n"
            "    r = mix(mix(tl, tr, fr.x), mix(bl, br, fr.x), fr.y);\n  }\n  vec4 c = r * v_user_loc1_;\n"
            "  if (fbuf0_d[0].z == 1u) {\n    float f = fract(fract(gl_FragCoord.x * 0.0671105608 + gl_FragCoord.y * 0.00583714992) * 52.9829178);\n"
            "    c = vec4(c.xyz + vec3((f - 0.5) * 0.0037254903), c.w);\n  }\n  o0 = c;\n}\n";
        Prog pc = mkprog(kFullVS, wrapF(cur)), po = mkprog(kFullVS, wrapF(opt));
        firstDraw(&pc, fullscreen); firstDraw(&po, fullscreen);
        glUseProgram(pc.p); double gc = gpuMs(fullscreen, 20);
        glUseProgram(po.p); double go = gpuMs(fullscreen, 20);
        report("egui fragment (dither on)", "translator", pc, gc, gc);
        report("", "structured + cleaned IR", po, go, gc);
        locals.dither = 0; ubo(&locals, 16, 31 + 0);
        glUseProgram(pc.p); gc = gpuMs(fullscreen, 20);
        glUseProgram(po.p); go = gpuMs(fullscreen, 20);
        report("egui fragment (dither off)", "translator", pc, gc, gc);
        report("", "structured + cleaned IR", po, go, gc);
        lib = nil;
    }
    // ---------------------------------------------------------------- 2. egui vertex shader (vertex pulling)
    {
        lib = lv;
        NSDictionary *q = nil; double tms;
        NSString *cur = translate(@"vs_main", nil, &q, &tms);
        printf("\n[2] egui vs_main, vertex pulling 20-byte vertices, 3M vertices (degenerate) (translate %.2f ms)\n", tms);
        const int N = 3 * 1000 * 1000;
        GLuint vb; glGenBuffers(1, &vb); glBindBuffer(GL_TEXTURE_BUFFER, vb); glBufferData(GL_TEXTURE_BUFFER, (GLsizeiptr)N * 20, NULL, GL_STATIC_DRAW);
        void *z = calloc(N, 20); glBufferSubData(GL_TEXTURE_BUFFER, 0, (GLsizeiptr)N * 20, z); free(z);
        texBuffer(vb, GL_R32UI, 1);
        float ss[4] = { W, H, 0, 0 }; uint32_t sizes[4] = { (uint32_t)N * 20, 0, 0, 0 };
        ubo(ss, 16, 0); ubo(sizes, 16, 1);
        NSString *fs = @"in vec2 v_user_loc0_; in vec4 v_user_loc1_; layout(location = 0) out vec4 o0; void main() { o0 = v_user_loc1_; }\n";
        NSString *head = @"uniform vbuf0 { uvec4 vbuf0_d[1]; };\nuniform vbuf1 { uvec4 vbuf1_d[1]; };\n"
            "uniform usamplerBuffer vssbo30; uniform int vssbo30_off;\nout vec2 v_user_loc0_;\nout vec4 v_user_loc1_;\n";
        NSString *tail = @"  vec4 c = vec4(col & 255u, (col >> 8) & 255u, (col >> 16) & 255u, col >> 24) * 0.00392156886;\n"
            "  vec2 ss = uintBitsToFloat(vbuf0_d[0].xy);\n  v_user_loc0_ = uv; v_user_loc1_ = c;\n"
            "  gl_Position = vec4(pos.x * 2.0 / ss.x - 1.0, 1.0 - pos.y * 2.0 / ss.y, 0.0, 1.0);\n}\n";
        NSString *byteLoads = [head stringByAppendingFormat:@"uint ld(int o) { return (texelFetch(vssbo30, (vssbo30_off + o) >> 2).r >> uint((o & 3) * 8)) & 0xFFu; }\n"
            "uint w(int o) { return ld(o) | (ld(o + 1) << 8) | (ld(o + 2) << 16) | (ld(o + 3) << 24); }\n"
            "void main() {\n  int vid = gl_VertexID; vec2 pos = vec2(0.0), uv = vec2(0.0); uint col = 0u;\n"
            "  if (vbuf1_d[0].x / 20u > uint(vid)) {\n    int b = vid * 20;\n"
            "    pos = uintBitsToFloat(uvec2(w(b), w(b + 4))); uv = uintBitsToFloat(uvec2(w(b + 8), w(b + 12))); col = w(b + 16);\n  }\n%@", tail];
        NSString *wordLoads = [head stringByAppendingFormat:@"void main() {\n  int vid = gl_VertexID; vec2 pos = vec2(0.0), uv = vec2(0.0); uint col = 0u;\n"
            "  if (vbuf1_d[0].x / 20u > uint(vid)) {\n    int b = (vssbo30_off >> 2) + vid * 5;\n"
            "    pos = uintBitsToFloat(uvec2(texelFetch(vssbo30, b).r, texelFetch(vssbo30, b + 1).r));\n"
            "    uv = uintBitsToFloat(uvec2(texelFetch(vssbo30, b + 2).r, texelFetch(vssbo30, b + 3).r));\n"
            "    col = texelFetch(vssbo30, b + 4).r;\n  }\n%@", tail];
        void (^draw)(void) = ^{ glDrawArrays(GL_TRIANGLES, 0, N); };
        Prog pc = mkprog(wrapV(cur), wrapF(fs)), pb = mkprog(wrapV(byteLoads), wrapF(fs)), pw = mkprog(wrapV(wordLoads), wrapF(fs));
        firstDraw(&pc, draw); firstDraw(&pb, draw); firstDraw(&pw, draw);
        glUseProgram(pc.p); double gc = gpuMs(draw, 3);
        glUseProgram(pb.p); double gb = gpuMs(draw, 3);
        glUseProgram(pw.p); double gw = gpuMs(draw, 3);
        report("egui vertex (3M vertices)", "translator", pc, gc, gc);
        report("", "structured, 20 byte fetches", pb, gb, gc);
        report("", "structured, 5 word fetches", pw, gw, gc);
        lib = nil;
    }
    // ---------------------------------------------------------------- 3. dynamic loop (blur)
    {
        lib = [dev newLibraryWithSource:kMSL options:nil error:&e];
        NSDictionary *q = nil; double tms;
        NSString *cur = translate(@"blur_dyn", nil, &q, &tms);
        printf("\n[3] blur with a uniform trip count (16 taps), full screen (translate %.2f ms)\n", tms);
        struct { int32_t taps; float step; int32_t pad[2]; } bu = { 16, 1.0f / 512 };
        ubo(&bu, 16, 31 + 0);
        NSString *opt = @"in vec2 v_user_loc0_;\nuniform fbuf0 { uvec4 fbuf0_d[1]; };\nuniform sampler2D ftex0_s0;\nlayout(location = 0) out vec4 o0;\n"
            "void main() {\n  vec4 acc = vec4(0.0); float wsum = 0.0;\n  int taps = int(fbuf0_d[0].x); float st = uintBitsToFloat(fbuf0_d[0].y);\n"
            "  for (int i = 0; i < taps; i++) { float w = 1.0 / (1.0 + float(i)); acc += texture(ftex0_s0, v_user_loc0_ + vec2(float(i) * st, 0.0)) * w; wsum += w; }\n"
            "  o0 = acc / max(wsum, 1e-6);\n}\n";
        Prog pc = mkprog(kFullVS, wrapF(cur)), po = mkprog(kFullVS, wrapF(opt));
        firstDraw(&pc, fullscreen); firstDraw(&po, fullscreen);
        glUseProgram(pc.p); double gc = gpuMs(fullscreen, 10);
        glUseProgram(po.p); double go = gpuMs(fullscreen, 10);
        report("blur loop, 16 taps", "translator", pc, gc, gc);
        report("", "structured for loop", po, go, gc);
    }
    // ---------------------------------------------------------------- 4. constant buffer, dynamic index
    {
        NSDictionary *q = nil; double tms;
        NSString *cur = translate(@"palette", nil, &q, &tms);
        printf("\n[4] constant float4 *pal indexed per pixel, full screen (translate %.2f ms)\n", tms);
        float *pal = malloc(65536); for (int i = 0; i < 16384; i++) pal[i] = (i % 7) * 0.1f;
        ubo(pal, 65536, 31 + 0);
        NSString *opt = @"in vec2 v_user_loc0_;\nuniform fbuf0 { uvec4 fbuf0_d[4096]; };\nlayout(location = 0) out vec4 o0;\n"
            "void main() {\n  int i = int(v_user_loc0_.x * 255.0) & 255, j = int(v_user_loc0_.y * 255.0) & 255;\n"
            "  o0 = uintBitsToFloat(fbuf0_d[i]) * uintBitsToFloat(fbuf0_d[j]) + uintBitsToFloat(fbuf0_d[(i + j) & 255]);\n}\n";
        Prog pc = mkprog(kFullVS, wrapF(cur)), po = mkprog(kFullVS, wrapF(opt));
        firstDraw(&pc, fullscreen); firstDraw(&po, fullscreen);
        glUseProgram(pc.p); double gc = gpuMs(fullscreen, 20);
        glUseProgram(po.p); double go = gpuMs(fullscreen, 20);
        report("cbuf float4[i], 3 loads/pixel", "translator", pc, gc, gc);
        report("", "3 uvec4 loads", po, go, gc);
    }
    // ---------------------------------------------------------------- 5. half decode
    {
        NSDictionary *q = nil; double tms;
        NSString *cur = translate(@"halfs", nil, &q, &tms);
        printf("\n[5] constant half4 *h indexed per pixel, full screen (translate %.2f ms)\n", tms);
        uint16_t *h = malloc(65536); for (int i = 0; i < 32768; i++) h[i] = 0x3C00 + (i & 0xff);
        ubo(h, 65536, 31 + 0);
        NSRange r1 = [cur rangeOfString:@"float ts_h2f(uint h) {"];
        NSRange r2 = [cur rangeOfString:@"}\n" options:0 range:NSMakeRange(r1.location, cur.length - r1.location)];
        NSString *opt = [cur stringByReplacingCharactersInRange:NSMakeRange(r1.location, NSMaxRange(r2) - r1.location) withString:
            @"float ts_h2f(uint h) {\n  float f = uintBitsToFloat((h & 0x7FFFu) << 13) * 5.192297e+33;\n"
            "  f = (h & 0x7C00u) == 0x7C00u ? uintBitsToFloat(((h & 0x3FFu) != 0u) ? 0x7fc00000u : 0x7f800000u) : f;\n"
            "  return (h & 0x8000u) != 0u ? -f : f;\n}\n"];
        Prog pc = mkprog(kFullVS, wrapF(cur)), po = mkprog(kFullVS, wrapF(opt));
        firstDraw(&pc, fullscreen); firstDraw(&po, fullscreen);
        glUseProgram(pc.p); double gc = gpuMs(fullscreen, 20);
        glUseProgram(po.p); double go = gpuMs(fullscreen, 20);
        report("half4 loads, 8 halves/pixel", "translator", pc, gc, gc);
        report("", "branchless ts_h2f", po, go, gc);
    }
    // ---------------------------------------------------------------- 6. device float4x4 per instance
    {
        NSDictionary *q = nil; double tfs, tvs;
        NSString *fcur = translate(@"inst_fs", nil, &q, &tfs);
        NSString *cur = translate(@"inst_vs", q, NULL, &tvs);
        printf("\n[6] device float4 p[vid], float4x4 m[iid]; 1000 instances x 3000 vertices (translate %.2f ms)\n", tvs);
        GLuint pb, mb; glGenBuffers(1, &pb); glGenBuffers(1, &mb);
        void *z = calloc(1, 1 << 20);
        glBindBuffer(GL_TEXTURE_BUFFER, pb); glBufferData(GL_TEXTURE_BUFFER, 3000 * 16, z, GL_STATIC_DRAW);
        glBindBuffer(GL_TEXTURE_BUFFER, mb); glBufferData(GL_TEXTURE_BUFFER, 1000 * 64, z, GL_STATIC_DRAW);
        texBuffer(pb, GL_R32UI, 2); texBuffer(mb, GL_R32UI, 3); texBuffer(pb, GL_RGBA32UI, 4); texBuffer(mb, GL_RGBA32UI, 5);
        NSString *opt = @"uniform usamplerBuffer vssbo0_4; uniform int vssbo0_off;\nuniform usamplerBuffer vssbo1_4; uniform int vssbo1_off;\n"
            "out vec2 v_user_loc0_;\nvoid main() {\n  int iid = gl_InstanceID;\n"
            "  int mb = (vssbo1_off >> 4) + iid * 4;\n"
            "  mat4 m = mat4(uintBitsToFloat(texelFetch(vssbo1_4, mb)), uintBitsToFloat(texelFetch(vssbo1_4, mb + 1)),\n"
            "                uintBitsToFloat(texelFetch(vssbo1_4, mb + 2)), uintBitsToFloat(texelFetch(vssbo1_4, mb + 3)));\n"
            "  gl_Position = m * uintBitsToFloat(texelFetch(vssbo0_4, (vssbo0_off >> 4) + gl_VertexID));\n  v_user_loc0_ = vec2(0.0);\n}\n";
        void (^draw)(void) = ^{ glDrawArraysInstanced(GL_TRIANGLES, 0, 3000, 1000); };
        Prog pc = mkprog(wrapV(cur), wrapF(fcur)), po = mkprog(wrapV(opt), wrapF(fcur));
        firstDraw(&pc, draw); firstDraw(&po, draw);
        glUseProgram(pc.p); double gc = gpuMs(draw, 3);
        glUseProgram(po.p); double go = gpuMs(draw, 3);
        report("instanced matrices (3M vertices)", "translator", pc, gc, gc);
        report("", "5 RGBA32UI fetches", po, go, gc);
    }
    GLenum err = glGetError();
    printf("\nGL error: 0x%x\n", err);
} return 0; }
