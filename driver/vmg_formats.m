// Viva Metal - Metal pixel/vertex formats -> Gallium formats. Objective-C only for the Metal enums; no Gallium
#pragma clang diagnostic ignored "-Wdeprecated-declarations"   // Depth24Unorm_Stencil8 / X24_Stencil8 still exist on iOS 16
// structures here (just the u_formats.h enum).
#import <Metal/Metal.h>
#include <stdbool.h>
#include "util/format/u_formats.h"

// macOS-only formats, by value (unavailable in the iOS SDK).
enum { VM_PF_D24S8 = 255, VM_PF_X24S8 = 262 };

enum pipe_format vmg_pipe_format(unsigned f);
enum pipe_format vmg_vertex_format(unsigned f);
bool vmg_format_is_depth(unsigned f), vmg_format_is_stencil(unsigned f);
bool vmg_format_is_integer(unsigned f), vmg_format_is_signed_integer(unsigned f);

enum pipe_format vmg_pipe_format(unsigned f)
{
    switch ((MTLPixelFormat)f) {
    case MTLPixelFormatA8Unorm: return PIPE_FORMAT_A8_UNORM;
    case MTLPixelFormatR8Unorm: return PIPE_FORMAT_R8_UNORM;
    case MTLPixelFormatR8Unorm_sRGB: return PIPE_FORMAT_R8_SRGB;
    case MTLPixelFormatR8Snorm: return PIPE_FORMAT_R8_SNORM;
    case MTLPixelFormatR8Uint: return PIPE_FORMAT_R8_UINT;
    case MTLPixelFormatR8Sint: return PIPE_FORMAT_R8_SINT;
    case MTLPixelFormatR16Unorm: return PIPE_FORMAT_R16_UNORM;
    case MTLPixelFormatR16Snorm: return PIPE_FORMAT_R16_SNORM;
    case MTLPixelFormatR16Uint: return PIPE_FORMAT_R16_UINT;
    case MTLPixelFormatR16Sint: return PIPE_FORMAT_R16_SINT;
    case MTLPixelFormatR16Float: return PIPE_FORMAT_R16_FLOAT;
    case MTLPixelFormatRG8Unorm: return PIPE_FORMAT_R8G8_UNORM;
    case MTLPixelFormatRG8Unorm_sRGB: return PIPE_FORMAT_R8G8_SRGB;
    case MTLPixelFormatRG8Snorm: return PIPE_FORMAT_R8G8_SNORM;
    case MTLPixelFormatRG8Uint: return PIPE_FORMAT_R8G8_UINT;
    case MTLPixelFormatRG8Sint: return PIPE_FORMAT_R8G8_SINT;
    case MTLPixelFormatB5G6R5Unorm: return PIPE_FORMAT_B5G6R5_UNORM;
    case MTLPixelFormatA1BGR5Unorm: return PIPE_FORMAT_A1B5G5R5_UNORM;
    case MTLPixelFormatABGR4Unorm: return PIPE_FORMAT_A4B4G4R4_UNORM;
    case MTLPixelFormatBGR5A1Unorm: return PIPE_FORMAT_B5G5R5A1_UNORM;
    case MTLPixelFormatR32Uint: return PIPE_FORMAT_R32_UINT;
    case MTLPixelFormatR32Sint: return PIPE_FORMAT_R32_SINT;
    case MTLPixelFormatR32Float: return PIPE_FORMAT_R32_FLOAT;
    case MTLPixelFormatRG16Unorm: return PIPE_FORMAT_R16G16_UNORM;
    case MTLPixelFormatRG16Snorm: return PIPE_FORMAT_R16G16_SNORM;
    case MTLPixelFormatRG16Uint: return PIPE_FORMAT_R16G16_UINT;
    case MTLPixelFormatRG16Sint: return PIPE_FORMAT_R16G16_SINT;
    case MTLPixelFormatRG16Float: return PIPE_FORMAT_R16G16_FLOAT;
    case MTLPixelFormatRGBA8Unorm: return PIPE_FORMAT_R8G8B8A8_UNORM;
    case MTLPixelFormatRGBA8Unorm_sRGB: return PIPE_FORMAT_R8G8B8A8_SRGB;
    case MTLPixelFormatRGBA8Snorm: return PIPE_FORMAT_R8G8B8A8_SNORM;
    case MTLPixelFormatRGBA8Uint: return PIPE_FORMAT_R8G8B8A8_UINT;
    case MTLPixelFormatRGBA8Sint: return PIPE_FORMAT_R8G8B8A8_SINT;
    case MTLPixelFormatBGRA8Unorm: return PIPE_FORMAT_B8G8R8A8_UNORM;
    case MTLPixelFormatBGRA8Unorm_sRGB: return PIPE_FORMAT_B8G8R8A8_SRGB;
    case MTLPixelFormatRGB10A2Unorm: return PIPE_FORMAT_R10G10B10A2_UNORM;
    case MTLPixelFormatRGB10A2Uint: return PIPE_FORMAT_R10G10B10A2_UINT;
    case MTLPixelFormatBGR10A2Unorm: return PIPE_FORMAT_B10G10R10A2_UNORM;
    case MTLPixelFormatRG11B10Float: return PIPE_FORMAT_R11G11B10_FLOAT;
    case MTLPixelFormatRGB9E5Float: return PIPE_FORMAT_R9G9B9E5_FLOAT;
    case MTLPixelFormatRG32Uint: return PIPE_FORMAT_R32G32_UINT;
    case MTLPixelFormatRG32Sint: return PIPE_FORMAT_R32G32_SINT;
    case MTLPixelFormatRG32Float: return PIPE_FORMAT_R32G32_FLOAT;
    case MTLPixelFormatRGBA16Unorm: return PIPE_FORMAT_R16G16B16A16_UNORM;
    case MTLPixelFormatRGBA16Snorm: return PIPE_FORMAT_R16G16B16A16_SNORM;
    case MTLPixelFormatRGBA16Uint: return PIPE_FORMAT_R16G16B16A16_UINT;
    case MTLPixelFormatRGBA16Sint: return PIPE_FORMAT_R16G16B16A16_SINT;
    case MTLPixelFormatRGBA16Float: return PIPE_FORMAT_R16G16B16A16_FLOAT;
    case MTLPixelFormatRGBA32Uint: return PIPE_FORMAT_R32G32B32A32_UINT;
    case MTLPixelFormatRGBA32Sint: return PIPE_FORMAT_R32G32B32A32_SINT;
    case MTLPixelFormatRGBA32Float: return PIPE_FORMAT_R32G32B32A32_FLOAT;
    // Extended-range (XR) formats of Apple displays: kept as half floats (same range, no bias); see docs/PIANO-GPU.md.
    case MTLPixelFormatBGRA10_XR: case MTLPixelFormatBGRA10_XR_sRGB: return PIPE_FORMAT_R16G16B16A16_FLOAT;
    case MTLPixelFormatBGR10_XR: case MTLPixelFormatBGR10_XR_sRGB: return PIPE_FORMAT_R16G16B16A16_FLOAT;
    // Block compression
    case MTLPixelFormatBC1_RGBA: return PIPE_FORMAT_DXT1_RGBA;
    case MTLPixelFormatBC1_RGBA_sRGB: return PIPE_FORMAT_DXT1_SRGBA;
    case MTLPixelFormatBC2_RGBA: return PIPE_FORMAT_DXT3_RGBA;
    case MTLPixelFormatBC2_RGBA_sRGB: return PIPE_FORMAT_DXT3_SRGBA;
    case MTLPixelFormatBC3_RGBA: return PIPE_FORMAT_DXT5_RGBA;
    case MTLPixelFormatBC3_RGBA_sRGB: return PIPE_FORMAT_DXT5_SRGBA;
    case MTLPixelFormatBC4_RUnorm: return PIPE_FORMAT_RGTC1_UNORM;
    case MTLPixelFormatBC4_RSnorm: return PIPE_FORMAT_RGTC1_SNORM;
    case MTLPixelFormatBC5_RGUnorm: return PIPE_FORMAT_RGTC2_UNORM;
    case MTLPixelFormatBC5_RGSnorm: return PIPE_FORMAT_RGTC2_SNORM;
    case MTLPixelFormatBC6H_RGBFloat: return PIPE_FORMAT_BPTC_RGB_FLOAT;
    case MTLPixelFormatBC6H_RGBUfloat: return PIPE_FORMAT_BPTC_RGB_UFLOAT;
    case MTLPixelFormatBC7_RGBAUnorm: return PIPE_FORMAT_BPTC_RGBA_UNORM;
    case MTLPixelFormatBC7_RGBAUnorm_sRGB: return PIPE_FORMAT_BPTC_SRGBA;
    case MTLPixelFormatEAC_R11Unorm: return PIPE_FORMAT_ETC2_R11_UNORM;
    case MTLPixelFormatEAC_R11Snorm: return PIPE_FORMAT_ETC2_R11_SNORM;
    case MTLPixelFormatEAC_RG11Unorm: return PIPE_FORMAT_ETC2_RG11_UNORM;
    case MTLPixelFormatEAC_RG11Snorm: return PIPE_FORMAT_ETC2_RG11_SNORM;
    case MTLPixelFormatEAC_RGBA8: return PIPE_FORMAT_ETC2_RGBA8;
    case MTLPixelFormatEAC_RGBA8_sRGB: return PIPE_FORMAT_ETC2_SRGBA8;
    case MTLPixelFormatETC2_RGB8: return PIPE_FORMAT_ETC2_RGB8;
    case MTLPixelFormatETC2_RGB8_sRGB: return PIPE_FORMAT_ETC2_SRGB8;
    case MTLPixelFormatETC2_RGB8A1: return PIPE_FORMAT_ETC2_RGB8A1;
    case MTLPixelFormatETC2_RGB8A1_sRGB: return PIPE_FORMAT_ETC2_SRGB8A1;
    case MTLPixelFormatASTC_4x4_LDR: return PIPE_FORMAT_ASTC_4x4;
    case MTLPixelFormatASTC_4x4_sRGB: return PIPE_FORMAT_ASTC_4x4_SRGB;
    case MTLPixelFormatASTC_5x4_LDR: return PIPE_FORMAT_ASTC_5x4;
    case MTLPixelFormatASTC_5x4_sRGB: return PIPE_FORMAT_ASTC_5x4_SRGB;
    case MTLPixelFormatASTC_5x5_LDR: return PIPE_FORMAT_ASTC_5x5;
    case MTLPixelFormatASTC_5x5_sRGB: return PIPE_FORMAT_ASTC_5x5_SRGB;
    case MTLPixelFormatASTC_6x5_LDR: return PIPE_FORMAT_ASTC_6x5;
    case MTLPixelFormatASTC_6x5_sRGB: return PIPE_FORMAT_ASTC_6x5_SRGB;
    case MTLPixelFormatASTC_6x6_LDR: return PIPE_FORMAT_ASTC_6x6;
    case MTLPixelFormatASTC_6x6_sRGB: return PIPE_FORMAT_ASTC_6x6_SRGB;
    case MTLPixelFormatASTC_8x5_LDR: return PIPE_FORMAT_ASTC_8x5;
    case MTLPixelFormatASTC_8x5_sRGB: return PIPE_FORMAT_ASTC_8x5_SRGB;
    case MTLPixelFormatASTC_8x6_LDR: return PIPE_FORMAT_ASTC_8x6;
    case MTLPixelFormatASTC_8x6_sRGB: return PIPE_FORMAT_ASTC_8x6_SRGB;
    case MTLPixelFormatASTC_8x8_LDR: return PIPE_FORMAT_ASTC_8x8;
    case MTLPixelFormatASTC_8x8_sRGB: return PIPE_FORMAT_ASTC_8x8_SRGB;
    case MTLPixelFormatASTC_10x5_LDR: return PIPE_FORMAT_ASTC_10x5;
    case MTLPixelFormatASTC_10x5_sRGB: return PIPE_FORMAT_ASTC_10x5_SRGB;
    case MTLPixelFormatASTC_10x6_LDR: return PIPE_FORMAT_ASTC_10x6;
    case MTLPixelFormatASTC_10x6_sRGB: return PIPE_FORMAT_ASTC_10x6_SRGB;
    case MTLPixelFormatASTC_10x8_LDR: return PIPE_FORMAT_ASTC_10x8;
    case MTLPixelFormatASTC_10x8_sRGB: return PIPE_FORMAT_ASTC_10x8_SRGB;
    case MTLPixelFormatASTC_10x10_LDR: return PIPE_FORMAT_ASTC_10x10;
    case MTLPixelFormatASTC_10x10_sRGB: return PIPE_FORMAT_ASTC_10x10_SRGB;
    case MTLPixelFormatASTC_12x10_LDR: return PIPE_FORMAT_ASTC_12x10;
    case MTLPixelFormatASTC_12x10_sRGB: return PIPE_FORMAT_ASTC_12x10_SRGB;
    case MTLPixelFormatASTC_12x12_LDR: return PIPE_FORMAT_ASTC_12x12;
    case MTLPixelFormatASTC_12x12_sRGB: return PIPE_FORMAT_ASTC_12x12_SRGB;
    // Depth / stencil
    case MTLPixelFormatDepth16Unorm: return PIPE_FORMAT_Z16_UNORM;
    case MTLPixelFormatDepth32Float: return PIPE_FORMAT_Z32_FLOAT;
    case MTLPixelFormatStencil8: return PIPE_FORMAT_S8_UINT;
    case (MTLPixelFormat)VM_PF_D24S8: return PIPE_FORMAT_Z24_UNORM_S8_UINT;
    case MTLPixelFormatDepth32Float_Stencil8: return PIPE_FORMAT_Z32_FLOAT_S8X24_UINT;
    case MTLPixelFormatX32_Stencil8: return PIPE_FORMAT_X32_S8X24_UINT;
    case (MTLPixelFormat)VM_PF_X24S8: return PIPE_FORMAT_X24S8_UINT;
    // YUV formats (video): not handled yet.
    default: return PIPE_FORMAT_NONE;
    }
}

