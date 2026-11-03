// TeraScale Glass (docs/PIANO-GLASS.md): Apple's Liquid Glass shader inside Moraea's OpenGL compositor.
//
// WindowServer composes AppKit glass with CoreAnimation's OpenGL renderer; Moraea (OCLP's SkyLight shim) replaces
// CoreAnimation's glass material with its own GLSL 1.20 port (cg9m_*), fed by cg9m_g[26]. This component keeps
// all of that and changes one thing: when Moraea's glass program has been linked, its fragment shader is rebuilt
// with Apple's own glass_background_sdf_no_bleed (QuartzCore's AIR, translated by our translator and converted to
// GLSL 1.20 + EXT_gpu_shader4 by TSGlassBuildSnippet) and relinked inside the same glLinkProgram call, so that
// CoreAnimation and Moraea query their uniforms on the final program and keep driving it as before. Apple's
// parameters are read from cg9m_g (the mapping below); level 1 of Apple's glass texture (variable_blur_downsample)
// is evaluated in the shader from Moraea's texture0. No draw, framebuffer or texture state is touched.
//
// Entry: Metal.framework loads the driver bundle into WindowServer (the kext lets it through only when
// System.Glass.Enabled is set); the constructor below starts the component there. Contexts are found from
// SkyLightOriginal's CARenderOGL* imports, as Moraea does: a pre-call stub on each import hooks the current context.
#import "TSGlass.h"
#import "TSLog.h"
#define GL_SILENCE_DEPRECATION 1
#import <OpenGL/OpenGL.h>
#import <OpenGL/CGLContext.h>
#import <OpenGL/gl.h>
#import <OpenGL/glext.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <mach/mach.h>
#import <mach/mach_vm.h>
#import <mach/mach_time.h>
#import <dlfcn.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <sys/stat.h>

NSString *TSMtlConfigDir(void);

#pragma mark - Apple's uniforms from Moraea's cg9m_g

// Apple's glass_background f1 (80 floats), field by field, as Moraea's cg9m_g holds it. Verified on the lab scene
// against the Metal renderer's buffers (docs/PIANO-GLASS.md, "Mappa dei parametri"). half >= 0: the 16-bit half
// (low/high) of a packed color-matrix word. nil: a field the mapping does not know.
static NSString *TSGlassF1Glass(int row, int comp, int half) {
    static const char *const tail[8][4] = {
        /* 12 */ { NULL, NULL, "cg9m_g[14].x", "cg9m_g[14].y" },
        /* 13 */ { "cg9m_g[14].z", "cg9m_g[14].w", "cg9m_g[15].x", "cg9m_g[15].y" },
        /* 14 */ { "cg9m_g[15].z", "cg9m_g[15].w", "cg9m_g[16].x", "cg9m_g[16].y" },
        /* 15 */ { "cg9m_g[16].z", "cg9m_g[16].w", "cg9m_g[17].x", "cg9m_g[17].y" },   // xyz: bleed range and amount
        /* 16 */ { "cg9m_g[17].z", "cg9m_g[17].w", "cg9m_g[18].x", "cg9m_g[18].y" },   // xy: bleed luminance coefficients
        /* 17 */ { "cg9m_g[18].z", "cg9m_g[18].w", "cg9m_g[19].x", "cg9m_g[19].y" },
        /* 18 */ { "cg9m_g[19].z", "cg9m_g[19].w", "cg9m_g[20].x", NULL },
        /* 19 */ { "cg9m_g[20].z", NULL, NULL, NULL },
    };
    if (half >= 0) {   // rows 8..12.xy: three 3x4 half matrices = cg9m_g[5..13], four halves per row of cg9m_g
        if (row < 8 || row > 12 || (row == 12 && comp > 1)) return nil;
        int k = ((row - 8) * 4 + comp) * 2 + half;
        return [NSString stringWithFormat:@"cg9m_g[%d].%c", 5 + k / 4, "xyzw"[k % 4]];
    }
    if (row <= 2) return [NSString stringWithFormat:@"cg9m_g[%d].%c", 23 + row, "xyzw"[comp]];   // shape
    if (row <= 7) return [NSString stringWithFormat:@"cg9m_g[%d].%c", row - 3, "xyzw"[comp]];    // refraction, ramps
    if (row >= 12 && row <= 19 && tail[row - 12][comp]) return @(tail[row - 12][comp]);
    return nil;
}

// glass_background_no_bleed (the shape from an SDF texture, Moraea's cg9m_gbt): the same f1 without the 3 shape rows.
static NSString *TSGlassF1Tex(int row, int comp, int half) {
    return TSGlassF1Glass(row + 3, comp, half);
}

// variable_blur_downsample's f1 = (lod, 1/width, 1/height) of the level it reads: level 0 = texture0 (S0 texels).
static NSString *TSGlassF1Blur(int row, int comp, int half) {
    if (half >= 0 || row != 0) return nil;
    return comp == 0 ? @"0.0" : comp == 1 ? @"cg9m_g[21].z" : comp == 2 ? @"cg9m_g[21].w" : nil;
}

#pragma mark - GLSL 4.10 -> 1.20 (+ EXT_gpu_shader4)

typedef NSString *(*TSGlassMap)(int row, int comp, int half);

// Replaces every match of pattern with block's result; a nil result stops and fails the conversion.
static NSString *TSGlassSub(NSString *s, NSString *pattern, NSString *(^block)(NSTextCheckingResult *m), BOOL *ok) {
    if (!*ok) return s;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSMutableString *out = [s mutableCopy];
    for (NSTextCheckingResult *m in [re matchesInString:s options:0 range:NSMakeRange(0, s.length)].reverseObjectEnumerator) {
        NSString *r = block(m);
        if (!r) { *ok = NO; return s; }
        [out replaceCharactersInRange:m.range withString:r];
    }
    return out;
}

