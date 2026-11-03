// Precompiled shader bundles (.mslbundle, docs/MSLBUNDLE.md). The driver records every translation an app
// needs (inputs only, next to its GLSL disk cache); this tool collects the records, translates them ahead of
// time with the same translator, checks that the GL driver compiles each result, and writes one bundle per app:
//
//   <out>/<bundle id>.mslbundle/Info.plist          { BundleID, TranslatorTag, Shaders, Failed, Built, Functions }
//   <out>/<bundle id>.mslbundle/shaders/<sha256>.plist   { glsl, q }   (sha256 of the translation inputs)
//   <out>/system.mslbundle                           shaders recorded by more than one app, and the seeds recorded
//                                                    by tools (tools/caglass: CoreAnimation's glass and blur)
//
// The driver looks a translation up in the app's bundle, then in system.mslbundle, before its disk cache, and
// ignores bundles built by another translator.
//
// Usage: mslbundle list  [record dirs...]                    apps and shaders recorded
//        mslbundle build [--out dir] [--app id]... [--min-apps n] [--seed proc:<tool>]... [cost options] [record dirs...]
//        mslbundle try   record.plist|dir [-v]               translate and compile records (repro)
//        mslbundle check [--out dir]                         bundles vs. this translator
//        mslbundle cost  [cost options] [--digest prefix [-v]] [record dirs...]
//                                                            deferred compile of each record, coalesced loads vs. words (TSV)
//        mslbundle prune [--dry-run] [record dirs...]        delete GLSL disk-cache entries of other translators (B5)
// Cost options (P2, docs/OTTIMIZZAZIONE-AIR.md §4.2): build measures the driver's deferred compile of every shader
// (Info.plist CompileMs) and, above --threshold ms (default 100), keeps the cheapest translation mode that compiles.
// --no-measure skips it; --max-kb n (default 40) skips shaders whose GLSL is larger (the driver can take minutes).
// Default record dirs: ~/Library/Caches/com.terascale.mtlshim/rec, the same in every app container, and the
// com.apple.metal layout under DARWIN_USER_CACHE_DIR. Default --out: <config dir>/mslbundles.
#import <Foundation/Foundation.h>
#define GL_SILENCE_DEPRECATION 1
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#import "TSPrivate.h"

static NSString *compileOne(GLenum type, NSString *src) {
    GLuint s = glCreateShader(type);
    const char *c = src.UTF8String;
    glShaderSource(s, 1, &c, NULL);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    char log[4096] = {0};
    if (!ok) glGetShaderInfoLog(s, sizeof log, NULL, log);
    glDeleteShader(s);
    return ok ? nil : @(log);
}

// Same wrappers as tools/airtrans; also the variant with every 2D slot as an IOSurface rectangle (TSR_* = 1) and
// every device buffer read word by word (TSU_* = 1, bindings that are not 16-aligned).
static NSString *compileCheck(NSString *glsl, BOOL vertex) {
    NSString *full = vertex
        ? [NSString stringWithFormat:@"#version 410 core\n#define main ts_main\n%@\n#undef main\nvoid main() { ts_main(); }\n", glsl]
        : [NSString stringWithFormat:@"#version 410 core\n%@", glsl];
    NSString *log = compileOne(vertex ? GL_VERTEX_SHADER : GL_FRAGMENT_SHADER, full);
    if (log || (![glsl containsString:@"#ifndef TSR_"] && ![glsl containsString:@"#ifndef TSU_"])) return log;
    NSMutableString *defs = [NSMutableString stringWithString:@"#version 410 core\n"];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"#ifndef (TS[RU]_[vf][0-9]+)" options:0 error:nil];
    for (NSTextCheckingResult *m in [re matchesInString:glsl options:0 range:NSMakeRange(0, glsl.length)])
        [defs appendFormat:@"#define %@ 1\n", [glsl substringWithRange:[m rangeAtIndex:1]]];
    log = compileOne(vertex ? GL_VERTEX_SHADER : GL_FRAGMENT_SHADER, [full stringByReplacingOccurrencesOfString:@"#version 410 core\n" withString:defs]);
    return log ? [@"(rectangle/unaligned variant) " stringByAppendingString:log] : nil;
}

static GLuint gZeroUBO;   // 64 KB of zeros behind every uniform block (an unbound block crashes the driver)

