// TeraScale Metal Shim - pipeline and state objects.
//
// Shader ABI (what the GLSL for a Metal function must look like; the Phase 3
// AIR translator emits exactly this, hand-written GLSL can be registered too):
//   - no #version line; the shim prepends "#version 410 core".
//   - vertex shaders write gl_Position in Metal clip space (y up, z in [0,1]);
//     the shim wraps main() and converts to GL clip space (y flipped, z remapped),
//     which keeps row 0 of every texture "on top" exactly like Metal.
//   - vertex attributes:  layout(location = <Metal attribute index>) in ...
//   - color outputs:      layout(location = <color attachment index>) out ...
//   - buffers:            uniform vbuf<N> { ... };  / fbuf<N>   (raw bytes from the bound offset)
//   - textures:           uniform sampler* vtex<T>_s<S>; / ftex<T>_s<S>  (texture T sampled with sampler S;
//                         "ftex<T>" alone uses sampler slot T; "ftex<T>_k<16 hex>" uses a constexpr
//                         sampler whose AIR state word is the hex value)
//   - device buffers:     uniform usamplerBuffer vssbo<N>; uniform int vssbo<N>_off;  (R32UI view of the
//                         whole buffer, byte offset of the binding in _off); optional vssbo<N>_4 / _2 are
//                         RGBA32UI / RG32UI views of the same buffer for 16- / 8-byte loads
//   - instance/vertex:    uniform int ts_base_instance; / ts_base_vertex;
#import "TSPrivate.h"
#import "TSMetal.h"
#import <OpenGL/gl3ext.h>
#import <objc/runtime.h>
#import <CommonCrypto/CommonDigest.h>
#import <os/lock.h>
#import <pthread.h>

#ifndef GL_MIRROR_CLAMP_TO_EDGE_EXT
#define GL_MIRROR_CLAMP_TO_EDGE_EXT 0x8743
#endif
#ifndef GL_TEXTURE_MAX_ANISOTROPY_EXT
#define GL_TEXTURE_MAX_ANISOTROPY_EXT 0x84FE
#endif

#pragma mark - GLSL registry

static NSMutableDictionary<NSString *, NSString *> *TSGLSLRegistry(void) {
    static NSMutableDictionary *registry;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ registry = [NSMutableDictionary dictionary]; });
    return registry;
}

void TSMtlRegisterGLSL(NSString *functionName, NSString *source) {
    NSMutableDictionary *r = TSGLSLRegistry();
    @synchronized (r) { r[functionName] = [source copy]; }
}

NSString *TSMtlGLSLForFunction(id<MTLFunction> function) {
    if (!function) return nil;
    NSMutableDictionary *r = TSGLSLRegistry();
    @synchronized (r) { return r[function.name]; }
}

// Translations survive restarts (C3), keyed by bitcode, interpolation qualifiers and translator build.
// Two layouts, the first writable one wins (probed once per process):
//   <Caches>/com.terascale.mtlshim/glsl/<sha256>.plist   - normal apps; sandboxed apps get their container's Caches
//   <DARWIN_USER_CACHE_DIR>[/<bundle id>]/com.apple.metal/tsmtl-<sha256>/functions0.data
//                                                        - GPU processes whose sandbox only lets Metal's own shader
//                                                          cache through (Chrome's GPU helper: that path pattern only)
// Both are safe to delete. TSMTL_NO_DISK_CACHE=1 disables the cache.
static BOOL TSProbeWrite(NSURL *file) {
    NSURL *dir = file.URLByDeletingLastPathComponent;
    if (![NSFileManager.defaultManager createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil]) return NO;
    BOOL ok = [[NSData dataWithBytes:"ok" length:2] writeToURL:file options:0 error:nil];
    return ok;
}

// Directory of the cache (probed once per process); metal = the com.apple.metal layout.
static NSURL *TSDiskCacheDir(BOOL *metal) {
    static NSURL *dir;
    static BOOL metalLayout;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (getenv("TSMTL_NO_DISK_CACHE")) return;
        NSURL *caches = [NSFileManager.defaultManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *d = [caches URLByAppendingPathComponent:@"com.terascale.mtlshim" isDirectory:YES];
        if (TSProbeWrite([d URLByAppendingPathComponent:@"glsl/probe"])) { dir = d; return; }
        char path[PATH_MAX];
        if (!confstr(_CS_DARWIN_USER_CACHE_DIR, path, sizeof path)) return;
        NSURL *user = [NSURL fileURLWithPath:@(path) isDirectory:YES];
        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
        NSMutableArray<NSURL *> *bases = [NSMutableArray arrayWithObject:user];
        if (bundleID) [bases insertObject:[user URLByAppendingPathComponent:bundleID isDirectory:YES] atIndex:0];
        for (NSURL *base in bases) {
            NSURL *m = [base URLByAppendingPathComponent:@"com.apple.metal" isDirectory:YES];
            if (TSProbeWrite([m URLByAppendingPathComponent:@"tsmtl-probe/functions0.data"])) { dir = m; metalLayout = YES; break; }
        }
        TSMtlLog(@"disk cache: %@", dir ? dir.path : @"none writable, translations are not kept");
    });
    *metal = metalLayout;
    return dir;
}

// <Caches>/com.terascale.mtlshim/<kind>/<sha256>.plist|.bin, or com.apple.metal/tsmtl-[<kind>-]<sha256>/functions0.data
// (GLSL keeps its original names there).
NSURL *TSMtlDiskCacheFile(NSString *kind, NSData *key) {
    BOOL metal = NO;
    NSURL *dir = TSDiskCacheDir(&metal);
    if (!dir) return nil;
    unsigned char md[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(key.bytes, (CC_LONG)key.length, md);
    char hex[2 * CC_SHA256_DIGEST_LENGTH + 1];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) snprintf(hex + 2 * i, 3, "%02x", md[i]);
    BOOL glsl = [kind isEqualToString:@"glsl"];
    if (metal)
        return [dir URLByAppendingPathComponent:[NSString stringWithFormat:@"tsmtl-%@%s/functions0.data", glsl ? @"" : [kind stringByAppendingString:@"-"], hex]];
    return [dir URLByAppendingPathComponent:[NSString stringWithFormat:@"%@/%s.%@", kind, hex, glsl ? @"plist" : @"bin"]];
}

// Atomic writes use a temporary name the Metal-cache sandbox rule rejects: write <name>.tmp (allowed by the
// same rule) and rename it over the final name.
BOOL TSMtlDiskCacheWrite(NSURL *file, NSData *data) {
    if (!file || !data) return NO;
    NSURL *tmp = [file URLByAppendingPathExtension:@"tmp"];
    [NSFileManager.defaultManager createDirectoryAtURL:file.URLByDeletingLastPathComponent withIntermediateDirectories:YES
                                            attributes:nil error:nil];
    if (![data writeToURL:tmp options:0 error:nil]) return NO;
    if (!rename(tmp.fileSystemRepresentation, file.fileSystemRepresentation)) return YES;
    unlink(tmp.fileSystemRepresentation);
    return NO;
}

// What a translation depends on, besides the translator: bitcode, varying qualifiers, linked functions.
NSData *TSMtlTranslationKey(NSData *bitcode, NSDictionary *interpolation, NSDictionary<NSString *, NSData *> *linked) {
    NSMutableData *key = [NSMutableData dataWithData:bitcode];
    for (NSString *k in [interpolation.allKeys sortedArrayUsingSelector:@selector(compare:)])
        [key appendData:[[NSString stringWithFormat:@"\n%@=%@", k, interpolation[k]] dataUsingEncoding:NSUTF8StringEncoding]];
    for (NSString *k in [linked.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        [key appendData:[[NSString stringWithFormat:@"\nlinked %@ ", k] dataUsingEncoding:NSUTF8StringEncoding]];
        [key appendData:linked[k]];
    }
    return key;
}

NSString *TSMtlHexDigest(NSData *data) {
    unsigned char md[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, md);
    char hex[2 * CC_SHA256_DIGEST_LENGTH + 1];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) snprintf(hex + 2 * i, 3, "%02x", md[i]);
    return @(hex);
}

