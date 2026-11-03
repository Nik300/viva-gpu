// CoreAnimation's own Metal renderer (CARenderer, the engine of iOS's render server in backboardd) on the Viva
// driver: a layer tree typical of iOS UI is composed on our device (llvmpipe or Panfrost-on-mock) and on the Mac's
// real GPU, and the two frames are compared. PNGs go to /tmp/vmg-ca-{viva,ref}.png.
// Usage: ca [frames [OUT.png]]          (phone: writes only our frame, default /tmp/vmg-ca-viva.png)
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <CoreText/CoreText.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <IOSurface/IOSurfaceRef.h>

id<MTLDevice> TSMtlCreateDevice(void);
enum { W = 360, H = 640 };

// CGColorCreateGenericRGB is macOS only.
static CGColorRef rgb(CGFloat r, CGFloat g, CGFloat b, CGFloat a) {
    static CGColorSpaceRef cs;
    if (!cs) cs = CGColorSpaceCreateDeviceRGB();
    const CGFloat c[4] = { r, g, b, a };
    return CGColorCreate(cs, c);
}

static CGImageRef checkerImage(void) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(NULL, 64, 64, 8, 0, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    for (int y = 0; y < 8; y++)
        for (int x = 0; x < 8; x++) {
            CGContextSetRGBFillColor(c, (x + y) & 1 ? 1 : 0.1, 0.4, (x + y) & 1 ? 0.2 : 0.9, 1);
            CGContextFillRect(c, CGRectMake(x * 8, y * 8, 8, 8));
        }
    CGImageRef img = CGBitmapContextCreateImage(c);
    CGContextRelease(c);
    CGColorSpaceRelease(cs);
    return img;
}

static CALayer *scene(void) {
    CALayer *root = [CALayer layer];
    root.frame = CGRectMake(0, 0, W, H);
    root.backgroundColor = rgb(0.95, 0.95, 0.97, 1);

    CALayer *card = [CALayer layer];                 // rounded, bordered, shadowed card
    card.frame = CGRectMake(20, 30, 320, 180);
    card.backgroundColor = rgb(1, 1, 1, 1);
    card.cornerRadius = 18;
    card.borderWidth = 1;
    card.borderColor = rgb(0.8, 0.8, 0.85, 1);
    card.shadowOpacity = 0.35;
    card.shadowRadius = 10;
    card.shadowOffset = CGSizeMake(0, 4);
    [root addSublayer:card];

    CALayer *image = [CALayer layer];                // image contents, clipped by a rounded mask
    image.frame = CGRectMake(16, 16, 120, 120);
    image.contents = (__bridge id)checkerImage();
    image.cornerRadius = 24;
    image.masksToBounds = YES;
    image.magnificationFilter = kCAFilterLinear;
    [card addSublayer:image];

    CATextLayer *text = [CATextLayer layer];         // text (glyph atlas)
    text.frame = CGRectMake(150, 30, 160, 80);
    text.string = @"Viva Metal\nMali-G57";
    text.fontSize = 22;
    text.foregroundColor = rgb(0.1, 0.1, 0.15, 1);
    text.contentsScale = 2;
    [card addSublayer:text];

    CAGradientLayer *grad = [CAGradientLayer layer]; // gradient
    grad.frame = CGRectMake(20, 240, 320, 90);
    grad.colors = @[(__bridge id)rgb(0.2, 0.5, 1, 1), (__bridge id)rgb(1, 0.3, 0.5, 1)];
    grad.startPoint = CGPointMake(0, 0.5);
    grad.endPoint = CGPointMake(1, 0.5);
    grad.cornerRadius = 12;
    [root addSublayer:grad];

    CALayer *tilted = [CALayer layer];               // 3D transform + opacity
    tilted.frame = CGRectMake(60, 360, 240, 120);
    tilted.backgroundColor = rgb(0.2, 0.8, 0.4, 1);
    tilted.opacity = 0.8;
    CATransform3D t = CATransform3DIdentity;
    t.m34 = -1.0 / 500;
    tilted.transform = CATransform3DRotate(t, M_PI / 6, 1, 0.3, 0);
    [root addSublayer:tilted];

    CALayer *blurred = [CALayer layer];              // Gaussian blur filter (CAFilter)
    blurred.frame = CGRectMake(40, 510, 280, 100);
    blurred.contents = (__bridge id)checkerImage();
    Class filter = NSClassFromString(@"CAFilter");
    if (filter) {
        id f = [filter performSelector:@selector(filterWithType:) withObject:@"gaussianBlur"];
        [f setValue:@6 forKey:@"inputRadius"];
        blurred.filters = @[f];
    }
    [root addSublayer:blurred];

    // An IOSurface as layer contents in luminance+alpha ('LA08', 2 bytes per pixel, rows of 480 bytes: not 64-aligned),
    // as backboardd receives some of SpringBoard's layers. VMG_CA_SIMPLE=1 leaves it out.
    if (!getenv("VMG_CA_SIMPLE")) {
        NSDictionary *props = @{ (id)kIOSurfaceWidth: @230, (id)kIOSurfaceHeight: @186, (id)kIOSurfaceBytesPerElement: @2,
                                 (id)kIOSurfaceBytesPerRow: @480, (id)kIOSurfacePixelFormat: @((uint32_t)'LA08') };
        IOSurfaceRef la = IOSurfaceCreate((__bridge CFDictionaryRef)props);
        if (la) {
            IOSurfaceLock(la, 0, NULL);
            uint8_t *m = IOSurfaceGetBaseAddress(la);
            for (int y = 0; y < 186; y++)
                for (int x = 0; x < 230; x++) { m[y * 480 + x * 2] = (uint8_t)(x + y); m[y * 480 + x * 2 + 1] = 200; }
            IOSurfaceUnlock(la, 0, NULL);
            CALayer *l = [CALayer layer];
            l.frame = CGRectMake(250, 380, 100, 80);
            l.contents = (__bridge id)la;
            [root addSublayer:l];
        }
    }

    // SpringBoard's materials (dock, folders, control center): a backdrop layer blurring what is behind it, with a
    // saturation colour matrix and vibrancy on top. VMG_CA_SIMPLE=1 leaves them out.
    Class backdrop = NSClassFromString(@"CABackdropLayer");
    if (backdrop && filter && !getenv("VMG_CA_SIMPLE")) {
        CALayer *bd = [backdrop layer];
        bd.frame = CGRectMake(30, 200, 300, 160);
        bd.cornerRadius = 24;
        bd.masksToBounds = YES;
        id blur = [filter performSelector:@selector(filterWithType:) withObject:@"gaussianBlur"];
        [blur setValue:@20 forKey:@"inputRadius"];
        id sat = [filter performSelector:@selector(filterWithType:) withObject:@"colorSaturate"];
        [sat setValue:@1.8 forKey:@"inputAmount"];
        bd.filters = @[blur, sat];
        [root addSublayer:bd];
        CALayer *tint = [CALayer layer];
        tint.frame = bd.bounds;
        tint.backgroundColor = rgb(1, 1, 1, 0.3);
        [bd addSublayer:tint];
        CATextLayer *vibrant = [CATextLayer layer];
        vibrant.frame = CGRectMake(20, 60, 260, 40);
        vibrant.string = @"Vibrancy";
        vibrant.fontSize = 28;
        vibrant.contentsScale = 2;
        vibrant.foregroundColor = rgb(0, 0, 0, 1);
        id vib = [filter performSelector:@selector(filterWithType:) withObject:@"vibrantDark"];
        if (vib) vibrant.compositingFilter = vib;
        [bd addSublayer:vibrant];
    }
    return root;
}