static void makeGLContext(void) {
    CGLPixelFormatAttribute a[] = { kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core, kCGLPFAAccelerated, 0 };
    CGLPixelFormatObj pf; GLint npf;
    CGLChoosePixelFormat(a, &pf, &npf);
    CGLContextObj ctx;
    CGLCreateContext(pf, NULL, &ctx);
    CGLSetCurrentContext(ctx);
    // 1x1 target for the cost draws.
    GLuint fbo, rb, vao;
    glGenFramebuffers(1, &fbo); glBindFramebuffer(GL_FRAMEBUFFER, fbo);
    glGenRenderbuffers(1, &rb); glBindRenderbuffer(GL_RENDERBUFFER, rb);
    glRenderbufferStorage(GL_RENDERBUFFER, GL_RGBA8, 1, 1);
    glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_RENDERBUFFER, rb);
    glGenVertexArrays(1, &vao); glBindVertexArray(vao);
    glGenBuffers(1, &gZeroUBO); glBindBuffer(GL_UNIFORM_BUFFER, gZeroUBO);
    void *zeros = calloc(1, 65536);
    glBufferData(GL_UNIFORM_BUFFER, 65536, zeros, GL_STATIC_DRAW);
    free(zeros);
    glViewport(0, 0, 1, 1);
    glEnable(GL_PROGRAM_POINT_SIZE);
}

#pragma mark Deferred compile cost (P2)

static double nowMs(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6; }

static GLuint costShader(GLenum type, NSString *src) {
    GLuint s = glCreateShader(type);
    const char *c = src.UTF8String;
    glShaderSource(s, 1, &c, NULL);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) { glDeleteShader(s); return 0; }
    return s;
}

// Vertex shader writing every varying a translated fragment shader reads, its point at x = ts_clip.
static NSString *costVertexFor(NSString *fs) {
    NSMutableString *vs = [NSMutableString string], *body = [NSMutableString string];
    NSMutableSet *seen = [NSMutableSet set];
    static NSRegularExpression *re;
    if (!re) re = [NSRegularExpression regularExpressionWithPattern:@"^((?:flat |noperspective |centroid )*)in (\\w+) (\\w+);"
                                                            options:NSRegularExpressionAnchorsMatchLines error:nil];
    for (NSTextCheckingResult *m in [re matchesInString:fs options:0 range:NSMakeRange(0, fs.length)]) {
        NSString *q = [fs substringWithRange:[m rangeAtIndex:1]], *t = [fs substringWithRange:[m rangeAtIndex:2]],
                 *n = [fs substringWithRange:[m rangeAtIndex:3]];
        if ([seen containsObject:n]) continue;
        [seen addObject:n];
        [vs appendFormat:@"%@out %@ %@;\n", q, t, n];
        [body appendFormat:@"  %@ = %@(0);\n", n, t];
    }
    [vs appendFormat:@"uniform float ts_clip;\nvoid main() {\n%@  gl_Position = vec4(ts_clip, 0.0, 0.0, 1.0);\n  gl_PointSize = 1.0;\n}\n", body];
    return vs;
}