static NSURL *TSDiskCacheURL(NSData *translationKey) {
    static NSString *tag;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ tag = TSAirTranslatorTag(); });
    NSMutableData *key = [translationKey mutableCopy];
    [key appendBytes:"\n" length:1];
    [key appendData:[tag dataUsingEncoding:NSUTF8StringEncoding]];
    return TSMtlDiskCacheFile(@"glsl", key);
}

#pragma mark Precompiled shader bundles

// <config>/mslbundles/<name>.mslbundle (built by tools/mslbundle, docs/MSLBUNDLE.md): Info.plist with the
// translator tag it was built for, and shaders/<sha256 of the translation key>.plist = { glsl, q }, the
// same record as the disk cache. The app's own bundle (by bundle id) is searched first, then system.mslbundle
// (shaders of the system frameworks every app shares). A bundle built by another translator is ignored.
static NSArray<NSString *> *TSMslBundleDirs(void) {
    static NSArray *dirs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray *found = [NSMutableArray array];
        if (getenv("TSMTL_NO_MSLBUNDLE")) { dirs = found; return; }
        NSString *root = [TSMtlConfigDir() stringByAppendingPathComponent:@"mslbundles"];
        NSString *tag = TSAirTranslatorTag();
        NSString *app = NSBundle.mainBundle.bundleIdentifier;
        // Helpers (Chrome's GPU process, XPC services) use their app's bundle: the outermost .app's id.
        NSString *outer = TSMtlProcessPolicy()->appId;
        NSMutableOrderedSet *names = [NSMutableOrderedSet orderedSet];
        if (outer.length) [names addObject:outer];
        if (app.length) [names addObject:app];
        [names addObject:@"system"];
        for (NSString *name in names) {
            NSString *dir = [root stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"mslbundle"]];
            NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[dir stringByAppendingPathComponent:@"Info.plist"]];
            if (!info) continue;
            if (![info[@"TranslatorTag"] isEqual:tag]) {
                TSMtlWarn(@"mslbundle %@ was built for another translator (%@, this driver: %@): ignored", name, info[@"TranslatorTag"], tag);
                continue;
            }
            [found addObject:[dir stringByAppendingPathComponent:@"shaders"]];
            TSMtlLog(@"mslbundle %@: %@ shaders", name, info[@"Shaders"]);
        }
        dirs = found;
    });
    return dirs;
}

static NSDictionary *TSMslBundleLookup(NSString *digest) {
    for (NSString *dir in TSMslBundleDirs()) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:[dir stringByAppendingPathComponent:[digest stringByAppendingPathExtension:@"plist"]]];
        if (d) return d;
    }
    return nil;
}

// Every translation each app needs is recorded once (inputs only) next to the disk cache, as <cache>/rec/<digest>.bin
// = { app, name, stage, bitcode, interp, linked }: tools/mslbundle collects them and precompiles .mslbundle files.
// TSMTL_RECORD=0 turns it off.
static BOOL TSRecordingOn(void) {
    static int on = -1;
    if (on < 0) { const char *e = getenv("TSMTL_RECORD"); on = !(e && *e == '0'); }
    return on;
}

static void TSRecordTranslation(id<MTLFunction> function, NSData *bitcode, NSDictionary *interpolation,
                                NSDictionary<NSString *, NSData *> *linked, NSData *translationKey) {
    if (!TSRecordingOn()) return;
    NSString *app = TSMtlProcessPolicy()->appId ?: NSBundle.mainBundle.bundleIdentifier ?: @"";
    NSMutableData *fileKey = [translationKey mutableCopy];   // one record per app and shader
    [fileKey appendData:[[@"\napp=" stringByAppendingString:app] dataUsingEncoding:NSUTF8StringEncoding]];
    NSURL *file = TSMtlDiskCacheFile(@"rec", fileKey);
    if (!file || [NSFileManager.defaultManager fileExistsAtPath:file.path]) return;
    NSString *stage = function.functionType == MTLFunctionTypeVertex ? @"vertex"
                    : function.functionType == MTLFunctionTypeFragment ? @"fragment" : @"other";
    NSDictionary *rec = @{ @"app": app,
                           @"name": function.name ?: @"", @"stage": stage, @"bitcode": bitcode,
                           @"interp": interpolation ?: @{}, @"linked": linked ?: @{} };
    TSMtlDiskCacheWrite(file, [NSPropertyListSerialization dataWithPropertyList:rec format:NSPropertyListBinaryFormat_v1_0
                                                                         options:0 error:nil]);
}

static NSData *TSBitcodeOf(id<MTLFunction> function) {
    if (![(id)function respondsToSelector:@selector(bitcodeData)]) return nil;
    NSData *bitcode = (NSData *)[(id)function performSelector:@selector(bitcodeData)];
    return bitcode.length ? bitcode : nil;
}

// Bitcode of the linked functions by name, only when `bitcode` references visible functions.
static NSDictionary<NSString *, NSData *> *TSLinkedBitcode(NSData *bitcode, MTLLinkedFunctions *lf) {
    if (!lf || !TSAirNeedsLinking(bitcode)) return nil;
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSArray<id<MTLFunction>> *list in @[lf.functions ?: @[], lf.privateFunctions ?: @[]])
        for (id<MTLFunction> f in list) {
            NSData *bc = TSBitcodeOf(f);
            if (bc && f.name) d[f.name] = bc;
        }
    return d;
}

