// Phase 3b differential test for the AIR -> GLSL control flow: every shader below is
// translated in four modes and rendered at 64x64 with GL directly; all must match the
// reference (original IR, while/switch state machine), which is the Phase 3 translator.
//   cleaned+structured (the default), original+structured, cleaned+state machine.
// Also checks the branchless half decode against the CPU.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#define GL_SILENCE_DEPRECATION 1
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#import "TSMetal.h"

enum { TSAirNoPasses = 1, TSAirNoStructure = 2, TSAirNoCoalesce = 4 };
NSString *TSAirTranslateWithFlags(NSData *, NSDictionary *, NSDictionary **, NSString **, unsigned);

static int failures, checks;
#define CHECK(cond, ...) do { checks++; if (cond) printf("  ok   "); else { failures++; printf("  FAIL "); } \
    printf(__VA_ARGS__); printf("\n"); } while (0)

static NSString *const kMSL = @
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct FIn { float4 pos [[position]]; float2 uv [[user(loc0)]]; };\n"
    "struct P { int n; int m; float k; int sel; };\n"
    // nested loops with continue / break depending on the pixel
    "fragment float4 nested(FIn in [[stage_in]], constant P &p [[buffer(0)]]) {\n"
    "  int x = int(in.uv.x * 64.0), y = int(in.uv.y * 64.0); float acc = 0;\n"
    "  for (int i = 0; i < p.n; i++) {\n"
    "    if (((i + x) & 3) == 0) continue;\n"
    "    for (int j = 0; j < p.m; j++) { if (j * i > y) break; acc += float(i * j) * p.k; }\n"
    "    if (acc > 200.0) break;\n"
    "  }\n"
    "  return float4(acc, float(x), float(y), 1); }\n"
    // return and discard from inside a loop
    "fragment float4 early(FIn in [[stage_in]], constant P &p [[buffer(0)]]) {\n"
    "  int x = int(in.uv.x * 64.0), y = int(in.uv.y * 64.0); float s = 0;\n"
    "  for (int i = 0; i < p.n; i++) {\n"
    "    s += float(i ^ x);\n"
    "    if (s > float(y * 4)) return float4(s, float(i), 1, 0);\n"
    "    if ((i & 7) == 5 && x > 32) discard_fragment();\n"
    "  }\n"
    "  return float4(s, -1, 0, 1); }\n"
    // switch with fall-through and grouped cases
    "fragment float4 sw(FIn in [[stage_in]], constant P &p [[buffer(0)]]) {\n"
    "  int x = int(in.uv.x * 64.0), y = int(in.uv.y * 64.0); float r = 0, g = 1;\n"
    "  switch ((x + y * p.sel) % 9) {\n"
    "    case 0: r = 1; break;\n"
    "    case 1: r += 2; g = 3;\n"
    "    case 2: r += 3; break;\n"
    "    case 4: case 5: r = float(x) * 0.5; g = float(y); break;\n"
    "    case 7: for (int i = 0; i < x; i++) r += 0.25; break;\n"
    "    default: r = -float(y);\n"
    "  }\n"
    "  return float4(r, g, 0, 1); }\n"
    // while with two exits and a do-while inside
    "fragment float4 collatz(FIn in [[stage_in]], constant P &p [[buffer(0)]]) {\n"
    "  uint v = uint(in.uv.x * 64.0) * 64u + uint(in.uv.y * 64.0) + 1u; int steps = 0;\n"
    "  while (v != 1u) {\n"
    "    if (steps > p.n * 4) { return float4(-1, float(v), 0, 1); }\n"
    "    if ((v & 1u) == 0u) { do { v >>= 1; steps++; } while ((v & 1u) == 0u); }\n"
    "    else v = 3u * v + 1u;\n"
    "    steps++;\n"
    "  }\n"
    "  return float4(float(steps), 0, 0, 1); }\n"
    // flag-driven two-level break, local array with dynamic indices
    "fragment float4 search(FIn in [[stage_in]], constant P &p [[buffer(0)]]) {\n"
    "  int x = int(in.uv.x * 64.0), y = int(in.uv.y * 64.0); int a[8];\n"
    "  for (int i = 0; i < 8; i++) a[i] = (i * 37 + x) & 15;\n"
    "  int found = -1;\n"
    "  for (int i = 0; i < 8 && found < 0; i++)\n"
    "    for (int j = i + 1; j < 8; j++) if (a[i] + a[j] == (y & 31)) { found = i * 8 + j; break; }\n"
    "  return float4(float(found), float(a[y & 7]), 0, 1); }\n"
    // nested loop exiting to the outer latch, values live out of loops
    "fragment float4 primes(FIn in [[stage_in]], constant P &p [[buffer(0)]]) {\n"
    "  int x = int(in.uv.x * 64.0), y = int(in.uv.y * 64.0); int count = 0, last = 0;\n"
    "  for (int n = 2; n < 2 + x + y; n++) {\n"
    "    bool prime = true;\n"
    "    for (int d = 2; d * d <= n; d++) if (n % d == 0) { prime = false; break; }\n"
    "    if (prime) { count++; last = n; }\n"
    "  }\n"
    "  return float4(float(count), float(last), 0, 1); }\n"
    // branches that rejoin at different points (shared tails), early returns
    "static float tailf(float v, int y) { return y > 30 ? v * 2.0 : v + 1.0; }\n"
    "fragment float4 tails(FIn in [[stage_in]], constant P &p [[buffer(0)]]) {\n"
    "  int x = int(in.uv.x * 64.0), y = int(in.uv.y * 64.0); float r = 0;\n"
    "  if (x > 10) { if (y > 20) { r = 1; } else { r = tailf(float(x), y); if (x > 50) return float4(9, 9, 9, 9); } }\n"
    "  else { if (y < 5) r = tailf(float(y), x); else if (y > 60) return float4(r, 7, 7, 7); else r = 3; }\n"
    "  if ((x ^ y) & 1) r = -r;\n"
    "  return float4(r, float(x & y), 0, 1); }\n"
    // continue from a nested if/switch inside a loop, loop with an uniform trip count
    "fragment float4 mixed(FIn in [[stage_in]], constant P &p [[buffer(0)]]) {\n"
    "  int x = int(in.uv.x * 64.0), y = int(in.uv.y * 64.0); float r = 0, g = 0;\n"
    "  for (int i = 0; i < p.m; i++) {\n"
    "    int k = (x * i + y) & 3;\n"
    "    if (k == 0) continue;\n"
    "    switch (k) { case 1: r += 1; break; case 2: if (i > 3) continue; g += 2; break; default: r -= 0.5; }\n"
    "    g += 0.125;\n"
    "  }\n"
    "  return float4(r, g, 0, 1); }\n"
    // half loads (branchless ts_h2f): one value per column
    "fragment float4 halfs(FIn in [[stage_in]], constant half *h [[buffer(1)]]) {\n"
    "  int x = int(in.uv.x * 64.0); return float4(float(h[x]), 0, 0, 1); }\n"
    // every half bit pattern (B7): constant half4 at an 8-byte stride, the .xy / .zw pair of a uniform block element
    "fragment float4 halfall(FIn in [[stage_in]], constant half4 *h [[buffer(1)]]) {\n"
    "  int x = int(in.uv.x * 64.0), y = int(in.uv.y * 64.0); return float4(h[y * 64 + x]); }\n"
    // buffer load shapes (A3): dynamic float4 from a constant buffer, float4 and bytes from a
    // device buffer, a matrix from a constant buffer; checked against the CPU
    "fragment float4 cpal(FIn in [[stage_in]], constant float4 *pal [[buffer(1)]]) {\n"
    "  int x = int(in.uv.x * 64.0), y = int(in.uv.y * 64.0); return pal[x] * pal[y & 15] + pal[(x * y) & 63]; }\n"
    "fragment float4 dev4(FIn in [[stage_in]], device const float4 *d [[buffer(2)]]) {\n"
    "  int x = int(in.uv.x * 64.0), y = int(in.uv.y * 64.0); return d[(x + y * 3) & 63] + d[1]; }\n"
    "struct Rec { packed_float3 p; uchar4 c; ushort2 s; };\n"
    "fragment float4 bytes(FIn in [[stage_in]], device const Rec *r [[buffer(2)]]) {\n"
    "  int x = int(in.uv.x * 64.0); Rec v = r[x];\n"
    "  return float4(v.p.x + v.p.z, float(v.c.y) + float(v.c.w) * 256.0, float(v.s.x), float(v.s.y)); }\n"
    "fragment float4 mat(FIn in [[stage_in]], constant float4x4 *m [[buffer(1)]]) {\n"
    "  int x = int(in.uv.x * 64.0); return m[x & 3] * float4(1, 2, 3, 4); }\n"
    // P1 coalescing: struct fields at offsets 0/4/8/12 with a 16-byte stride (RGBA32UI view), an 8-byte stride
    // (RG32UI view), constant indices; also drawn with the binding at offsets 16, 4 and 8 (TSU_f2 variant)
    "struct R16 { float a; float b; float c; uint d; };\n"
    "struct R8 { float x; float y; };\n"
    "fragment float4 recs(FIn in [[stage_in]], device const R16 *r [[buffer(2)]]) {\n"
    "  int x = int(in.uv.x * 64.0), y = int(in.uv.y * 64.0); R16 v = r[(x + y) & 63];\n"
    "  device const R8 *q = (device const R8 *)(r + 64); R8 u = q[(x * 3 + y) & 127];\n"
    "  return float4(v.b + v.c, float(v.d & 0xFFFFu) + v.a, u.x - u.y, r[5].c + float(r[2].d)); }\n"
    // Dawn's layout: a u32 array indexed i * 20 | k and i * 20 + k (16-byte blocks once the index alignment is known),
    // and y * 3 + 1 (4-aligned only: word loads)
    "fragment float4 words(FIn in [[stage_in]], device const uint *w [[buffer(2)]]) {\n"
    "  uint x = uint(in.uv.x * 64.0), y = uint(in.uv.y * 64.0); uint i = ((x + y) & 31u) * 20u;\n"
    "  return float4(as_type<float>(w[i | 1u]) + as_type<float>(w[i | 3u]), float(w[i + 2u] & 0xFFFFu), float(w[i + 5u] >> 20),\n"
    "                float(w[y * 3u + 1u] & 255u)); }\n"
    // constant buffer with a dynamic 16-byte stride: static components of one uvec4
    "struct C16 { float a; float b; float c; float d; };\n"
    "fragment float4 crecs(FIn in [[stage_in]], constant C16 *c [[buffer(1)]]) {\n"
    "  int x = int(in.uv.x * 64.0); C16 v = c[x]; return float4(v.d, v.c - v.a, v.b, c[x + 1].a); }\n";