// Milliseconds the GL driver needs to make a translated shader drawable: compile, link and the deferred hardware
// compile of the first draw (99-100% of the total for large shaders, superlinear in the number of buffer fetches).
// The draw puts its point outside the clip volume, so the driver compiles everything and nothing runs: with
// zero-filled buffers a loop could spin on the GPU until the watchdog (exp/airopt/glsize.m). A vertex shader's
// body sits behind a uniform branch that is false at the draw, for the same reason. A unique comment per call
// defeats any source-keyed cache in the driver. -1 = does not compile or link.
static double costMs(NSString *glsl, BOOL vertex) {
    static int run;
    NSString *tag = [NSString stringWithFormat:@"#version 410 core\n// cost %d\n", ++run];
    NSString *vs, *fs;
    if (vertex) {
        vs = [NSString stringWithFormat:@"%@#define main ts_main\n%@\n#undef main\nuniform float ts_clip;\n"
              "void main() { if (ts_clip < 1.0) ts_main(); gl_Position = vec4(ts_clip, 0.0, 0.0, 1.0); gl_PointSize = 1.0; }\n", tag, glsl];
        fs = [tag stringByAppendingString:@"out vec4 ts_o;\nvoid main() { ts_o = vec4(0.0); }\n"];
    } else {
        vs = [tag stringByAppendingString:costVertexFor(glsl)];
        fs = [tag stringByAppendingString:glsl];
    }
    double t0 = nowMs();
    GLuint v = costShader(GL_VERTEX_SHADER, vs), f = costShader(GL_FRAGMENT_SHADER, fs);
    if (!v || !f) { if (v) glDeleteShader(v); if (f) glDeleteShader(f); return -1; }
    GLuint p = glCreateProgram();
    glAttachShader(p, v); glAttachShader(p, f);
    glLinkProgram(p);
    GLint ok = 0;
    glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (ok) {
        glUseProgram(p);
        GLint n = 0, unit = 0;
        glGetProgramiv(p, GL_ACTIVE_UNIFORMS, &n);
        for (GLint i = 0; i < n; i++) {
            char name[256]; GLint size; GLenum type;
            glGetActiveUniform(p, i, sizeof name, NULL, &size, &type, name);
            BOOL sampler = (type >= GL_SAMPLER_1D && type <= GL_SAMPLER_2D_SHADOW) || (type >= GL_SAMPLER_1D_ARRAY && type <= GL_UNSIGNED_INT_SAMPLER_BUFFER) ||
                           type == GL_SAMPLER_2D_RECT || type == GL_SAMPLER_2D_RECT_SHADOW || type == GL_INT_SAMPLER_2D_RECT ||
                           type == GL_UNSIGNED_INT_SAMPLER_2D_RECT || type == GL_SAMPLER_BUFFER;
            if (sampler) glUniform1i(glGetUniformLocation(p, name), unit++);
        }
        GLint nb = 0;
        glGetProgramiv(p, GL_ACTIVE_UNIFORM_BLOCKS, &nb);
        for (GLint i = 0; i < nb; i++) { glUniformBlockBinding(p, i, i); glBindBufferBase(GL_UNIFORM_BUFFER, i, gZeroUBO); }
        glUniform1f(glGetUniformLocation(p, "ts_clip"), 4.0f);
        glDrawArrays(GL_POINTS, 0, 1);
        glFinish();
        glUseProgram(0);
    }
    double ms = nowMs() - t0;
    glDeleteProgram(p); glDeleteShader(v); glDeleteShader(f);
    return ok && !glGetError() ? ms : -1;
}

static BOOL gMeasure = YES;
static double gThresholdMs = 100, gMaxKB = 40;

// 4-byte buffer fetches left in a translation (ts_ld_ calls), for the cost report.
static unsigned wordFetches(NSString *glsl) {
    return (unsigned)[glsl componentsSeparatedByString:@" = ts_ld_"].count - 1;
}

#pragma mark Records

static NSArray<NSString *> *defaultRecordDirs(void) {
    NSMutableArray *dirs = [NSMutableArray array];
    NSString *home = NSHomeDirectory();
    [dirs addObject:[home stringByAppendingPathComponent:@"Library/Caches/com.terascale.mtlshim/rec"]];
    NSString *containers = [home stringByAppendingPathComponent:@"Library/Containers"];
    for (NSString *c in [NSFileManager.defaultManager contentsOfDirectoryAtPath:containers error:nil] ?: @[])
        [dirs addObject:[containers stringByAppendingFormat:@"/%@/Data/Library/Caches/com.terascale.mtlshim/rec", c]];
    char path[PATH_MAX];
    if (confstr(_CS_DARWIN_USER_CACHE_DIR, path, sizeof path)) [dirs addObject:@(path)];
    return dirs;
}

// Record files under `dir`: rec/<sha>.bin, or com.apple.metal/tsmtl-rec-<sha>/functions0.data (searched 2 levels deep).
static void findRecords(NSString *dir, NSMutableArray<NSString *> *out) {
    BOOL isDir = NO;
    if (![NSFileManager.defaultManager fileExistsAtPath:dir isDirectory:&isDir]) return;
    if (!isDir) { [out addObject:dir]; return; }
    if ([dir.lastPathComponent isEqualToString:@"rec"]) {
        for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil])
            if ([f.pathExtension isEqualToString:@"bin"] || [f.pathExtension isEqualToString:@"plist"]) [out addObject:[dir stringByAppendingPathComponent:f]];
        return;
    }
    if ([dir.lastPathComponent isEqualToString:@"com.apple.metal"]) {
        for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil])
            if ([f hasPrefix:@"tsmtl-rec-"]) [out addObject:[dir stringByAppendingFormat:@"/%@/functions0.data", f]];
        return;
    }
    // DARWIN_USER_CACHE_DIR: com.apple.metal directly or under <bundle id>/; any other dir: its records.
    NSString *metal = [dir stringByAppendingPathComponent:@"com.apple.metal"];
    if ([NSFileManager.defaultManager fileExistsAtPath:metal]) findRecords(metal, out);
    BOOL plain = NO;
    for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil] ?: @[]) {
        NSString *p = [dir stringByAppendingPathComponent:f];
        if ([f.pathExtension isEqualToString:@"plist"]) { [out addObject:p]; plain = YES; continue; }
        NSString *m = [p stringByAppendingPathComponent:@"com.apple.metal"];
        if ([NSFileManager.defaultManager fileExistsAtPath:m]) findRecords(m, out);
    }
    (void)plain;
}

