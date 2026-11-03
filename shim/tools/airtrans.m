// Developer tool: translate every function of an MSL file to GLSL and compile the result
// with the real GL driver. Usage: airtrans file.metal|file.metallib [-v] [function]   (-v prints the GLSL)
// Kernels are tried as fragment shaders (TeraScale Compute GL path); those that need OpenCL are listed as "cl".
#import <Foundation/Foundation.h>
#define GL_SILENCE_DEPRECATION 1
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl3.h>
#import "TSMetal.h"
NSString *TSAirTranslate(NSData *, NSDictionary *, NSDictionary **, NSString **);

static NSString *compile(GLenum type, NSString *src) {
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

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 2) { fprintf(stderr, "usage: airtrans file.metal|file.metallib [-v] [function]\n"); return 2; }
    BOOL verbose = NO;
    const char *only = NULL;
    for (int i = 2; i < argc; i++) { if (!strcmp(argv[i], "-v")) verbose = YES; else only = argv[i]; }
    id<MTLDevice> d = TSMtlCreateDevice();   // also creates a GL context we can borrow
    CGLPixelFormatAttribute a[] = { kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core, kCGLPFAAccelerated, 0 };
    CGLPixelFormatObj pf; GLint npf; CGLChoosePixelFormat(a, &pf, &npf);
    CGLContextObj ctx; CGLCreateContext(pf, NULL, &ctx); CGLSetCurrentContext(ctx);
    NSString *path = @(argv[1]);
    NSError *e = nil;
    id<MTLLibrary> lib = [path.pathExtension isEqualToString:@"metallib"]
        ? [d newLibraryWithURL:[NSURL fileURLWithPath:path] error:&e]
        : [d newLibraryWithSource:[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] options:nil error:&e];
    if (!lib) { fprintf(stderr, "%s\n", e.description.UTF8String); return 1; }
    int ok = 0, total = 0;
    for (NSString *name in [lib.functionNames sortedArrayUsingSelector:@selector(compare:)]) {
        if (only && strcmp(name.UTF8String, only)) continue;
        id<MTLFunction> f = [lib newFunctionWithName:name];
        if (f.functionConstantsDictionary.count) {
            // Apps specialize these at pipeline creation; zero (false) every constant to get one variant.
            MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new];
            uint8_t zero[64] = {0};
            // AIR_CONST=<hex bytes> (e.g. 00001000 = uint bit 20) fills every constant with those bytes instead of zero.
            const char *hex = getenv("AIR_CONST");
            for (int i = 0; hex && i < 64 && isxdigit(hex[2 * i]) && isxdigit(hex[2 * i + 1]); i++)
                sscanf(hex + 2 * i, "%2hhx", &zero[i]);
            for (MTLFunctionConstant *k in f.functionConstantsDictionary.allValues) [cv setConstantValue:zero type:k.type atIndex:k.index];
            NSError *ce = nil;
            id<MTLFunction> sf = [lib newFunctionWithName:name constantValues:cv error:&ce];
            if (!sf) { printf("  FAIL  %-28s specialize: %s\n", name.UTF8String, ce.localizedDescription.UTF8String); total++; continue; }
            f = sf;
        }
        BOOL kernel = f.functionType == MTLFunctionTypeKernel;
        NSData *bc = (NSData *)[(id)f performSelector:@selector(bitcodeData)];
        NSString *err = nil;
        NSString *glsl = TSAirTranslate(bc, nil, NULL, &err);
        if (!glsl && kernel) { printf("  cl    %-28s %s\n", name.UTF8String, err.UTF8String); continue; }
        total++;
        if (!glsl) { printf("  FAIL  %-28s translate: %s\n", name.UTF8String, err.UTF8String); continue; }
        BOOL vertex = f.functionType == MTLFunctionTypeVertex;
        NSString *full = vertex
            ? [NSString stringWithFormat:@"#version 410 core\n#define main ts_main\n%@\n#undef main\nvoid main() { ts_main(); }\n", glsl]
            : kernel ? [NSString stringWithFormat:@"#version 410 core\n#define main ts_main\n%@\n#undef main\n"
                                                  "void main() { ts_main(); if (!ts_wrote) discard; }\n", glsl]
            : [NSString stringWithFormat:@"#version 410 core\n%@", glsl];
        NSString *log = compile(vertex ? GL_VERTEX_SHADER : GL_FRAGMENT_SHADER, full);
        if (!log && [glsl containsString:@"#ifndef TSR_"]) {
            // Also the variant with every 2D slot as an IOSurface rectangle texture (all TSR_* = 1).
            NSMutableString *defs = [NSMutableString string];
            NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"#ifndef (TSR_[vf][0-9]+)" options:0 error:nil];
            for (NSTextCheckingResult *m in [re matchesInString:glsl options:0 range:NSMakeRange(0, glsl.length)])
                [defs appendFormat:@"#define %@ 1\n", [glsl substringWithRange:[m rangeAtIndex:1]]];
            NSString *rect = [full stringByReplacingOccurrencesOfString:@"#version 410 core\n"
                                                             withString:[@"#version 410 core\n" stringByAppendingString:defs]];
            log = compile(vertex ? GL_VERTEX_SHADER : GL_FRAGMENT_SHADER, rect);
            if (log) log = [@"(rectangle variant) " stringByAppendingString:log];
        }
        if (log) printf("  FAIL  %-28s GLSL: %s", name.UTF8String, log.UTF8String);
        else { printf("  ok    %-28s %lu lines\n", name.UTF8String, (unsigned long)[glsl componentsSeparatedByString:@"\n"].count); ok++; }
        if (verbose || log) printf("%s\n", glsl.UTF8String);
    }
    printf("%d/%d translated and compiled\n", ok, total);
    return ok == total ? 0 : 1;
} }
