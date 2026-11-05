// mpstest: MetalPerformanceShaders / MPSGraph on the installed Metal driver (analysis of the accelerators, item D).
// CoreImage, Vision, Photos and CoreML use these frameworks; whether they work on our device decides how much GPU work
// those frameworks can do instead of falling back to the CPU. Each case runs on the GPU and is compared with a CPU
// reference (max abs error on 0..1 values or relative error for matrices); prints ok/KO and the GPU time.
// Usage: mpstest [case...]   (cases: support blur sobel lanczos convert matmul graph)
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import <MetalPerformanceShadersGraph/MetalPerformanceShadersGraph.h>
#include <math.h>
#include <mach/mach_time.h>

static id<MTLDevice> dev;
static id<MTLCommandQueue> queue;
static int failures;

static double now_ms(void)
{
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return (double)mach_absolute_time() * tb.numer / tb.denom / 1e6;
}

static void report(const char *name, bool ok, double err, double ms, const char *note)
{
    printf("%-10s %s  err %-10.4g %8.3f ms  %s\n", name, ok ? "ok" : "KO", err, ms, note ? note : "");
    if (!ok) failures++;
    fflush(stdout);
}

static id<MTLTexture> texture(unsigned w, unsigned h, MTLPixelFormat f, const void *data, unsigned bpr)
{
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:f width:w height:h mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
    d.storageMode = MTLStorageModeShared;
    id<MTLTexture> t = [dev newTextureWithDescriptor:d];
    if (data) [t replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:data bytesPerRow:bpr];
    return t;
}

// Test image: smooth gradients plus a hard edge and a few dots (blur and edge filters have something to do).
static void make_image(float *rgba, unsigned w, unsigned h)
{
    for (unsigned y = 0; y < h; y++) for (unsigned x = 0; x < w; x++) {
        float *p = rgba + 4 * (y * w + x);
        p[0] = (float)x / (w - 1);
        p[1] = (float)y / (h - 1);
        p[2] = (x > w / 2) ? 0.8f : 0.2f;
        p[3] = ((x / 16 + y / 16) % 2) ? 1.0f : 0.5f;
        if ((x % 37) == 5 && (y % 41) == 7) p[0] = p[1] = p[2] = 1.0f;
    }
}

static double run(void (^encode)(id<MTLCommandBuffer>))
{
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    encode(cb);
    double t0 = now_ms();
    [cb commit];
    [cb waitUntilCompleted];
    double t = now_ms() - t0;
    if (cb.error) printf("  command buffer error: %s\n", cb.error.localizedDescription.UTF8String);
    return t;
}

static void read_f32(id<MTLTexture> t, float *out)
{
    [t getBytes:out bytesPerRow:t.width * 16 fromRegion:MTLRegionMake2D(0, 0, t.width, t.height) mipmapLevel:0];
}

static void case_support(void)
{
    BOOL s = MPSSupportsMTLDevice(dev);
    report("support", s, 0, 0, s ? "MPSSupportsMTLDevice = YES" : "MPSSupportsMTLDevice = NO (MPS refuses the device)");
}

