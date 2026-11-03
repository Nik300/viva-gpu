// TeraScale Glass, app side (docs/PIANO-GLASS.md, "Barre laterali"): Tahoe's sidebars float over the desktop behind
// the window. AppKit gives every window a capture-only backdrop of what is behind it (CABackdropLayer
// "NSCGSWindow capture backdrop", group NSCGSWindowBehindWindowCaptureBackdropGroup) and leaves the area under a
// sidebar (NSBlurryAlleywayView) unpainted; Tahoe's WindowServer shows the blurred capture there. The SkyLight that
// Moraea wraps predates that and paints the window background instead, so the sidebar glass refracts a flat gray.
//
// Here, in the app: under each NSBlurryAlleywayView goes a behind-window NSVisualEffectView reduced to its backdrop
// layer with the capture's filters (no tint layers, no colorSaturate). The old WindowServer does fill that (a bare
// CABackdropLayer is not enough: the effect view registers the window's backdrop with it). Measured on the real
// WindowServer against the capture drawn in a transparent window: 0.05% of the pixels differ by more than 16/255.
//
// Only in AppKit apps with System.Glass on; decided once per app (changes apply to apps launched afterwards).
// AppKit is reached through the runtime: the driver bundle is also loaded by processes without it, and by AppKit
// processes that never create their NSApplication (helpers, agents): those must be left without one (tests/glass/helper.m).
#import "TSGlass.h"
#import "TSLog.h"
#import <QuartzCore/QuartzCore.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

static Class gEffectView, gBackdropView;
static const void *const kTSGlassSidebarKey = &kTSGlassSidebarKey;

// The backdrop view keeps only the material's CABackdropLayer, filtered like the window's capture. AppKit rebuilds
// the material layers when the appearance or the state changes, so this runs after each of its updates.
static void TSGlassSidebarStrip(id view) {
    @try {
        CALayer *layer = [view valueForKey:@"layer"];
        for (CALayer *material in layer.sublayers)
            for (CALayer *l in material.sublayers) {
                if (![l isKindOfClass:NSClassFromString(@"CABackdropLayer")]) {
                    if (!l.hidden) l.hidden = YES;
                    continue;
                }
                NSArray *filters = [l.filters filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"name != 'colorSaturate'"]];
                if (filters.count != l.filters.count) l.filters = filters;
            }
    } @catch (id e) {}
}

// Overrides of the backdrop view: the superclass's implementation, then TSGlassSidebarStrip.
static void TSGlassSidebarOverride(SEL sel) {
    Method m = class_getInstanceMethod(gEffectView, sel);
    if (!m) return;
    IMP imp = imp_implementationWithBlock(^(id self) {
        struct objc_super sup = { self, gEffectView };
        ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, sel);
        TSGlassSidebarStrip(self);
    });
    class_addMethod(gBackdropView, sel, imp, method_getTypeEncoding(m));
}

static void TSGlassSidebarAttach(id alley) {
    @try {
        id wrapper = [alley valueForKey:@"superview"];
        if (!wrapper || ![alley valueForKey:@"window"] || objc_getAssociatedObject(wrapper, kTSGlassSidebarKey)) return;
        NSRect bounds = [[wrapper valueForKey:@"bounds"] rectValue];
        id v = ((id (*)(id, SEL, NSRect))objc_msgSend)([gBackdropView alloc], @selector(initWithFrame:), bounds);
        [v setValue:@0 forKey:@"blendingMode"];    // NSVisualEffectBlendingModeBehindWindow
        [v setValue:@21 forKey:@"material"];       // NSVisualEffectMaterialUnderWindowBackground
        [v setValue:@1 forKey:@"state"];           // NSVisualEffectStateActive
        [v setValue:@18 forKey:@"autoresizingMask"];   // NSViewWidthSizable | NSViewHeightSizable
        ((void (*)(id, SEL, id, NSInteger, id))objc_msgSend)(wrapper, @selector(addSubview:positioned:relativeTo:), v, -1, alley);   // NSWindowBelow
        objc_setAssociatedObject(wrapper, kTSGlassSidebarKey, v, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2), dispatch_get_main_queue(), ^{ TSGlassSidebarStrip(v); });
        TSMtlGlass(@"sidebar backdrop under %@", NSStringFromClass([wrapper class]));
    } @catch (id e) {
        TSMtlGlass(@"sidebar backdrop not added: %@", e);
    }
}