// GLSL disk caches next to the record dirs: <...>/com.terascale.mtlshim/glsl/<sha>.plist, or the com.apple.metal
// layout's tsmtl-<sha>/ directories (64 hex digits: records and other kinds carry a "<kind>-" prefix).
static void findGLSLCaches(NSString *dir, NSMutableArray<NSString *> *out) {
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:dir isDirectory:&isDir] || !isDir) return;
    if ([dir.lastPathComponent isEqualToString:@"rec"]) {
        NSString *glsl = [dir.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"glsl"];
        for (NSString *f in [fm contentsOfDirectoryAtPath:glsl error:nil])
            if ([f.pathExtension isEqualToString:@"plist"] && f.stringByDeletingPathExtension.length == 64) [out addObject:[glsl stringByAppendingPathComponent:f]];
        return;
    }
    if ([dir.lastPathComponent isEqualToString:@"com.apple.metal"]) {
        for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:nil])
            if ([f hasPrefix:@"tsmtl-"] && f.length == 6 + 64) [out addObject:[dir stringByAppendingPathComponent:f]];
        return;
    }
    NSString *metal = [dir stringByAppendingPathComponent:@"com.apple.metal"];
    if ([fm fileExistsAtPath:metal]) findGLSLCaches(metal, out);
    for (NSString *f in [fm contentsOfDirectoryAtPath:dir error:nil] ?: @[]) {
        NSString *m = [dir stringByAppendingFormat:@"/%@/com.apple.metal", f];
        if ([fm fileExistsAtPath:m]) findGLSLCaches(m, out);
    }
}

// Digest of the file name the driver gives the GLSL of a record in its disk cache with this translator.
static NSString *cacheDigest(NSDictionary *r) {
    NSMutableData *key = [TSMtlTranslationKey(r[@"bitcode"], r[@"interp"], r[@"linked"]) mutableCopy];
    [key appendBytes:"\n" length:1];
    [key appendData:[TSAirTranslatorTag() dataUsingEncoding:NSUTF8StringEncoding]];
    return TSMtlHexDigest(key);
}

static NSDictionary *loadRecord(NSString *file) {
    NSData *d = [NSData dataWithContentsOfFile:file];
    NSDictionary *r = d ? [NSPropertyListSerialization propertyListWithData:d options:0 format:NULL error:nil] : nil;
    if (![r isKindOfClass:[NSDictionary class]] || ![r[@"bitcode"] isKindOfClass:[NSData class]]) return nil;
    return r;
}

// digest -> record, and app -> digests.
static void collect(NSArray<NSString *> *dirs, NSMutableDictionary<NSString *, NSDictionary *> *records,
                    NSMutableDictionary<NSString *, NSMutableSet *> *apps) {
    NSMutableArray *files = [NSMutableArray array];
    for (NSString *d in dirs) findRecords(d, files);
    for (NSString *f in files) {
        NSDictionary *r = loadRecord(f);
        if (!r) continue;
        NSString *digest = TSMtlHexDigest(TSMtlTranslationKey(r[@"bitcode"], r[@"interp"], r[@"linked"]));
        if (!records[digest]) records[digest] = r;
        NSString *app = [r[@"app"] length] ? r[@"app"] : @"unknown";
        if (!apps[app]) apps[app] = [NSMutableSet set];
        [apps[app] addObject:digest];
    }
}

// Translation modes the builder may use: the driver's own first, then the fallbacks (P2 also tries them for cost).
static const unsigned kModes[] = { 0, TSAirNoStructure, TSAirNoPasses, TSAirNoUnroll, TSAirNoCoalesce };
static NSString *const kModeNames[] = { @"default", @"no-structure", @"no-passes", @"no-unroll", @"no-coalesce" };
enum { kModeCount = sizeof kModes / sizeof kModes[0], kRescueModes = 3 };

