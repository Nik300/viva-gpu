// VivaDisplay: SpringBoard hooks for viva's native 360x800 pt display (docs/PIANO-DISPLAY-NATIVO.md, section 8).
// Built into VivaIsland.dylib (same LC_LOAD_WEAK_DYLIB in SpringBoard, tweak/inject.sh); a second constructor.
//
// Active only when the kernel presents the native panel: IODeviceTree:/arm-io/disp0 canvas-width == 1080 (patch 0203,
// boot-arg sweetfb_native=1), so with the iPhone X presentation (1125x2436) nothing is touched. Preferences
// it.viva.display: DisplayHooks (default YES) turns everything off; numbers override the geometry below.
//
// What SpringBoard decides for itself and for every app (UISDisplayContext over XPC), hooked here:
//  - the island: -[SBUISystemApertureLayoutMetrics sensorRegionSize] (every compact / minimal size derives from it
//    through _inertSize), minimumScreenEdgeInsets (top only: the sides keep Apple's 11.33 pt), and
//    interSensorRegionInWindowSpace (where the privacy dot goes);
//  - the exclusion area: +[UISDisplaySingleRectShape sb_displayShapeForScreenType:] -> rect in points, y > 0, so every
//    app's status bar is _UIStatusBarVisualProvider_DynamicSplitMedium, laid out on that rect (no size tables);
//  - safe areas: +[UISApplicationSupportDisplayEdgeInfo _sbh_displayEdgeInfoForScreenType:];
//  - compatibility: -[SBApplication _defaultClassicMode] -> 0 (native) for apps with a launch storyboard /
//    UILaunchScreen / SwiftUI (usesSplashBoard), unchanged for the others (letterboxed 375x667 / 375x812 windows).
// Geometry from fork/tools/viva-display-geometry.py with the camera hole and corners measured on the phone.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <os/log.h>
#import <notify.h>
#import <IOKit/IOKitLib.h>

#define VD_DOMAIN "it.viva.display"

static os_log_t VDLog;
#define VDLOG(fmt, ...) os_log(VDLog, fmt, ##__VA_ARGS__)

// viva-display-geometry.py defaults (hole 543,50 r 20 px; corners 110 px), points unless _PX
static double VDIslandW = 100.0, VDIslandH = 29.333, VDIslandTop = 2.0;
static double VDInterX = 193.333, VDInterW = 9.0;
// What the status bar avoids around the island (points, centred): wider than the pill pushes the time and the icons
// toward the screen edges (they are centred between edgeInsets and the area; user request 2026-11-14).
static double VDAvoidW = 150.0;
static double VDSafeTop = 53.667, VDSafeBottom = 34.0, VDSafeLandscapeSide = 53.667, VDSafeLandscapeBottom = 21.0;
static double VDScreenW = 360.0;

static double VDPrefNumber(NSDictionary *d, NSString *key, double def) {
    id v = d[key];
    return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : def;
}