// One translated function (its main) turned into `signature { ... return o0; }`: uniforms become cg9m_g fields,
// varyings the expressions in `varyings` (matched by substring), texture/textureLod(ftexN_*, ...) the call that
// `samplers` gives for "ftexN" (the rectangle variants under #if TSR_* are dropped).
// GLSL 4.10 built-ins that 1.20 lacks become tsg_* helpers (TSGlassBuildSnippet defines them).
static NSString *TSGlassConvert(NSString *src, NSString *signature, NSDictionary<NSString *, NSString *> *varyings,
                                NSDictionary<NSString *, NSString *> *samplers, TSGlassMap f1, NSString *f6x, NSString *prefix,
                                NSString **error) {
    __block NSString *why = nil;
    NSMutableArray<NSString *> *kept = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSString *> *rename = [NSMutableDictionary dictionary];
    NSMutableSet<NSString *> *boolTemps = [NSMutableSet set], *intTemps = [NSMutableSet set];
    NSRegularExpression *decl = [NSRegularExpression regularExpressionWithPattern:@"^  (bool|bvec[234]|int) (t[0-9]+);$" options:0 error:nil];
    int skip = 0;   // 1: inside the TSR_ (rectangle) branch of an #if, 2: inside #ifndef TSR_ ... #endif, 3: inside ts_h2f
    for (NSString *line in [src componentsSeparatedByString:@"\n"]) {
        NSString *t = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (skip == 3) { if ([line isEqualToString:@"}"]) skip = 0; continue; }
        if ([t hasPrefix:@"#ifndef TSR_"]) { skip = 2; continue; }
        if ([t hasPrefix:@"#if TSR_"]) { skip = 1; continue; }
        if (skip && [t isEqualToString:@"#else"]) { skip = 0; continue; }
        if ([t isEqualToString:@"#endif"]) { skip = 0; continue; }
        if (skip) continue;
        if ([line hasPrefix:@"float ts_h2f("]) { skip = 3; continue; }
        if ([line hasPrefix:@"uniform fbuf"] || [line hasPrefix:@"uint ts_ld_"] || [line hasPrefix:@"layout("] ||
            [line hasPrefix:@"uniform sampler"]) continue;
        if ([line hasPrefix:@"in "] || [line hasPrefix:@"noperspective in "] || [line hasPrefix:@"flat in "]) {
            NSString *name = [[t componentsSeparatedByString:@" "].lastObject stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@";"]];
            for (NSString *key in varyings) if ([name containsString:key]) rename[name] = varyings[key];
            if (!rename[name]) { why = [NSString stringWithFormat:@"varying %@ has no counterpart", name]; break; }
            continue;
        }
        NSTextCheckingResult *m = [decl firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
        if (m) [[[line substringWithRange:[m rangeAtIndex:1]] isEqualToString:@"int"] ? intTemps : boolTemps
                   addObject:[line substringWithRange:[m rangeAtIndex:2]]];
        [kept addObject:line];
    }
    if (why) { if (error) *error = why; return nil; }
    NSString *s = [kept componentsJoinedByString:@"\n"];
    BOOL ok = YES;
    NSString *(^field)(int, int, int) = ^NSString *(int row, int comp, int half) {
        NSString *e = f1(row, comp, half);
        if (!e && !why) why = [NSString stringWithFormat:@"f1 row %d.%c%@ is not mapped", row, "xyzw"[comp], half < 0 ? @"" : half ? @" (high half)" : @" (low half)"];
        return e;
    };
    int (^comp)(NSString *) = ^int(NSString *c) { return (int)[@"xyzw" rangeOfString:c].location; };
    s = TSGlassSub(s, @"ts_h2f\\(\\(fbuf1_d\\[([0-9]+)\\]\\.([xyzw]) >> (0|16)u\\) & 0xFFFFu\\)", ^NSString *(NSTextCheckingResult *m) {
        return field([s substringWithRange:[m rangeAtIndex:1]].intValue, comp([s substringWithRange:[m rangeAtIndex:2]]),
                     [s substringWithRange:[m rangeAtIndex:3]].intValue / 16);
    }, &ok);
    s = TSGlassSub(s, @"uintBitsToFloat\\(fbuf1_d\\[([0-9]+)\\]\\.([xyzw])\\)", ^NSString *(NSTextCheckingResult *m) {
        return field([s substringWithRange:[m rangeAtIndex:1]].intValue, comp([s substringWithRange:[m rangeAtIndex:2]]), -1);
    }, &ok);
    s = TSGlassSub(s, @"uintBitsToFloat\\(fbuf1_d\\[([0-9]+) >> 4\\]\\)", ^NSString *(NSTextCheckingResult *m) {
        int row = [s substringWithRange:[m rangeAtIndex:1]].intValue / 16;
        NSString *x = field(row, 0, -1), *y = field(row, 1, -1), *z = field(row, 2, -1), *w = field(row, 3, -1);
        return x && y && z && w ? [NSString stringWithFormat:@"vec4(%@, %@, %@, %@)", x, y, z, w] : nil;
    }, &ok);
    s = TSGlassSub(s, @"uintBitsToFloat\\(fbuf6_d\\[0\\]\\.x\\)", ^NSString *(NSTextCheckingResult *m) {
        if (!f6x && !why) why = @"f6 is not mapped";
        return f6x;
    }, &ok);
    s = TSGlassSub(s, @"texture(Lod)?\\((ftex[0-9]+)_[A-Za-z0-9_]+, ", ^NSString *(NSTextCheckingResult *m) {
        NSString *call = samplers[[s substringWithRange:[m rangeAtIndex:2]]];
        if (!call && !why) why = [NSString stringWithFormat:@"texture %@ has no counterpart", [s substringWithRange:[m rangeAtIndex:2]]];
        return call;
    }, &ok);
    s = TSGlassSub(s, @"\\bfma\\(", ^NSString *(NSTextCheckingResult *m) { return @"tsg_fma("; }, &ok);
    s = TSGlassSub(s, @"\\babs\\((t[0-9]+)\\)", ^NSString *(NSTextCheckingResult *m) {
        NSString *v = [s substringWithRange:[m rangeAtIndex:1]];
        return [NSString stringWithFormat:@"%@(%@)", [intTemps containsObject:v] ? @"tsg_iabs" : @"abs", v];
    }, &ok);
    // mix(a, b, bvec) is GLSL 1.30: a component-wise select.
    NSMutableString *ms = [s mutableCopy];
    for (NSRange r = [ms rangeOfString:@"mix("]; r.location != NSNotFound;
         r = [ms rangeOfString:@"mix(" options:0 range:NSMakeRange(NSMaxRange(r), ms.length - NSMaxRange(r))]) {
        unichar before = r.location ? [ms characterAtIndex:r.location - 1] : ' ';
        if ([NSCharacterSet.alphanumericCharacterSet characterIsMember:before] || before == '_') continue;
        NSUInteger depth = 0, start = NSMaxRange(r), lastComma = NSNotFound, end = NSNotFound;
        for (NSUInteger i = start; i < ms.length && end == NSNotFound; i++) {
            unichar ch = [ms characterAtIndex:i];
            if (ch == '(') depth++;
            else if (ch == ')') { if (depth == 0) end = i; else depth--; }
            else if (ch == ',' && depth == 0) lastComma = i;
        }
        if (end == NSNotFound || lastComma == NSNotFound) continue;
        NSString *third = [[ms substringWithRange:NSMakeRange(lastComma + 1, end - lastComma - 1)]
                           stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([boolTemps containsObject:third]) [ms replaceCharactersInRange:NSMakeRange(r.location, 3) withString:@"tsg_sel"];
    }
    s = ms;
    for (NSString *from in rename)
        s = TSGlassSub(s, [NSString stringWithFormat:@"\\b%@\\b", from], ^NSString *(NSTextCheckingResult *m) {
            return [NSString stringWithFormat:@"(%@)", rename[from]];
        }, &ok);
    // Names that both functions could define at file scope (structs, translator helpers).
    s = TSGlassSub(s, @"\\b(S[0-9]+|ts_[A-Za-z0-9_]+)\\b", ^NSString *(NSTextCheckingResult *m) {
        return [prefix stringByAppendingString:[s substringWithRange:m.range]];
    }, &ok);
    NSRange mainAt = [s rangeOfString:@"void main() {\n"], close = [s rangeOfString:@"\n}" options:NSBackwardsSearch];
    if (ok && (mainAt.location == NSNotFound || close.location == NSNotFound || close.location < mainAt.location)) { ok = NO; why = @"no main()"; }
    if (!ok) { if (error) *error = why ?: @"conversion failed"; return nil; }
    NSString *head = [s substringToIndex:mainAt.location];
    NSString *body = [s substringWithRange:NSMakeRange(NSMaxRange(mainAt), close.location - NSMaxRange(mainAt))];
    body = [body stringByReplacingOccurrencesOfString:@"return;" withString:@"return o0;"];
    s = [NSString stringWithFormat:@"%@%@ {\n  vec4 o0 = vec4(0.0);\n%@\n  return o0;\n}\n", head, signature, body];
    // Anything left that needs GLSL 1.30+ or a resource the snippet does not have.
    NSRegularExpression *left = [NSRegularExpression regularExpressionWithPattern:
        @"\\buint\\b|\\buvec[234]\\b|BitsTo|fbuf|ftex|textureSize|\\btexture\\(|layout|TSR_|\\b[0-9]+u\\b|\\b(in|out) (vec|float)"
                                                                          options:0 error:nil];
    NSTextCheckingResult *bad = [left firstMatchInString:s options:0 range:NSMakeRange(0, s.length)];
    if (bad) {
        NSRange line = [s lineRangeForRange:bad.range];
        if (error) *error = [NSString stringWithFormat:@"unsupported construct: %@",
                             [[s substringWithRange:line] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
        return nil;
    }
    return s;
}

NSString *TSGlassBuildSnippet(NSDictionary<NSString *, NSString *> *glsl410, NSString **error) {
    NSString *why = nil;
    NSString *glass410 = glsl410[@"glass_background_sdf_no_bleed_lpf"], *glassTex410 = glsl410[@"glass_background_no_bleed_lpf"];
    NSString *bleed410 = glsl410[@"glass_background_sdf_lpf"], *bleedTex410 = glsl410[@"glass_background_lpf"];
    NSString *blur410 = glsl410[@"variable_blur_downsample_frag_lpf"];
    if (!glass410 || !glassTex410 || !bleed410 || !bleedTex410 || !blur410) { if (error) *error = @"a translated function is missing"; return nil; }
    NSString *blur = TSGlassConvert(blur410, @"vec4 tsg_vblur(vec2 tsg_uv)", @{ @"texcoord0": @"tsg_uv" }, @{ @"ftex3": @"tsg_l0(" },
                                    TSGlassF1Blur, nil, @"tsgb_", &why);
    if (!blur) { if (error) *error = [@"variable_blur_downsample: " stringByAppendingString:why]; return nil; }
    // Moraea's cg9m_gbs: the shape is computed (sdf_uv = cg9m_v0), the backdrop coordinate is normalized (cg9m_v1).
    NSString *glass = TSGlassConvert(glass410, @"vec4 tsg_glass()", @{ @"sdf_uv": @"cg9m_v0", @"src_uv": @"cg9m_v1" },
                                     @{ @"ftex3": @"tsg_tex(" }, TSGlassF1Glass, @"1.0", @"tsgg_", &why);
    if (!glass) { if (error) *error = [@"glass_background_sdf_no_bleed: " stringByAppendingString:why]; return nil; }
    // Moraea's cg9m_gbt: the shape comes from CoreAnimation's SDF texture (texture1, a rectangle of cg9m_g[22].xy
    // texels: r distance, gb gradient, a coverage); both coordinates are rectangle texels there.
    NSString *glassTex = TSGlassConvert(glassTex410, @"vec4 tsg_glass_tex()",
                                        @{ @"texcoord0": @"texcoord0_0 * cg9m_g[21].zw", @"texcoord1": @"texcoord1_0 * cg9m_g[22].zw" },
                                        @{ @"ftex3": @"tsg_tex(", @"ftex4": @"tsg_sdf(" }, TSGlassF1Tex, @"1.0", @"tsgt_", &why);
    if (!glassTex) { if (error) *error = [@"glass_background_no_bleed: " stringByAppendingString:why]; return nil; }
    // The bleed variants (cg9m_gbs(true) / cg9m_gbt(..., true): sidebars, where the window's own colors bleed into
    // the glass): same f1, plus the bleed fields (rows 9.zw-10 halves, 5.w, 6.xy, 15.xyz, 16.xy).
    NSString *bleed = TSGlassConvert(bleed410, @"vec4 tsg_glass_bleed()", @{ @"sdf_uv": @"cg9m_v0", @"src_uv": @"cg9m_v1" },
                                     @{ @"ftex3": @"tsg_tex(" }, TSGlassF1Glass, @"1.0", @"tsgB_", &why);
    if (!bleed) { if (error) *error = [@"glass_background_sdf: " stringByAppendingString:why]; return nil; }
    NSString *bleedTex = TSGlassConvert(bleedTex410, @"vec4 tsg_glass_tex_bleed()",
                                        @{ @"texcoord0": @"texcoord0_0 * cg9m_g[21].zw", @"texcoord1": @"texcoord1_0 * cg9m_g[22].zw" },
                                        @{ @"ftex3": @"tsg_tex(", @"ftex4": @"tsg_sdf(" }, TSGlassF1Tex, @"1.0", @"tsgT_", &why);
    if (!bleedTex) { if (error) *error = [@"glass_background: " stringByAppendingString:why]; return nil; }
    return [NSString stringWithFormat:@
        "// TeraScale Glass: Apple's glass_background_sdf_no_bleed, glass_background_no_bleed and variable_blur_downsample\n"
        "// (QuartzCore), translated by the TeraScale AIR translator for Moraea's GLSL 1.20 context. Generated by\n"
        "// tools/glassgen: do not edit. TSGlassCompose defines TSG_SHAPE (cg9m_gbs) or TSG_SHAPE_TEXTURE (cg9m_gbt), and\n"
        "// TSG_BLEED for their bleed variants (glass_background_sdf and glass_background).\n"
        "#define tsg_fma(a, b, c) ((a) * (b) + (c))\n"
        "int tsg_iabs(int x) { return x < 0 ? -x : x; }\n"
        "float tsg_sel(float a, float b, bool c) { return c ? b : a; }\n"
        "vec2 tsg_sel(vec2 a, vec2 b, bool c) { return c ? b : a; }\n"
        "vec3 tsg_sel(vec3 a, vec3 b, bool c) { return c ? b : a; }\n"
        "vec4 tsg_sel(vec4 a, vec4 b, bool c) { return c ? b : a; }\n"
        "vec2 tsg_sel(vec2 a, vec2 b, bvec2 c) { return vec2(c.x ? b.x : a.x, c.y ? b.y : a.y); }\n"
        "vec3 tsg_sel(vec3 a, vec3 b, bvec3 c) { return vec3(c.x ? b.x : a.x, c.y ? b.y : a.y, c.z ? b.z : a.z); }\n"
        "vec4 tsg_sel(vec4 a, vec4 b, bvec4 c) { return vec4(c.x ? b.x : a.x, c.y ? b.y : a.y, c.z ? b.z : a.z, c.w ? b.w : a.w); }\n"
        "// Apple's glass texture: level 0 = CoreAnimation's 1/4 downsample of the backdrop (Moraea's texture0, S0 =\n"
        "// cg9m_g[21].xy texels), level 1 = variable_blur_downsample of level 0, evaluated in place; trilinear between them.\n"
        "vec4 tsg_l0(vec2 uv, float lod) { return texture2DRect(texture0, uv * cg9m_g[21].xy); }\n"
        "%@"
        "vec4 tsg_tex(vec2 uv, float lod) {\n"
        "  float l = clamp(lod, 0.0, 1.0);\n"
        "  vec4 a = tsg_l0(uv, 0.0);\n"
        "  return l > 0.0 ? mix(a, tsg_vblur(uv), l) : a;\n"
        "}\n"
        "#if defined(TSG_SHAPE) && !defined(TSG_BLEED)\n%@#endif\n"
        "#if defined(TSG_SHAPE) && defined(TSG_BLEED)\n%@#endif\n"
        "#ifdef TSG_SHAPE_TEXTURE\n"
        "vec4 tsg_sdf(vec2 uv) { return texture2DRect(texture1, uv * cg9m_g[22].xy); }\n"
        "#endif\n"
        "#if defined(TSG_SHAPE_TEXTURE) && !defined(TSG_BLEED)\n%@#endif\n"
        "#if defined(TSG_SHAPE_TEXTURE) && defined(TSG_BLEED)\n%@#endif\n", blur, glass, bleed, glassTex, bleedTex];
}

NSString *TSGlassCompose(NSString *src, NSString *snippet) {
    static NSString *const version = @"#version 120\n";
    // Moraea's glass shaders: what main() calls, the defines that select the snippet's function, which function
    // replaces the call, what the snippet needs declared.
    NSArray *shape = @[ @"uniform highp vec4 cg9m_g[26];", @"varying highp vec2 cg9m_v0, cg9m_v1;", @"sampler2DRect texture0;" ];
    NSArray *shapeTex = @[ @"uniform highp vec4 cg9m_g[26];", @"varying highp vec2 texcoord0_0;", @"varying highp vec2 texcoord1_0;",
                           @"sampler2DRect texture0;", @"sampler2DRect texture1;" ];
    const struct { NSString *call, *define, *mine; NSArray *needs; } kinds[] = {
        { @"cg9m_gbs(false)", @"TSG_SHAPE", @"tsg_glass()", shape },
        { @"cg9m_gbt(texcoord0_0, texcoord1_0, false)", @"TSG_SHAPE_TEXTURE", @"tsg_glass_tex()", shapeTex },
        { @"cg9m_gbs(true)", @"TSG_SHAPE\n#define TSG_BLEED", @"tsg_glass_bleed()", shape },
        { @"cg9m_gbt(texcoord0_0, texcoord1_0, true)", @"TSG_SHAPE_TEXTURE\n#define TSG_BLEED", @"tsg_glass_tex_bleed()", shapeTex },
    };
    NSRange main = [src rangeOfString:@"void main"];
    if (![src hasPrefix:version] || main.location == NSNotFound) return nil;
    NSString *head = [src substringWithRange:NSMakeRange(version.length, main.location - version.length)];
    NSString *body = [src substringFromIndex:main.location];
    for (int k = 0; k < 4; k++) {
        if ([body componentsSeparatedByString:kinds[k].call].count != 2) continue;
        for (NSString *need in kinds[k].needs) if (![head containsString:need]) return nil;
        // Moraea's call stays, behind a condition that is never true (a negative backdrop width) but that the compiler
        // cannot drop: the program keeps exactly Moraea's active uniforms, and the driver gives the same set the same
        // locations, so a program CoreAnimation already queried can be rebuilt in place (TSGlassSwap).
        body = [body stringByReplacingOccurrencesOfString:kinds[k].call
                                               withString:[NSString stringWithFormat:@"(cg9m_g[21].x < 0.0 ? %@ : %@)", kinds[k].call, kinds[k].mine]];
        return [NSString stringWithFormat:@"%@#extension GL_EXT_gpu_shader4 : enable\n%@#define %@\n%@\n%@",
                                          version, head, kinds[k].define, snippet, body];
    }
    return nil;
}

#pragma mark - State, policy, kill switch, crash guard

static NSString *gSnippet;          // set once by TSGlassStart; nil = component off
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static int gOff, gOffGen = 1;       // runtime switch (kill file / policy) and its generation
static int gReplaced, gFailed;      // programs rebuilt / left to Moraea

// Kill switch (DISABLE), crash counter (starts) and status.plist live in /var/tmp/TeraScaleGlass, a directory that
// both WindowServer (_windowserver) and the user can write and delete in (0777, not sticky), or under
// TSMTL_CONFIG_DIR when that redirects the configuration (lab, tests).
static NSString *TSGlassStatePath(NSString *name) {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *config = getenv("TSMTL_CONFIG_DIR");
        dir = [(config && *config ? @(config) : @"/var/tmp") stringByAppendingPathComponent:@"TeraScaleGlass"];
        if (mkdir(dir.fileSystemRepresentation, 0777) == 0) chmod(dir.fileSystemRepresentation, 0777);
    });
    return [dir stringByAppendingPathComponent:name];
}

// System.Glass in policy.plist: Enabled, and Trial.Deadline (tsmtl glass trial): past that date without a
// confirmation (tsmtl glass confirm removes Trial) the glass goes back to Moraea's, at runtime too.
static BOOL TSGlassPolicyEnabled(void) {
    static struct timespec seen;
    static BOOL enabled;
    static NSDate *deadline;
    NSString *path = [TSMtlConfigDir() stringByAppendingPathComponent:@"policy.plist"];
    struct stat st;
    if (stat(path.fileSystemRepresentation, &st) != 0) return NO;
    if (st.st_mtimespec.tv_sec != seen.tv_sec || st.st_mtimespec.tv_nsec != seen.tv_nsec) {
        seen = st.st_mtimespec;
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:path];
        NSDictionary *system = [plist[@"System"] isKindOfClass:[NSDictionary class]] ? plist[@"System"] : nil;
        NSDictionary *glass = [system[@"Glass"] isKindOfClass:[NSDictionary class]] ? system[@"Glass"] : nil;
        NSDictionary *trial = [glass[@"Trial"] isKindOfClass:[NSDictionary class]] ? glass[@"Trial"] : nil;
        enabled = [glass[@"Enabled"] isKindOfClass:[NSNumber class]] && [glass[@"Enabled"] boolValue];
        // Unix seconds (the kext's OSUnserializeXML has no <date>); a <date> is accepted too.
        id d = trial[@"Deadline"];
        deadline = [d isKindOfClass:[NSNumber class]] ? [NSDate dateWithTimeIntervalSince1970:[d doubleValue]]
                 : [d isKindOfClass:[NSDate class]] ? d : nil;
    }
    return enabled && (!deadline || deadline.timeIntervalSinceNow > 0);
}