// Existing windows (the driver can be loaded after the first window): every NSBlurryAlleywayView in their views.
// Only through the process's own NSApp: +sharedApplication would create one in AppKit processes that are not apps, and
// where WindowServer is denied (Chrome's GPU helper) that throws: Chrome gave up on its GPU process and quit.
static void TSGlassSidebarSweep(void) {
    __unsafe_unretained id *app = (__unsafe_unretained id *)dlsym(RTLD_DEFAULT, "NSApp");
    if (!app || !*app) return;   // no windows yet: the ones to come arrive through -viewDidMoveToWindow
    @try {
        Class alleyClass = NSClassFromString(@"NSBlurryAlleywayView");
        for (id window in [*app valueForKey:@"windows"]) {
            id frame = [[window valueForKey:@"contentView"] valueForKey:@"superview"];
            NSMutableArray *queue = frame ? [NSMutableArray arrayWithObject:frame] : [NSMutableArray array];
            while (queue.count) {
                id view = queue.lastObject;
                [queue removeLastObject];
                if ([view isKindOfClass:alleyClass]) TSGlassSidebarAttach(view);
                else [queue addObjectsFromArray:[view valueForKey:@"subviews"]];
            }
        }
    } @catch (id e) {
        TSMtlGlass(@"sidebar sweep failed: %@", e);
    }
}

void TSGlassSidebarStart(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ @autoreleasepool {
        Class alleyClass = NSClassFromString(@"NSBlurryAlleywayView");
        gEffectView = NSClassFromString(@"NSVisualEffectView");
        if (!alleyClass || !gEffectView || !TSGlassWanted()) return;
        gBackdropView = objc_allocateClassPair(gEffectView, "TSGlassSidebarBackdropView", 0);
        if (!gBackdropView) return;
        for (NSString *sel in @[ @"updateLayer", @"layout", @"viewDidChangeEffectiveAppearance", @"viewDidMoveToWindow" ])
            TSGlassSidebarOverride(NSSelectorFromString(sel));
        objc_registerClassPair(gBackdropView);
        // NSBlurryAlleywayView -viewDidMoveToWindow: its own implementation (or NSView's), then the backdrop view.
        SEL sel = @selector(viewDidMoveToWindow);
        Method own = NULL;
        unsigned n = 0;
        Method *list = class_copyMethodList(alleyClass, &n);
        for (unsigned i = 0; i < n; i++) if (method_getName(list[i]) == sel) own = list[i];
        free(list);
        IMP previous = own ? method_getImplementation(own) : NULL;
        Class superclass = class_getSuperclass(alleyClass);
        IMP imp = imp_implementationWithBlock(^(id self) {
            if (previous) ((void (*)(id, SEL))previous)(self, sel);
            else { struct objc_super sup = { self, superclass }; ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&sup, sel); }
            TSGlassSidebarAttach(self);
        });
        if (own) method_setImplementation(own, imp);
        else class_addMethod(alleyClass, sel, imp, method_getTypeEncoding(class_getInstanceMethod(superclass, sel)));
        dispatch_async(dispatch_get_main_queue(), ^{ TSGlassSidebarSweep(); });
        TSMtlGlass(@"sidebars: backdrop views on in %s", getprogname());
    } });
}

__attribute__((constructor)) static void TSGlassSidebarInit(void) {
    // AppKit apps only (WindowServer has its own component; daemons that load the driver have no AppKit).
    if (!NSClassFromString(@"NSApplication") || !strcmp(getprogname(), "WindowServer")) return;
    TSGlassSidebarStart();
}