static NSString *const kFullVS = @"#version 410 core\nout vec2 v_user_loc0_;\n"
    "void main() { vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2); v_user_loc0_ = p; gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0); }\n";

static GLuint compile(GLenum type, NSString *src) {
    GLuint s = glCreateShader(type);
    const char *c = src.UTF8String;
    glShaderSource(s, 1, &c, NULL);
    glCompileShader(s);
    GLint ok; glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) { char log[8192]; glGetShaderInfoLog(s, sizeof log, NULL, log); printf("compile failed:\n%s\n%s\n", src.UTF8String, log); return 0; }
    return s;
}

static GLuint program(NSString *fs) {
    GLuint v = compile(GL_VERTEX_SHADER, kFullVS), f = compile(GL_FRAGMENT_SHADER, [@"#version 410 core\n" stringByAppendingString:fs]);
    if (!v || !f) return 0;
    GLuint p = glCreateProgram();
    glAttachShader(p, v); glAttachShader(p, f);
    glBindFragDataLocation(p, 0, "o0");
    glLinkProgram(p);
    GLint ok; glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (!ok) return 0;
    GLuint b = glGetUniformBlockIndex(p, "fbuf0"); if (b != GL_INVALID_INDEX) glUniformBlockBinding(p, b, 31);
    b = glGetUniformBlockIndex(p, "fbuf1"); if (b != GL_INVALID_INDEX) glUniformBlockBinding(p, b, 32);
    glUseProgram(p);   // device buffer 2: R32UI view on unit 1, RGBA32UI view on unit 2, RG32UI view on unit 3, offset 0
    GLint l = glGetUniformLocation(p, "fssbo2"); if (l >= 0) glUniform1i(l, 1);
    l = glGetUniformLocation(p, "fssbo2_4"); if (l >= 0) glUniform1i(l, 2);
    l = glGetUniformLocation(p, "fssbo2_2"); if (l >= 0) glUniform1i(l, 3);
    l = glGetUniformLocation(p, "fssbo2_off"); if (l >= 0) glUniform1i(l, 0);
    return p;
}