static void TSGlassWriteStatus(NSString *state, NSString *detail) {
    NSDictionary *status = @{ @"PID": @(getpid()), @"State": state, @"Detail": detail ?: @"", @"Date": [NSDate date],
                              @"Replaced": @(gReplaced), @"Failed": @(gFailed), @"Off": @(gOff) };
    [status writeToFile:TSGlassStatePath(@"status.plist") atomically:YES];
}

// At most once a second, from the use-program hook: the kill file or the policy can turn the glass back to Moraea's.
static void TSGlassPoll(void) {
    static uint64_t last, second;
    if (!second) { mach_timebase_info_data_t tb; mach_timebase_info(&tb); second = 1000000000ull * tb.denom / tb.numer; }
    uint64_t now = mach_absolute_time();
    if (now - last < second) return;
    last = now;
    @autoreleasepool {
        int off = access(TSGlassStatePath(@"DISABLE").fileSystemRepresentation, F_OK) == 0 || !TSGlassPolicyEnabled();
        if (off == gOff) return;
        gOff = off;
        gOffGen++;
        TSMtlGlass(@"glass %s at runtime", off ? "switched back to Moraea's" : "switched to Apple's");
        TSGlassWriteStatus(off ? @"off" : @"active", off ? @"switched off at runtime" : nil);
    }
}