static void case_blur(void)
{
    const unsigned W = 256, H = 256;
    float *img = malloc(W * H * 16), *gpu = malloc(W * H * 16), *ref = calloc(W * H, 16);
    make_image(img, W, H);
    id<MTLTexture> src = texture(W, H, MTLPixelFormatRGBA32Float, img, W * 16), dst = texture(W, H, MTLPixelFormatRGBA32Float, NULL, 0);
    const float sigma = 3.0f;
    MPSImageGaussianBlur *k = [[MPSImageGaussianBlur alloc] initWithDevice:dev sigma:sigma];
    k.edgeMode = MPSImageEdgeModeClamp;
    double ms = run(^(id<MTLCommandBuffer> cb) { [k encodeToCommandBuffer:cb sourceTexture:src destinationTexture:dst]; });
    read_f32(dst, gpu);
    // reference: separable Gaussian, clamp to edge (MPS uses a kernel of radius ~3 sigma)
    int r = (int)ceilf(3 * sigma);
    float wsum = 0, wk[64];
    for (int i = -r; i <= r; i++) { wk[i + r] = expf(-(float)(i * i) / (2 * sigma * sigma)); wsum += wk[i + r]; }
    float *tmp = calloc(W * H, 16);
    for (unsigned y = 0; y < H; y++) for (unsigned x = 0; x < W; x++) for (int c = 0; c < 4; c++) {
        float a = 0;
        for (int i = -r; i <= r; i++) { int xx = (int)x + i; xx = xx < 0 ? 0 : xx >= (int)W ? W - 1 : xx; a += wk[i + r] * img[4 * (y * W + xx) + c]; }
        tmp[4 * (y * W + x) + c] = a / wsum;
    }
    for (unsigned y = 0; y < H; y++) for (unsigned x = 0; x < W; x++) for (int c = 0; c < 4; c++) {
        float a = 0;
        for (int i = -r; i <= r; i++) { int yy = (int)y + i; yy = yy < 0 ? 0 : yy >= (int)H ? H - 1 : yy; a += wk[i + r] * tmp[4 * (yy * W + x) + c]; }
        ref[4 * (y * W + x) + c] = a / wsum;
    }
    double err = 0;
    for (unsigned i = 0; i < W * H * 4; i++) err = fmax(err, fabs(gpu[i] - ref[i]));
    report("blur", err < 0.02, err, ms, "MPSImageGaussianBlur sigma 3, RGBA32F 256x256");
    free(img); free(gpu); free(ref); free(tmp);
}

static void case_sobel(void)
{
    const unsigned W = 128, H = 128;
    float *img = malloc(W * H * 16), *gpu = malloc(W * H * 16);
    make_image(img, W, H);
    id<MTLTexture> src = texture(W, H, MTLPixelFormatRGBA32Float, img, W * 16), dst = texture(W, H, MTLPixelFormatRGBA32Float, NULL, 0);
    MPSImageSobel *k = [[MPSImageSobel alloc] initWithDevice:dev];
    double ms = run(^(id<MTLCommandBuffer> cb) { [k encodeToCommandBuffer:cb sourceTexture:src destinationTexture:dst]; });
    read_f32(dst, gpu);
    // reference: |G| of the 3x3 Sobel per colour channel (with an RGBA destination MPS filters each channel), interior
    double err = 0;
    for (unsigned y = 1; y + 1 < H; y++) for (unsigned x = 1; x + 1 < W; x++) for (int c = 0; c < 3; c++) {
        float L[3][3];
        for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) L[j + 1][i + 1] = img[4 * ((y + j) * W + x + i) + c];
        float gx = (L[0][2] + 2 * L[1][2] + L[2][2]) - (L[0][0] + 2 * L[1][0] + L[2][0]);
        float gy = (L[2][0] + 2 * L[2][1] + L[2][2]) - (L[0][0] + 2 * L[0][1] + L[0][2]);
        float e = fabs(gpu[4 * (y * W + x) + c] - sqrtf(gx * gx + gy * gy));
        if (getenv("MPSTEST_DEBUG") && e > 0.02 && err <= 0.02) printf("  sobel (%u,%u) c%d: gpu %g ref %g\n", x, y, c, gpu[4 * (y * W + x) + c], sqrtf(gx * gx + gy * gy));
        err = fmax(err, e);
    }
    report("sobel", err < 0.02, err, ms, "MPSImageSobel, RGBA32F 128x128 (RGB)");
    free(img); free(gpu);
}

