// Developer tool: renders AppKit glass materials with CoreAnimation's own Metal renderer (CARenderer) on the
// shim device, in-process, and saves a PNG. This is the renderer WindowServer would use for sidebars and
// Spotlight-style glass on a Metal GPU: it exercises QuartzCore's native glass shaders (glass_background,
// sdf_gen_*, simple_rim, variable_blur, ...) through the AIR -> GLSL translator without touching WindowServer.
// Usage: DYLD_INSERT_LIBRARIES=build/libTSMetalInject.dylib tools/caglass out.png [scene]
//   scenes: all (default), glass, sidebar, clear
//   TSMTL_LOG=1 shows the pipelines and any fallback; TSMTL_TRACE=1 each pipeline once.
//   CAGLASS_WINDOW=<seconds>: show the scene in a real window instead (WindowServer's rendering, for comparison).
//   CAGLASS_SIZE=<w>x<h>, CAGLASS_FRAMES=<n> (default 3): size and number of rendered frames.
//   CAGLASS_OGL=1: CoreAnimation's OpenGL renderer offscreen instead of Metal; from a copy named WindowServer the
//   Moraea SkyLight shim patches it in-process (WindowServer's sidebar material, without touching WindowServer).
#import <Cocoa/Cocoa.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <objc/message.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl.h>
#import <OpenGL/glext.h>


static NSView *background(NSRect r) {
    NSView *v = [[NSView alloc] initWithFrame:r];
    v.wantsLayer = YES;
    CAGradientLayer *g = [CAGradientLayer layer];
    g.frame = v.bounds;
    g.colors = @[(id)NSColor.systemRedColor.CGColor, (id)NSColor.systemBlueColor.CGColor,
                 (id)NSColor.systemGreenColor.CGColor, (id)NSColor.systemYellowColor.CGColor];
    g.startPoint = CGPointMake(0, 0); g.endPoint = CGPointMake(1, 1);
    [v.layer addSublayer:g];
    // Stripes and text give the blur and the refraction something to bend.
    for (int i = 0; i < 12; i++) {
        CALayer *s = [CALayer layer];
        s.frame = CGRectMake(i * 70, 0, 18, r.size.height);
        s.backgroundColor = [NSColor colorWithWhite:i % 2 ? 1 : 0 alpha:0.55].CGColor;
        [v.layer addSublayer:s];
    }
    NSTextField *t = [NSTextField labelWithString:@"TeraScale glass — Liquid Glass test"];
    t.font = [NSFont boldSystemFontOfSize:34];
    t.textColor = NSColor.whiteColor;
    t.frame = NSMakeRect(40, r.size.height / 2 - 20, r.size.width - 80, 44);
    [v addSubview:t];
    return v;
}