// TeraScale Glass is wanted in this process: policy on (trial not expired) and no kill switch. Used by the app side
// (TSGlassSidebar.m), which decides once per app.
BOOL TSGlassWanted(void) {
    return TSGlassPolicyEnabled() && access(TSGlassStatePath(@"DISABLE").fileSystemRepresentation, F_OK) != 0;
}

#pragma mark - Dispatch-table hooks

typedef struct {
    CGLContextObj ctx;
    GLIContext rend;
    void (*link)(GLIContext, GLhandleARB);
    void (*use)(GLIContext, GLhandleARB);
    void (*source)(GLIContext, GLhandleARB, GLsizei, const GLcharARB *const *, const GLint *);   // GLEngine's if found
    // Moraea glass programs now on Apple's shader: their fragment shader, both sources (malloc'd), the off generation
    // they reflect (TSGlassUse swaps the source when the runtime switch changes).
    struct { GLhandleARB prog, fs; char *moraea, *mine; int gen; } programs[32];
    int nprograms;
    int scanned;   // programs linked before the hook looked for (first use-program call)
} TSGlassCtx;

static TSGlassCtx gCtx[8];
static _Atomic int gNCtx;

static TSGlassCtx *TSGlassFind(GLIContext rend) {
    int n = atomic_load_explicit(&gNCtx, memory_order_acquire);
    for (int i = 0; i < n; i++) if (gCtx[i].rend == rend) return &gCtx[i];
    return NULL;
}

static BOOL TSGlassFromGLEngine(void *fn) {
    Dl_info di;
    return fn && dladdr(fn, &di) && di.dli_fname && strstr(di.dli_fname, "GLEngine");
}

// A symbol of a loaded image whose path ends with `image` (local symbols included: GLEngine and Moraea export
// almost nothing), 0 if absent.
static uintptr_t TSGlassSymbol(const char *image, const char *symbol) {
    size_t il = strlen(image);
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        size_t nl = name ? strlen(name) : 0;
        if (nl < il || strcmp(name + nl - il, image)) continue;
        const struct mach_header_64 *mh = (const void *)_dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const struct segment_command_64 *linkedit = NULL;
        const struct symtab_command *symtab = NULL;
        const struct load_command *lc = (const void *)(mh + 1);
        for (uint32_t k = 0; k < mh->ncmds; k++, lc = (const void *)((const char *)lc + lc->cmdsize)) {
            if (lc->cmd == LC_SEGMENT_64 && !strcmp(((const struct segment_command_64 *)lc)->segname, SEG_LINKEDIT)) linkedit = (const void *)lc;
            else if (lc->cmd == LC_SYMTAB) symtab = (const void *)lc;
        }
        if (!linkedit || !symtab) return 0;
        uintptr_t base = slide + linkedit->vmaddr - linkedit->fileoff;
        const struct nlist_64 *syms = (const void *)(base + symtab->symoff);
        const char *strings = (const char *)(base + symtab->stroff);
        for (uint32_t k = 0; k < symtab->nsyms; k++)
            if ((syms[k].n_type & N_TYPE) == N_SECT && !strcmp(strings + syms[k].n_un.n_strx, symbol)) return syms[k].n_value + slide;
        return 0;
    }
    return 0;
}

