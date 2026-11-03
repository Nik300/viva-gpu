// TeraScale Metal Shim - OpenGL 4.1 core context and pixel format table.
#import "TSPrivate.h"
#import <OpenGL/gl3ext.h>

#ifndef GL_COMPRESSED_RGBA_S3TC_DXT1_EXT
#define GL_COMPRESSED_RGBA_S3TC_DXT1_EXT 0x83F1
#define GL_COMPRESSED_RGBA_S3TC_DXT3_EXT 0x83F2
#define GL_COMPRESSED_RGBA_S3TC_DXT5_EXT 0x83F3
#endif
#ifndef GL_COMPRESSED_SRGB_ALPHA_S3TC_DXT1_EXT
#define GL_COMPRESSED_SRGB_ALPHA_S3TC_DXT1_EXT 0x8C4D
#define GL_COMPRESSED_SRGB_ALPHA_S3TC_DXT3_EXT 0x8C4E
#define GL_COMPRESSED_SRGB_ALPHA_S3TC_DXT5_EXT 0x8C4F
#endif

// Video memory and IORegistry ID of the renderer behind the context, via the renderer info API.
// The registry ID names the IOAccelerator that drives the displays (not the idle Intel HD 3000).
static void TSGLRendererIdentity(CGLContextObj ctx, TSGLInfo *out) {
    GLint current = 0;
    CGLGetParameter(ctx, kCGLCPCurrentRendererID, &current);
    CGLRendererInfoObj info;
    GLint count = 0;
    if (CGLQueryRendererInfo(0xFFFFFFFF, &info, &count) != kCGLNoError) return;
    for (GLint i = 0; i < count; i++) {
        GLint rid = 0, accelerated = 0, mb = 0, lo = 0, hi = 0;
        CGLDescribeRenderer(info, i, kCGLRPRendererID, &rid);
        CGLDescribeRenderer(info, i, kCGLRPAccelerated, &accelerated);
        CGLDescribeRenderer(info, i, kCGLRPVideoMemoryMegabytes, &mb);
        BOOL isCurrent = (rid & kCGLRendererIDMatchingMask) == (current & kCGLRendererIDMatchingMask);
        // Without a match keep the accelerated renderer with the most memory, as before.
        if (!isCurrent && (!accelerated || out->registryID || (uint64_t)mb << 20 <= out->vramBytes)) continue;
        out->vramBytes = (uint64_t)mb << 20;
        if (isCurrent && CGLDescribeRenderer(info, i, kCGLRPRegistryIDLow, &lo) == kCGLNoError &&
            CGLDescribeRenderer(info, i, kCGLRPRegistryIDHigh, &hi) == kCGLNoError) {
            out->registryID = (uint64_t)(uint32_t)hi << 32 | (uint32_t)lo;
            break;
        }
    }
    CGLDestroyRendererInfo(info);
}