// VMG_CA_SETTINGS=1: the Settings app (inset grouped table): sections with only their top or bottom corners rounded
// (maskedCorners, continuous curve), switches (pill + shadowed knob), a navigation bar backdrop over the content.
static CALayer *settingsScene(void) {
    CALayer *root = [CALayer layer];
    root.frame = CGRectMake(0, 0, W, H);
    root.backgroundColor = rgb(0.949, 0.949, 0.969, 1);
    Class filter = NSClassFromString(@"CAFilter");
    for (int s = 0; s < 3; s++) {
        CGFloat y0 = 100 + s * 170;
        for (int r = 0; r < 3; r++) {
            CALayer *cell = [CALayer layer];
            cell.frame = CGRectMake(16, y0 + r * 44, W - 32, 44);
            cell.backgroundColor = rgb(1, 1, 1, 1);
            cell.cornerRadius = 10;
            if (@available(iOS 13.0, macOS 10.15, *)) cell.cornerCurve = kCACornerCurveContinuous;
            cell.maskedCorners = r == 0 ? (kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner)
                               : r == 2 ? (kCALayerMinXMaxYCorner | kCALayerMaxXMaxYCorner) : 0;
            cell.masksToBounds = s == 1;    // section 1 clips (subviews), the others only round the background
            [root addSublayer:cell];
            CALayer *icon = [CALayer layer];
            icon.frame = CGRectMake(12, 8, 28, 28);
            icon.backgroundColor = rgb(0.2 + 0.3 * r, 0.4, 0.9 - 0.3 * s, 1);
            icon.cornerRadius = 7;
            if (@available(iOS 13.0, macOS 10.15, *)) icon.cornerCurve = kCACornerCurveContinuous;
            [cell addSublayer:icon];
            CALayer *pill = [CALayer layer];                 // UISwitch: track
            pill.frame = CGRectMake(W - 32 - 16 - 51, 6.5, 51, 31);
            pill.backgroundColor = (r & 1) ? rgb(0.2, 0.78, 0.35, 1) : rgb(0.47, 0.47, 0.5, 0.16);
            pill.cornerRadius = 15.5;
            [cell addSublayer:pill];
            CALayer *knob = [CALayer layer];                 // knob with a shadow
            knob.frame = CGRectMake((r & 1) ? 22 : 2, 2, 27, 27);
            knob.backgroundColor = rgb(1, 1, 1, 1);
            knob.cornerRadius = 13.5;
            knob.shadowOpacity = 0.25;
            knob.shadowRadius = 4;
            knob.shadowOffset = CGSizeMake(0, 3);
            [pill addSublayer:knob];
            if (r < 2) {
                CALayer *sep = [CALayer layer];
                sep.frame = CGRectMake(52, 43.5, W - 32 - 52, 0.5);
                sep.backgroundColor = rgb(0.24, 0.24, 0.26, 0.29);
                [cell addSublayer:sep];
            }
        }
    }
    Class backdrop = NSClassFromString(@"CABackdropLayer");
    if (backdrop && filter) {                                // navigation bar material
        CALayer *bd = [backdrop layer];
        bd.frame = CGRectMake(0, 0, W, 90);
        id blur = [filter performSelector:@selector(filterWithType:) withObject:@"gaussianBlur"];
        [blur setValue:@20 forKey:@"inputRadius"];
        bd.filters = @[blur];
        [root addSublayer:bd];
        CALayer *tint = [CALayer layer];
        tint.frame = bd.bounds;
        tint.backgroundColor = rgb(0.97, 0.97, 0.97, 0.8);
        [bd addSublayer:tint];
    }
    return root;
}