// glShaderSource as GLEngine implements it, so that Moraea's source hook (which rewrites CoreAnimation's glass
// shaders) never sees ours: the slot itself when it is GLEngine's, otherwise GLEngine's function of the same
// flavour as the context's compile entry (_Exec, or _ExecThread for the multithreaded engine). Else the slot.
static void *TSGlassEngineShaderSource(CGLContextObj ctx) {
    void *slot = (void *)ctx->disp.shader_source_ARB;
    if (TSGlassFromGLEngine(slot)) return slot;
    static const char *const engine = "/GLEngine.bundle/GLEngine";
    uintptr_t compile = (uintptr_t)ctx->disp.compile_shader_ARB;
    const char *flavour = compile == TSGlassSymbol(engine, "_glCompileShaderARB_Exec") ? "_glShaderSourceARB_Exec"
                        : compile == TSGlassSymbol(engine, "_glCompileShaderARB_ExecThread") ? "_glShaderSourceARB_ExecThread" : NULL;
    uintptr_t source = flavour ? TSGlassSymbol(engine, flavour) : 0;
    return source ? (void *)source : slot;
}

static BOOL TSGlassRebuild(TSGlassCtx *t, GLhandleARB prog, GLhandleARB fs, NSString *source, NSString **log) {
    GLIContext c = t->rend;
    GLIFunctionDispatch *d = &t->ctx->disp;
    const GLcharARB *text = source.UTF8String;
    t->source(c, fs, 1, &text, NULL);
    d->compile_shader_ARB(c, fs);
    GLint ok = 0;
    d->get_object_parameteriv_ARB(c, fs, GL_OBJECT_COMPILE_STATUS_ARB, &ok);
    if (ok) {
        t->link(c, prog);
        d->get_object_parameteriv_ARB(c, prog, GL_OBJECT_LINK_STATUS_ARB, &ok);
    }
    if (!ok && log) {
        char buf[2048] = "";
        GLsizei n = 0;
        d->get_info_log_ARB(c, fs, sizeof buf - 1, &n, buf);
        if (!n) d->get_info_log_ARB(c, prog, sizeof buf - 1, &n, buf);
        *log = @(buf);
    }
    return ok;
}

// A program linked before the hook (WindowServer drew before Metal loaded the driver): CoreAnimation already holds
// its uniform locations and set its uniforms once (samplers), so a rebuild must keep both. TSGlassSnapshot records
// every active uniform element (location, type, value); TSGlassSameLocations / TSGlassRestore check and reapply them.
typedef struct { GLint loc; GLenum type; char name[72]; GLfloat f[16]; GLint i[4]; } TSGlassUniform;
typedef struct { TSGlassUniform u[128]; int n; } TSGlassUniforms;

static int TSGlassComponents(GLenum type, BOOL *isInt, BOOL *isMatrix) {
    *isInt = NO; *isMatrix = NO;
    switch (type) {
    case GL_FLOAT: return 1;
    case GL_FLOAT_VEC2: return 2;
    case GL_FLOAT_VEC3: return 3;
    case GL_FLOAT_VEC4: return 4;
    case GL_FLOAT_MAT2: *isMatrix = YES; return 4;
    case GL_FLOAT_MAT3: *isMatrix = YES; return 9;
    case GL_FLOAT_MAT4: *isMatrix = YES; return 16;
    case GL_INT: case GL_BOOL: *isInt = YES; return 1;
    case GL_INT_VEC2: case GL_BOOL_VEC2: *isInt = YES; return 2;
    case GL_INT_VEC3: case GL_BOOL_VEC3: *isInt = YES; return 3;
    case GL_INT_VEC4: case GL_BOOL_VEC4: *isInt = YES; return 4;
    case GL_SAMPLER_1D: case GL_SAMPLER_2D: case GL_SAMPLER_3D: case GL_SAMPLER_CUBE: case GL_SAMPLER_2D_RECT_ARB:
    case GL_SAMPLER_2D_SHADOW: *isInt = YES; return 1;
    default: return 0;
    }
}

static BOOL TSGlassSnapshot(TSGlassCtx *t, GLhandleARB prog, TSGlassUniforms *out) {
    GLIContext c = t->rend;
    GLIFunctionDispatch *d = &t->ctx->disp;
    GLint count = 0;
    out->n = 0;
    d->get_object_parameteriv_ARB(c, prog, GL_OBJECT_ACTIVE_UNIFORMS_ARB, &count);
    for (GLint k = 0; k < count; k++) {
        char name[64] = "";
        GLsizei len = 0;
        GLint size = 0;
        GLenum type = 0;
        d->get_active_uniform_ARB(c, prog, (GLuint)k, sizeof name, &len, &size, &type, name);
        char *bracket = strchr(name, '[');
        if (bracket) *bracket = 0;
        BOOL isInt, isMatrix;
        if (!TSGlassComponents(type, &isInt, &isMatrix)) return NO;   // a type we could not restore: do not touch
        for (GLint e = 0; e < size; e++) {
            if (out->n >= 128) return NO;
            TSGlassUniform *u = &out->u[out->n];
            if (size > 1 || bracket) snprintf(u->name, sizeof u->name, "%s[%d]", name, e);
            else strlcpy(u->name, name, sizeof u->name);
            u->type = type;
            u->loc = d->get_uniform_location_ARB(c, prog, u->name);
            if (u->loc < 0) continue;
            if (isInt) d->get_uniformiv_ARB(c, prog, u->loc, u->i);
            else d->get_uniformfv_ARB(c, prog, u->loc, u->f);
            out->n++;
        }
    }
    return YES;
}

static BOOL TSGlassSameLocations(TSGlassCtx *t, GLhandleARB prog, const TSGlassUniforms *u) {
    for (int k = 0; k < u->n; k++)
        if (t->ctx->disp.get_uniform_location_ARB(t->rend, prog, u->u[k].name) != u->u[k].loc) return NO;
    return YES;
}

// The program must be current.
static void TSGlassRestore(TSGlassCtx *t, const TSGlassUniforms *u) {
    GLIContext c = t->rend;
    GLIFunctionDispatch *d = &t->ctx->disp;
    for (int k = 0; k < u->n; k++) {
        const TSGlassUniform *v = &u->u[k];
        BOOL isInt, isMatrix;
        int n = TSGlassComponents(v->type, &isInt, &isMatrix);
        if (isMatrix) {
            if (n == 4) d->uniform_matrix2fv_ARB(c, v->loc, 1, GL_FALSE, v->f);
            else if (n == 9) d->uniform_matrix3fv_ARB(c, v->loc, 1, GL_FALSE, v->f);
            else d->uniform_matrix4fv_ARB(c, v->loc, 1, GL_FALSE, v->f);
        } else if (isInt) {
            if (n == 1) d->uniform1iv_ARB(c, v->loc, 1, v->i);
            else if (n == 2) d->uniform2iv_ARB(c, v->loc, 1, v->i);
            else if (n == 3) d->uniform3iv_ARB(c, v->loc, 1, v->i);
            else d->uniform4iv_ARB(c, v->loc, 1, v->i);
        } else {
            if (n == 1) d->uniform1fv_ARB(c, v->loc, 1, v->f);
            else if (n == 2) d->uniform2fv_ARB(c, v->loc, 1, v->f);
            else if (n == 3) d->uniform3fv_ARB(c, v->loc, 1, v->f);
            else d->uniform4fv_ARB(c, v->loc, 1, v->f);
        }
    }
}