static NSView *scene(NSString *name, NSRect r) {
    if ([name isEqualToString:@"split"]) {
        // An app sidebar as in System Settings or Notes: NSSplitViewController with a sidebar item (Tahoe draws it as
        // floating glass over the window's content, the "bleed" glass of Moraea).
        static NSSplitViewController *split;
        split = [NSSplitViewController new];
        NSViewController *side = [NSViewController new], *main = [NSViewController new];
        side.view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, r.size.height)];
        NSTextField *l = [NSTextField labelWithString:@"Sidebar"];
        l.frame = NSMakeRect(20, r.size.height - 80, 180, 24);
        [side.view addSubview:l];
        main.view = getenv("CAGLASS_SPLIT_EMPTY") ? [[NSView alloc] initWithFrame:r] : background(r);   // empty: no content
        if (getenv("CAGLASS_SPLIT_VEV")) {   // a behind-window material of <n> points, so AppKit registers the window's backdrop
            CGFloat n = atof(getenv("CAGLASS_SPLIT_VEV"));
            NSVisualEffectView *v = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, n, n)];
            v.blendingMode = NSVisualEffectBlendingModeBehindWindow;
            v.material = NSVisualEffectMaterialSidebar;
            v.state = NSVisualEffectStateActive;
            [main.view addSubview:v];
        }
        [split addSplitViewItem:[NSSplitViewItem sidebarWithViewController:side]];
        [split addSplitViewItem:[NSSplitViewItem splitViewItemWithViewController:main]];
        split.view.frame = r;
        [split.view layoutSubtreeIfNeeded];
        return split.view;
    }
    NSView *root = background(r);
    if ([name isEqualToString:@"sidebar"] || [name isEqualToString:@"all"]) {
        NSVisualEffectView *side = [[NSVisualEffectView alloc] initWithFrame:NSMakeRect(0, 0, 220, r.size.height)];
        side.material = NSVisualEffectMaterialSidebar;
        side.blendingMode = getenv("CAGLASS_VEV_BEHIND") ? NSVisualEffectBlendingModeBehindWindow : NSVisualEffectBlendingModeWithinWindow;
        side.state = NSVisualEffectStateActive;
        NSTextField *l = [NSTextField labelWithString:@"Sidebar"];
        l.frame = NSMakeRect(20, r.size.height - 60, 180, 24);
        [side addSubview:l];
        [root addSubview:side];
    }
    if ([name isEqualToString:@"glass"] || [name isEqualToString:@"all"] || [name isEqualToString:@"clear"]) {
        Class glassClass = NSClassFromString(@"NSGlassEffectView");
        if (glassClass) {
            NSView *g = [[glassClass alloc] initWithFrame:NSMakeRect(300, 120, 360, 140)];
            if ([g respondsToSelector:@selector(setCornerRadius:)]) [(id)g setCornerRadius:40];
            if ([name isEqualToString:@"clear"] && [g respondsToSelector:@selector(setStyle:)]) ((void (*)(id, SEL, NSInteger))objc_msgSend)(g, @selector(setStyle:), 1);
            NSTextField *l = [NSTextField labelWithString:@"Glass"];
            l.font = [NSFont systemFontOfSize:28];
            l.frame = NSMakeRect(130, 50, 120, 36);
            if ([g respondsToSelector:@selector(setContentView:)]) [(id)g setContentView:l];
            [root addSubview:g];
        } else fprintf(stderr, "NSGlassEffectView not available\n");
    }
    return root;
}

static BOOL writePNG(void *px, size_t W, size_t H, const char *path) {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, W, H, 8, W * 4, cs, kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(path)],
                                                                (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    CGImageDestinationAddImage(dst, img, NULL);
    BOOL ok = CGImageDestinationFinalize(dst);
    CFRelease(dst); CGImageRelease(img); CGContextRelease(ctx); CGColorSpaceRelease(cs);
    return ok;
}

