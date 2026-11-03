// Phase 2 window test: a real NSWindow with a CAMetalLayer driven by the shim device.
// Animates the clear color and a spinning triangle (shaders translated from AIR by the shim),
// then saves the last frame as PNG
// and exits. Usage: window [seconds] [png path]
#import <Cocoa/Cocoa.h>
#import <QuartzCore/CAMetalLayer.h>
#import "TSMetal.h"

static NSString *const kMSL = @
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct VIn { float2 pos [[attribute(0)]]; float4 color [[attribute(1)]]; };\n"
    "struct VOut { float4 pos [[position]]; float4 color; };\n"
    "vertex VOut vs_spin(VIn in [[stage_in]], constant float &angle [[buffer(1)]]) {\n"
    "  float c = cos(angle), s = sin(angle); VOut o;\n"
    "  o.pos = float4(c * in.pos.x - s * in.pos.y, s * in.pos.x + c * in.pos.y, 0.5, 1); o.color = in.color; return o; }\n"
    "fragment float4 fs_spin(VOut in [[stage_in]]) { return in.color; }\n";

@interface Renderer : NSObject
@property (strong) CAMetalLayer *layer;
@property (strong) id<MTLDevice> device;
@property (strong) id<MTLCommandQueue> queue;
@property (strong) id<MTLRenderPipelineState> pipeline;
@property (strong) id<MTLBuffer> vertices;
@property int frames;
@property double drawableWait;
@property CFTimeInterval startTime;
@property (strong) NSString *pngPath;
@property (strong) NSWindow *window;
@end

@implementation Renderer
- (void)frame:(NSTimer *)timer {
    @autoreleasepool {
        CFTimeInterval waitStart = CACurrentMediaTime();
        id<CAMetalDrawable> drawable = [self.layer nextDrawable];
        self.drawableWait += CACurrentMediaTime() - waitStart;
        if (!drawable) return;
        if (getenv("USECOUNT") && self.frames % 20 == 0) {
            IOSurfaceRef s = drawable.texture.iosurface;
            printf("frame %d: drawable surface %u use count %d in use %d\n", self.frames, IOSurfaceGetID(s), IOSurfaceGetUseCount(s), IOSurfaceIsInUse(s));
        }
        float t = self.frames / 60.0f;
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = drawable.texture;
        rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.15 + 0.1 * sin(t), 0.3, 1);
        id<MTLCommandBuffer> cb = [self.queue commandBuffer];
        id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
        [e setRenderPipelineState:self.pipeline];
        [e setVertexBuffer:self.vertices offset:0 atIndex:0];
        [e setVertexBytes:&t length:sizeof t atIndex:1];
        [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [e endEncoding];
        BOOL transaction = getenv("TRANSACTION") != NULL;   // VectorKit style: waitUntilScheduled + present in the CA transaction
        if (!transaction) [cb presentDrawable:drawable];
        if (getenv("TIMELINE")) {
            CFTimeInterval c = CACurrentMediaTime();
            int f = self.frames;
            [cb addScheduledHandler:^(id<MTLCommandBuffer> b) {
                if (f % 15 == 0) printf("frame %d: scheduled %.2f ms after commit\n", f, 1000 * (CACurrentMediaTime() - c));
            }];
            [drawable addPresentedHandler:^(id<MTLDrawable> d) {
                if (f % 15 == 0) printf("frame %d: presented %.2f ms after commit (presentedTime %.2f)\n", f, 1000 * (CACurrentMediaTime() - c),
                                        d.presentedTime ? 1000 * (d.presentedTime - c) : -1.0);
            }];
        }
        [cb commit];
        if (transaction) { [cb waitUntilScheduled]; [drawable present]; }
        self.frames++;
    }
}