enum { W = 64 };
static void render(GLuint prog, float *out) {
    glClearColor(-7, -7, -7, -7);
    glClear(GL_COLOR_BUFFER_BIT);
    glUseProgram(prog);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glReadPixels(0, 0, W, W, GL_RGBA, GL_FLOAT, out);
}

static BOOL same(const float *a, const float *b, int *where) {
    for (int i = 0; i < W * W * 4; i++) {
        if (a[i] == b[i] || (isnan(a[i]) && isnan(b[i]))) continue;
        float d = fabsf(a[i] - b[i]), m = fmaxf(fabsf(a[i]), fabsf(b[i]));
        if (!(d <= 1e-5f * fmaxf(m, 1.0f))) { *where = i; return NO; }
    }
    return YES;
}

static void setOffset(GLuint prog, int off) {
    glUseProgram(prog);
    GLint l = glGetUniformLocation(prog, "fssbo2_off"); if (l >= 0) glUniform1i(l, off);
}

static float f32(const uint8_t *p) { float f; memcpy(&f, p, 4); return f; }
static uint32_t u32(const uint8_t *p) { uint32_t u; memcpy(&u, p, 4); return u; }

// CPU value of recs at (x, y) with device buffer 2 bound at byte `off` of `b`.
static void recsCPU(const uint8_t *b, int off, int x, int y, float out[4]) {
    const uint8_t *base = b + off, *v = base + ((x + y) & 63) * 16, *u = base + 1024 + ((x * 3 + y) & 127) * 8;
    out[0] = f32(v + 4) + f32(v + 8);
    out[1] = (float)(u32(v + 12) & 0xFFFF) + f32(v);
    out[2] = f32(u) - f32(u + 4);
    out[3] = f32(base + 5 * 16 + 8) + (float)u32(base + 2 * 16 + 12);
}