// The fragment shader of prog gets `source` and prog is relinked. keep: prog was already in use, so its uniform
// locations must not move (TSGlassCompose keeps Moraea's uniforms, which the driver then places the same way) and
// its uniform values are put back. On failure `fallback` goes back in the same way. The previous program is current
// again afterwards. *log: why it failed.
static BOOL TSGlassSwap(TSGlassCtx *t, GLhandleARB prog, GLhandleARB fs, NSString *source, NSString *fallback, BOOL keep, NSString **log) {
    static TSGlassUniforms before;   // render thread only
    GLIContext c = t->rend;
    GLIFunctionDispatch *d = &t->ctx->disp;
    GLint prev = 0;
    d->get_integerv(c, GL_CURRENT_PROGRAM, &prev);
    if (keep && !TSGlassSnapshot(t, prog, &before)) { if (log) *log = @"uniforms that cannot be saved"; return NO; }
    BOOL ok = TSGlassRebuild(t, prog, fs, source, log);
    if (ok && keep && !TSGlassSameLocations(t, prog, &before)) { ok = NO; if (log) *log = @"uniform locations moved"; }
    if (!ok) TSGlassRebuild(t, prog, fs, fallback, NULL);
    if (keep) {
        t->use(c, prog);
        TSGlassRestore(t, &before);
        t->use(c, (GLhandleARB)(uintptr_t)prev);
    }
    return ok;
}

// Moraea's path (kept for the locations) samples cg9m_mipT, a sampler2D. Left on the unit of texture0 or texture1
// (rectangles), as it is until Moraea's chain binds its mip texture (always, in the lab), it makes every draw of the
// program invalid: it gets a unit of its own. Moraea sets it again when its chain runs.
static void TSGlassSeparateMip(TSGlassCtx *t, GLhandleARB prog) {
    GLIContext c = t->rend;
    GLIFunctionDispatch *d = &t->ctx->disp;
    GLint mip = d->get_uniform_location_ARB(c, prog, "cg9m_mipT");
    if (mip < 0) return;
    GLint unit = -1, u0 = -2, u1 = -2, prev = 0, units = 16;
    d->get_uniformiv_ARB(c, prog, mip, &unit);
    GLint l0 = d->get_uniform_location_ARB(c, prog, "texture0"), l1 = d->get_uniform_location_ARB(c, prog, "texture1");
    if (l0 >= 0) d->get_uniformiv_ARB(c, prog, l0, &u0);
    if (l1 >= 0) d->get_uniformiv_ARB(c, prog, l1, &u1);
    if (unit != u0 && unit != u1) return;
    d->get_integerv(c, GL_CURRENT_PROGRAM, &prev);
    d->get_integerv(c, GL_MAX_TEXTURE_IMAGE_UNITS, &units);
    t->use(c, prog);
    d->uniform1i_ARB(c, mip, units - 1);
    t->use(c, (GLhandleARB)(uintptr_t)prev);
}

// After a successful link: if this is Moraea's glass program, rebuild it with Apple's shader (or leave it alone).
// late: the program was linked before the hook and CoreAnimation already uses it (TSGlassScan).
static void TSGlassAfterLink(TSGlassCtx *t, GLhandleARB prog, BOOL late) {
    GLIContext c = t->rend;
    GLIFunctionDispatch *d = &t->ctx->disp;
    GLint ok = 0;
    d->get_object_parameteriv_ARB(c, prog, GL_OBJECT_LINK_STATUS_ARB, &ok);
    if (!ok) return;
    GLhandleARB objs[4];
    GLsizei n = 0;
    d->get_attached_objects_ARB(c, prog, 4, &n, objs);
    for (GLsizei i = 0; i < n; i++) {
        GLint type = 0, len = 0;
        d->get_object_parameteriv_ARB(c, objs[i], GL_OBJECT_SUBTYPE_ARB, &type);
        d->get_object_parameteriv_ARB(c, objs[i], GL_OBJECT_SHADER_SOURCE_LENGTH_ARB, &len);
        if (type != GL_FRAGMENT_SHADER_ARB || len <= 0 || len > (1 << 20)) continue;
        char *buf = malloc(len + 1);
        GLsizei got = 0;
        d->get_shader_source_ARB(c, objs[i], len + 1, &got, buf);
        buf[got] = 0;
        BOOL glass = (strstr(buf, "cg9m_gbs(") || strstr(buf, "cg9m_gbt(")) && !strstr(buf, "tsg_glass");
        NSString *moraea = glass ? @(buf) : nil;
        free(buf);
        if (!glass) continue;
        @autoreleasepool {
            NSString *mine = TSGlassCompose(moraea, gSnippet), *log = nil;
            if (!mine) {
                gFailed++;
                TSMtlGlass(@"Moraea glass program %u has an unexpected shape (another Moraea version?): left to Moraea",
                           (unsigned)(uintptr_t)prog);
                TSGlassWriteStatus(@"active", @"a Moraea glass program was left alone (unexpected shape)");
                return;
            }
            if (!gOff && !TSGlassSwap(t, prog, objs[i], mine, moraea, late, &log)) {
                gFailed++;
                TSMtlGlass(@"Apple glass for program %u not applied (%@): Moraea's kept", (unsigned)(uintptr_t)prog, log);
                TSGlassWriteStatus(@"active", [@"not applied: " stringByAppendingString:log ?: @"?"]);
                return;
            }
            if (!gOff) TSGlassSeparateMip(t, prog);
            os_unfair_lock_lock(&gLock);
            if (t->nprograms < 32) {
                int k = t->nprograms++;
                t->programs[k].prog = prog; t->programs[k].fs = objs[i]; t->programs[k].gen = gOffGen;
                t->programs[k].moraea = strdup(moraea.UTF8String); t->programs[k].mine = strdup(mine.UTF8String);
            }
            os_unfair_lock_unlock(&gLock);
            if (!gOff) gReplaced++;
            BOOL tex = [moraea containsString:@"cg9m_gbt("], bleed = [moraea containsString:@", true)"] || [moraea containsString:@"cg9m_gbs(true)"];
            TSMtlGlass(@"Moraea glass program %u %s Apple's glass_background%s%s%s", (unsigned)(uintptr_t)prog,
                       gOff ? "will run (switched off now)" : "now runs", tex ? "" : "_sdf", bleed ? "" : "_no_bleed",
                       late ? " (linked before the hook, uniforms kept)" : "");
            TSGlassWriteStatus(gOff ? @"off" : @"active", nil);
        }
        return;
    }
}

// TSGLASS_LATE_TEST=<n> (lab): links are left alone and the scan waits for n use-program calls, so every glass
// program goes through the late path.
static int gLateTest = -1;

static void TSGlassLink(GLIContext c, GLhandleARB prog) {
    TSGlassCtx *t = TSGlassFind(c);
    if (!t) return;
    t->link(c, prog);
    if (gLateTest < 0) { const char *v = getenv("TSGLASS_LATE_TEST"); gLateTest = v && atoi(v) > 0 ? atoi(v) : 0; }
    if (gSnippet && !gLateTest) TSGlassAfterLink(t, prog, NO);
}

// Once per context, from inside its rendering: the glass programs linked before the hook.
static void TSGlassScan(TSGlassCtx *t) {
    static int uses;
    if (gLateTest > 0 && ++uses < gLateTest) return;   // lab: let CoreAnimation link and use its programs first
    t->scanned = 1;
    int programs = 0, before = t->nprograms;
    for (GLuint h = 1; h < 4096; h++)
        if (t->ctx->disp.is_program(t->rend, h)) { programs++; TSGlassAfterLink(t, (GLhandleARB)(uintptr_t)h, YES); }
    TSMtlGlass(@"context %p: %d programs linked before the hook, %d of them Moraea glass moved to Apple's", (void *)t->ctx, programs,
               t->nprograms - before);
}

