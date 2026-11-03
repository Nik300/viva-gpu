// TeraScale Glass (docs/PIANO-GLASS.md): Apple's glass shaders from QuartzCore's metallib, translated by the AIR
// translator and converted for Moraea's GLSL 1.20 context, checked against Moraea's glass shader in a legacy
// OpenGL context, written to <dir>/glass.glsl (+ glass.plist: what it was built from).
// Usage: glassgen [-o dir] [--metallib file] [--moraea vert frag...] [-v]
//   default dir: /Library/GPUBundles/TeraScaleMTLDriver.config/glass; -o - only checks; -v prints the composed shader.
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#define GL_SILENCE_DEPRECATION 1
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl.h>
#import "TSMetal.h"
#import "TSGlass.h"
NSString *TSAirTranslate(NSData *, NSDictionary *, NSDictionary **, NSString **);

static NSString *translate(id<MTLLibrary> lib, NSString *name) {
    id<MTLFunction> f = [lib newFunctionWithName:name];
    if (!f) { fprintf(stderr, "glassgen: %s not in the metallib\n", name.UTF8String); return nil; }
    NSString *err = nil;
    NSString *glsl = TSAirTranslate((NSData *)[(id)f performSelector:@selector(bitcodeData)], nil, NULL, &err);
    if (!glsl) fprintf(stderr, "glassgen: %s: %s\n", name.UTF8String, err.UTF8String);
    return glsl;
}

static BOOL compile(GLuint sh, NSString *src, const char *what) {
    const char *c = src.UTF8String;
    glShaderSource(sh, 1, &c, NULL);
    glCompileShader(sh);
    GLint ok = 0;
    glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
    if (!ok) { char log[4096] = ""; glGetShaderInfoLog(sh, sizeof log, NULL, log); fprintf(stderr, "glassgen: %s: %s", what, log); }
    return ok;
}