CGLContextObj TSGLCreateContext(TSGLInfo *out) {
    memset(out, 0, sizeof *out);
    CGLPixelFormatAttribute attrs[] = {
        kCGLPFAOpenGLProfile, (CGLPixelFormatAttribute)kCGLOGLPVersion_GL4_Core,
        kCGLPFAAccelerated, kCGLPFANoRecovery, (CGLPixelFormatAttribute)0
    };
    CGLPixelFormatObj pf = NULL;
    GLint npf = 0;
    if (CGLChoosePixelFormat(attrs, &pf, &npf) != kCGLNoError || !pf) return NULL;
    CGLContextObj ctx = NULL;
    CGLError err = CGLCreateContext(pf, NULL, &ctx);
    CGLReleasePixelFormat(pf);
    if (err != kCGLNoError || !ctx) return NULL;

    CGLContextObj prev = CGLGetCurrentContext();
    CGLSetCurrentContext(ctx);
    const char *r = (const char *)glGetString(GL_RENDERER);
    snprintf(out->renderer, sizeof out->renderer, "%s", r ? r : "TeraScale");
    char *suffix = strstr(out->renderer, " OpenGL Engine");
    if (suffix) *suffix = 0;
    glGetIntegerv(GL_MAX_TEXTURE_SIZE, &out->maxTextureSize);
    glGetIntegerv(GL_MAX_3D_TEXTURE_SIZE, &out->max3DTextureSize);
    glGetIntegerv(GL_MAX_CUBE_MAP_TEXTURE_SIZE, &out->maxCubeMapSize);
    glGetIntegerv(GL_MAX_ARRAY_TEXTURE_LAYERS, &out->maxArrayLayers);
    glGetIntegerv(GL_MAX_COLOR_ATTACHMENTS, &out->maxColorAttachments);
    glGetIntegerv(GL_MAX_SAMPLES, &out->maxSamples);
    glGetIntegerv(GL_MAX_VERTEX_ATTRIBS, &out->maxVertexAttribs);
    glGetIntegerv(GL_MAX_TEXTURE_IMAGE_UNITS, &out->maxTextureUnits);
    glGetIntegerv(GL_MAX_VERTEX_TEXTURE_IMAGE_UNITS, &out->maxVertexTextureUnits);
    glGetIntegerv(GL_MAX_UNIFORM_BLOCK_SIZE, &out->maxUniformBlockSize);
    glGetIntegerv(GL_MAX_VERTEX_OUTPUT_COMPONENTS, &out->maxVaryingComponents);
    glGetIntegerv(GL_MAX_TEXTURE_BUFFER_SIZE, &out->maxTextureBufferSize);
    GLfloat range[2] = {1, 1};
    glGetFloatv(GL_POINT_SIZE_RANGE, range);
    out->maxPointSize = range[1];
    glGetFloatv(GL_ALIASED_LINE_WIDTH_RANGE, range);
    out->maxLineWidth = range[1];
    glGetError();
    CGLSetCurrentContext(prev);

    TSGLRendererIdentity(ctx, out);
    return ctx;
}