- (void)finish {
    // Render the last frame once more into an offscreen texture and save it.
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                 width:(NSUInteger)self.layer.drawableSize.width
                                                                                height:(NSUInteger)self.layer.drawableSize.height mipmapped:NO];
    d.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> snapshot = [self.device newTextureWithDescriptor:d];
    float t = (self.frames - 1) / 60.0f;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = snapshot;
    rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.15 + 0.1 * sin(t), 0.3, 1);
    id<MTLCommandBuffer> cb = [self.queue commandBuffer];
    id<MTLRenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:rp];
    [e setRenderPipelineState:self.pipeline];
    [e setVertexBuffer:self.vertices offset:0 atIndex:0];
    [e setVertexBytes:&t length:sizeof t atIndex:1];
    [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [e endEncoding];
    [cb commit];
    [cb waitUntilCompleted];

    NSUInteger w = snapshot.width, h = snapshot.height;
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h bitsPerSample:8
                                                               samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
                                                                  bitmapFormat:NSBitmapFormatThirtyTwoBitLittleEndian bytesPerRow:w * 4 bitsPerPixel:32];
    [snapshot getBytes:rep.bitmapData bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
    // BGRA little endian -> bitmap rep expects ARGB little endian word order = BGRA bytes. Convert to RGBA for PNG.
    uint8_t *px = rep.bitmapData;
    for (NSUInteger i = 0; i < w * h; i++) { uint8_t b = px[i * 4]; px[i * 4] = px[i * 4 + 2]; px[i * 4 + 2] = b; }
    NSBitmapImageRep *rgba = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:&px pixelsWide:w pixelsHigh:h bitsPerSample:8
                                                                samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
                                                                    bytesPerRow:w * 4 bitsPerPixel:32];
    [[rgba representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:self.pngPath atomically:YES];
    double elapsed = CACurrentMediaTime() - self.startTime;
    printf("%.1f fps over %.1f s, %.1f ms/frame waiting in nextDrawable\n", self.frames / elapsed, elapsed, 1000 * self.drawableWait / MAX(self.frames, 1));
    printf("frames presented: %d, snapshot %lux%lu -> %s\n", self.frames, (unsigned long)w, (unsigned long)h, self.pngPath.UTF8String);
    fflush(stdout);
    [NSApp terminate:nil];
}
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        double seconds = argc > 1 ? atof(argv[1]) : 4;
        NSString *png = argc > 2 ? @(argv[2]) : @"window.png";
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];

        Renderer *r = [Renderer new];
        r.pngPath = png;
        r.device = TSMtlCreateDevice();
        r.queue = [r.device newCommandQueue];
        NSError *err = nil;
        id<MTLLibrary> lib = [r.device newLibraryWithSource:kMSL options:nil error:&err];
        MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
        pd.vertexFunction = [lib newFunctionWithName:@"vs_spin"];
        pd.fragmentFunction = [lib newFunctionWithName:@"fs_spin"];
        MTLVertexDescriptor *vd = [MTLVertexDescriptor new];
        vd.attributes[0].format = MTLVertexFormatFloat2;
        vd.attributes[1].format = MTLVertexFormatFloat4;
        vd.attributes[1].offset = 8;
        vd.layouts[0].stride = 24;
        pd.vertexDescriptor = vd;
        pd.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        r.pipeline = [r.device newRenderPipelineStateWithDescriptor:pd error:&err];
        static const float tri[] = { 0, 0.8f, 1, 0, 0, 1,   -0.7f, -0.6f, 0, 1, 0, 1,   0.7f, -0.6f, 0, 0, 1, 1 };
        r.vertices = [r.device newBufferWithBytes:tri length:sizeof tri options:0];

        // WINDOW_SIZE=WxH and FAST=1 (timer at 240 Hz) measure the present rate the shim can sustain.
        int ww = 480, wh = 360;
        if (getenv("WINDOW_SIZE")) sscanf(getenv("WINDOW_SIZE"), "%dx%d", &ww, &wh);
        NSWindow *w = [[NSWindow alloc] initWithContentRect:NSMakeRect(200, 200, ww, wh)
                                                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable
                                                    backing:NSBackingStoreBuffered defer:NO];
        w.title = @"TeraScale Metal Shim";
        r.window = w;
        NSView *v = w.contentView;
        v.wantsLayer = YES;
        r.layer = [CAMetalLayer layer];
        r.layer.device = r.device;
        r.layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        r.layer.framebufferOnly = NO;
        if (getenv("NOSYNC")) r.layer.displaySyncEnabled = NO;
        if (getenv("DRAWABLES")) r.layer.maximumDrawableCount = atoi(getenv("DRAWABLES"));
        if (getenv("TRANSACTION")) r.layer.presentsWithTransaction = YES;
        r.layer.frame = v.bounds;
        r.layer.contentsScale = w.backingScaleFactor;
        r.layer.drawableSize = CGSizeMake(v.bounds.size.width * w.backingScaleFactor, v.bounds.size.height * w.backingScaleFactor);
        [v.layer addSublayer:r.layer];
        [w makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
        printf("window id %ld\n", (long)w.windowNumber);
        fflush(stdout);

        r.startTime = CACurrentMediaTime();
        [NSTimer scheduledTimerWithTimeInterval:getenv("FAST") ? 1.0 / 240 : 1.0 / 60 target:r selector:@selector(frame:) userInfo:nil repeats:YES];
        [r performSelector:@selector(finish) withObject:nil afterDelay:seconds];
        [NSApp run];
    }
    return 0;
}