int main(int argc, char **argv) { @autoreleasepool {
    NSString *out = @"/Library/GPUBundles/TeraScaleMTLDriver.config/glass";
    NSString *metallib = @"/System/Library/Frameworks/QuartzCore.framework/Versions/A/Resources/default.metallib";
    NSString *root = @TS_SOURCE_DIR;
    // Moraea's two no-bleed glass shaders as captured in the lab (exp/glspy): computed shape, shape from a texture.
    NSString *vert = [root stringByAppendingPathComponent:@"tests/glass/moraea-glass.vert"];
    NSMutableArray<NSString *> *frags = [@[ [root stringByAppendingPathComponent:@"tests/glass/moraea-glass.frag"],
                                            [root stringByAppendingPathComponent:@"tests/glass/moraea-glass-tex.frag"] ] mutableCopy];
    BOOL verbose = NO;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "-o") && i + 1 < argc) out = @(argv[++i]);
        else if (!strcmp(argv[i], "--metallib") && i + 1 < argc) metallib = @(argv[++i]);
        else if (!strcmp(argv[i], "--moraea") && i + 2 < argc) {
            vert = @(argv[++i]);
            [frags removeAllObjects];
            while (i + 1 < argc && argv[i + 1][0] != '-') [frags addObject:@(argv[++i])];
        }
        else if (!strcmp(argv[i], "-v")) verbose = YES;
        else { fprintf(stderr, "usage: glassgen [-o dir|-] [--metallib file] [--moraea vert frag...] [-v]\n"); return 2; }
    }
    id<MTLDevice> device = TSMtlCreateDevice();
    NSError *e = nil;
    id<MTLLibrary> lib = [device newLibraryWithURL:[NSURL fileURLWithPath:metallib] error:&e];
    if (!lib) { fprintf(stderr, "glassgen: %s: %s\n", metallib.UTF8String, e.localizedDescription.UTF8String); return 1; }
    NSArray *functions = @[ @"glass_background_sdf_no_bleed_lpf", @"glass_background_no_bleed_lpf", @"glass_background_sdf_lpf",
                            @"glass_background_lpf", @"variable_blur_downsample_frag_lpf" ];
    NSMutableDictionary *glsl = [NSMutableDictionary dictionary];
    for (NSString *name in functions) {
        NSString *g = translate(lib, name);
        if (!g) return 1;
        glsl[name] = g;
    }
    NSString *err = nil;
    NSString *snippet = TSGlassBuildSnippet(glsl, &err);
    if (!snippet) { fprintf(stderr, "glassgen: %s\n", err.UTF8String); return 1; }

    // Each Moraea shader with the snippet, linked with Moraea's vertex shader in a legacy context like WindowServer's.
    CGLPixelFormatAttribute a[] = { kCGLPFAAccelerated, 0 };
    CGLPixelFormatObj pf; GLint n; CGLContextObj ctx;
    if (CGLChoosePixelFormat(a, &pf, &n) || CGLCreateContext(pf, NULL, &ctx)) { fprintf(stderr, "glassgen: no legacy context\n"); return 1; }
    CGLSetCurrentContext(ctx);
    NSString *vs = [NSString stringWithContentsOfFile:vert encoding:NSUTF8StringEncoding error:nil];
    GLuint vsh = glCreateShader(GL_VERTEX_SHADER);
    if (!vs || !compile(vsh, vs, "Moraea's vertex shader")) return 1;
    // Each captured shader as Moraea writes it without and with bleed (only the argument of its glass call changes).
    // The composed program must link and keep Moraea's uniform locations: programs linked before the hook in
    // WindowServer are rebuilt in place, with the locations CoreAnimation already holds.
    for (NSString *frag in frags) {
        NSString *captured = [NSString stringWithContentsOfFile:frag encoding:NSUTF8StringEncoding error:nil];
        for (int bleed = 0; bleed < 2; bleed++) {
            NSString *moraea = !bleed ? captured : [[captured stringByReplacingOccurrencesOfString:@"cg9m_gbs(false)" withString:@"cg9m_gbs(true)"]
                                                    stringByReplacingOccurrencesOfString:@"texcoord1_0, false)" withString:@"texcoord1_0, true)"];
            NSString *what = [frag.lastPathComponent stringByAppendingString:bleed ? @" (bleed)" : @""];
            NSString *composed = moraea ? TSGlassCompose(moraea, snippet) : nil;
            if (!composed) { fprintf(stderr, "glassgen: %s does not have the shape TSGlassCompose expects\n", what.UTF8String); return 1; }
            if (verbose) printf("%s\n", composed.UTF8String);
            GLuint progs[2];
            for (int k = 0; k < 2; k++) {
                GLuint fs = glCreateShader(GL_FRAGMENT_SHADER);
                progs[k] = glCreateProgram();
                if (!compile(fs, k ? composed : moraea, what.UTF8String)) return 1;
                glAttachShader(progs[k], vsh); glAttachShader(progs[k], fs);
                glLinkProgram(progs[k]);
                GLint linked = 0;
                glGetProgramiv(progs[k], GL_LINK_STATUS, &linked);
                if (!linked) { char log[4096] = ""; glGetProgramInfoLog(progs[k], sizeof log, NULL, log); fprintf(stderr, "glassgen: link: %s", log); return 1; }
            }
            GLint count = 0, moved = 0;
            glGetProgramiv(progs[0], GL_ACTIVE_UNIFORMS, &count);
            for (GLint u = 0; u < count; u++) {
                char name[64]; GLint size; GLenum type;
                glGetActiveUniform(progs[0], u, sizeof name, NULL, &size, &type, name);
                if (glGetUniformLocation(progs[0], name) != glGetUniformLocation(progs[1], name)) {
                    fprintf(stderr, "glassgen: %s: uniform %s moves (%d -> %d)\n", what.UTF8String, name,
                            glGetUniformLocation(progs[0], name), glGetUniformLocation(progs[1], name));
                    moved++;
                }
            }
            if (moved) return 1;
            printf("glassgen: %s + snippet linked, %d uniforms at Moraea's locations\n", what.UTF8String, count);
        }
    }
    if ([out isEqualToString:@"-"]) return 0;

    NSData *lib_ = [NSData dataWithContentsOfFile:metallib];
    unsigned char md[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(lib_.bytes, (CC_LONG)lib_.length, md);
    NSMutableString *sha = [NSMutableString string];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [sha appendFormat:@"%02x", md[i]];
    [[NSFileManager defaultManager] createDirectoryAtPath:out withIntermediateDirectories:YES attributes:nil error:nil];
    NSDictionary *info = @{ @"Translator": @TS_TRANSLATOR_REV, @"Metallib": metallib, @"MetallibSHA256": sha, @"Date": [NSDate date],
                            @"Functions": functions };
    if (![snippet writeToFile:[out stringByAppendingPathComponent:@"glass.glsl"] atomically:YES encoding:NSUTF8StringEncoding error:&e] ||
        ![info writeToFile:[out stringByAppendingPathComponent:@"glass.plist"] atomically:YES]) {
        fprintf(stderr, "glassgen: cannot write %s: %s\n", out.UTF8String, e.localizedDescription.UTF8String ?: "");
        return 1;
    }
    printf("glassgen: wrote %s/glass.glsl\n", out.UTF8String);
    return 0;
} }