TSGLFormat TSGLFormatFor(MTLPixelFormat f) {
#define F(i, fmt, ty) return (TSGLFormat){ i, fmt, ty, YES, NO, NO, NO, NO, NO }
#define FI(i, fmt, ty, sgn) return (TSGLFormat){ i, fmt, ty, YES, NO, YES, sgn, NO, NO }
#define FC(i) return (TSGLFormat){ i, 0, 0, YES, YES, NO, NO, NO, NO }
#define FD(i, fmt, ty, st) return (TSGLFormat){ i, fmt, ty, YES, NO, NO, NO, YES, st }
    switch (f) {
    case MTLPixelFormatA8Unorm:          F(GL_R8, GL_RED, GL_UNSIGNED_BYTE);
    case MTLPixelFormatR8Unorm:          F(GL_R8, GL_RED, GL_UNSIGNED_BYTE);
    case MTLPixelFormatR8Snorm:          F(GL_R8_SNORM, GL_RED, GL_BYTE);
    case MTLPixelFormatR8Uint:           FI(GL_R8UI, GL_RED_INTEGER, GL_UNSIGNED_BYTE, NO);
    case MTLPixelFormatR8Sint:           FI(GL_R8I, GL_RED_INTEGER, GL_BYTE, YES);
    case MTLPixelFormatR16Unorm:         F(GL_R16, GL_RED, GL_UNSIGNED_SHORT);
    case MTLPixelFormatR16Snorm:         F(GL_R16_SNORM, GL_RED, GL_SHORT);
    case MTLPixelFormatR16Uint:          FI(GL_R16UI, GL_RED_INTEGER, GL_UNSIGNED_SHORT, NO);
    case MTLPixelFormatR16Sint:          FI(GL_R16I, GL_RED_INTEGER, GL_SHORT, YES);
    case MTLPixelFormatR16Float:         F(GL_R16F, GL_RED, GL_HALF_FLOAT);
    case MTLPixelFormatRG8Unorm:         F(GL_RG8, GL_RG, GL_UNSIGNED_BYTE);
    case MTLPixelFormatRG8Snorm:         F(GL_RG8_SNORM, GL_RG, GL_BYTE);
    case MTLPixelFormatRG8Uint:          FI(GL_RG8UI, GL_RG_INTEGER, GL_UNSIGNED_BYTE, NO);
    case MTLPixelFormatRG8Sint:          FI(GL_RG8I, GL_RG_INTEGER, GL_BYTE, YES);
    case MTLPixelFormatB5G6R5Unorm:      F(GL_RGB565, GL_RGB, GL_UNSIGNED_SHORT_5_6_5);
    case MTLPixelFormatR32Uint:          FI(GL_R32UI, GL_RED_INTEGER, GL_UNSIGNED_INT, NO);
    case MTLPixelFormatR32Sint:          FI(GL_R32I, GL_RED_INTEGER, GL_INT, YES);
    case MTLPixelFormatR32Float:         F(GL_R32F, GL_RED, GL_FLOAT);
    case MTLPixelFormatRG16Unorm:        F(GL_RG16, GL_RG, GL_UNSIGNED_SHORT);
    case MTLPixelFormatRG16Snorm:        F(GL_RG16_SNORM, GL_RG, GL_SHORT);
    case MTLPixelFormatRG16Uint:         FI(GL_RG16UI, GL_RG_INTEGER, GL_UNSIGNED_SHORT, NO);
    case MTLPixelFormatRG16Sint:         FI(GL_RG16I, GL_RG_INTEGER, GL_SHORT, YES);
    case MTLPixelFormatRG16Float:        F(GL_RG16F, GL_RG, GL_HALF_FLOAT);
    case MTLPixelFormatRGBA8Unorm:       F(GL_RGBA8, GL_RGBA, GL_UNSIGNED_BYTE);
    case MTLPixelFormatRGBA8Unorm_sRGB:  F(GL_SRGB8_ALPHA8, GL_RGBA, GL_UNSIGNED_BYTE);
    case MTLPixelFormatRGBA8Snorm:       F(GL_RGBA8_SNORM, GL_RGBA, GL_BYTE);
    case MTLPixelFormatRGBA8Uint:        FI(GL_RGBA8UI, GL_RGBA_INTEGER, GL_UNSIGNED_BYTE, NO);
    case MTLPixelFormatRGBA8Sint:        FI(GL_RGBA8I, GL_RGBA_INTEGER, GL_BYTE, YES);
    case MTLPixelFormatBGRA8Unorm:       F(GL_RGBA8, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV);
    case MTLPixelFormatBGRA8Unorm_sRGB:  F(GL_SRGB8_ALPHA8, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV);
    case MTLPixelFormatRGB10A2Unorm:     F(GL_RGB10_A2, GL_RGBA, GL_UNSIGNED_INT_2_10_10_10_REV);
    case MTLPixelFormatRGB10A2Uint:      FI(GL_RGB10_A2UI, GL_RGBA_INTEGER, GL_UNSIGNED_INT_2_10_10_10_REV, NO);
    case MTLPixelFormatBGR10A2Unorm:     F(GL_RGB10_A2, GL_BGRA, GL_UNSIGNED_INT_2_10_10_10_REV);
    case MTLPixelFormatRG11B10Float:     F(GL_R11F_G11F_B10F, GL_RGB, GL_UNSIGNED_INT_10F_11F_11F_REV);
    case MTLPixelFormatRGB9E5Float:      F(GL_RGB9_E5, GL_RGB, GL_UNSIGNED_INT_5_9_9_9_REV);
    case MTLPixelFormatRG32Uint:         FI(GL_RG32UI, GL_RG_INTEGER, GL_UNSIGNED_INT, NO);
    case MTLPixelFormatRG32Sint:         FI(GL_RG32I, GL_RG_INTEGER, GL_INT, YES);
    case MTLPixelFormatRG32Float:        F(GL_RG32F, GL_RG, GL_FLOAT);
    case MTLPixelFormatRGBA16Unorm:      F(GL_RGBA16, GL_RGBA, GL_UNSIGNED_SHORT);
    case MTLPixelFormatRGBA16Snorm:      F(GL_RGBA16_SNORM, GL_RGBA, GL_SHORT);
    case MTLPixelFormatRGBA16Uint:       FI(GL_RGBA16UI, GL_RGBA_INTEGER, GL_UNSIGNED_SHORT, NO);
    case MTLPixelFormatRGBA16Sint:       FI(GL_RGBA16I, GL_RGBA_INTEGER, GL_SHORT, YES);
    case MTLPixelFormatRGBA16Float:      F(GL_RGBA16F, GL_RGBA, GL_HALF_FLOAT);
    case MTLPixelFormatRGBA32Uint:       FI(GL_RGBA32UI, GL_RGBA_INTEGER, GL_UNSIGNED_INT, NO);
    case MTLPixelFormatRGBA32Sint:       FI(GL_RGBA32I, GL_RGBA_INTEGER, GL_INT, YES);
    case MTLPixelFormatRGBA32Float:      F(GL_RGBA32F, GL_RGBA, GL_FLOAT);
    case MTLPixelFormatBC1_RGBA:         FC(GL_COMPRESSED_RGBA_S3TC_DXT1_EXT);
    case MTLPixelFormatBC1_RGBA_sRGB:    FC(GL_COMPRESSED_SRGB_ALPHA_S3TC_DXT1_EXT);
    case MTLPixelFormatBC2_RGBA:         FC(GL_COMPRESSED_RGBA_S3TC_DXT3_EXT);
    case MTLPixelFormatBC2_RGBA_sRGB:    FC(GL_COMPRESSED_SRGB_ALPHA_S3TC_DXT3_EXT);
    case MTLPixelFormatBC3_RGBA:         FC(GL_COMPRESSED_RGBA_S3TC_DXT5_EXT);
    case MTLPixelFormatBC3_RGBA_sRGB:    FC(GL_COMPRESSED_SRGB_ALPHA_S3TC_DXT5_EXT);
    case MTLPixelFormatBC4_RUnorm:       FC(GL_COMPRESSED_RED_RGTC1);
    case MTLPixelFormatBC4_RSnorm:       FC(GL_COMPRESSED_SIGNED_RED_RGTC1);
    case MTLPixelFormatBC5_RGUnorm:      FC(GL_COMPRESSED_RG_RGTC2);
    case MTLPixelFormatBC5_RGSnorm:      FC(GL_COMPRESSED_SIGNED_RG_RGTC2);
    case MTLPixelFormatDepth16Unorm:     FD(GL_DEPTH_COMPONENT16, GL_DEPTH_COMPONENT, GL_UNSIGNED_SHORT, NO);
    case MTLPixelFormatDepth32Float:     FD(GL_DEPTH_COMPONENT32F, GL_DEPTH_COMPONENT, GL_FLOAT, NO);
    // GL 4.1 has no stencil-only textures: stencil lives in a packed depth/stencil texture.
    case MTLPixelFormatStencil8:
    case MTLPixelFormatDepth24Unorm_Stencil8:
    case MTLPixelFormatX24_Stencil8:     FD(GL_DEPTH24_STENCIL8, GL_DEPTH_STENCIL, GL_UNSIGNED_INT_24_8, YES);
    case MTLPixelFormatDepth32Float_Stencil8:
    case MTLPixelFormatX32_Stencil8:     FD(GL_DEPTH32F_STENCIL8, GL_DEPTH_STENCIL, GL_FLOAT_32_UNSIGNED_INT_24_8_REV, YES);
    default: // BC6H/BC7 (no BPTC on this GPU), ASTC/ETC/PVRTC, YUV: contents are not representable
        return (TSGLFormat){ GL_RGBA8, GL_RGBA, GL_UNSIGNED_BYTE, NO, NO, NO, NO, NO, NO };
    }
#undef F
#undef FI
#undef FC
#undef FD
}