// Registered GLSL first, then the AIR translator (memory cache, then disk cache).
static NSString *TSShaderSource(id<MTLFunction> function, MTLLinkedFunctions *linkedFunctions, NSDictionary *interpolation,
                                NSDictionary **qualifiers, NSString **error) {
    NSString *registered = TSMtlGLSLForFunction(function);
    if (registered) return registered;
    if (![(id)function respondsToSelector:@selector(bitcodeData)]) { *error = @"function has no bitcode"; return nil; }
    NSData *bitcode = TSBitcodeOf(function);
    if (!bitcode) { *error = @"empty bitcode"; return nil; }
    NSDictionary<NSString *, NSData *> *linked = TSLinkedBitcode(bitcode, linkedFunctions);
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });
    NSArray *key = @[bitcode, interpolation ?: @{}, linked ?: @{}];
    NSArray *hit = [cache objectForKey:key];
    if (hit) { if (qualifiers) *qualifiers = hit[1]; return hit[0]; }
    NSData *translationKey = TSMtlTranslationKey(bitcode, interpolation, linked);
    NSDictionary *stored = TSMslBundleDirs().count ? TSMslBundleLookup(TSMtlHexDigest(translationKey)) : nil;
    BOOL precompiled = stored != nil;
    NSURL *file = precompiled ? nil : TSDiskCacheURL(translationKey);
    if (!precompiled) stored = file ? [NSDictionary dictionaryWithContentsOfURL:file] : nil;
    NSString *glsl = [stored[@"glsl"] isKindOfClass:[NSString class]] ? stored[@"glsl"] : nil;
    NSDictionary *q = [stored[@"q"] isKindOfClass:[NSDictionary class]] ? stored[@"q"] : nil;
    if (glsl && precompiled) {
        TSMtlStatAlways(TSStatBundleHits, 1);
    } else if (glsl) {
        TSMtlStat(TSStatDiskCacheHits, 1);
        TSRecordTranslation(function, bitcode, interpolation, linked, translationKey);
    } else {
        TSRecordTranslation(function, bitcode, interpolation, linked, translationKey);
        uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        glsl = TSAirTranslateLinked(bitcode, linked, interpolation, &q, error, TSAirDefaultFlags());
        TSMtlStat(TSStatTranslateMicros, (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1000);
        if (!glsl) return nil;
        NSData *plist = [NSPropertyListSerialization dataWithPropertyList:@{ @"glsl": glsl, @"q": q ?: @{} }
                                                                   format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
        TSMtlDiskCacheWrite(file, plist);
    }
    if (getenv("TSMTL_DUMP_GLSL")) fprintf(stderr, "[TSMtl] GLSL for %s:\n%s\n", function.name.UTF8String, glsl.UTF8String);
    [cache setObject:@[glsl, q ?: @{}] forKey:key];
    if (qualifiers) *qualifiers = q;
    return glsl;
}

// Constexpr sampler word layout (from AIR, see docs/PIANO.md): s/t/r address 3 bits each,
// mag 9-10, min 11-12, mip 13-14, pixel coords 15, compare 16-19, anisotropy-1 20-23,
// lod min/max as half floats 24-39/40-55, border color 56-57.
static float TSHalfToFloat(uint16_t h) {
    uint32_t e = (h >> 10) & 0x1f, m = h & 0x3ff;
    float s = (h & 0x8000) ? -1.f : 1.f;
    if (e == 0) return s * m * 5.9604645e-8f;
    if (e == 31) return m ? NAN : s * INFINITY;
    return s * ldexpf(1.f + m / 1024.f, (int)e - 15);
}

GLuint TSGLSamplerForConstexpr(uint64_t key) {
    static NSMutableDictionary<NSNumber *, NSNumber *> *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSNumber *hit = cache[@(key)];
    if (hit) return hit.unsignedIntValue;
    static const MTLSamplerAddressMode address[] = { MTLSamplerAddressModeClampToZero, MTLSamplerAddressModeClampToEdge,
        MTLSamplerAddressModeRepeat, MTLSamplerAddressModeMirrorRepeat, MTLSamplerAddressModeClampToBorderColor,
        MTLSamplerAddressModeMirrorClampToEdge, MTLSamplerAddressModeClampToEdge, MTLSamplerAddressModeClampToEdge };
    static const MTLCompareFunction compare[] = { MTLCompareFunctionNever, MTLCompareFunctionLess, MTLCompareFunctionLessEqual,
        MTLCompareFunctionGreater, MTLCompareFunctionGreaterEqual, MTLCompareFunctionEqual, MTLCompareFunctionNotEqual,
        MTLCompareFunctionAlways, MTLCompareFunctionNever };
    MTLSamplerDescriptor *d = [MTLSamplerDescriptor new];
    d.sAddressMode = address[key & 7];
    d.tAddressMode = address[(key >> 3) & 7];
    d.rAddressMode = address[(key >> 6) & 7];
    d.magFilter = (key >> 9) & 3 ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    d.minFilter = (key >> 11) & 3 ? MTLSamplerMinMagFilterLinear : MTLSamplerMinMagFilterNearest;
    unsigned mip = (key >> 13) & 3;
    d.mipFilter = mip == 2 ? MTLSamplerMipFilterLinear : mip == 1 ? MTLSamplerMipFilterNearest : MTLSamplerMipFilterNotMipmapped;
    unsigned cmp = (key >> 16) & 15;
    d.compareFunction = cmp < 9 ? compare[cmp] : MTLCompareFunctionNever;
    d.maxAnisotropy = ((key >> 20) & 15) + 1;
    d.lodMinClamp = TSHalfToFloat((key >> 24) & 0xffff);
    d.lodMaxClamp = TSHalfToFloat((key >> 40) & 0xffff);
    unsigned border = (key >> 56) & 3;
    d.borderColor = border == 2 ? MTLSamplerBorderColorOpaqueWhite : border == 1 ? MTLSamplerBorderColorOpaqueBlack
                                                                            : MTLSamplerBorderColorTransparentBlack;
    GLuint name = TSGLCreateSampler(d);
    cache[@(key)] = @(name);
    return name;
}

static GLenum TSGLCompare(MTLCompareFunction f) {
    static const GLenum map[] = { GL_NEVER, GL_LESS, GL_EQUAL, GL_LEQUAL, GL_GREATER, GL_NOTEQUAL, GL_GEQUAL, GL_ALWAYS };
    return f < 8 ? map[f] : GL_ALWAYS;
}

#pragma mark - Sampler state

@implementation TSMtlSamplerState {
    MTLSamplerDescriptor *_desc;
    TSMtlDevice *_tsDevice;
    GLuint _sampler, _rectSampler;
}

+ (void)initialize { if (self == [TSMtlSamplerState class]) TSMtlInstallCatchAll(self); }

- (instancetype)initWithDevice:(id)device samplerDescriptor:(MTLSamplerDescriptor *)desc {
    if ((self = [super initWithDevice:device samplerDescriptor:desc])) { _desc = [desc copy]; _tsDevice = device; }
    return self;
}

- (MTLSamplerDescriptor *)samplerDescriptor { return _desc; }

- (void)dealloc {
    GLuint s = _sampler, r = _rectSampler;
    if (s || r) [_tsDevice gpuAsync:^{ glDeleteSamplers(1, &s); glDeleteSamplers(1, &r); }];
}

static GLenum TSGLAddress(MTLSamplerAddressMode m) {
    switch (m) {
    case MTLSamplerAddressModeClampToEdge:       return GL_CLAMP_TO_EDGE;
    case MTLSamplerAddressModeMirrorClampToEdge: return GL_MIRROR_CLAMP_TO_EDGE_EXT;
    case MTLSamplerAddressModeRepeat:            return GL_REPEAT;
    case MTLSamplerAddressModeMirrorRepeat:      return GL_MIRRORED_REPEAT;
    default:                                     return GL_CLAMP_TO_BORDER;   // clampToZero, clampToBorderColor
    }
}

- (GLuint)glSampler {
    if (!_sampler) _sampler = TSGLCreateSampler(_desc);
    return _sampler;
}

- (GLuint)glRectangleSampler {
    if (!_rectSampler) _rectSampler = TSGLCreateRectangleSampler([self glSampler]);
    return _rectSampler;
}
@end

GLuint TSGLCreateSampler(MTLSamplerDescriptor *_desc) {
    GLuint _sampler;
    glGenSamplers(1, &_sampler);
    BOOL linearMin = _desc.minFilter == MTLSamplerMinMagFilterLinear;
    GLenum minFilter;
    switch (_desc.mipFilter) {
    case MTLSamplerMipFilterNearest: minFilter = linearMin ? GL_LINEAR_MIPMAP_NEAREST : GL_NEAREST_MIPMAP_NEAREST; break;
    case MTLSamplerMipFilterLinear:  minFilter = linearMin ? GL_LINEAR_MIPMAP_LINEAR : GL_NEAREST_MIPMAP_LINEAR; break;
    default:                         minFilter = linearMin ? GL_LINEAR : GL_NEAREST; break;
    }
    glSamplerParameteri(_sampler, GL_TEXTURE_MIN_FILTER, minFilter);
    glSamplerParameteri(_sampler, GL_TEXTURE_MAG_FILTER, _desc.magFilter == MTLSamplerMinMagFilterLinear ? GL_LINEAR : GL_NEAREST);
    glSamplerParameteri(_sampler, GL_TEXTURE_WRAP_S, TSGLAddress(_desc.sAddressMode));
    glSamplerParameteri(_sampler, GL_TEXTURE_WRAP_T, TSGLAddress(_desc.tAddressMode));
    glSamplerParameteri(_sampler, GL_TEXTURE_WRAP_R, TSGLAddress(_desc.rAddressMode));
    GLfloat border[4] = {0, 0, 0, 0};
    if (_desc.borderColor == MTLSamplerBorderColorOpaqueBlack) border[3] = 1;
    else if (_desc.borderColor == MTLSamplerBorderColorOpaqueWhite) border[0] = border[1] = border[2] = border[3] = 1;
    glSamplerParameterfv(_sampler, GL_TEXTURE_BORDER_COLOR, border);
    glSamplerParameterf(_sampler, GL_TEXTURE_MIN_LOD, _desc.lodMinClamp);
    glSamplerParameterf(_sampler, GL_TEXTURE_MAX_LOD, _desc.lodMaxClamp);
    if (_desc.maxAnisotropy > 1) glSamplerParameterf(_sampler, GL_TEXTURE_MAX_ANISOTROPY_EXT, MIN(_desc.maxAnisotropy, 16));
    if (_desc.compareFunction != MTLCompareFunctionNever) {
        glSamplerParameteri(_sampler, GL_TEXTURE_COMPARE_MODE, GL_COMPARE_REF_TO_TEXTURE);
        glSamplerParameteri(_sampler, GL_TEXTURE_COMPARE_FUNC, TSGLCompare(_desc.compareFunction));
    }
    return _sampler;
}

GLuint TSGLRectangleSamplerForConstexpr(uint64_t key) {
    static NSMutableDictionary<NSNumber *, NSNumber *> *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSNumber *hit = cache[@(key)];
    if (hit) return hit.unsignedIntValue;
    GLuint r = TSGLCreateRectangleSampler(TSGLSamplerForConstexpr(key));
    cache[@(key)] = @(r);
    return r;
}

GLuint TSGLCreateRectangleSampler(GLuint sampler) {
    GLuint r;
    glGenSamplers(1, &r);
    GLint minFilter = GL_NEAREST, magFilter = GL_NEAREST;
    if (sampler) {
        glGetSamplerParameteriv(sampler, GL_TEXTURE_MIN_FILTER, &minFilter);
        glGetSamplerParameteriv(sampler, GL_TEXTURE_MAG_FILTER, &magFilter);
        GLfloat border[4];
        glGetSamplerParameterfv(sampler, GL_TEXTURE_BORDER_COLOR, border);
        glSamplerParameterfv(r, GL_TEXTURE_BORDER_COLOR, border);
        GLenum wraps[3] = { GL_TEXTURE_WRAP_S, GL_TEXTURE_WRAP_T, GL_TEXTURE_WRAP_R };
        for (int i = 0; i < 3; i++) {
            GLint w;
            glGetSamplerParameteriv(sampler, wraps[i], &w);
            glSamplerParameteri(r, wraps[i], w == GL_CLAMP_TO_BORDER ? GL_CLAMP_TO_BORDER : GL_CLAMP_TO_EDGE);
        }
    } else {
        for (GLenum w = GL_TEXTURE_WRAP_S; w <= GL_TEXTURE_WRAP_T; w++) glSamplerParameteri(r, w, GL_CLAMP_TO_EDGE);
        glSamplerParameteri(r, GL_TEXTURE_WRAP_R, GL_CLAMP_TO_EDGE);
    }
    BOOL linear = minFilter == GL_LINEAR || minFilter == GL_LINEAR_MIPMAP_NEAREST || minFilter == GL_LINEAR_MIPMAP_LINEAR;
    glSamplerParameteri(r, GL_TEXTURE_MIN_FILTER, linear ? GL_LINEAR : GL_NEAREST);
    glSamplerParameteri(r, GL_TEXTURE_MAG_FILTER, magFilter);
    return r;
}

#pragma mark - Depth/stencil state

@implementation TSMtlDepthStencilState {
    TSGLDepthStencil _gl;
}
+ (void)initialize { if (self == [TSMtlDepthStencilState class]) TSMtlInstallCatchAll(self); }
- (instancetype)initWithDevice:(id)device depthStencilDescriptor:(MTLDepthStencilDescriptor *)desc {
    if ((self = [super initWithDevice:device depthStencilDescriptor:desc])) {
        _descriptor = [desc copy];
        TSGLBakeDepthStencil(_descriptor, &_gl);
    }
    return self;
}
- (const TSGLDepthStencil *)glState { return &_gl; }
@end

#pragma mark - Render pipeline

static GLuint TSGLCompile(GLenum type, NSString *source, NSString **log) {
    GLuint shader = glCreateShader(type);
    const char *src = source.UTF8String;
    glShaderSource(shader, 1, &src, NULL);
    glCompileShader(shader);
    GLint ok = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char buf[4096] = {0};
        glGetShaderInfoLog(shader, sizeof buf, NULL, buf);
        if (log) *log = [NSString stringWithUTF8String:buf];
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

static NSString *TSWrapVertex(NSString *body) {
    return [NSString stringWithFormat:@"#version 410 core\n#define TS_VERTEX 1\n#define main ts_main\n%@\n#undef main\n"
            "void main() { ts_main(); gl_Position.y = -gl_Position.y; gl_Position.z = 2.0 * gl_Position.z - gl_Position.w; }\n", body];
}

static NSString *TSWrapFragment(NSString *body) {
    return [NSString stringWithFormat:@"#version 410 core\n#define TS_FRAGMENT 1\n%@\n", body];
}

// Inserts #define lines right after the #version line of a wrapped shader.
static NSString *TSWithDefines(NSString *wrapped, NSString *defines) {
    if (!defines.length) return wrapped;
    return [wrapped stringByReplacingOccurrencesOfString:@"#version 410 core\n" withString:[@"#version 410 core\n" stringByAppendingString:defines]
                                                 options:NSAnchoredSearch range:NSMakeRange(0, wrapped.length)];
}

// Variant slots of a translated source, as TSSlotBuffer | stage << 8 | index: TSR_<stage><index> (texture sampled
// as a rectangle, see TSAirTranslator rectSlotFor:) and TSU_<stage><index> (device buffer bound at an offset that is
// not 16-aligned: word-by-word loads, see TSAirTranslator blockWord:at:).
static void TSCollectRectSlots(NSString *src, char stage, uint16_t *slots, NSUInteger *count) {
    if (![src containsString:@"#ifndef TSR_"] && ![src containsString:@"#ifndef TSU_"]) return;
    static NSRegularExpression *re;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ re = [NSRegularExpression regularExpressionWithPattern:@"#ifndef TS([RU])_([vf])([0-9]+)\n" options:0 error:nil]; });
    for (NSTextCheckingResult *m in [re matchesInString:src options:0 range:NSMakeRange(0, src.length)]) {
        if ([src characterAtIndex:[m rangeAtIndex:2].location] != stage) continue;
        int idx = [src substringWithRange:[m rangeAtIndex:3]].intValue;
        BOOL buffer = [src characterAtIndex:[m rangeAtIndex:1].location] == 'U';
        uint16_t slot = (uint16_t)((buffer ? TSSlotBuffer : 0) | (stage == 'f') << 8 | (idx & 0xff));
        BOOL dup = NO;
        for (NSUInteger i = 0; i < *count; i++) dup |= slots[i] == slot;
        if (!dup && *count < 32) slots[(*count)++] = slot;
    }
}