static NSString *translateRecord(NSDictionary *r, unsigned flags, NSDictionary **q, NSString **err) {
    return TSAirTranslateLinked(r[@"bitcode"], r[@"linked"], [r[@"interp"] count] ? r[@"interp"] : nil, q, err, flags);
}

// Translates and compiles one record; returns { glsl, q, mode, ms? } or nil with an error. The driver's own mode
// comes first; when its GLSL does not compile on this GPU's driver, the other translation modes are tried
// (this is what the app would otherwise get as the fallback shader), and the first that compiles is kept.
// With measuring on, a shader whose deferred compile takes more than gThresholdMs is translated in every mode
// and the cheapest that compiles wins (`cheaper`): all modes are equivalent (tests/cfg.m checks them at the
// pixel), they differ only in what they ask of the driver's compiler.
static NSDictionary *build(NSDictionary *r, NSString **error) {
    NSString *first = nil;
    BOOL vertex = [r[@"stage"] isEqualToString:@"vertex"];
    NSMutableDictionary *best = nil;
    for (unsigned m = 0; m < kRescueModes && !best; m++) {
        NSDictionary *q = nil;
        NSString *err = nil;
        NSString *glsl = translateRecord(r, kModes[m], &q, &err);
        NSString *log = glsl ? compileCheck(glsl, vertex) : nil;
        if (glsl && !log) { best = [@{ @"glsl": glsl, @"q": q ?: @{}, @"mode": kModeNames[m] } mutableCopy]; break; }
        if (!first) first = glsl ? [@"GLSL: " stringByAppendingString:log] : [@"translate: " stringByAppendingString:err ?: @"failed"];
        if (!glsl && m == 0) break;   // the IR itself is not translatable: the other modes refuse it too
    }
    if (!best) { *error = first; return nil; }
    if (!gMeasure || [best[@"glsl"] length] > gMaxKB * 1024) return best;
    double ms = costMs(best[@"glsl"], vertex);
    if (ms < 0) return best;
    best[@"ms"] = @(ms);
    if (ms <= gThresholdMs) return best;
    NSString *chosen = best[@"mode"];
    for (unsigned m = 0; m < kModeCount; m++) {
        if ([kModeNames[m] isEqual:chosen]) continue;
        NSDictionary *q = nil;
        NSString *glsl = translateRecord(r, kModes[m], &q, NULL);
        if (!glsl || [glsl isEqual:best[@"glsl"]] || glsl.length > gMaxKB * 1024 || compileCheck(glsl, vertex)) continue;
        double c = costMs(glsl, vertex);
        // Measurements of large shaders vary by up to 2x run to run: switch only for a clear win.
        if (c >= 0 && c < [best[@"ms"] doubleValue] * 0.8)
            best = [@{ @"glsl": glsl, @"q": q ?: @{}, @"mode": kModeNames[m], @"ms": @(c), @"cheaper": @YES, @"was": @(ms) } mutableCopy];
    }
    return best;
}

static NSString *configOut(void) { return [TSMtlConfigDir() stringByAppendingPathComponent:@"mslbundles"]; }