static void case_lanczos(void)
{
    const unsigned W = 256, H = 256, DW = 128, DH = 96;
    float *img = malloc(W * H * 16), *gpu = malloc(DW * DH * 16);
    for (unsigned y = 0; y < H; y++) for (unsigned x = 0; x < W; x++) {
        float *p = img + 4 * (y * W + x);
        p[0] = (float)x / (W - 1); p[1] = (float)y / (H - 1); p[2] = 0.5f; p[3] = 1.0f;
    }
    id<MTLTexture> src = texture(W, H, MTLPixelFormatRGBA32Float, img, W * 16), dst = texture(DW, DH, MTLPixelFormatRGBA32Float, NULL, 0);
    MPSImageLanczosScale *k = [[MPSImageLanczosScale alloc] initWithDevice:dev];
    double ms = run(^(id<MTLCommandBuffer> cb) { [k encodeToCommandBuffer:cb sourceTexture:src destinationTexture:dst]; });
    read_f32(dst, gpu);
    // reference: the gradient channels are linear, so any interpolating filter keeps them (away from the edges)
    double err = 0;
    for (unsigned y = 4; y + 4 < DH; y++) for (unsigned x = 4; x + 4 < DW; x++) {
        float sx = ((x + 0.5f) * W / DW - 0.5f) / (W - 1), sy = ((y + 0.5f) * H / DH - 0.5f) / (H - 1);
        double e = fmax(fabs(gpu[4 * (y * DW + x)] - sx), fabs(gpu[4 * (y * DW + x) + 1] - sy));
        if (getenv("MPSTEST_DEBUG") && e > 0.03 && err <= 0.03) printf("  lanczos (%u,%u): gpu %g %g ref %g %g\n", x, y, gpu[4 * (y * DW + x)], gpu[4 * (y * DW + x) + 1], sx, sy);
        err = fmax(err, e);
    }
    report("lanczos", err < 0.03, err, ms, "MPSImageLanczosScale 256x256 -> 128x96 (linear channels)");
    free(img); free(gpu);
}