// Runtime switch (kill file, policy, trial deadline): when a known program is used after the switch changed, its
// source goes back to Moraea's, or forward to Apple's, in place (TSGlassSwap keeps locations and values).
static void TSGlassUse(GLIContext c, GLhandleARB prog) {
    TSGlassCtx *t = TSGlassFind(c);
    if (!t) return;
    t->use(c, prog);
    if (!gSnippet) return;
    if (!t->scanned) TSGlassScan(t);
    if (!t->nprograms) return;
    TSGlassPoll();
    for (int i = 0; i < t->nprograms; i++) {
        if (t->programs[i].prog != prog || t->programs[i].gen == gOffGen) continue;
        t->programs[i].gen = gOffGen;
        @autoreleasepool {
            NSString *moraea = @(t->programs[i].moraea), *mine = @(t->programs[i].mine), *log = nil;
            BOOL ok = TSGlassSwap(t, prog, t->programs[i].fs, gOff ? moraea : mine, gOff ? mine : moraea, YES, &log);
            if (!ok) TSMtlGlass(@"program %u: switch to %s's glass failed (%@)", (unsigned)(uintptr_t)prog, gOff ? "Moraea" : "Apple", log);
            gReplaced += ok ? (gOff ? -1 : 1) : 0;
            TSGlassWriteStatus(gOff ? @"off" : @"active", nil);
        }
    }
}

void TSGlassHookContext(void *cglContext) {
    CGLContextObj ctx = cglContext;
    if (!ctx || !gSnippet || ctx->disp.link_program_ARB == TSGlassLink) return;
    void *source = TSGlassEngineShaderSource(ctx);
    os_unfair_lock_lock(&gLock);
    if (ctx->disp.link_program_ARB != TSGlassLink) {
        TSGlassCtx *t = NULL;
        int n = atomic_load_explicit(&gNCtx, memory_order_relaxed);
        for (int i = 0; i < n && !t; i++) if (gCtx[i].ctx == ctx) t = &gCtx[i];   // a new context at a freed one's address
        if (!t && n < 8) t = &gCtx[n];
        if (t) {
            TSGlassCtx fresh = { .ctx = ctx, .rend = ctx->rend, .link = ctx->disp.link_program_ARB, .use = ctx->disp.use_program_object_ARB };
            fresh.source = source;
            *t = fresh;
            ctx->disp.link_program_ARB = TSGlassLink;
            ctx->disp.use_program_object_ARB = TSGlassUse;
            if (t == &gCtx[n]) atomic_store_explicit(&gNCtx, n + 1, memory_order_release);
            Dl_info di;
            TSMtlGlass(@"hooked GL context %p (shader source via %s)", (void *)ctx,
                       dladdr((void *)t->source, &di) && di.dli_fname ? strrchr(di.dli_fname, '/') + 1 : "?");
        } else {
            TSMtlGlass(@"too many GL contexts: %p not hooked", (void *)ctx);
        }
    }
    os_unfair_lock_unlock(&gLock);
}

#pragma mark - SkyLightOriginal's CARenderOGL* imports

// Pre-call stubs: the argument registers are saved, TSGlassPre(first argument, stub index) hooks a context, and the
// stub jumps to what the pointer held before, so the call itself is unchanged. Stubs 0-3: SkyLightOriginal's
// CARenderOGL* imports. Stub 4: Moraea's _gQCOrigBeginRendering, the QuartzCore function its CG9M_BeginRendering
// calls right after hooking the renderer's context (Moraea composes the desktop itself and calls QuartzCore through
// its own pointers, so in WindowServer the imports above are not used).
#define TSG_STUBS 5
#define TSG_MORAEA_BEGIN 4
static const char *const kTSGlassImports[TSG_STUBS - 1] = {
    "CARenderOGLBeginRendering", "CARenderOGLRender", "CARenderOGLRenderDisplayWithOptions", "CARenderOGLEndRendering"
};
__attribute__((used)) static void *tsg_next[TSG_STUBS];
static intptr_t gRendererContextOffset = -1;   // where a CoreAnimation OGL renderer keeps its CGL context (from Moraea's code)
__attribute__((used)) static void TSGlassPre(void *renderer, long index) {
    CGLContextObj c = NULL;
    if ((index == 0 || index == TSG_MORAEA_BEGIN) && renderer && gRendererContextOffset >= 0)
        c = *(CGLContextObj *)((char *)renderer + gRendererContextOffset);
    if (!c) c = CGLGetCurrentContext();
    if (c) TSGlassHookContext(c);
}
extern char tsg_stub0[] __asm__("_tsg_stub0"), tsg_stub1[] __asm__("_tsg_stub1"), tsg_stub2[] __asm__("_tsg_stub2"),
            tsg_stub3[] __asm__("_tsg_stub3"), tsg_stub4[] __asm__("_tsg_stub4");
__asm__(
    ".text\n"
    ".p2align 4\n_tsg_stub0: movl $0, %r11d\n jmp _tsg_common\n"
    ".p2align 4\n_tsg_stub1: movl $1, %r11d\n jmp _tsg_common\n"
    ".p2align 4\n_tsg_stub2: movl $2, %r11d\n jmp _tsg_common\n"
    ".p2align 4\n_tsg_stub3: movl $3, %r11d\n jmp _tsg_common\n"
    ".p2align 4\n_tsg_stub4: movl $4, %r11d\n jmp _tsg_common\n"
    ".p2align 4\n_tsg_common:\n"
    " push %rdi\n push %rsi\n push %rdx\n push %rcx\n push %r8\n push %r9\n push %rax\n push %r11\n"
    " sub $136, %rsp\n"   // 8 + 64 + 136: 16-byte aligned for the call
    " movdqu %xmm0, 0(%rsp)\n movdqu %xmm1, 16(%rsp)\n movdqu %xmm2, 32(%rsp)\n movdqu %xmm3, 48(%rsp)\n"
    " movdqu %xmm4, 64(%rsp)\n movdqu %xmm5, 80(%rsp)\n movdqu %xmm6, 96(%rsp)\n movdqu %xmm7, 112(%rsp)\n"
    " mov %r11, %rsi\n"  // rdi (first argument) is untouched: TSGlassPre(renderer, index)
    " call _TSGlassPre\n"
    " movdqu 0(%rsp), %xmm0\n movdqu 16(%rsp), %xmm1\n movdqu 32(%rsp), %xmm2\n movdqu 48(%rsp), %xmm3\n"
    " movdqu 64(%rsp), %xmm4\n movdqu 80(%rsp), %xmm5\n movdqu 96(%rsp), %xmm6\n movdqu 112(%rsp), %xmm7\n"
    " add $136, %rsp\n"
    " pop %r11\n pop %rax\n pop %r9\n pop %r8\n pop %rcx\n pop %rdx\n pop %rsi\n pop %rdi\n"
    " leaq _tsg_next(%rip), %r10\n"
    " jmp *(%r10,%r11,8)\n");