// CAGLASS_OGL=1: CoreAnimation's OpenGL renderer (the one WindowServer uses on this Mac) into an offscreen FBO.
// Run from a copy of this binary named WindowServer and the Moraea SkyLight shim patches the renderer in this
// process too (it checks the program name): WindowServer's glass, reproduced without touching WindowServer.
static int renderOGL(CALayer *top, NSRect r, const char *out, int frames, CALayer *mover) {
    CGLPixelFormatAttribute a[] = { kCGLPFAAccelerated, kCGLPFAColorSize, 24, kCGLPFAAlphaSize, 8, 0 };
    CGLPixelFormatObj pf; GLint npf;
    CGLChoosePixelFormat(a, &pf, &npf);
    CGLContextObj ctx;
    if (!pf || CGLCreateContext(pf, NULL, &ctx)) { fprintf(stderr, "no CGL context\n"); return 1; }
    CGLSetCurrentContext(ctx);
    GLsizei W = (GLsizei)r.size.width, H = (GLsizei)r.size.height;
    GLuint fbo, tex;
    glGenFramebuffersEXT(1, &fbo);
    glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, fbo);
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, W, H, 0, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, NULL);
    glFramebufferTexture2DEXT(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT, GL_TEXTURE_2D, tex, 0);
    glViewport(0, 0, W, H);
    glMatrixMode(GL_PROJECTION);   // CARenderer draws in layer coordinates with the caller's projection
    glLoadIdentity();
    glOrtho(0, W, 0, H, -1, 1);
    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();
    glClearColor(0, 0, 0, 0);
    glClear(GL_COLOR_BUFFER_BIT);
    CARenderer *rr = [CARenderer rendererWithCGLContext:ctx options:nil];
    rr.layer = top;
    rr.bounds = r;
    [CATransaction flush];
    // Same motion as the Metal path: from the 4th frame the stripe slides 7 px per frame under the materials.
    for (int frame = 0; frame < frames; frame++) {
        if (frame >= 3 && mover) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            mover.position = CGPointMake(fmod(mover.position.x + 7, r.size.width), mover.position.y);
            [CATransaction commit];
            [CATransaction flush];
        }
        [rr beginFrameAtTime:CACurrentMediaTime() + frame / 60.0 timeStamp:NULL];
        [rr addUpdateRect:r];
        [rr render];
        [rr endFrame];
    }
    glFinish();
    NSMutableData *px = [NSMutableData dataWithLength:(size_t)W * H * 4];
    glReadPixels(0, 0, W, H, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, px.mutableBytes);
    // The layer tree is geometry-flipped, so GL's bottom-up rows already come out top-down.
    uint8_t *b = px.mutableBytes;
    BOOL ok = writePNG(b, W, H, out);
    printf("%s %s (OpenGL renderer, process %s)\n", ok ? "wrote" : "FAILED", out, getprogname());
    return ok ? 0 : 1;
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 2) { fprintf(stderr, "usage: caglass out.png [all|glass|sidebar|clear|split]\n"); return 2; }
    NSString *name = argc > 2 ? @(argv[2]) : @"all";
    [NSApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    NSRect r = NSMakeRect(0, 0, 840, 420);
    int sw = 0, sh = 0;   // CAGLASS_SIZE=<w>x<h>: render size (GPU cost at screen resolution)
    if (getenv("CAGLASS_SIZE") && sscanf(getenv("CAGLASS_SIZE"), "%dx%d", &sw, &sh) == 2) r.size = NSMakeSize(sw, sh);
    int frames = getenv("CAGLASS_FRAMES") ? atoi(getenv("CAGLASS_FRAMES")) : 3;
    // An offscreen window gives AppKit a real view hierarchy (materials, appearance, glass); its layer tree is
    // then rendered by our CARenderer instead of WindowServer.
    NSWindow *w = [[NSWindow alloc] initWithContentRect:r styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
    NSView *root = scene(name, r);
    w.contentView = root;
    if (getenv("CAGLASS_CLEARWIN")) { w.opaque = NO; w.backgroundColor = NSColor.clearColor; }   // no window background
    if (getenv("CAGLASS_SIDEBAR_BACKDROP")) {   // a drawing copy of the window's capture backdrop under the split sidebar
        [w displayIfNeeded];
        CALayer *top = root.layer, *capture = nil;
        while (top.superlayer) top = top.superlayer;
        for (CALayer *l in top.sublayers) if ([[l valueForKey:@"captureOnly"] respondsToSelector:@selector(boolValue)] && [l.name containsString:@"capture backdrop"]) capture = l;
        NSView *alley = nil;
        NSMutableArray *queue = [NSMutableArray arrayWithObject:root];
        while (queue.count && !alley) {
            NSView *v = queue.firstObject; [queue removeObjectAtIndex:0];
            if ([NSStringFromClass(v.class) isEqualToString:@"NSBlurryAlleywayView"]) alley = v;
            [queue addObjectsFromArray:v.subviews];
        }
        if (atoi(getenv("CAGLASS_SIDEBAR_BACKDROP")) == 2) {   // 2: a real behind-window NSVisualEffectView instead of a bare layer
            NSVisualEffectView *v = [[NSVisualEffectView alloc] initWithFrame:alley.superview.bounds];
            v.blendingMode = NSVisualEffectBlendingModeBehindWindow;
            v.material = NSVisualEffectMaterialUnderWindowBackground;
            v.state = NSVisualEffectStateActive;
            v.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            [alley.superview addSubview:v positioned:NSWindowBelow relativeTo:alley];
            if (getenv("CAGLASS_STRIP")) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{
                // only the backdrop: the material's tint layers hidden (AppKit builds them at the first display)
                for (CALayer *material in v.layer.sublayers)
                    for (CALayer *l in material.sublayers) {
                        if (![l isKindOfClass:NSClassFromString(@"CABackdropLayer")]) l.hidden = YES;
                        else if ((l.filters = [l.filters filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"name != 'colorSaturate'"]]), 1) fprintf(stderr, "kept %s filters %s\n", l.name.UTF8String, [[l.filters valueForKey:@"name"] componentsJoinedByString:@","].UTF8String);
                    }
            });
            fprintf(stderr, "sidebar NSVisualEffectView under %s\n", NSStringFromClass(alley.superview.class).UTF8String);
            capture = nil;
        }
        CALayer *b = capture ? [NSClassFromString(@"CABackdropLayer") layer] : nil;
        for (NSString *k in @[ @"groupName", @"windowServerAware", @"scale" ]) [b setValue:[capture valueForKey:k] forKey:k];
        b.filters = capture.filters;
        b.frame = alley.superview.layer.bounds;
        b.name = @"TeraScale sidebar backdrop";
        [alley.superview.layer insertSublayer:b atIndex:0];
        fprintf(stderr, "sidebar backdrop under %s: %s\n", NSStringFromClass(alley.superview.class).UTF8String, capture ? "copied" : "no capture layer");
    }
    if (getenv("CAGLASS_UNCAPTURE")) {   // CAGLASS_UNCAPTURE=1: the window's behind-window capture backdrop draws itself
        [w displayIfNeeded];
        CALayer *top = root.layer;
        while (top.superlayer) top = top.superlayer;
        for (CALayer *l in top.sublayers)
            if ([l isKindOfClass:NSClassFromString(@"CABackdropLayer")] && [[l valueForKey:@"captureOnly"] boolValue]) {
                // bits: 1 draw, 2 only the gaussian blur filter, 4 no group name, 8 scale 0.25, 16 not windowServerAware
                int bits = atoi(getenv("CAGLASS_UNCAPTURE"));
                if (bits & 1) [l setValue:@NO forKey:@"captureOnly"];
                if (bits & 2) l.filters = [l.filters filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"name == 'gaussianBlur'"]];
                if (bits & 4) [l setValue:nil forKey:@"groupName"];
                if (bits & 8) [l setValue:@0.25 forKey:@"scale"];
                if (bits & 16) [l setValue:@NO forKey:@"windowServerAware"];
                fprintf(stderr, "capture backdrop %s: bits %d, filters %s\n", l.name.UTF8String, bits,
                        [[l.filters valueForKey:@"name"] componentsJoinedByString:@","].UTF8String);
            }
    }
    if (getenv("CAGLASS_LAYERS")) {   // CAGLASS_LAYERS=1: the window's layer tree (class, frame, filters, backdrop keys)
        [w displayIfNeeded];
        [CATransaction flush];
        __block void (^dump)(CALayer *, int);
        dump = ^(CALayer *l, int depth) {
            NSMutableString *extra = [NSMutableString string];
            if (l.filters.count) [extra appendFormat:@" filters=%@", [l.filters valueForKey:@"name"]];
            if (l.backgroundColor) {
                const CGFloat *c = CGColorGetComponents(l.backgroundColor);
                size_t n = CGColorGetNumberOfComponents(l.backgroundColor);
                [extra appendString:@" bg=("];
                for (size_t i = 0; i < n; i++) [extra appendFormat:@"%s%.3g", i ? " " : "", c[i]];
                [extra appendString:@")"];
            }
            if (l.compositingFilter) [extra appendFormat:@" compositing=%@", [l.compositingFilter respondsToSelector:@selector(name)] ? [l.compositingFilter name] : l.compositingFilter];
            if (l.opacity != 1) [extra appendFormat:@" opacity=%.2f", l.opacity];
            if (l.hidden) [extra appendString:@" hidden"];
            if (l.mask) [extra appendFormat:@" mask=%@", NSStringFromClass(l.mask.class)];
            if (l.contents) [extra appendFormat:@" contents=%@", NSStringFromClass([l.contents class])];
            if (l.cornerRadius) [extra appendFormat:@" radius=%.0f", l.cornerRadius];
            if ([l isKindOfClass:NSClassFromString(@"CABackdropLayer")])
                for (NSString *k in @[ @"groupName", @"windowServerAware", @"scale", @"captureOnly", @"enabled", @"marginWidth",
                                       @"statisticsType", @"allowsInPlaceFiltering", @"reducesCaptureBitDepth", @"bleedAmount",
                                       @"tracksLuma", @"usesGlobalGroupNamespace", @"ignoresOffscreenGroups", @"zoom", @"backdropRect" ])
                    @try { [extra appendFormat:@" %@=%@", k, [l valueForKey:k]]; } @catch (id e) {}
            printf("%*s%s %s %.0f,%.0f %.0fx%.0f%s\n", depth * 2, "", NSStringFromClass(l.class).UTF8String, l.name.UTF8String ?: "",
                   l.frame.origin.x, l.frame.origin.y, l.frame.size.width, l.frame.size.height, extra.UTF8String);
            for (CALayer *c in l.sublayers) dump(c, depth + 1);
        };
        CALayer *top = root.layer;
        while (top.superlayer) top = top.superlayer;
        dump(top, 0);
    }
    if (getenv("CAGLASS_WINDOW") && getenv("CAGLASS_BEHIND")) {
        // CAGLASS_BEHIND=1: the materials live in a transparent window above a second window with the (moving)
        // background, so the glass has to sample another window: WindowServer's behind-window backdrop.
        NSWindow *top = [[NSWindow alloc] initWithContentRect:r styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
        top.opaque = NO;
        top.backgroundColor = NSColor.clearColor;
        NSView *holder = [[NSView alloc] initWithFrame:r];
        for (NSView *v in [root.subviews copy]) {
            if ([v isKindOfClass:NSVisualEffectView.class]) ((NSVisualEffectView *)v).blendingMode = NSVisualEffectBlendingModeBehindWindow;
            if ([v isKindOfClass:NSVisualEffectView.class] || [NSStringFromClass(v.class) containsString:@"Glass"]) {
                [v removeFromSuperview];
                [holder addSubview:v];
            }
        }
        top.contentView = holder;
        [w center];
        [top setFrame:w.frame display:NO];
        [w orderFrontRegardless];
        [top orderFrontRegardless];
        NSRect sf = NSScreen.mainScreen.frame, wf = w.frame;   // screencapture -R wants top-left origin points
        printf("window %ld pid %d (glass window above background window %ld) rect %.0f,%.0f,%.0f,%.0f\n", (long)top.windowNumber, getpid(),
               (long)w.windowNumber, wf.origin.x, sf.size.height - wf.origin.y - wf.size.height, wf.size.width, wf.size.height);
        fflush(stdout);
        // Window list capture: both windows below and including the glass one.
        setenv("CAGLASS_TOPWIN", [NSString stringWithFormat:@"%ld", (long)top.windowNumber].UTF8String, 1);
    }
    if (getenv("CAGLASS_WINDOW")) {   // reference: the same scene composited by WindowServer, for N seconds
        if (!getenv("CAGLASS_BEHIND")) {
            [w center];
            [w orderFrontRegardless];
            printf("window %ld pid %d\n", (long)w.windowNumber, getpid());
            fflush(stdout);
        }
        // CAGLASS_MOVE=<px per frame>: a stripe keeps sliding under the materials (does the glass follow it?).
        CALayer *mover = root.layer.sublayers.count > 1 ? root.layer.sublayers[1] : nil;
        // CAGLASS_MOVE_W=<px>: make the moving stripe wider and opaque white (easier to see behind the blur).
        // CAGLASS_JIGGLE=1: also nudge the glass view by a fraction of a point each frame, so its own layer is dirty.
        if (getenv("CAGLASS_MOVE_W") && mover) {
            CGRect f = mover.frame; f.size.width = atof(getenv("CAGLASS_MOVE_W")); mover.frame = f;
            mover.backgroundColor = NSColor.whiteColor.CGColor;
        }
        NSView *glassView = nil;
        for (NSView *v in root.subviews) if ([NSStringFromClass(v.class) containsString:@"Glass"]) glassView = v;
        __block int tick = 0;
        // CAGLASS_MOVEWIN=<px per frame> (with CAGLASS_BEHIND): the whole background window slides back and forth under
        // the glass window, like dragging a window under a translucent one.
        if (getenv("CAGLASS_MOVEWIN")) {
            double step = atof(getenv("CAGLASS_MOVEWIN"));
            NSPoint o = w.frame.origin;
            [NSTimer scheduledTimerWithTimeInterval:1 / 30.0 repeats:YES block:^(NSTimer *t) {
                tick++;
                [w setFrameOrigin:NSMakePoint(o.x + step * ((tick / 30) % 2 ? 30 - tick % 30 : tick % 30), o.y)];
            }];
        }
        // CAGLASS_ANIM=<seconds>: the stripe crosses the window with a CABasicAnimation instead: WindowServer's render
        // server animates it by itself, the app commits nothing per frame (like momentum scrolling and most UI motion).
        if (getenv("CAGLASS_ANIM") && mover) {
            CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"position.x"];
            a.fromValue = @(0); a.toValue = @(r.size.width);
            a.duration = atof(getenv("CAGLASS_ANIM")); a.repeatCount = HUGE_VALF;
            [mover addAnimation:a forKey:@"slide"];
        }
        if (getenv("CAGLASS_MOVE") && mover) {
            double step = atof(getenv("CAGLASS_MOVE"));
            BOOL jiggle = getenv("CAGLASS_JIGGLE") != NULL;
            [NSTimer scheduledTimerWithTimeInterval:1 / 30.0 repeats:YES block:^(NSTimer *t) {
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                mover.position = CGPointMake(fmod(mover.position.x + step, r.size.width), mover.position.y);
                [CATransaction commit];
                if (jiggle && glassView) [glassView setFrameOrigin:NSMakePoint(300 + (++tick % 2) * 0.5, 120)];
            }];
        }
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:atof(getenv("CAGLASS_WINDOW"))]];
        return 0;
    }
    [root layoutSubtreeIfNeeded];
    [root displayIfNeeded];
    [CATransaction flush];

    // The window's content layer belongs to the window's tree: render it through a wrapper root.
    CALayer *top = [CALayer layer];
    top.frame = r;
    top.geometryFlipped = YES;
    CALayer *content = root.layer;
    [content removeFromSuperlayer];
    [top addSublayer:content];
    // CAGLASS_OFFSET=<px>: start with the moving stripe already shifted (the reference for N moving frames is
    // CAGLASS_OFFSET=7*N with the default 3 still frames).
    CALayer *mover = content.sublayers.count > 1 ? content.sublayers[1] : nil;
    if (getenv("CAGLASS_OFFSET") && mover) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        mover.position = CGPointMake(fmod(mover.position.x + atof(getenv("CAGLASS_OFFSET")), r.size.width), mover.position.y);
        [CATransaction commit];
        [CATransaction flush];
    }
    if (getenv("CAGLASS_OGL")) return renderOGL(top, r, argv[1], frames, mover);
    id<MTLDevice> dev = MTLCreateSystemDefaultDevice();   // the shim device: run under build/libTSMetalInject.dylib
    if (![NSStringFromClass([(id)dev class]) hasPrefix:@"TSMtl"]) { fprintf(stderr, "not the shim device: run with DYLD_INSERT_LIBRARIES=build/libTSMetalInject.dylib\n"); return 1; }
    id<MTLCommandQueue> q = [dev newCommandQueue];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                  width:(NSUInteger)r.size.width height:(NSUInteger)r.size.height mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    td.storageMode = MTLStorageModeManaged;
    id<MTLTexture> tex = [dev newTextureWithDescriptor:td];
    CARenderer *rr = [CARenderer rendererWithMTLTexture:tex options:@{ kCARendererMetalCommandQueue: q }];
    rr.layer = top;
    rr.bounds = r;
    [CATransaction flush];
    // From the 4th frame a stripe moves under the materials, like content scrolling under a sidebar: CoreAnimation
    // only redraws what changed, and the backdrops above it have to be recomputed every frame.
    uint64_t t0 = 0;
    for (int frame = 0; frame < frames; frame++) {   // a few frames: backdrops and SDF caches settle after the first
        if (frame == 3) t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        if (frame >= 3 && mover) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            mover.position = CGPointMake(fmod(mover.position.x + 7, r.size.width), mover.position.y);
            [CATransaction commit];
            [CATransaction flush];
        }
        [rr beginFrameAtTime:CACurrentMediaTime() + frame / 60.0 timeStamp:NULL];
        [rr addUpdateRect:r];
        [rr render];
        [rr endFrame];
    }
    id<MTLCommandBuffer> cb = [q commandBuffer];
    if (frames > 3) {
        id<MTLCommandBuffer> fence = [q commandBuffer];
        [fence commit];
        [fence waitUntilCompleted];
        double ms = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6 / (frames - 3);
        printf("%.2f ms per frame (%d moving frames, CPU encode + GPU, %.0fx%.0f)\n", ms, frames - 3, r.size.width, r.size.height);
    }
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b synchronizeResource:tex];
    [b endEncoding];
    [cb commit];
    [cb waitUntilCompleted];

    size_t W = tex.width, H = tex.height;
    NSMutableData *px = [NSMutableData dataWithLength:W * H * 4];
    [tex getBytes:px.mutableBytes bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px.mutableBytes, W, H, 8, W * 4, cs,
                                             kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(argv[1])],
                                                                (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    CGImageDestinationAddImage(dst, img, NULL);
    BOOL ok = CGImageDestinationFinalize(dst);
    CFRelease(dst); CGImageRelease(img); CGContextRelease(ctx); CGColorSpaceRelease(cs);
    printf("%s %s\n", ok ? "wrote" : "FAILED", argv[1]);
    return ok ? 0 : 1;
} }