static BOOL writePlist(id obj, NSString *path) {
    NSData *d = [NSPropertyListSerialization dataWithPropertyList:obj format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    return [d writeToFile:path atomically:YES];
}

// Writes <out>/<name>.mslbundle from the given digests. Replaces the bundle atomically (new dir, then rename).
static void writeBundle(NSString *out, NSString *name, NSSet<NSString *> *digests, NSDictionary<NSString *, NSDictionary *> *records,
                        NSMutableDictionary<NSString *, NSDictionary *> *built, NSMutableDictionary<NSString *, NSString *> *failed) {
    NSString *final = [out stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"mslbundle"]];
    NSString *tmp = [final stringByAppendingString:@".new"];
    [NSFileManager.defaultManager removeItemAtPath:tmp error:nil];
    [NSFileManager.defaultManager createDirectoryAtPath:[tmp stringByAppendingPathComponent:@"shaders"] withIntermediateDirectories:YES
                                             attributes:nil error:nil];
    NSMutableArray *functions = [NSMutableArray array], *failures = [NSMutableArray array], *costly = [NSMutableArray array];
    NSMutableDictionary *compileMs = [NSMutableDictionary dictionary];
    unsigned ok = 0, rescued = 0, cheaper = 0;
    for (NSString *digest in [digests.allObjects sortedArrayUsingSelector:@selector(compare:)]) {
        NSDictionary *r = records[digest];
        if (!built[digest] && !failed[digest]) {
            NSString *err = nil;
            NSDictionary *b = build(r, &err);
            if (b) built[digest] = b; else failed[digest] = err;
        }
        if (built[digest]) {
            writePlist(@{ @"glsl": built[digest][@"glsl"], @"q": built[digest][@"q"] }, [tmp stringByAppendingFormat:@"/shaders/%@.plist", digest]);
            NSDictionary *b = built[digest];
            if ([b[@"cheaper"] boolValue]) cheaper++;
            else if (![b[@"mode"] isEqual:@"default"]) rescued++;
            if (b[@"ms"]) {
                compileMs[digest] = @(round([b[@"ms"] doubleValue] * 10) / 10);
                if ([b[@"ms"] doubleValue] > gThresholdMs) [costly addObject:@[b[@"ms"], r[@"stage"] ?: @"", r[@"name"] ?: @"", b[@"mode"], b[@"was"] ?: @0]];
            }
            [functions addObject:[NSString stringWithFormat:@"%@ %@ %@", r[@"stage"], r[@"name"], [digest substringToIndex:12]]];
            ok++;
        } else {
            [failures addObject:@{ @"Function": r[@"name"] ?: @"", @"Stage": r[@"stage"] ?: @"", @"Digest": digest,
                                   @"Error": [failed[digest] substringToIndex:MIN(failed[digest].length, 400)] }];
        }
    }
    NSDictionary *info = @{ @"BundleID": name, @"TranslatorTag": TSAirTranslatorTag(), @"Shaders": @(ok), @"Rescued": @(rescued),
                            @"Cheaper": @(cheaper), @"CompileMs": compileMs,
                            @"Failed": failures, @"Built": NSDate.date, @"Functions": functions, @"Version": @1 };
    writePlist(info, [tmp stringByAppendingPathComponent:@"Info.plist"]);
    [NSFileManager.defaultManager removeItemAtPath:final error:nil];
    if (rename(tmp.fileSystemRepresentation, final.fileSystemRepresentation))
        fprintf(stderr, "cannot write %s\n", final.UTF8String);
    printf("  %-44s %4u shaders%s%s\n", [name stringByAppendingPathExtension:@"mslbundle"].UTF8String, ok,
           rescued ? [NSString stringWithFormat:@" (%u compile only in another mode)", rescued].UTF8String : "",
           failures.count ? [NSString stringWithFormat:@", %lu not translatable", (unsigned long)failures.count].UTF8String : "");
    for (NSDictionary *f in failures)
        printf("      - %s %s: %s\n", [f[@"Stage"] UTF8String], [f[@"Function"] UTF8String],
               [[f[@"Error"] componentsSeparatedByString:@"\n"].firstObject UTF8String]);
    [costly sortUsingComparator:^NSComparisonResult(NSArray *a, NSArray *b) { return [b[0] compare:a[0]]; }];
    for (NSArray *c in costly)
        printf("      ! %8.0f ms %s %s (%s%s)\n", [c[0] doubleValue], [c[1] UTF8String], [c[2] UTF8String], [c[3] UTF8String],
               [c[4] doubleValue] > 0 ? [NSString stringWithFormat:@", default %.0f ms", [c[4] doubleValue]].UTF8String : "");
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 2) {
        fprintf(stderr, "usage: mslbundle list|build|try|check [options] [record dirs...]  (see tools/mslbundle.m)\n");
        return 2;
    }
    NSString *cmd = @(argv[1]), *out = nil;
    NSMutableArray<NSString *> *dirs = [NSMutableArray array], *only = [NSMutableArray array];
    NSMutableSet<NSString *> *seeds = [NSMutableSet setWithObjects:@"proc:caglass", @"proc:rbglass", nil];
    BOOL verbose = NO, dryRun = NO;
    NSString *digestPrefix = nil;   // cost: only records whose digest starts with it (-v: print the coalesced GLSL)
    unsigned minApps = 2;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--out") && i + 1 < argc) out = @(argv[++i]);
        else if (!strcmp(argv[i], "--app") && i + 1 < argc) [only addObject:@(argv[++i])];
        else if (!strcmp(argv[i], "--min-apps") && i + 1 < argc) minApps = (unsigned)atoi(argv[++i]);
        else if (!strcmp(argv[i], "--seed") && i + 1 < argc) [seeds addObject:@(argv[++i])];
        else if (!strcmp(argv[i], "-v")) verbose = YES;
        else if (!strcmp(argv[i], "--no-measure")) gMeasure = NO;
        else if (!strcmp(argv[i], "--dry-run")) dryRun = YES;
        else if (!strcmp(argv[i], "--digest") && i + 1 < argc) digestPrefix = @(argv[++i]);
        else if (!strcmp(argv[i], "--threshold") && i + 1 < argc) gThresholdMs = atof(argv[++i]);
        else if (!strcmp(argv[i], "--max-kb") && i + 1 < argc) gMaxKB = atof(argv[++i]);
        else [dirs addObject:@(argv[i])];
    }
    if (!out) out = configOut();
    if (getenv("TSMTL_NO_PASSES") || getenv("TSMTL_NO_STRUCT") || getenv("TSMTL_NO_COALESCE")) {
        fprintf(stderr, "unset TSMTL_NO_PASSES/TSMTL_NO_STRUCT/TSMTL_NO_COALESCE: bundles are built in the driver's default mode\n");
        return 2;
    }

    if ([cmd isEqualToString:@"check"]) {
        NSString *tag = TSAirTranslatorTag();
        int stale = 0;
        printf("translator: %s\n", tag.UTF8String);
        for (NSString *f in [[NSFileManager.defaultManager contentsOfDirectoryAtPath:out error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
            if (![f.pathExtension isEqualToString:@"mslbundle"]) continue;
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[out stringByAppendingFormat:@"/%@/Info.plist", f]];
            BOOL same = [info[@"TranslatorTag"] isEqual:tag];
            stale += !same;
            printf("  %-44s %4d shaders, %lu failed, %s\n", f.UTF8String, [info[@"Shaders"] intValue],
                   (unsigned long)[info[@"Failed"] count], same ? "current" : "STALE (rebuild)");
        }
        return stale ? 1 : 0;
    }

    if ([cmd isEqualToString:@"prune"]) {
        // B5: the disk cache is keyed by translator, so every driver update leaves the old entries behind (3775
        // files for 413 shaders measured). Keep the entries this translator names for the recorded shaders and
        // anything written in the last day (a driver installed after this tool was built), delete the rest.
        NSArray *from = dirs.count ? dirs : defaultRecordDirs();
        NSMutableDictionary<NSString *, NSDictionary *> *records = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, NSMutableSet *> *apps = [NSMutableDictionary dictionary];
        collect(from, records, apps);
        NSMutableSet *keep = [NSMutableSet set];
        for (NSDictionary *r in records.allValues) [keep addObject:cacheDigest(r)];
        NSMutableArray<NSString *> *files = [NSMutableArray array];
        for (NSString *d in from) findGLSLCaches(d, files);
        NSDate *recent = [NSDate dateWithTimeIntervalSinceNow:-86400];
        unsigned long removed = 0, kept = 0;
        unsigned long long bytes = 0;
        for (NSString *f in files) {
            NSString *name = f.lastPathComponent;
            NSString *digest = [name hasPrefix:@"tsmtl-"] ? [name substringFromIndex:6] : name.stringByDeletingPathExtension;
            NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:f error:nil];
            NSString *data = [name hasPrefix:@"tsmtl-"] ? [f stringByAppendingPathComponent:@"functions0.data"] : f;
            NSDictionary *dataAttrs = [NSFileManager.defaultManager attributesOfItemAtPath:data error:nil] ?: attrs;
            if ([keep containsObject:digest] || [dataAttrs.fileModificationDate compare:recent] == NSOrderedDescending) { kept++; continue; }
            bytes += dataAttrs.fileSize;
            removed++;
            if (dryRun) { if (verbose) printf("  would remove %s\n", f.UTF8String); continue; }
            [NSFileManager.defaultManager removeItemAtPath:f error:nil];
        }
        printf("GLSL disk cache: %lu entries kept, %lu %s (%.1f MB) for %lu recorded shaders\n", kept, removed,
               dryRun ? "to remove" : "removed", bytes / 1048576.0, (unsigned long)records.count);
        return 0;
    }

    makeGLContext();
    if ([cmd isEqualToString:@"try"]) {
        NSMutableArray *files = [NSMutableArray array];
        for (NSString *d in dirs) findRecords(d, files);
        int ok = 0;
        for (NSString *f in files) {
            NSDictionary *r = loadRecord(f);
            if (!r) continue;
            NSString *err = nil;
            NSDictionary *b = build(r, &err);
            printf("  %-4s %-8s %-36s %s\n", b ? "ok" : "FAIL", [r[@"stage"] UTF8String], [r[@"name"] UTF8String],
                   b ? "" : [[err componentsSeparatedByString:@"\n"].firstObject UTF8String]);
            if (verbose && b) printf("%s\n", [b[@"glsl"] UTF8String]);
            ok += b != nil;
        }
        printf("%d/%lu translated and compiled\n", ok, (unsigned long)files.count);
        return ok == (int)files.count ? 0 : 1;
    }

    NSMutableDictionary<NSString *, NSDictionary *> *records = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableSet *> *apps = [NSMutableDictionary dictionary];
    collect(dirs.count ? dirs : defaultRecordDirs(), records, apps);
    if ([cmd isEqualToString:@"cost"]) {
        // P1 check: deferred compile with coalesced loads vs. one fetch per word, for records that read device or
        // constant buffers word by word; the order alternates so neither form always runs first.
        printf("digest\tstage\tname\tbytes\tword_fetches\tcoalesced_fetches\tms_coalesced\tms_words\n");
        unsigned i = 0;
        for (NSString *digest in [records.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            if (digestPrefix && ![digest hasPrefix:digestPrefix]) continue;
            NSDictionary *r = records[digest];
            BOOL vertex = [r[@"stage"] isEqualToString:@"vertex"];
            NSString *words = translateRecord(r, TSAirNoCoalesce, NULL, NULL), *coal = translateRecord(r, 0, NULL, NULL);
            if (verbose && digestPrefix) { printf("%s\n", coal.UTF8String); continue; }
            if (!words || !coal || [words isEqual:coal] || words.length > gMaxKB * 1024) continue;
            unsigned blocks = (unsigned)[coal componentsSeparatedByString:@"texelFetch("].count - 1 + (unsigned)[coal componentsSeparatedByString:@"_d["].count - 1;
            double a, b;
            if (i++ & 1) { a = costMs(coal, vertex); b = costMs(words, vertex); }
            else { b = costMs(words, vertex); a = costMs(coal, vertex); }
            printf("%s\t%s\t%s\t%lu\t%u\t%u\t%.1f\t%.1f\n", [digest substringToIndex:12].UTF8String, [r[@"stage"] UTF8String],
                   [r[@"name"] UTF8String], (unsigned long)words.length, wordFetches(words), blocks, a, b);
            fflush(stdout);
        }
        return 0;
    }
    NSArray *names = [apps.allKeys sortedArrayUsingSelector:@selector(compare:)];
    if ([cmd isEqualToString:@"list"]) {
        for (NSString *a in names) printf("  %-44s %4lu shaders\n", a.UTF8String, (unsigned long)apps[a].count);
        printf("%lu distinct shaders\n", (unsigned long)records.count);
        return 0;
    }
    if (![cmd isEqualToString:@"build"]) { fprintf(stderr, "unknown command %s\n", argv[1]); return 2; }

    [NSFileManager.defaultManager createDirectoryAtPath:out withIntermediateDirectories:YES attributes:nil error:nil];
    printf("translator %s -> %s\n", TSAirTranslatorTag().UTF8String, out.UTF8String);
    NSMutableDictionary *built = [NSMutableDictionary dictionary], *failed = [NSMutableDictionary dictionary];
    // Shared shaders (recorded by minApps apps or more) go to system.mslbundle; each app keeps all of its own,
    // so an app bundle alone is complete. Records of the seed tools (tools/caglass: CoreAnimation's glass and blur;
    // tools/rbglass: RenderBox + SwiftUI glass; more with --seed proc:<name>) go to the system bundle only; other
    // processes without a bundle id (tests) are skipped.
    NSCountedSet *uses = [NSCountedSet set];
    NSMutableSet *shared = [NSMutableSet set];
    for (NSString *a in names) {
        if ([seeds containsObject:a]) [shared unionSet:apps[a]];
        else if (![a hasPrefix:@"proc:"]) for (NSString *d in apps[a]) [uses addObject:d];
    }
    for (NSString *d in uses) if ([uses countForObject:d] >= minApps) [shared addObject:d];
    for (NSString *a in names) {
        if ([a hasPrefix:@"proc:"] || [a isEqualToString:@"unknown"]) continue;   // seeds, tests, tools
        if (only.count && ![only containsObject:a]) continue;
        writeBundle(out, a, apps[a], records, built, failed);
    }
    if (!only.count && shared.count) writeBundle(out, @"system", shared, records, built, failed);
    (void)verbose;
    return failed.count ? 1 : 0;
} }