static void case_convert(void)
{
    const unsigned W = 64, H = 64;
    uint8_t *img = malloc(W * H * 4), *gpu = malloc(W * H * 4);
    for (unsigned i = 0; i < W * H; i++) { img[4 * i] = i & 255; img[4 * i + 1] = (i >> 6) & 255; img[4 * i + 2] = 255 - (i & 255); img[4 * i + 3] = 255; }
    id<MTLTexture> src = texture(W, H, MTLPixelFormatRGBA8Unorm, img, W * 4), dst = texture(W, H, MTLPixelFormatBGRA8Unorm, NULL, 0);
    MPSImageConversion *k = [[MPSImageConversion alloc] initWithDevice:dev srcAlpha:MPSAlphaTypeAlphaIsOne destAlpha:MPSAlphaTypeAlphaIsOne
                                                       backgroundColor:nil conversionInfo:NULL];
    double ms = run(^(id<MTLCommandBuffer> cb) { [k encodeToCommandBuffer:cb sourceTexture:src destinationTexture:dst]; });
    [dst getBytes:gpu bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
    double err = 0;
    for (unsigned i = 0; i < W * H; i++) {
        err = fmax(err, abs((int)gpu[4 * i + 2] - img[4 * i]));
        err = fmax(err, abs((int)gpu[4 * i + 1] - img[4 * i + 1]));
        err = fmax(err, abs((int)gpu[4 * i] - img[4 * i + 2]));
    }
    report("convert", err <= 1, err, ms, "MPSImageConversion RGBA8 -> BGRA8");
    free(img); free(gpu);
}

static void case_matmul(void)
{
    const unsigned M = 64, N = 48, K = 80;
    id<MTLBuffer> a = [dev newBufferWithLength:M * K * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> b = [dev newBufferWithLength:K * N * 4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> c = [dev newBufferWithLength:M * N * 4 options:MTLResourceStorageModeShared];
    float *A = a.contents, *B = b.contents, *C = c.contents;
    for (unsigned i = 0; i < M * K; i++) A[i] = sinf(i * 0.37f);
    for (unsigned i = 0; i < K * N; i++) B[i] = cosf(i * 0.11f);
    memset(C, 0, M * N * 4);
    MPSMatrixDescriptor *da = [MPSMatrixDescriptor matrixDescriptorWithRows:M columns:K rowBytes:K * 4 dataType:MPSDataTypeFloat32];
    MPSMatrixDescriptor *db = [MPSMatrixDescriptor matrixDescriptorWithRows:K columns:N rowBytes:N * 4 dataType:MPSDataTypeFloat32];
    MPSMatrixDescriptor *dc = [MPSMatrixDescriptor matrixDescriptorWithRows:M columns:N rowBytes:N * 4 dataType:MPSDataTypeFloat32];
    MPSMatrix *ma = [[MPSMatrix alloc] initWithBuffer:a descriptor:da], *mb = [[MPSMatrix alloc] initWithBuffer:b descriptor:db],
              *mc = [[MPSMatrix alloc] initWithBuffer:c descriptor:dc];
    MPSMatrixMultiplication *k = [[MPSMatrixMultiplication alloc] initWithDevice:dev resultRows:M resultColumns:N interiorColumns:K];
    double ms = run(^(id<MTLCommandBuffer> cb) { [k encodeToCommandBuffer:cb leftMatrix:ma rightMatrix:mb resultMatrix:mc]; });
    double err = 0;
    for (unsigned i = 0; i < M; i++) for (unsigned j = 0; j < N; j++) {
        double s = 0;
        for (unsigned q = 0; q < K; q++) s += (double)A[i * K + q] * B[q * N + j];
        err = fmax(err, fabs(C[i * N + j] - s));
    }
    report("matmul", err < 1e-3, err, ms, "MPSMatrixMultiplication 64x80 * 80x48 f32");
}

static void case_graph(void)
{
    if (@available(iOS 14.0, *)) {
        MPSGraph *g = [MPSGraph new];
        MPSGraphTensor *x = [g placeholderWithShape:@[ @4, @8 ] dataType:MPSDataTypeFloat32 name:@"x"];
        MPSGraphTensor *w = [g placeholderWithShape:@[ @8, @3 ] dataType:MPSDataTypeFloat32 name:@"w"];
        MPSGraphTensor *y = [g reLUWithTensor:[g matrixMultiplicationWithPrimaryTensor:x secondaryTensor:w name:nil] name:nil];
        float X[32], Wt[24], ref[12];
        for (int i = 0; i < 32; i++) X[i] = sinf(i * 0.5f);
        for (int i = 0; i < 24; i++) Wt[i] = cosf(i * 0.3f);
        for (int i = 0; i < 4; i++) for (int j = 0; j < 3; j++) {
            float s = 0;
            for (int q = 0; q < 8; q++) s += X[i * 8 + q] * Wt[q * 3 + j];
            ref[i * 3 + j] = s > 0 ? s : 0;
        }
        MPSGraphDevice *gd = [MPSGraphDevice deviceWithMTLDevice:dev];
        MPSGraphTensorData *tx = [[MPSGraphTensorData alloc] initWithDevice:gd data:[NSData dataWithBytes:X length:sizeof X] shape:@[ @4, @8 ] dataType:MPSDataTypeFloat32];
        MPSGraphTensorData *tw = [[MPSGraphTensorData alloc] initWithDevice:gd data:[NSData dataWithBytes:Wt length:sizeof Wt] shape:@[ @8, @3 ] dataType:MPSDataTypeFloat32];
        double t0 = now_ms();
        NSDictionary *res = nil;
        @try {
            res = [g runWithMTLCommandQueue:queue feeds:@{ x : tx, w : tw } targetTensors:@[ y ] targetOperations:nil];
        } @catch (NSException *e) {
            printf("  MPSGraph exception: %s\n", e.reason.UTF8String);
        }
        double ms = now_ms() - t0;
        float out[12] = { 0 };
        if (res[y]) [[res[y] mpsndarray] readBytes:out strideBytes:nil];
        double err = res[y] ? 0 : 1e9;
        for (int i = 0; i < 12 && res[y]; i++) err = fmax(err, fabs(out[i] - ref[i]));
        report("graph", err < 1e-3, err, ms, "MPSGraph matmul 4x8 * 8x3 + relu (first run includes the graph compile)");
    }
}

int main(int argc, char **argv)
{
    @autoreleasepool {
        dev = MTLCreateSystemDefaultDevice();
        if (!dev) { printf("no Metal device\n"); return 1; }
        queue = [dev newCommandQueue];
        printf("mpstest on %s\n", dev.name.UTF8String);
        struct { const char *name; void (*fn)(void); } cases[] = {
            { "support", case_support }, { "blur", case_blur }, { "sobel", case_sobel }, { "lanczos", case_lanczos },
            { "convert", case_convert }, { "matmul", case_matmul }, { "graph", case_graph },
        };
        for (unsigned i = 0; i < sizeof cases / sizeof cases[0]; i++) {
            bool want = argc < 2;
            for (int a = 1; a < argc; a++) if (!strcmp(argv[a], cases[i].name)) want = true;
            if (want) @autoreleasepool { cases[i].fn(); }
        }
        printf("%d failed\n", failures);
        return failures != 0;
    }
}
