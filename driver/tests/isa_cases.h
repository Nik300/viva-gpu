// Test cases for the AIR -> Valhall ISA compiler (docs/ANALISI-ISA-DIRETTA-2026-11-04.md §2.1, IDs of §4): one or
// more per feature, each a minimal Metal pipeline whose shader uses only that feature plus trivial plumbing (a
// full-screen triangle, a grid of points or a compute grid), with a CPU reference of the same formula. Shared by the
// CLI (isatest.m) and Viva Manager (app/Sources/VMIsa.m).
//
// Run modes: 0 = ISA path (VMG_ISA=1 VMG_ISA_STRICT=1 VMG_ISA_ONLY=<case features>: pipeline creation fails instead of
// falling back, so a passing case really ran ISA code), 1 = NIR path (VMG_ISA=0). The environment is set before the
// library and pipelines are created and restored after the run.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdbool.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

typedef enum { ISA_FRAG, ISA_VERT, ISA_COMPUTE } isa_kind;

// Output, compared as doubles (RGBA per pixel / element):
//   render: RGBA8 or RGBA32F colour attachment 0;
//   compute: buffer(0) of float4 / uint4 / int4 per element, or texture(0) RGBA32Float (ISA_OUT_TEX).
typedef enum { ISA_OUT_RGBA8, ISA_OUT_RGBA32F, ISA_OUT_F32, ISA_OUT_U32, ISA_OUT_I32, ISA_OUT_TEX } isa_out;

// Resources of one run. Buffers, textures and samplers are bound at their index on every stage (vertex and fragment,
// or the kernel); compute outputs take buffer(0) / texture(0).
@interface ISAInputs : NSObject
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, id<MTLBuffer>> *buffers;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, id<MTLTexture>> *textures;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, id<MTLSamplerState>> *samplers;
@property (nonatomic, strong, nullable) id<MTLTexture> depth;     // render: depth attachment (pass hook)
@property (nonatomic, strong, nullable) id<MTLLibrary> library;
@property (nonatomic, strong, nullable) id<MTLRenderPipelineState> pipeline;   // render: the case's pipeline
@property (nonatomic, strong, nullable) id extra;                 // case-specific (tile pipeline, function table)
@end

typedef struct isa_case isa_case;
struct isa_case {
    const char *id;          // feature ID of §4 ("D3"); several cases can share one
    const char *title;       // short Italian title
    isa_kind kind;
    isa_out out;
    int w, h;                // output size (pixels / elements)
    const char *msl;         // source after "#include <metal_stdlib> using namespace metal;"
    const char *_Nullable vs, *_Nullable fs;     // render functions (NULL: "vs" and "fs", "fp" for ISA_VERT)
    const char *_Nullable prep_fs;     // render: optional plumbing draw before the case's draws (framebuffer fetch input)
    const char *_Nullable kernel;      // compute function (NULL: "k")
    int gw, gh, tw, th;      // compute: grid in threads (0: w x h), threadgroup (0: 8 x 8)
    bool groups;             // compute: dispatchThreadgroups(gw/tw, gh/th) instead of dispatchThreads
    double tol, rel;         // a channel is bad when |gpu - ref| > tol + rel * |ref| (tol 0: 1.5/255 RGBA8, 1e-5
                             // float, exact integers)
    double max_bad_pct;      // allowed % of bad pixels
    float clear[4];          // render: clear colour
    const char *_Nullable feats;       // features used besides the ID and the plumbing (added to VMG_ISA_ONLY)
    double vis_lo, vis_hi;   // display range of float outputs (0, 0: 0..1)
    const char *_Nullable mac_note;    // why it fails on the Mac (llvmpipe, NIR path): known, not counted by isatest
    bool skip_llvmpipe;                // crashes the driver on llvmpipe: isatest skips it there (mac_note says why)

    void (*_Nullable setup)(ISAInputs *in);                                       // input resources
    void (*_Nullable pipe)(MTLRenderPipelineDescriptor *d);                       // render pipeline tweaks
    void (*_Nullable pass)(MTLRenderPassDescriptor *p, ISAInputs *in);            // render pass tweaks (depth...)
    void (*_Nullable draw)(id<MTLRenderCommandEncoder> e, ISAInputs *in, const isa_case *c, int n);   // n draws (NULL: full-
                                                                        // screen triangle / w*h points)
    id _Nullable (*_Nullable extra)(ISAInputs *in, NSError **err);              // more pipeline objects, in the same env
    id<MTLComputePipelineState> _Nullable (*_Nullable cpipe)(ISAInputs *in, id<MTLFunction> fn, NSError **err);
    void (*_Nullable cbind)(id<MTLComputeCommandEncoder> e, ISAInputs *in);       // more compute bindings
    // Expected RGBA per pixel (w*h*4). gpu is the GPU output (NULL for the CPU panel): subgroup cases read the
    // reported SIMD width from it. NaN = don't care.
    void (*ref)(const isa_case *c, const double *_Nullable gpu, double *out);
};

typedef struct {
    double max_err;          // largest |gpu - ref| over the checked channels
    double pct_bad;          // % of pixels with a channel out of tolerance
    bool ok;
    double gpu_ms;           // per draw / dispatch (mean of ISA_TIMING_RUNS in one command buffer)
    char note[256];          // error or remark
} isa_result;

enum { ISA_MODE_ISA = 0, ISA_MODE_NIR = 1, ISA_TIMING_RUNS = 20 };

extern const isa_case isa_cases[];
extern const int isa_case_count;

// rgba_out: w*h*4 bytes for the panel (may be NULL); diff_out: w*h, per pixel max over the channels of
// error / tolerance (> 1 = bad, -1 = not checked), may be NULL.
isa_result isa_run_case(id<MTLDevice> dev, const isa_case *c, int mode, uint8_t *_Nullable rgba_out,
                        float *_Nullable diff_out);
// The CPU reference as an image (w*h*4 bytes), as the panel shows it.
void isa_cpu_reference(const isa_case *c, uint8_t *rgba_out);
// The VMG_ISA_ONLY list used in ISA mode (NULL for the infrastructure cases A*, which leave it unset).
const char *_Nullable isa_case_only(const isa_case *c, char *buf, size_t size);

NS_ASSUME_NONNULL_END