static BOOL close4(const float *got, const float *want) {
    for (int c = 0; c < 4; c++) {
        float a = got[c], b = want[c];
        if (!(a == b || (isnan(a) && isnan(b)) || fabsf(a - b) <= 1e-4f * fmaxf(fabsf(b), 1.0f))) return NO;
    }
    return YES;
}

static float halfToFloat(uint16_t h) {
    __fp16 v; memcpy(&v, &h, 2); return (float)v;
}

int main(void) { @autoreleasepool {
    id<MTLDevice> dev = TSMtlCreateDevice();
    NSError *e = nil;
    id<MTLLibrary> lib = [dev newLibraryWithSource:kMSL options:nil error:&e];
    if (!lib) { printf("MSL: %s\n", e.description.UTF8String); return 1; }

    CGLPixelFormatAttribute a[] = { kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core, kCGLPFAAccelerated, 0 };
    CGLPixelFormatObj pf; GLint npf; CGLChoosePixelFormat(a, &pf, &npf);
    CGLContextObj ctx; CGLCreateContext(pf, NULL, &ctx); CGLSetCurrentContext(ctx);
    GLuint fbo, rt, vao; glGenFramebuffers(1, &fbo); glGenTextures(1, &rt); glGenVertexArrays(1, &vao);
    glBindTexture(GL_TEXTURE_2D, rt); glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA32F, W, W, 0, GL_RGBA, GL_FLOAT, NULL);
    glBindFramebuffer(GL_FRAMEBUFFER, fbo); glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, rt, 0);
    glViewport(0, 0, W, W); glBindVertexArray(vao);

    struct { int32_t n, m; float k; int32_t sel; } params = { 23, 9, 0.75f, 3 };
    GLuint ubo[2]; glGenBuffers(2, ubo);
    glBindBuffer(GL_UNIFORM_BUFFER, ubo[0]); glBufferData(GL_UNIFORM_BUFFER, 16, &params, GL_STATIC_DRAW);
    glBindBufferBase(GL_UNIFORM_BUFFER, 31, ubo[0]);
    uint16_t halves[2048] = {0};
    const uint16_t special[] = { 0x0000, 0x8000, 0x3C00, 0xBC00, 0x3555, 0x7BFF, 0xFBFF, 0x0400, 0x8400, 0x7C00, 0xFC00, 0x4248, 0xC248, 0x1234, 0x5A5A, 0x2E66 };
    for (int i = 0; i < W; i++) halves[i] = i < 16 ? special[i] : (uint16_t)(i * 997);
    glBindBuffer(GL_UNIFORM_BUFFER, ubo[1]); glBufferData(GL_UNIFORM_BUFFER, sizeof halves, halves, GL_STATIC_DRAW);
    glBindBufferBase(GL_UNIFORM_BUFFER, 32, ubo[1]);
    // Load-shape data: 4 KB of floats (constant buffer 1) and 4 KB of mixed bytes (device buffer 2).
    static float fdata[1024];
    static uint8_t bdata[4096];
    for (int i = 0; i < 1024; i++) fdata[i] = (float)((i * 37) % 101) * 0.25f - 7.0f;
    for (int i = 0; i < 4096; i++) bdata[i] = (uint8_t)(i * 13 + (i >> 5));
    GLuint ubo2; glGenBuffers(1, &ubo2);
    GLuint dbuf, dtex[3]; glGenBuffers(1, &dbuf); glGenTextures(3, dtex);
    glBindBuffer(GL_TEXTURE_BUFFER, dbuf); glBufferData(GL_TEXTURE_BUFFER, sizeof bdata, bdata, GL_STATIC_DRAW);
    glActiveTexture(GL_TEXTURE1); glBindTexture(GL_TEXTURE_BUFFER, dtex[0]); glTexBuffer(GL_TEXTURE_BUFFER, GL_R32UI, dbuf);
    glActiveTexture(GL_TEXTURE2); glBindTexture(GL_TEXTURE_BUFFER, dtex[1]); glTexBuffer(GL_TEXTURE_BUFFER, GL_RGBA32UI, dbuf);
    glActiveTexture(GL_TEXTURE3); glBindTexture(GL_TEXTURE_BUFFER, dtex[2]); glTexBuffer(GL_TEXTURE_BUFFER, GL_RG32UI, dbuf);
    glActiveTexture(GL_TEXTURE0);
    (void)ubo2;

    // The reference reads buffers word by word (TSAirNoCoalesce); the default modes coalesce, and "unaligned variant"
    // is the coalesced translation compiled with TSU_f2 = 1 (its word-by-word fallback for unaligned bindings).
    const struct { unsigned flags; const char *name; BOOL unaligned; } modes[] = {
        { 0, "cleaned+structured" }, { TSAirNoPasses, "original+structured" }, { TSAirNoStructure, "cleaned+state machine" },
        { TSAirNoCoalesce, "word loads" }, { 0, "unaligned variant", YES },
    };
    float *ref = malloc(W * W * 16), *got = malloc(W * W * 16);
    for (NSString *name in @[@"nested", @"early", @"sw", @"collatz", @"search", @"primes", @"tails", @"mixed", @"halfs",
                              @"cpal", @"dev4", @"bytes", @"mat", @"recs", @"words", @"crecs"]) {
        BOOL loads = [@[@"cpal", @"dev4", @"bytes", @"mat", @"recs", @"words", @"crecs"] containsObject:name];
        if (loads) {   // constant buffer 1 holds the float table for these
            glBindBuffer(GL_UNIFORM_BUFFER, ubo[1]); glBufferData(GL_UNIFORM_BUFFER, sizeof fdata, fdata, GL_STATIC_DRAW);
        }
        NSData *bc = (NSData *)[(id)[lib newFunctionWithName:name] performSelector:@selector(bitcodeData)];
        printf("%s\n", name.UTF8String);
        NSString *err = nil;
        NSString *g0 = TSAirTranslateWithFlags(bc, nil, NULL, &err, TSAirNoPasses | TSAirNoStructure | TSAirNoCoalesce);
        GLuint p0 = g0 ? program(g0) : 0;
        CHECK(p0 != 0, "reference (original IR, state machine) translates and links%s%s", err ? ": " : "", err ? err.UTF8String : "");
        if (!p0) continue;
        render(p0, ref);
        for (unsigned m = 0; m < sizeof modes / sizeof modes[0]; m++) {
            NSString *g = TSAirTranslateWithFlags(bc, nil, NULL, &err, modes[m].flags);
            if (modes[m].unaligned && ![g containsString:@"#ifndef TSU_f2"]) continue;   // no coalesced device loads
            GLuint p = g ? program(modes[m].unaligned ? [@"#define TSU_f2 1\n" stringByAppendingString:g] : g) : 0;
            if (!p) { CHECK(NO, "%s: translation or link failed (%s)", modes[m].name, err.UTF8String); continue; }
            render(p, got);
            int at = -1;
            BOOL structured = [g rangeOfString:@"switch (ts_bb"].location == NSNotFound;
            BOOL ok = same(ref, got, &at);
            if (ok) CHECK(YES, "%-22s matches the reference (%s, %lu GLSL lines)", modes[m].name,
                          structured ? "structured" : "state machine", (unsigned long)[g componentsSeparatedByString:@"\n"].count);
            else CHECK(NO, "%-22s differs at pixel (%d,%d) channel %d: %g vs %g", modes[m].name, at / 4 % W, at / 4 / W, at % 4, got[at], ref[at]);
            if (!ok && getenv("CFG_DUMP")) printf("%s\n", g.UTF8String);
            glDeleteProgram(p);
        }
        if (loads) {
            // CPU reference for the load-shape shaders, from the same bytes.
            const float (*pal)[4] = (const float (*)[4])fdata, (*d4)[4] = (const float (*)[4])bdata;
            int bad = -1;
            for (int y = 0; y < W && bad < 0; y++) for (int x = 0; x < W && bad < 0; x++) {
                float want[4];
                for (int c = 0; c < 4; c++) {
                    if ([name isEqualToString:@"cpal"]) want[c] = pal[x][c] * pal[y & 15][c] + pal[(x * y) & 63][c];
                    else if ([name isEqualToString:@"dev4"]) want[c] = d4[(x + y * 3) & 63][c] + d4[1][c];
                    else if ([name isEqualToString:@"recs"]) { float v[4]; recsCPU(bdata, 0, x, y, v); want[c] = v[c]; }
                    else if ([name isEqualToString:@"words"]) {
                        const uint8_t *w = bdata + ((x + y) & 31) * 80;
                        float v[4] = { f32(w + 4) + f32(w + 12), (float)(u32(w + 8) & 0xFFFF), (float)(u32(w + 20) >> 20),
                                       (float)(u32(bdata + (y * 3 + 1) * 4) & 255) };
                        want[c] = v[c];
                    }
                    else if ([name isEqualToString:@"crecs"]) {
                        const float *r = fdata + x * 4;
                        float v[4] = { r[3], r[2] - r[0], r[1], r[4] };
                        want[c] = v[c];
                    }
                    else if ([name isEqualToString:@"mat"]) {
                        const float *m = fdata + (x & 3) * 16;   // column-major float4x4
                        want[c] = m[c] * 1 + m[4 + c] * 2 + m[8 + c] * 3 + m[12 + c] * 4;
                    } else {
                        const uint8_t *r = bdata + x * 20;   // packed_float3 (12) + uchar4 (4) + ushort2 (4)
                        float p0, p2; memcpy(&p0, r, 4); memcpy(&p2, r + 8, 4);
                        uint16_t s0, s1; memcpy(&s0, r + 16, 2); memcpy(&s1, r + 18, 2);
                        float v[4] = { p0 + p2, (float)r[13] + (float)r[15] * 256.0f, s0, s1 };
                        want[c] = v[c];
                    }
                }
                const float *got4 = ref + (y * W + x) * 4;
                for (int c = 0; c < 4; c++) {
                    float a = got4[c], b = want[c];
                    if (!(a == b || (isnan(a) && isnan(b)) || fabsf(a - b) <= 1e-4f * fmaxf(fabsf(b), 1.0f))) bad = (y * W + x) * 4 + c;
                }
            }
            CHECK(bad < 0, "reference values equal the CPU computation%s", bad < 0 ? "" :
                  [NSString stringWithFormat:@" - pixel (%d,%d) channel %d", bad / 4 % W, bad / 4 / W, bad % 4].UTF8String);
            if (bad >= 0 && getenv("CFG_DUMP")) printf("%s\n", g0.UTF8String);
        }
        if ([name isEqualToString:@"words"]) {
            NSString *g = TSAirTranslateWithFlags(bc, nil, NULL, &err, 0);
            NSUInteger blocks = [g componentsSeparatedByString:@"_4, "].count - 1;
            CHECK(blocks == 2, "i * 20 | k: the words share 16-byte fetches (%lu blocks for 4 words in 2 blocks)", (unsigned long)blocks);
        }
        if ([name isEqualToString:@"recs"]) {
            // Bindings at other offsets: 16-aligned uses the coalesced base program, 4 and 8 the TSU_f2 variant.
            NSString *g = TSAirTranslateWithFlags(bc, nil, NULL, &err, 0);
            CHECK([g containsString:@"_4, "] && [g containsString:@"_2, "], "recs coalesces through the RGBA32UI and RG32UI views");
            GLuint base = program(g), variant = program([@"#define TSU_f2 1\n" stringByAppendingString:g]);
            for (int off = 16; off >= 4; off = off == 16 ? 4 : off == 4 ? 8 : 0) {
                GLuint p = off & 15 ? variant : base;
                setOffset(p, off);
                render(p, got);
                setOffset(p, 0);
                int bad = -1;
                for (int i = 0; i < W * W && bad < 0; i++) { float v[4]; recsCPU(bdata, off, i % W, i / W, v); if (!close4(got + i * 4, v)) bad = i; }
                CHECK(bad < 0, "binding at offset %2d (%s) equals the CPU computation%s", off, off & 15 ? "TSU_f2 variant" : "coalesced",
                      bad < 0 ? "" : [NSString stringWithFormat:@" - pixel (%d,%d)", bad % W, bad / W].UTF8String);
            }
            glDeleteProgram(base); glDeleteProgram(variant);
        }
        if ([name isEqualToString:@"halfs"]) {
            int bad = -1;
            for (int x = 0; x < W && bad < 0; x++) {
                float want = halfToFloat(halves[x]), v = ref[x * 4];
                BOOL denormal = (halves[x] & 0x7C00) == 0 && (halves[x] & 0x3FF);
                if (!(v == want || (isnan(v) && isnan(want)) || (denormal && v == 0))) bad = x;
            }
            CHECK(bad < 0, "branchless ts_h2f equals the CPU conversion for 64 halves (zero, signs, max, inf, denormal flush)%s",
                  bad < 0 ? "" : [NSString stringWithFormat:@" - wrong at %d: 0x%04x -> %g", bad, halves[bad], ref[bad * 4]].UTF8String);
        }
        glDeleteProgram(p0);
    }

    // B7: ts_h2f on all 65536 half bit patterns, 16384 per draw, read through the pair path of constant buffers.
    // Bits equal to the CPU conversion; NaN payloads too, except the quiet bit the CPU sets; denormals flush to 0.
    printf("halfall\n");
    {
        NSData *bc = (NSData *)[(id)[lib newFunctionWithName:@"halfall"] performSelector:@selector(bitcodeData)];
        NSString *err = nil, *g = TSAirTranslateWithFlags(bc, nil, NULL, &err, 0);
        GLuint p = g ? program(g) : 0;
        static uint16_t all[16384];
        int bad = -1;
        float badV = 0;
        for (int round = 0; round < 4 && p && bad < 0; round++) {
            for (int i = 0; i < 16384; i++) all[i] = (uint16_t)(round * 16384 + i);
            glBindBuffer(GL_UNIFORM_BUFFER, ubo[1]); glBufferData(GL_UNIFORM_BUFFER, sizeof all, all, GL_STATIC_DRAW);
            render(p, got);
            for (int i = 0; i < 16384 && bad < 0; i++) {
                uint16_t h = all[i];
                float want = halfToFloat(h);
                uint32_t vb, wb;
                memcpy(&vb, &got[i], 4); memcpy(&wb, &want, 4);
                BOOL denormal = (h & 0x7C00) == 0 && (h & 0x3FF), nan = (h & 0x7C00) == 0x7C00 && (h & 0x3FF);
                if (!(vb == wb || (denormal && !(vb & 0x7FFFFFFF)) || (nan && (vb | 0x400000) == wb))) { bad = h; badV = got[i]; }
            }
        }
        CHECK(p && bad < 0, "ts_h2f equals the CPU conversion bit for bit on all 65536 halves (half4 pairs)%s",
              !p ? " - translation or link failed" : bad < 0 ? "" : [NSString stringWithFormat:@" - wrong at 0x%04x -> %g", bad, badV].UTF8String);
        if (p) glDeleteProgram(p);
    }
    printf("\n%d/%d checks passed\n", checks - failures, checks);
    return failures ? 1 : 0;
} }