// fishhook-style: the image's indirect symbol table names each pointer of its __got sections.
static int TSGlassRebind(const struct mach_header_64 *mh, intptr_t slide) {
    void *const stubs[TSG_STUBS - 1] = { tsg_stub0, tsg_stub1, tsg_stub2, tsg_stub3 };
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    const struct load_command *lc = (const void *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++, lc = (const void *)((const char *)lc + lc->cmdsize)) {
        if (lc->cmd == LC_SEGMENT_64 && !strcmp(((const struct segment_command_64 *)lc)->segname, SEG_LINKEDIT)) linkedit = (const void *)lc;
        else if (lc->cmd == LC_SYMTAB) symtab = (const void *)lc;
        else if (lc->cmd == LC_DYSYMTAB) dysymtab = (const void *)lc;
    }
    if (!linkedit || !symtab || !dysymtab || !dysymtab->nindirectsyms) return 0;
    uintptr_t base = slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *syms = (const void *)(base + symtab->symoff);
    const char *strings = (const char *)(base + symtab->stroff);
    const uint32_t *indirect = (const void *)(base + dysymtab->indirectsymoff);
    int found = 0;
    lc = (const void *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++, lc = (const void *)((const char *)lc + lc->cmdsize)) {
        if (lc->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *seg = (const void *)lc;
        const struct section_64 *sect = (const void *)(seg + 1);
        for (uint32_t j = 0; j < seg->nsects; j++, sect++) {
            uint32_t type = sect->flags & SECTION_TYPE;
            if (type != S_NON_LAZY_SYMBOL_POINTERS && type != S_LAZY_SYMBOL_POINTERS) continue;
            void **ptrs = (void **)(slide + sect->addr);
            for (uint64_t k = 0; k < sect->size / sizeof(void *); k++) {
                uint32_t sym = indirect[sect->reserved1 + k];
                if (sym == INDIRECT_SYMBOL_ABS || sym == INDIRECT_SYMBOL_LOCAL || sym == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS) ||
                    sym >= symtab->nsyms) continue;
                const char *name = strings + syms[sym].n_un.n_strx;
                for (int s = 0; s < TSG_STUBS - 1; s++) {
                    if (name[0] != '_' || strcmp(name + 1, kTSGlassImports[s]) || ptrs[k] == stubs[s] || tsg_next[s]) continue;
                    mach_vm_address_t page = (mach_vm_address_t)&ptrs[k] & ~(mach_vm_address_t)(vm_page_size - 1);
                    if (mach_vm_protect(mach_task_self(), page, vm_page_size, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS)
                        continue;
                    tsg_next[s] = ptrs[k];
                    ptrs[k] = stubs[s];
                    mach_vm_protect(mach_task_self(), page, vm_page_size, FALSE, VM_PROT_READ);
                    Dl_info di;
                    TSMtlGlass(@"%s hooked (was %s)", kTSGlassImports[s], dladdr(tsg_next[s], &di) && di.dli_sname ? di.dli_sname : "?");
                    found++;
                }
            }
        }
    }
    return found;
}

static int TSGlassRebindSkyLight(void) {
    int found = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "/SkyLightOriginal"))
            found += TSGlassRebind((const void *)_dyld_get_image_header(i), _dyld_get_image_vmaddr_slide(i));
    }
    return found;
}

// Moraea's renderer hook: _gQCOrigBeginRendering (a pointer in its data, filled when Moraea hooks QuartzCore)
// becomes stub 4. The offset of the renderer's CGL context comes from Moraea's own CG9M_PatchShaderSource, which
// reads it with `mov disp32(%rax), %rax` (48 8b 80 <disp32>). NO while Moraea has not filled the pointer yet.
static BOOL TSGlassHookMoraea(void) {
    static const char *const shim = "/SkyLight.framework/Versions/A/SkyLight";
    void **slot = (void **)TSGlassSymbol(shim, "_gQCOrigBeginRendering");
    if (!slot) return NO;
    const uint8_t *code = (const uint8_t *)TSGlassSymbol(shim, "_CG9M_PatchShaderSource");
    for (int k = 0; code && k < 64 && gRendererContextOffset < 0; k++) {
        if (code[k] != 0x48 || code[k + 1] != 0x8b || code[k + 2] != 0x80) continue;
        int32_t off;
        memcpy(&off, code + k + 3, sizeof off);
        if (off > 0 && off < 0x10000) gRendererContextOffset = off;
    }
    void *cur = __atomic_load_n(slot, __ATOMIC_ACQUIRE);
    if (!cur) return NO;
    if (cur == (void *)tsg_stub4) return YES;
    tsg_next[TSG_MORAEA_BEGIN] = cur;
    __atomic_store_n(slot, (void *)tsg_stub4, __ATOMIC_RELEASE);
    Dl_info di;
    TSMtlGlass(@"Moraea's BeginRendering hooked (was %s, renderer context at +0x%lx)",
               dladdr(cur, &di) && di.dli_sname ? di.dli_sname : "?", (long)gRendererContextOffset);
    return YES;
}

#pragma mark - Start

void TSGlassStart(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ @autoreleasepool {
        NSString *kill = TSGlassStatePath(@"DISABLE"), *starts = TSGlassStatePath(@"starts");
        if (access(kill.fileSystemRepresentation, F_OK) == 0) {
            TSMtlGlass(@"off: kill switch %@ present", kill);
            TSGlassWriteStatus(@"off", @"kill switch present");
            return;
        }
        if (!TSGlassPolicyEnabled()) {
            TSMtlGlass(@"off: System.Glass.Enabled is not set in policy.plist (or its trial expired)");
            TSGlassWriteStatus(@"off", @"not enabled in policy.plist");
            return;
        }
        // Crash guard: three starts without 2 minutes of uptime in between turn the component off for good (the kill
        // file), so a WindowServer that crashes because of it comes back with Moraea's glass at the next restart.
        int count = [NSString stringWithContentsOfFile:starts encoding:NSUTF8StringEncoding error:nil].intValue;
        if (count >= 3) {
            [@"crash guard: WindowServer restarted 3 times within 2 minutes of starting TeraScale Glass\n"
                writeToFile:kill atomically:YES encoding:NSUTF8StringEncoding error:nil];
            TSMtlGlass(@"off: crash guard tripped (%d quick restarts), kill switch written", count);
            TSGlassWriteStatus(@"off", @"crash guard tripped");
            return;
        }
        [[NSString stringWithFormat:@"%d\n", count + 1] writeToFile:starts atomically:YES encoding:NSUTF8StringEncoding error:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            [@"0\n" writeToFile:starts atomically:YES encoding:NSUTF8StringEncoding error:nil];
        });
        NSString *file = [TSMtlConfigDir() stringByAppendingPathComponent:@"glass/glass.glsl"];
        NSString *snippet = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:nil];
        if (![snippet containsString:@"vec4 tsg_glass()"]) {
            TSMtlGlass(@"off: %@ missing or not a TeraScale Glass snippet (run tools/glassgen)", file);
            TSGlassWriteStatus(@"off", @"glass.glsl missing");
            return;
        }
        gSnippet = snippet;
        int hooked = TSGlassRebindSkyLight();
        BOOL moraea = TSGlassHookMoraea();
        TSMtlGlass(@"active in %s (pid %d): %d CARenderOGL entries hooked, Moraea's BeginRendering %s", getprogname(), getpid(),
                   hooked, moraea ? "hooked" : "not yet filled (retrying)");
        TSGlassWriteStatus(@"active", moraea ? nil : @"waiting for Moraea's BeginRendering pointer");
        if (!moraea) {   // Moraea installs its QuartzCore hooks with dispatch_after: retry for two minutes
            __block int tries = 0;
            dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
            dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 4), NSEC_PER_SEC / 4, NSEC_PER_SEC / 20);
            dispatch_source_set_event_handler(timer, ^{
                if (TSGlassHookMoraea()) { TSGlassWriteStatus(@"active", nil); dispatch_source_cancel(timer); }
                else if (++tries >= 480) {
                    TSMtlGlass(@"Moraea's BeginRendering pointer never filled: no context hooked");
                    TSGlassWriteStatus(@"active", @"Moraea's BeginRendering not found");
                    dispatch_source_cancel(timer);
                }
            });
            dispatch_resume(timer);
        }
    } });
}

__attribute__((constructor)) static void TSGlassInit(void) {
    if (strcmp(getprogname(), "WindowServer")) return;
    // The real WindowServer, or a lab copy with its own configuration (TSMTL_CONFIG_DIR): a lab copy without one would
    // share the real kill switch, crash counter and status (three lab runs once tripped the real crash guard).
    char exe[PATH_MAX];
    uint32_t size = sizeof exe;
    BOOL real = _NSGetExecutablePath(exe, &size) == 0 &&
                !strcmp(exe, "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer");
    if (!real && !(getenv("TSMTL_CONFIG_DIR") && *getenv("TSMTL_CONFIG_DIR"))) return;
    // One component per process: in the lab the injected libTSMetal and the installed driver bundle are both loaded.
    if (getenv("TSGLASS_STARTED")) return;
    setenv("TSGLASS_STARTED", "1", 1);
    TSGlassStart();
}