static NSData *render(id<MTLDevice> dev, int frames, NSString *png) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeShared;
    id<MTLTexture> tex;
    if (getenv("VMG_CA_IOSURFACE")) {   // like backboardd: render straight into an IOSurface (the framebuffer)
        NSDictionary *props = @{ (id)kIOSurfaceWidth: @(W), (id)kIOSurfaceHeight: @(H), (id)kIOSurfaceBytesPerElement: @4,
                                 (id)kIOSurfacePixelFormat: @((uint32_t)'BGRA') };
        IOSurfaceRef surf = IOSurfaceCreate((__bridge CFDictionaryRef)props);
        tex = [dev newTextureWithDescriptor:td iosurface:surf plane:0];
        CFRelease(surf);
    } else
        tex = [dev newTextureWithDescriptor:td];
    id<MTLCommandQueue> q = [dev newCommandQueue];
    CARenderer *rr = [CARenderer rendererWithMTLTexture:tex options:@{ kCARendererMetalCommandQueue: q }];
    rr.layer = getenv("VMG_CA_SETTINGS") ? settingsScene() : scene();
    rr.bounds = CGRectMake(0, 0, W, H);
    [CATransaction flush];
    for (int f = 0; f < frames; f++) {
        [rr beginFrameAtTime:CACurrentMediaTime() timeStamp:NULL];
        [rr addUpdateRect:rr.bounds];
        [rr render];
        [rr endFrame];
    }
    id<MTLCommandBuffer> cb = [q commandBuffer];   // wait for CARenderer's command buffers
    [cb commit];
    [cb waitUntilCompleted];
    NSMutableData *px = [NSMutableData dataWithLength:W * H * 4];
    [tex getBytes:px.mutableBytes bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef c = CGBitmapContextCreate(px.mutableBytes, W, H, 8, W * 4, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGImageRef img = CGBitmapContextCreateImage(c);
    CGImageDestinationRef d = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:png],
                                                              (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    CGImageDestinationAddImage(d, img, NULL);
    CGImageDestinationFinalize(d);
    CFRelease(d); CGImageRelease(img); CGContextRelease(c); CGColorSpaceRelease(cs);
    return px;
}

int main(int argc, char **argv) { @autoreleasepool {
    int frames = argc > 1 ? atoi(argv[1]) : 2;
    id<MTLDevice> viva = TSMtlCreateDevice(), ref = MTLCreateSystemDefaultDevice();
#if TARGET_OS_IPHONE
    ref = nil;   // on the phone the system device is ours: only our frame, to look at
#endif
    printf("viva: %s / reference: %s\n", viva.name.UTF8String, ref.name.UTF8String);
    NSData *a = render(viva, frames, argc > 2 ? [NSString stringWithUTF8String:argv[2]] : @"/tmp/vmg-ca-viva.png");
    NSData *b = ref ? render(ref, frames, @"/tmp/vmg-ca-ref.png") : nil;
    if (!b) { printf("no reference device\n"); return 0; }
    const uint8_t *pa = a.bytes, *pb = b.bytes;
    size_t off = 0, big = 0, blank = 0;
    for (size_t i = 0; i < (size_t)W * H; i++) {
        int d = 0;
        for (int k = 0; k < 4; k++) d = MAX(d, abs(pa[i * 4 + k] - pb[i * 4 + k]));
        if (d > 8) off++;
        if (d > 64) big++;
        if (!pa[i * 4 + 3]) blank++;
    }
    printf("pixels differing by >8: %.2f%%, by >64: %.2f%%, transparent in viva: %.2f%%\n",
           100.0 * off / (W * H), 100.0 * big / (W * H), 100.0 * blank / (W * H));
    return 0;
} }