bool vmg_format_is_depth(unsigned f)
{
    switch ((MTLPixelFormat)f) {
    case MTLPixelFormatDepth16Unorm: case MTLPixelFormatDepth32Float: case (MTLPixelFormat)VM_PF_D24S8:
    case MTLPixelFormatDepth32Float_Stencil8: return true;
    default: return false;
    }
}

bool vmg_format_is_stencil(unsigned f)
{
    switch ((MTLPixelFormat)f) {
    case MTLPixelFormatStencil8: case (MTLPixelFormat)VM_PF_D24S8: case MTLPixelFormatDepth32Float_Stencil8:
    case MTLPixelFormatX32_Stencil8: case (MTLPixelFormat)VM_PF_X24S8: return true;
    default: return false;
    }
}

bool vmg_format_is_signed_integer(unsigned f)
{
    switch ((MTLPixelFormat)f) {
    case MTLPixelFormatR8Sint: case MTLPixelFormatR16Sint: case MTLPixelFormatRG8Sint: case MTLPixelFormatR32Sint:
    case MTLPixelFormatRG16Sint: case MTLPixelFormatRGBA8Sint: case MTLPixelFormatRG32Sint: case MTLPixelFormatRGBA16Sint:
    case MTLPixelFormatRGBA32Sint: return true;
    default: return false;
    }
}