#pragma mark Drawn variants (P3)

// P3 (docs/OTTIMIZZAZIONE-AIR.md §4.3): the variant a pipeline drew last, as its TSR_ / TSU_ macros ("" = base
// program), in the disk cache as var/<sha256 of the two wrapped sources>. The next creation of the same pipeline
// links and warms up that variant instead of guessing: in Chrome 27% of the programs linked were never drawn
// (base programs of pipelines drawn only as rectangle variants). Keyed by the GLSL, so a new translator starts over.
static NSURL *TSVariantFile(NSString *vs, NSString *fs) {
    if (!TSRecordingOn() || !vs || !fs) return nil;
    NSMutableData *key = [[vs dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
    [key appendBytes:"\0" length:1];
    [key appendData:[fs dataUsingEncoding:NSUTF8StringEncoding]];
    return TSMtlDiskCacheFile(@"var", key);
}

static NSString *TSSlotMacro(uint16_t slot) {
    return [NSString stringWithFormat:@"TS%c_%c%u", (slot & TSSlotBuffer) ? 'U' : 'R', ((slot >> 8) & 1) ? 'f' : 'v', slot & 0xff];
}

static NSString *TSMaskMacros(const uint16_t *slots, NSUInteger n, uint32_t mask) {
    NSMutableArray *m = [NSMutableArray array];
    for (NSUInteger i = 0; i < n; i++) if (mask & (1u << i)) [m addObject:TSSlotMacro(slots[i])];
    return [m componentsJoinedByString:@" "];
}

static uint32_t TSMacrosMask(NSString *macros, const uint16_t *slots, NSUInteger n) {
    NSSet *set = [NSSet setWithArray:[macros componentsSeparatedByString:@" "]];
    uint32_t mask = 0;
    for (NSUInteger i = 0; i < n; i++) if ([set containsObject:TSSlotMacro(slots[i])]) mask |= 1u << i;
    return mask;
}

static NSString *TSFallbackVertex(void) {
    return @"layout(location = 0) in vec4 ts_position;\nvoid main() { gl_Position = ts_position; }\n";
}

// Solid magenta on every color attachment: visible marker for untranslated shaders.
static NSString *TSFallbackFragment(MTLRenderPipelineDescriptor *desc) {
    NSMutableString *decl = [NSMutableString string], *body = [NSMutableString string];
    for (NSUInteger i = 0; i < 8; i++) {
        MTLPixelFormat f = desc.colorAttachments[i].pixelFormat;
        if (f == MTLPixelFormatInvalid) continue;
        TSGLFormat gf = TSGLFormatFor(f);
        const char *type = gf.integer ? (gf.isSigned ? "ivec4" : "uvec4") : "vec4";
        [decl appendFormat:@"layout(location = %lu) out %s o%lu;\n", (unsigned long)i, type, (unsigned long)i];
        [body appendFormat:@"  o%lu = %s(1, 0, 1, 1);\n", (unsigned long)i, type];
    }
    return [NSString stringWithFormat:@"%@void main() {\n%@}\n", decl, body];
}

// GL programs (TSGLProgram, declared in TSPrivate.h) are shared by every pipeline with the same
// vertex + fragment source (C2): blend, write mask, formats and vertex layout live outside the
// program, so pipeline variants reuse it.

static GLenum TSGLSamplerTarget(GLenum type) {
    switch (type) {
    case GL_SAMPLER_1D: case GL_INT_SAMPLER_1D: case GL_UNSIGNED_INT_SAMPLER_1D: case GL_SAMPLER_1D_SHADOW: return GL_TEXTURE_1D;
    case GL_SAMPLER_1D_ARRAY: case GL_INT_SAMPLER_1D_ARRAY: case GL_UNSIGNED_INT_SAMPLER_1D_ARRAY: case GL_SAMPLER_1D_ARRAY_SHADOW:
        return GL_TEXTURE_1D_ARRAY;
    case GL_SAMPLER_2D_ARRAY: case GL_INT_SAMPLER_2D_ARRAY: case GL_UNSIGNED_INT_SAMPLER_2D_ARRAY: case GL_SAMPLER_2D_ARRAY_SHADOW:
        return GL_TEXTURE_2D_ARRAY;
    case GL_SAMPLER_3D: case GL_INT_SAMPLER_3D: case GL_UNSIGNED_INT_SAMPLER_3D: return GL_TEXTURE_3D;
    case GL_SAMPLER_CUBE: case GL_INT_SAMPLER_CUBE: case GL_UNSIGNED_INT_SAMPLER_CUBE: case GL_SAMPLER_CUBE_SHADOW: return GL_TEXTURE_CUBE_MAP;
    case GL_SAMPLER_BUFFER: case GL_INT_SAMPLER_BUFFER: case GL_UNSIGNED_INT_SAMPLER_BUFFER: return GL_TEXTURE_BUFFER;
    case GL_SAMPLER_2D_MULTISAMPLE: case GL_INT_SAMPLER_2D_MULTISAMPLE: case GL_UNSIGNED_INT_SAMPLER_2D_MULTISAMPLE:
        return GL_TEXTURE_2D_MULTISAMPLE;
    case GL_SAMPLER_2D_RECT: case GL_INT_SAMPLER_2D_RECT: case GL_UNSIGNED_INT_SAMPLER_2D_RECT: case GL_SAMPLER_2D_RECT_SHADOW:
        return GL_TEXTURE_RECTANGLE;
    case 0x900C: case 0x900D: case 0x900E: case 0x900F: return 0x9009;   // cube map arrays (ARB_texture_cube_map_array)
    default: return GL_TEXTURE_2D;
    }
}

// 1x1 placeholder texture for a target (GPU queue), so a warm-up draw never samples an unbound unit.
static GLuint TSGLDummyTexture(GLenum target) {
    static NSMutableDictionary<NSNumber *, NSNumber *> *dummies;
    if (!dummies) dummies = [NSMutableDictionary dictionary];
    NSNumber *hit = dummies[@(target)];
    if (hit) return hit.unsignedIntValue;
    static const uint32_t texel[6] = {0};
    GLuint t;
    glGenTextures(1, &t);
    glBindTexture(target, t);
    switch (target) {
    case GL_TEXTURE_1D: glTexImage1D(target, 0, GL_RGBA8, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, texel); break;
    case GL_TEXTURE_1D_ARRAY: case GL_TEXTURE_RECTANGLE: case GL_TEXTURE_2D:
        glTexImage2D(target, 0, GL_RGBA8, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, texel); break;
    case GL_TEXTURE_2D_ARRAY: case GL_TEXTURE_3D: glTexImage3D(target, 0, GL_RGBA8, 1, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, texel); break;
    case 0x9009: glTexImage3D(target, 0, GL_RGBA8, 1, 1, 6, 0, GL_RGBA, GL_UNSIGNED_BYTE, texel); break;
    case GL_TEXTURE_CUBE_MAP:
        for (GLenum f = 0; f < 6; f++) glTexImage2D(GL_TEXTURE_CUBE_MAP_POSITIVE_X + f, 0, GL_RGBA8, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, texel);
        break;
    case GL_TEXTURE_2D_MULTISAMPLE: glTexImage2DMultisample(target, 1, GL_RGBA8, 1, 1, GL_TRUE); break;
    case GL_TEXTURE_BUFFER: {
        GLuint b;
        glGenBuffers(1, &b);
        glBindBuffer(GL_TEXTURE_BUFFER, b);
        glBufferData(GL_TEXTURE_BUFFER, 256, NULL, GL_STATIC_DRAW);
        glTexBuffer(GL_TEXTURE_BUFFER, GL_R32UI, b);
        break;
    }
    }
    if (target != GL_TEXTURE_BUFFER && target != GL_TEXTURE_2D_MULTISAMPLE) {
        glTexParameteri(target, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
        glTexParameteri(target, GL_TEXTURE_MAX_LEVEL, 0);
    }
    glBindTexture(target, 0);
    dummies[@(target)] = @(t);
    return t;
}

uint64_t gTSGLProgramLinkCount;

@implementation TSGLProgram
- (void)dealloc {
    GLuint p = _program;
    if (p) [_device gpuAsync:^{ glDeleteProgram(p); }];
    free(_blocks);
    free(_textures);
    free(_targets);
}

static GLuint TSGLLink(NSString *vs, NSString *fs, NSString **log) {
    GLuint v = TSGLCompile(GL_VERTEX_SHADER, vs, log);
    GLuint f = v ? TSGLCompile(GL_FRAGMENT_SHADER, fs, log) : 0;
    if (!v || !f) { if (v) glDeleteShader(v); return 0; }
    GLuint p = glCreateProgram();
    glAttachShader(p, v);
    glAttachShader(p, f);
    for (NSUInteger i = 0; i < 8; i++) glBindFragDataLocationIndexed(p, (GLuint)i, 0, [NSString stringWithFormat:@"o%lu", (unsigned long)i].UTF8String);
    glLinkProgram(p);
    glDeleteShader(v);
    glDeleteShader(f);
    GLint ok = 0;
    glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (!ok) {
        char buf[4096] = {0};
        glGetProgramInfoLog(p, sizeof buf, NULL, buf);
        if (log) *log = [NSString stringWithUTF8String:buf];
        glDeleteProgram(p);
        return 0;
    }
    return p;
}

// GPU queue. Cached program for the pair, or a new one; nil (with *log) if it does not link.
+ (TSGLProgram *)programForDevice:(TSMtlDevice *)device vertex:(NSString *)vs fragment:(NSString *)fs log:(NSString **)log {
    static NSMapTable<NSString *, TSGLProgram *> *cache;
    if (!cache) cache = [NSMapTable strongToWeakObjectsMapTable];
    NSString *key = [NSString stringWithFormat:@"%p\n%@\n%@", device, vs, fs];
    TSGLProgram *hit = [cache objectForKey:key];
    if (hit) { TSMtlStat(TSStatProgramHits, 1); return hit; }
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    GLuint p = TSGLLink(vs, fs, log);
    TSMtlStat(TSStatLinkMicros, (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1000);
    gTSGLProgramLinkCount++;
    if (!p) return nil;
    TSMtlStat(TSStatProgramLinks, 1);
    TSGLProgram *prog = [TSGLProgram new];
    prog->_device = device;
    prog->_program = p;
    [prog introspect];
    if (!getenv("TSMTL_NO_WARMUP")) {
        t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        [prog warmUp];
        TSMtlStat(TSStatWarmupMicros, (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1000);
    }
    prog->_uniforms.baseInstance = prog->_uniforms.baseVertex = INT32_MIN;
    for (int i = 0; i < 32; i++) prog->_uniforms.bufferOffset[i] = INT32_MIN;
    for (int i = 0; i < 8; i++) prog->_uniforms.texInfo[i] = INT32_MIN;
    [cache setObject:prog forKey:key];
    return prog;
}

// Maps the ABI names onto GL binding points and texture units.
- (void)introspect {
    GLuint p = _program;
    _baseInstanceLocation = glGetUniformLocation(p, "ts_base_instance");
    _baseVertexLocation = glGetUniformLocation(p, "ts_base_vertex");
    _gridLocation = glGetUniformLocation(p, "ts_grid");
    _threadgroupLocation = glGetUniformLocation(p, "ts_tg");
    _outSizeLocation = glGetUniformLocation(p, "ts_out_size");
    GLint n = 0;
    char name[256];
    glGetProgramiv(p, GL_ACTIVE_UNIFORM_BLOCKS, &n);
    _blocks = calloc(MAX(n, 1), sizeof *_blocks);
    for (GLint i = 0; i < n; i++) {
        glGetActiveUniformBlockName(p, i, sizeof name, NULL, name);
        char stage;
        unsigned idx;
        if (sscanf(name, "%cbuf%u", &stage, &idx) != 2 || (stage != 'v' && stage != 'f') || idx > 30) {
            TSMtlWarn(@"program %u: uniform block %s does not follow the ABI, ignored", p, name);
            continue;
        }
        TSGLBinding *b = &_blocks[_blockCount++];
        b->stage = stage == 'f';
        b->index = idx;
        glGetActiveUniformBlockiv(p, i, GL_UNIFORM_BLOCK_DATA_SIZE, &b->size);
        glUniformBlockBinding(p, i, b->stage * 31 + idx);
    }
    glGetProgramiv(p, GL_ACTIVE_UNIFORMS, &n);
    _textures = calloc(MAX(n, 1), sizeof *_textures);
    _targets = calloc(MAX(n, 1), sizeof *_targets);
    glUseProgram(p);
    for (GLint i = 0; i < n; i++) {
        GLint size;
        GLenum type;
        glGetActiveUniform(p, i, sizeof name, NULL, &size, &type, name);
        char stage;
        unsigned tex, smp;
        unsigned long long key;
        TSGLBinding *b = &_textures[_textureCount];
        memset(b, 0, sizeof *b);
        size_t len = strlen(name);
        if (sscanf(name, "%ctexinfo%u", &stage, &tex) == 2 && (stage == 'v' || stage == 'f')) {
            if (_infoCount < 8 && tex < 128)
                _infos[_infoCount++] = (TSGLBinding){ .stage = stage == 'f', .index = (uint8_t)tex, .aux = glGetUniformLocation(p, name) };
            continue;
        }
        if (sscanf(name, "%cssbo%u", &stage, &tex) == 2 && (stage == 'v' || stage == 'f') && len > 2 &&
            (!strcmp(name + len - 2, "_4") || !strcmp(name + len - 2, "_2"))) {
            b->kind = name[len - 1] == '4' ? 3 : 4;
            b->index = tex;
            // Shares <name>_off with the R32UI view, which may be unused (inactive) in this program.
            b->aux = glGetUniformLocation(p, [NSString stringWithFormat:@"%cssbo%u_off", stage, tex].UTF8String);
        } else if (sscanf(name, "%cssbo%u", &stage, &tex) == 2 && (stage == 'v' || stage == 'f') && !strstr(name, "_off")) {
            b->kind = 2;
            b->index = tex;
            b->aux = glGetUniformLocation(p, [NSString stringWithFormat:@"%s_off", name].UTF8String);
        } else if (sscanf(name, "%ctex%u_k%16llx", &stage, &tex, &key) == 3 && (stage == 'v' || stage == 'f')) {
            b->kind = 1;
            b->index = tex;
            b->key = key;
            b->aux = (GLint)TSGLSamplerForConstexpr(key);   // GL sampler object, resolved once
        } else {
            int fields = sscanf(name, "%ctex%u_s%u", &stage, &tex, &smp);
            if (fields < 2 || (stage != 'v' && stage != 'f')) continue;
            b->index = tex;
            b->sampler = fields == 2 ? tex : smp;
        }
        b->stage = stage == 'f';
        _targets[_textureCount] = TSGLSamplerTarget(type);
        b->rect = _targets[_textureCount] == GL_TEXTURE_RECTANGLE;
        b->unit = (GLint)_textureCount++;
        glUniform1i(glGetUniformLocation(p, name), b->unit);
    }
    glUseProgram(0);
}

// The driver compiles the hardware variant of a program at its first draw (18-200 ms with
// complex shaders) and keeps it per context, so a shared context cannot do it in the
// background (measured). A 1x1 draw right after linking moves that cost from the first
// frame to pipeline creation, which apps do while loading (C4). Blend state does not cause
// a recompile; other attachment formats may. Every resource the program reads is bound to
// a placeholder, and passes reset their GL state shadow, so nothing leaks.
- (void)warmUp {
    // Linked mid-pass while the pass counts visibility samples: the 1x1 draw would be counted.
    GLint active = 0, any = 0;
    glGetQueryiv(GL_SAMPLES_PASSED, GL_CURRENT_QUERY, &active);
    glGetQueryiv(GL_ANY_SAMPLES_PASSED, GL_CURRENT_QUERY, &any);
    if (active || any) return;
    static GLuint fbo, vao, color, zeros;
    if (!fbo) {
        glGenFramebuffers(1, &fbo);
        glGenVertexArrays(1, &vao);
        glGenTextures(1, &color);
        glBindTexture(GL_TEXTURE_2D, color);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 1, 1, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
        glBindTexture(GL_TEXTURE_2D, 0);
        glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbo);
        glFramebufferTexture2D(GL_DRAW_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, color, 0);
        glGenBuffers(1, &zeros);
        glBindBuffer(GL_UNIFORM_BUFFER, zeros);
        void *z = calloc(1, 65536);   // explicit zeros: uniform-driven loops end at once
        glBufferData(GL_UNIFORM_BUFFER, 65536, z, GL_STATIC_DRAW);
        free(z);
    }
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, fbo);
    GLenum buf = GL_COLOR_ATTACHMENT0;
    glDrawBuffers(1, &buf);
    if (glCheckFramebufferStatus(GL_DRAW_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) { glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0); return; }
    glBindVertexArray(vao);
    glUseProgram(_program);
    for (NSUInteger i = 0; i < _blockCount; i++) glBindBufferRange(GL_UNIFORM_BUFFER, _blocks[i].stage * 31 + _blocks[i].index, zeros, 0, 65536);
    for (NSUInteger i = 0; i < _textureCount; i++) {
        glActiveTexture(GL_TEXTURE0 + _textures[i].unit);
        glBindTexture(_targets[i], TSGLDummyTexture(_targets[i]));
        glBindSampler(_textures[i].unit, 0);
    }
    glActiveTexture(GL_TEXTURE0);
    glViewport(0, 0, 1, 1);
    glDisable(GL_SCISSOR_TEST);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glUseProgram(0);
    glBindVertexArray(0);
    glBindFramebuffer(GL_DRAW_FRAMEBUFFER, 0);
}
@end

@implementation TSMtlRenderPipelineState {
    TSMtlDevice *_device;
    TSGLProgram *_prog;
    TSGLPipelineState _gl;
    NSString *_vsWrapped, *_fsWrapped;              // translated sources, for the rectangle variants
    uint16_t _rectSlots[32];
    NSUInteger _rectSlotCount;
    NSMutableDictionary<NSNumber *, TSGLProgram *> *_variants;   // GPU queue
    NSString *_profileName;
    NSURL *_variantFile;                // P3: where the drawn variant is recorded (nil = not recorded)
    uint32_t _recordedMask;             // the variant the file names (GPU queue after creation)
    int _variantWrites;                 // records written by this object (bounded: pipelines may alternate)
}

+ (void)initialize { if (self == [TSMtlRenderPipelineState class]) TSMtlInstallCatchAll(self); }

- (instancetype)initWithDevice:(TSMtlDevice *)device descriptor:(MTLRenderPipelineDescriptor *)desc error:(NSError **)error {
    if (!(self = [super init])) return nil;
    uint64_t created = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    _device = device;
    _descriptor = [desc copy];
    self.label = desc.label;

    if (gTSMtlTraceOn && (desc.fragmentLinkedFunctions.functions.count || desc.fragmentLinkedFunctions.privateFunctions.count ||
                          desc.fragmentLinkedFunctions.binaryFunctions.count || desc.fragmentLinkedFunctions.groups.count)) {
        MTLLinkedFunctions *lf = desc.fragmentLinkedFunctions;
        NSMutableArray *names = [NSMutableArray array];
        for (id<MTLFunction> f in lf.functions) [names addObject:[NSString stringWithFormat:@"fn %@ (%@)", f.name, [(id)f class]]];
        for (id<MTLFunction> f in lf.privateFunctions) [names addObject:[NSString stringWithFormat:@"private %@ (%@)", f.name, [(id)f class]]];
        for (id<MTLFunction> f in lf.binaryFunctions) [names addObject:[NSString stringWithFormat:@"binary %@", f.name]];
        for (NSString *g in lf.groups) [names addObject:[NSString stringWithFormat:@"group %@ = %lu", g, (unsigned long)lf.groups[g].count]];
        TSMtlTraceOnce(@"pipeline %@ fragment %@ linked: %@", desc.label, desc.fragmentFunction.name, [names componentsJoinedByString:@", "]);
    }
    __block NSString *failure = nil;
    NSDictionary *qualifiers = nil;
    NSString *fsError = nil, *vsError = nil;
    NSString *fs = desc.fragmentFunction ? TSShaderSource(desc.fragmentFunction, desc.fragmentLinkedFunctions, nil, &qualifiers, &fsError)
                                         : @"void main() {}\n";
    NSString *vs = desc.vertexFunction ? TSShaderSource(desc.vertexFunction, desc.vertexLinkedFunctions, qualifiers, NULL, &vsError) : nil;
    TSGLBakePipeline(_descriptor, &_gl);
    _gl.usesVertexID = [vs containsString:@"gl_VertexID"] || [vs containsString:@"ts_base_vertex"];
    if (!vs) failure = [NSString stringWithFormat:@"vertex %@: %@", desc.vertexFunction.name, vsError ?: @"missing"];
    else if (!fs) failure = [NSString stringWithFormat:@"fragment %@: %@", desc.fragmentFunction.name, fsError];
    if (!failure) {
        _vsWrapped = TSWrapVertex(vs);
        _fsWrapped = TSWrapFragment(fs);
        TSCollectRectSlots(vs, 'v', _rectSlots, &_rectSlotCount);
        TSCollectRectSlots(fs, 'f', _rectSlots, &_rectSlotCount);
    }
    // P3: the variant this pipeline drew last time, if it was not the base program.
    uint32_t predicted = 0;
    if (!failure && _rectSlotCount && (_variantFile = TSVariantFile(_vsWrapped, _fsWrapped))) {
        NSString *macros = [NSString stringWithContentsOfURL:_variantFile encoding:NSUTF8StringEncoding error:nil];
        if (macros.length) predicted = _recordedMask = TSMacrosMask(macros, _rectSlots, _rectSlotCount);
    }
    // Link and warm up now: the recorded variant, else the base program. Measured alternatives that were not
    // better (docs/FINDINGS-RENDERING.md §22): base program on first need, all-rectangles variant first (a blind
    // guess, unlike the record), links on a shared context.
    [device gpuSync:^{
        uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        TSGLProgram *variant = predicted ? [self linkVariant:predicted log:NULL] : nil;
        if (variant) {
            self->_variants = [NSMutableDictionary dictionaryWithObject:variant forKey:@(predicted)];
            TSMtlStat(TSStatPredictedVariants, 1);
        } else {
            if (!failure) self->_prog = [TSGLProgram programForDevice:device vertex:self->_vsWrapped fragment:self->_fsWrapped log:&failure];
            if (!self->_prog) [self useFallback:failure];
        }
        TSMtlStat(TSStatPipelineSyncMicros, (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1000);
    }];
    TSMtlStatAlways(TSStatPipelines, 1);
    TSMtlStat(TSStatPipelineMicros, (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - created) / 1000);
    static int pipeLog = -1;
    if (pipeLog < 0) pipeLog = getenv("TSMTL_PIPE_LOG") != NULL;
    if (pipeLog) {   // per pipeline: who created it and how long it took (TSMTL_PIPE_LOG=1)
        char thread[64] = "";
        pthread_getname_np(pthread_self(), thread, sizeof thread);
        fprintf(stderr, "[TSPipe] %.1f ms thread '%s'%s rect %lu %s/%s\n", (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - created) / 1e6, thread,
                pthread_main_np() ? " (main)" : "", (unsigned long)_rectSlotCount, desc.vertexFunction.name.UTF8String,
                desc.fragmentFunction.name.UTF8String);
    }
    if (gTSMtlTraceOn)
        TSMtlTraceOnce(@"pipeline %@/%@ samples %lu c0 fmt%lu depth fmt%lu%@", desc.vertexFunction.name, desc.fragmentFunction.name,
                       (unsigned long)desc.rasterSampleCount, (unsigned long)desc.colorAttachments[0].pixelFormat,
                       (unsigned long)desc.depthAttachmentPixelFormat, _usesFallback ? @" FALLBACK" : @"");
    return self;
}

- (NSString *)profileName {
    // Interned for the profiler's unretained references; pipelines may die before their draws are read.
    static NSMutableSet *names;
    static os_unfair_lock lock = OS_UNFAIR_LOCK_INIT;
    if (!_profileName) {
        NSString *n = [NSString stringWithFormat:@"%@/%@%@", _descriptor.vertexFunction.name, _descriptor.fragmentFunction.name,
                       _usesFallback ? @" (fallback)" : @""];
        os_unfair_lock_lock(&lock);
        if (!names) names = [NSMutableSet set];
        NSString *hit = [names member:n];
        if (!hit) [names addObject:(hit = n)];
        os_unfair_lock_unlock(&lock);
        _profileName = hit;
    }
    return _profileName;
}

- (const uint16_t *)rectSlots { return _rectSlots; }
- (NSUInteger)rectSlotCount { return _rectSlotCount; }
// GPU queue. The base program, linked on first need when creation linked the recorded variant instead (P3).
- (TSGLProgram *)baseProgram {
    if (!_prog && !_usesFallback) {
        NSString *failure = nil;
        TSMtlStat(TSStatVariantLinks, 1);
        _prog = [TSGLProgram programForDevice:_device vertex:_vsWrapped fragment:_fsWrapped log:&failure];
        if (!_prog) [self useFallback:failure];
    }
    return _prog;
}

// GPU queue: the encoder draws with the variant `mask`. Recorded when it differs from what the file says (P3).
- (void)noteDrawnMask:(uint32_t)mask {
    if (!_variantFile || mask == _recordedMask || _variantWrites >= 4) return;
    _recordedMask = mask;
    _variantWrites++;
    NSURL *file = _variantFile;
    NSData *macros = [TSMaskMacros(_rectSlots, _rectSlotCount, mask) dataUsingEncoding:NSUTF8StringEncoding];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ TSMtlDiskCacheWrite(file, macros); });
}

// GPU queue, at creation. The base program does not link: draw with the fallback shader.
- (void)useFallback:(NSString *)failure {
    MTLRenderPipelineDescriptor *desc = _descriptor;
    _usesFallback = YES;
    _rectSlotCount = 0;
    _prog = [TSGLProgram programForDevice:_device vertex:TSWrapVertex(TSFallbackVertex())
                                 fragment:TSWrapFragment(TSFallbackFragment(desc)) log:NULL];
    TSMtlStatAlways(TSStatFallbacks, 1);
    TSMtlError(@"pipeline %@ (%@/%@) uses the fallback shader: %@", desc.label, desc.vertexFunction.name, desc.fragmentFunction.name, failure);
}

// GPU queue. The program with TSR_ / TSU_<slot> = 1 for every slot in the mask; the base program if it fails to link.
- (TSGLProgram *)programForRectMask:(uint32_t)mask {
    if (!mask || !_rectSlotCount) return self.baseProgram;
    if (!_variants) _variants = [NSMutableDictionary dictionary];
    TSGLProgram *hit = _variants[@(mask)];
    if (hit) return hit;
    NSString *log = nil;
    TSGLProgram *prog = [self linkVariant:mask log:&log];
    if (!prog) {
        TSMtlWarn(@"pipeline %@: variant 0x%x does not link, sampling through copies: %@", self.label, mask, log);
        prog = self.baseProgram;
    }
    _variants[@(mask)] = prog;
    return prog;
}

// GPU queue: links the variant `mask` (nil if it does not link).
- (TSGLProgram *)linkVariant:(uint32_t)mask log:(NSString **)log {
    NSMutableString *vdefs = [NSMutableString string], *fdefs = [NSMutableString string];
    BOOL unaligned = NO;
    for (NSUInteger i = 0; i < _rectSlotCount; i++) {
        if (!(mask & (1u << i))) continue;
        BOOL frag = (_rectSlots[i] >> 8) & 1, buffer = (_rectSlots[i] & TSSlotBuffer) != 0;
        unaligned |= buffer;
        [frag ? fdefs : vdefs appendFormat:@"#define TS%c_%c%u 1\n", buffer ? 'U' : 'R', frag ? 'f' : 'v', _rectSlots[i] & 0xff];
    }
    TSMtlStat(TSStatVariantLinks, 1);
    if (unaligned) TSMtlStatAlways(TSStatUnalignedVariants, 1);
    return [TSGLProgram programForDevice:_device vertex:TSWithDefines(_vsWrapped, vdefs) fragment:TSWithDefines(_fsWrapped, fdefs) log:log];
}

- (GLuint)glProgram { return self.baseProgram->_program; }
- (GLint)baseInstanceLocation { return self.baseProgram->_baseInstanceLocation; }
- (GLint)baseVertexLocation { return self.baseProgram->_baseVertexLocation; }
- (const TSGLPipelineState *)glState { return &_gl; }
- (TSGLProgramUniforms *)programUniforms { return &self.baseProgram->_uniforms; }
- (const TSGLBinding *)uniformBlocks { return self.baseProgram->_blocks; }
- (NSUInteger)uniformBlockCount { return self.baseProgram->_blockCount; }
- (const TSGLBinding *)textures { return self.baseProgram->_textures; }
- (const TSGLBinding *)textureInfos { return self.baseProgram->_infos; }
- (NSUInteger)textureInfoCount { return self.baseProgram->_infoCount; }
- (NSUInteger)textureCount { return self.baseProgram->_textureCount; }
- (id<MTLDevice>)device { return _device; }
- (NSUInteger)maxTotalThreadsPerThreadgroup { return 0; }
- (BOOL)threadgroupSizeMatchesTileSize { return NO; }
- (NSUInteger)imageblockSampleLength { return 0; }
- (BOOL)supportIndirectCommandBuffers { return NO; }
- (MTLResourceID)gpuResourceID { return (MTLResourceID){ (uint64_t)(__bridge void *)self }; }
@end

#pragma mark - Compute pipeline

// The translated kernel's main becomes ts_main: a thread that wrote nothing leaves its texel alone.
static NSString *TSWrapKernel(NSString *body) {
    return [NSString stringWithFormat:@"#version 410 core\n#define TS_FRAGMENT 1\n#define main ts_main\n%@\n#undef main\n"
            "void main() { ts_main(); if (!ts_wrote) discard; }\n", body];
}

// One triangle covering the viewport (= the dispatched grid, clipped to the written texture). No y flip:
// GL row 0 is Metal row 0 in our textures, so gl_FragCoord.xy is thread_position_in_grid.
static NSString *TSKernelVertex(void) {
    return @"#version 410 core\nvoid main() { vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);"
            " gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0); }\n";
}

// Same decision as -initWithDevice:function: below, without linking: the translator found the written texture.
BOOL TSMtlKernelFitsGL(id<MTLFunction> function) {
    NSString *error = nil, *glsl = TSShaderSource(function, nil, nil, NULL, &error);
    return glsl && [glsl rangeOfString:@"// ts_kernel_output "].location != NSNotFound;
}

@implementation TSMtlComputePipelineState {
    TSMtlDevice *_device;
    TSGLProgram *_prog;
    NSString *_fsWrapped;
    uint16_t _rectSlots[32];
    NSUInteger _rectSlotCount;
    NSMutableDictionary<NSNumber *, TSGLProgram *> *_variants;   // GPU queue
}

- (instancetype)initWithDevice:(TSMtlDevice *)device function:(id<MTLFunction>)function {
    if (!(self = [super initWithDevice:device protocols:@[@protocol(MTLComputePipelineState)]])) return nil;
    _device = device;
    _outputTextureIndex = -1;
    if (!TSMtlComputeEnabled()) { _computePath = @"off"; return self; }
    NSString *error = nil, *glsl = TSShaderSource(function, nil, nil, NULL, &error);
    __block NSString *failure = glsl ? nil : error;
    if (glsl) {
        // The translator marks the texture slot whose writes became the output o0.
        NSRange r = [glsl rangeOfString:@"// ts_kernel_output "];
        _outputTextureIndex = r.location == NSNotFound ? -1 : [glsl substringFromIndex:NSMaxRange(r)].integerValue;
        if (_outputTextureIndex < 0) failure = @"no texture output";
        _fsWrapped = TSWrapKernel(glsl);
        TSCollectRectSlots(glsl, 'f', _rectSlots, &_rectSlotCount);
    }
    if (!failure)
        [device gpuSync:^{
            self->_prog = [TSGLProgram programForDevice:device vertex:TSKernelVertex() fragment:self->_fsWrapped log:&failure];
        }];
    _runsOnGL = _prog != nil;
    if (_runsOnGL) {
        _computePath = @"gl";
        TSMtlCompute(@"kernel %@ runs as a GL pass (texture %ld)", function.name, (long)_outputTextureIndex);
        return self;
    }
    // Not expressible as a fragment pass: OpenCL (TSMtlComputeCL.m).
    NSString *clFailure = nil;
    _clKernel = TSMtlCLKernelForFunction(device, function, &clFailure);
    if (_clKernel) { _computePath = @"cl"; return self; }
    _computePath = [NSString stringWithFormat:@"GL pass: %@; OpenCL: %@", failure, clFailure];
    TSMtlStatAlways(TSStatComputeRejected, 1);
    TSMtlCompute(@"kernel %@ does not run: %@", function.name, _computePath);
    return self;
}

// GPU queue: as -[TSMtlRenderPipelineState programForRectMask:], fragment stage only.
- (TSGLProgram *)programForRectMask:(uint32_t)mask {
    if (!mask || !_rectSlotCount || !_prog) return _prog;
    if (!_variants) _variants = [NSMutableDictionary dictionary];
    TSGLProgram *hit = _variants[@(mask)];
    if (hit) return hit;
    NSMutableString *defs = [NSMutableString string];
    BOOL unaligned = NO;
    for (NSUInteger i = 0; i < _rectSlotCount; i++) {
        if (!(mask & (1u << i))) continue;
        BOOL buffer = (_rectSlots[i] & TSSlotBuffer) != 0;
        unaligned |= buffer;
        [defs appendFormat:@"#define TS%c_f%u 1\n", buffer ? 'U' : 'R', _rectSlots[i] & 0xff];
    }
    NSString *log = nil;
    TSMtlStat(TSStatVariantLinks, 1);
    if (unaligned) TSMtlStatAlways(TSStatUnalignedVariants, 1);
    TSGLProgram *prog = [TSGLProgram programForDevice:_device vertex:TSKernelVertex() fragment:TSWithDefines(_fsWrapped, defs) log:&log];
    if (!prog) {
        TSMtlWarn(@"compute pipeline %@: variant 0x%x does not link, sampling through copies: %@", self.label, mask, log);
        prog = _prog;
    }
    _variants[@(mask)] = prog;
    return prog;
}

- (const uint16_t *)rectSlots { return _rectSlots; }
- (NSUInteger)rectSlotCount { return _rectSlotCount; }
- (id<MTLDevice>)device { return _device; }
// The GL path has no threadgroup semantics left (no barriers, no threadgroup memory): any shape runs. OpenCL
// kernels report the driver's work-group limit (256 on the HD 6750M); AMD wavefronts are 64 wide.
- (NSUInteger)maxTotalThreadsPerThreadgroup { return _clKernel ? _clKernel->maxThreads : 1024; }
- (NSUInteger)threadExecutionWidth { return 64; }
- (NSUInteger)staticThreadgroupMemoryLength { return _clKernel ? _clKernel->staticThreadgroupMemory : 0; }
- (BOOL)supportIndirectCommandBuffers { return NO; }
- (MTLResourceID)gpuResourceID { return (MTLResourceID){ (uint64_t)(__bridge void *)self }; }
@end