static NSDictionary *VDPrefs(void) {
    CFStringRef domain = CFSTR(VD_DOMAIN);
    CFPreferencesAppSynchronize(domain);
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    NSDictionary *file = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/" VD_DOMAIN ".plist"];
    if (file) [d addEntriesFromDictionary:file];
    CFArrayRef keys = CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (keys) {
        NSDictionary *cf = CFBridgingRelease(CFPreferencesCopyMultiple(keys, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
        [d addEntriesFromDictionary:cf];
        CFRelease(keys);
    }
    return d;
}

// The kernel's presented canvas (0203 writes it into the device tree with sweetfb_native=1).
static uint32_t VDCanvasWidth(void) {
    uint32_t w = 0;
    io_registry_entry_t e = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/arm-io/disp0");
    if (e == MACH_PORT_NULL) return 0;
    CFTypeRef v = IORegistryEntryCreateCFProperty(e, CFSTR("canvas-width"), kCFAllocatorDefault, 0);
    if (v && CFGetTypeID(v) == CFDataGetTypeID() && CFDataGetLength(v) >= 4) {
        CFDataGetBytes(v, CFRangeMake(0, 4), (UInt8 *)&w);
    }
    if (v) CFRelease(v);
    IOObjectRelease(e);
    return w;
}

// Replace an instance (or, with meta, class) method; the old IMP goes to *orig. NO when the class or method is missing.
static BOOL VDHook(NSString *cls, SEL sel, BOOL meta, id block, IMP *orig) {
    Class c = NSClassFromString(cls);
    if (meta) c = object_getClass(c);
    Method m = c ? class_getInstanceMethod(c, sel) : NULL;     /* on the metaclass for class methods */
    if (!m) {
        VDLOG("hook: %{public}@ %{public}s missing", cls, sel_getName(sel));
        return NO;
    }
    IMP imp = imp_implementationWithBlock(block);
    IMP old = method_setImplementation(m, imp);
    if (orig) *orig = old;
    VDLOG("hook: %{public}@ %{public}s", cls, sel_getName(sel));
    return YES;
}

static id VDInsets(double top, double left, double bottom, double right) {
    Class w = NSClassFromString(@"UISApplicationSupportDisplayEdgeInsetsWrapper");
    id o = [w new];
    if (!o) return nil;
    @try {
        [o setValue:@(top) forKey:@"topInset"];
        [o setValue:@(left) forKey:@"leftInset"];
        [o setValue:@(bottom) forKey:@"bottomInset"];
        [o setValue:@(right) forKey:@"rightInset"];
    } @catch (NSException *e) {
        VDLOG("insets: %{public}@", e);
        return nil;
    }
    return o;
}

static IMP VDOrigEdgeInfo, VDOrigClassicMode, VDOrigEdgeInsets;

static void VDInstall(void) {
    // SpringBoardUIServices: the island
    VDHook(@"SBUISystemApertureLayoutMetrics", @selector(sensorRegionSize), NO, ^CGSize(id self) {
        return CGSizeMake(VDIslandW, VDIslandH);
    }, NULL);
    VDHook(@"SBUISystemApertureLayoutMetrics", @selector(minimumScreenEdgeInsets), NO, ^NSDirectionalEdgeInsets(id self) {
        NSDirectionalEdgeInsets i = ((NSDirectionalEdgeInsets (*)(id, SEL))VDOrigEdgeInsets)(self, @selector(minimumScreenEdgeInsets));
        i.top = VDIslandTop;    // sides and bottom stay Apple's (the expanded island keeps its distance from the edges)
        return i;
    }, &VDOrigEdgeInsets);
    VDHook(@"SBUISystemApertureLayoutMetrics", @selector(interSensorRegionInWindowSpace), NO, ^CGRect(id self) {
        return CGRectMake(VDInterX, VDIslandTop, VDInterW, VDIslandH);
    }, NULL);

    // SpringBoard: the exclusion area every app gets (points, y > 0 -> DynamicSplit status bar)
    VDHook(@"UISDisplaySingleRectShape", NSSelectorFromString(@"sb_displayShapeForScreenType:"), YES, ^id(id self, NSInteger type) {
        // Points, not pixels: the status bar takes _exclusionArea.rect x nativeScale / scale as points
        // (-[_UIStatusBarVisualProvider_DynamicSplit sensorAreaRect]); px put the island at x 390 pt (phone, 2026-11-14).
        double w = MAX(VDAvoidW, VDIslandW);
        CGRect r = CGRectMake(VDScreenW / 2 - w / 2, VDIslandTop, w, VDIslandH);
        id (*init)(id, SEL, CGRect) = (id (*)(id, SEL, CGRect))objc_msgSend;
        return init([NSClassFromString(@"UISDisplaySingleRectShape") alloc], @selector(initWithRect:), r);
    }, NULL);

    // SpringBoardHome: safe areas
    VDHook(@"UISApplicationSupportDisplayEdgeInfo", NSSelectorFromString(@"_sbh_displayEdgeInfoForScreenType:"), YES,
           ^id(id self, NSInteger type) {
        id info = ((id (*)(id, SEL, NSInteger))VDOrigEdgeInfo)(self, NSSelectorFromString(@"_sbh_displayEdgeInfoForScreenType:"), type);
        if (!info) return info;
        @try {
            id portrait = VDInsets(VDSafeTop, 0, VDSafeBottom, 0);
            id left = VDInsets(0, VDSafeLandscapeSide, VDSafeLandscapeBottom, VDSafeLandscapeSide);
            id right = VDInsets(0, VDSafeLandscapeSide, VDSafeLandscapeBottom, VDSafeLandscapeSide);
            if (portrait) [info setValue:portrait forKey:@"safeAreaInsetsPortrait"];
            if (left) [info setValue:left forKey:@"safeAreaInsetsLandscapeLeft"];
            if (right) [info setValue:right forKey:@"safeAreaInsetsLandscapeRight"];
        } @catch (NSException *e) {
            VDLOG("edge info: %{public}@", e);
        }
        return info;
    }, &VDOrigEdgeInfo);

    // SpringBoard: compatibility mode of third-party apps
    VDHook(@"SBApplication", NSSelectorFromString(@"_defaultClassicMode"), NO, ^NSInteger(id self) {
        NSInteger mode = ((NSInteger (*)(id, SEL))VDOrigClassicMode)(self, NSSelectorFromString(@"_defaultClassicMode"));
        @try {
            id info = [self valueForKey:@"info"];
            if (mode != 0 && [[info valueForKey:@"usesSplashBoard"] boolValue]) {
                VDLOG("classic mode %ld -> 0 for %{public}@", (long)mode, [self valueForKey:@"bundleIdentifier"]);
                return 0;
            }
        } @catch (NSException *e) {
            VDLOG("classic mode: %{public}@", e);
        }
        return mode;
    }, &VDOrigClassicMode);
}

// Diagnostics: Darwin notification it.viva.display.dump (fork/tools/vivad/vnotify) writes SpringBoard's windows with
// their view trees and frames, the screen geometry and the keyboard's traits to /var/mobile/Library/Caches/VivaDisplay/
// views.txt (pull it over the link). For layout bugs inside SpringBoard (keyboard 20 pt to the right, 2026-11-14).
static void VDDump(void) {
    NSMutableString *out = [NSMutableString string];
    @try {
        UIScreen *scr = UIScreen.mainScreen;
        [out appendFormat:@"screen bounds %@ native %@ scale %.2f nativeScale %.2f\n", NSStringFromCGRect(scr.bounds),
            NSStringFromCGRect(scr.nativeBounds), scr.scale, scr.nativeScale];
        for (NSString *sel in @[@"_referenceBounds", @"_unjailedReferenceBounds"]) {
            if ([scr respondsToSelector:NSSelectorFromString(sel)]) {
                CGRect r = ((CGRect (*)(id, SEL))objc_msgSend)(scr, NSSelectorFromString(sel));
                [out appendFormat:@"screen %@ %@\n", sel, NSStringFromCGRect(r)];
            }
        }
        for (NSString *sel in @[@"_exclusionArea", @"_displayInfoProvider", @"_screenType"]) {
            if (![scr respondsToSelector:NSSelectorFromString(sel)]) continue;
            if ([sel isEqualToString:@"_screenType"]) {
                [out appendFormat:@"screen _screenType %ld\n", ((long (*)(id, SEL))objc_msgSend)(scr, NSSelectorFromString(sel))];
            } else {
                [out appendFormat:@"screen %@ %@\n", sel, [scr valueForKey:sel]];
            }
        }
        Class traits = NSClassFromString(@"UIKBScreenTraits");
        if ([traits respondsToSelector:@selector(traitsWithScreen:orientation:)]) {
            id t = ((id (*)(id, SEL, id, long))objc_msgSend)(traits, @selector(traitsWithScreen:orientation:), scr, 1);
            [out appendFormat:@"UIKBScreenTraits %@\n", t];
        }
        id impl = [NSClassFromString(@"UIKeyboardImpl") respondsToSelector:@selector(activeInstance)] ?
            [NSClassFromString(@"UIKeyboardImpl") performSelector:@selector(activeInstance)] : nil;
        if (impl) {
            [out appendFormat:@"UIKeyboardImpl %@ frame %@\n", impl, NSStringFromCGRect([(UIView *)impl frame])];
            if ([impl respondsToSelector:NSSelectorFromString(@"_layout")]) {
                id layout = [impl valueForKey:@"_layout"];
                [out appendFormat:@"layout %@\n", layout];
            }
        }
        NSArray *windows = nil;
        @try {
            windows = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(UIWindow.class,
                NSSelectorFromString(@"allWindowsIncludingInternalWindows:onlyVisibleWindows:"), YES, YES);
        } @catch (NSException *e) {
            windows = UIApplication.sharedApplication.windows;
        }
        for (UIWindow *w in windows) {
            [out appendFormat:@"\n=== %@ level %.0f frame %@\n", NSStringFromClass(w.class), w.windowLevel,
                NSStringFromCGRect(w.frame)];
            NSString *tree = [w respondsToSelector:NSSelectorFromString(@"recursiveDescription")] ?
                [w valueForKey:@"recursiveDescription"] : w.description;
            [out appendString:tree ?: @"?"];
        }
    } @catch (NSException *e) {
        [out appendFormat:@"\nexception %@\n", e];
    }
    NSString *dir = @"/var/mobile/Library/Caches/VivaDisplay";
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    [out writeToFile:[dir stringByAppendingPathComponent:@"views.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    VDLOG("dump: %lu bytes", (unsigned long)out.length);
}

__attribute__((constructor)) static void VDInit(void) {
    @autoreleasepool {
        VDLog = os_log_create("it.viva.display", "tweak");
        if (strcmp(getprogname(), "SpringBoard") != 0) return;
        int token;
        notify_register_dispatch("it.viva.display.dump", &token, dispatch_get_main_queue(), ^(int t) { VDDump(); });
        uint32_t canvas = VDCanvasWidth();
        NSDictionary *p = VDPrefs();
        id on = p[@"DisplayHooks"];
        if (canvas != 1080 || (on && ![on boolValue])) {
            VDLOG("inactive (canvas width %u, DisplayHooks %{public}@)", canvas, on);
            return;
        }
        VDIslandW = VDPrefNumber(p, @"IslandWidth", VDIslandW);
        VDIslandH = VDPrefNumber(p, @"IslandHeight", VDIslandH);
        VDIslandTop = VDPrefNumber(p, @"IslandTop", VDIslandTop);
        VDInterX = VDPrefNumber(p, @"InterSensorX", VDInterX);
        VDAvoidW = VDPrefNumber(p, @"StatusBarAvoidWidth", VDAvoidW);
        VDSafeTop = VDPrefNumber(p, @"SafeTop", VDSafeTop);
        VDSafeBottom = VDPrefNumber(p, @"SafeBottom", VDSafeBottom);
        VDSafeLandscapeSide = VDPrefNumber(p, @"SafeLandscapeSide", VDSafeLandscapeSide);
        VDSafeLandscapeBottom = VDPrefNumber(p, @"SafeLandscapeBottom", VDSafeLandscapeBottom);
        @try {
            VDInstall();
        } @catch (NSException *e) {
            VDLOG("install: %{public}@", e);
        }
        VDLOG("active: island %.2fx%.2f at %.2f pt, status bar avoids %.2f pt, safe top %.2f bottom %.2f", VDIslandW,
              VDIslandH, VDIslandTop, VDAvoidW, VDSafeTop, VDSafeBottom);
    }
}