bool vmg_format_is_integer(unsigned f)
{
    if (vmg_format_is_signed_integer(f)) return true;
    switch ((MTLPixelFormat)f) {
    case MTLPixelFormatR8Uint: case MTLPixelFormatR16Uint: case MTLPixelFormatRG8Uint: case MTLPixelFormatR32Uint:
    case MTLPixelFormatRG16Uint: case MTLPixelFormatRGBA8Uint: case MTLPixelFormatRGB10A2Uint: case MTLPixelFormatRG32Uint:
    case MTLPixelFormatRGBA16Uint: case MTLPixelFormatRGBA32Uint: case MTLPixelFormatStencil8: return true;
    default: return false;
    }
}

enum pipe_format vmg_vertex_format(unsigned f)
{
    switch ((MTLVertexFormat)f) {
    case MTLVertexFormatUChar2: return PIPE_FORMAT_R8G8_UINT;
    case MTLVertexFormatUChar3: return PIPE_FORMAT_R8G8B8_UINT;
    case MTLVertexFormatUChar4: return PIPE_FORMAT_R8G8B8A8_UINT;
    case MTLVertexFormatChar2: return PIPE_FORMAT_R8G8_SINT;
    case MTLVertexFormatChar3: return PIPE_FORMAT_R8G8B8_SINT;
    case MTLVertexFormatChar4: return PIPE_FORMAT_R8G8B8A8_SINT;
    case MTLVertexFormatUChar2Normalized: return PIPE_FORMAT_R8G8_UNORM;
    case MTLVertexFormatUChar3Normalized: return PIPE_FORMAT_R8G8B8_UNORM;
    case MTLVertexFormatUChar4Normalized: return PIPE_FORMAT_R8G8B8A8_UNORM;
    case MTLVertexFormatChar2Normalized: return PIPE_FORMAT_R8G8_SNORM;
    case MTLVertexFormatChar3Normalized: return PIPE_FORMAT_R8G8B8_SNORM;
    case MTLVertexFormatChar4Normalized: return PIPE_FORMAT_R8G8B8A8_SNORM;
    case MTLVertexFormatUShort2: return PIPE_FORMAT_R16G16_UINT;
    case MTLVertexFormatUShort3: return PIPE_FORMAT_R16G16B16_UINT;
    case MTLVertexFormatUShort4: return PIPE_FORMAT_R16G16B16A16_UINT;
    case MTLVertexFormatShort2: return PIPE_FORMAT_R16G16_SINT;
    case MTLVertexFormatShort3: return PIPE_FORMAT_R16G16B16_SINT;
    case MTLVertexFormatShort4: return PIPE_FORMAT_R16G16B16A16_SINT;
    case MTLVertexFormatUShort2Normalized: return PIPE_FORMAT_R16G16_UNORM;
    case MTLVertexFormatUShort3Normalized: return PIPE_FORMAT_R16G16B16_UNORM;
    case MTLVertexFormatUShort4Normalized: return PIPE_FORMAT_R16G16B16A16_UNORM;
    case MTLVertexFormatShort2Normalized: return PIPE_FORMAT_R16G16_SNORM;
    case MTLVertexFormatShort3Normalized: return PIPE_FORMAT_R16G16B16_SNORM;
    case MTLVertexFormatShort4Normalized: return PIPE_FORMAT_R16G16B16A16_SNORM;
    case MTLVertexFormatHalf2: return PIPE_FORMAT_R16G16_FLOAT;
    case MTLVertexFormatHalf3: return PIPE_FORMAT_R16G16B16_FLOAT;
    case MTLVertexFormatHalf4: return PIPE_FORMAT_R16G16B16A16_FLOAT;
    case MTLVertexFormatFloat: return PIPE_FORMAT_R32_FLOAT;
    case MTLVertexFormatFloat2: return PIPE_FORMAT_R32G32_FLOAT;
    case MTLVertexFormatFloat3: return PIPE_FORMAT_R32G32B32_FLOAT;
    case MTLVertexFormatFloat4: return PIPE_FORMAT_R32G32B32A32_FLOAT;
    case MTLVertexFormatInt: return PIPE_FORMAT_R32_SINT;
    case MTLVertexFormatInt2: return PIPE_FORMAT_R32G32_SINT;
    case MTLVertexFormatInt3: return PIPE_FORMAT_R32G32B32_SINT;
    case MTLVertexFormatInt4: return PIPE_FORMAT_R32G32B32A32_SINT;
    case MTLVertexFormatUInt: return PIPE_FORMAT_R32_UINT;
    case MTLVertexFormatUInt2: return PIPE_FORMAT_R32G32_UINT;
    case MTLVertexFormatUInt3: return PIPE_FORMAT_R32G32B32_UINT;
    case MTLVertexFormatUInt4: return PIPE_FORMAT_R32G32B32A32_UINT;
    case MTLVertexFormatInt1010102Normalized: return PIPE_FORMAT_R10G10B10A2_SNORM;
    case MTLVertexFormatUInt1010102Normalized: return PIPE_FORMAT_R10G10B10A2_UNORM;
    case MTLVertexFormatUChar4Normalized_BGRA: return PIPE_FORMAT_B8G8R8A8_UNORM;
    case MTLVertexFormatUChar: return PIPE_FORMAT_R8_UINT;
    case MTLVertexFormatChar: return PIPE_FORMAT_R8_SINT;
    case MTLVertexFormatUCharNormalized: return PIPE_FORMAT_R8_UNORM;
    case MTLVertexFormatCharNormalized: return PIPE_FORMAT_R8_SNORM;
    case MTLVertexFormatUShort: return PIPE_FORMAT_R16_UINT;
    case MTLVertexFormatShort: return PIPE_FORMAT_R16_SINT;
    case MTLVertexFormatUShortNormalized: return PIPE_FORMAT_R16_UNORM;
    case MTLVertexFormatShortNormalized: return PIPE_FORMAT_R16_SNORM;
    case MTLVertexFormatHalf: return PIPE_FORMAT_R16_FLOAT;
    default: return PIPE_FORMAT_NONE;
    }
}
