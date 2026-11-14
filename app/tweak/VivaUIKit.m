// VivaUIKit.dylib: fixes inside every app for viva's native 360x800 pt display (docs/PIANO-DISPLAY-NATIVO.md section 9).
//
// Inserted by the kernel (patch 0205: DYLD_INSERT_LIBRARIES for executables inside an .app bundle, dyld allowed by the
// "AMFI" policy stand-in; a missing or failing dylib is not fatal). It links only Foundation and the ObjC runtime, so a
// process without UIKit pays nothing: the hooks go in once UIKitCore is loaded, and only when the kernel presents the
// native panel (IODeviceTree:/arm-io/disp0 canvas-width 1080). Off: delete the dylib, or create
// /var/jb/usr/lib/VivaUIKit.off (checked at every launch), or boot-arg vivainject=0.
//
// Keyboard: UIKit sizes the keyboard view from the layout's native width unless the screen's reference size is one of
// six exact iPhone sizes (_UIKeyboardGetDerivedKeyboardForSpecificOrientation); 360x800 is not one, so the 320 pt
// layout was stretched to 360 inside a 320 pt view centred at x 20: the right column fell off the screen.
// -[UIKBScreenTraits keyboardScreenReferenceSize] answers 360x780 (the iPhone 12/13 mini's size, in the table) for
// 360x800: the keyboard takes the mini's derived layout, 360 pt wide at x 0. Its only callers are keyboard code.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <os/log.h>
#import <IOKit/IOKitLib.h>
#import <unistd.h>

static os_log_t VULog;
#define VULOG(fmt, ...) os_log(VULog, fmt, ##__VA_ARGS__)

static IMP VUOrigRefSize;

static BOOL VUNativeCanvas(void) {
    uint32_t w = 0;
    io_registry_entry_t e = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/arm-io/disp0");
    if (e == MACH_PORT_NULL) return NO;
    CFTypeRef v = IORegistryEntryCreateCFProperty(e, CFSTR("canvas-width"), kCFAllocatorDefault, 0);
    if (v && CFGetTypeID(v) == CFDataGetTypeID() && CFDataGetLength(v) >= 4) {
        CFDataGetBytes(v, CFRangeMake(0, 4), (UInt8 *)&w);
    }
    if (v) CFRelease(v);
    IOObjectRelease(e);
    return w == 1080;
}

static BOOL VUInstall(void) {
    Class c = objc_getClass("UIKBScreenTraits");
    SEL sel = sel_registerName("keyboardScreenReferenceSize");
    Method m = c ? class_getInstanceMethod(c, sel) : NULL;
    if (!m) return NO;
    IMP imp = imp_implementationWithBlock(^CGSize(id self) {
        CGSize s = ((CGSize (*)(id, SEL))VUOrigRefSize)(self, sel);
        if (s.width == 360 && s.height == 800) return CGSizeMake(360, 780);
        if (s.width == 800 && s.height == 360) return CGSizeMake(780, 360);
        return s;
    });
    VUOrigRefSize = method_setImplementation(m, imp);
    VULOG("keyboard reference size hook in %{public}s[%d]", getprogname(), getpid());
    return YES;
}

static BOOL VUDone;

static void VUImageAdded(const struct mach_header *mh, intptr_t slide) {
    (void)mh; (void)slide;
    if (VUDone) return;
    if (objc_getClass("UIKBScreenTraits")) VUDone = VUInstall() || YES;   // installed or missing: stop looking
}

__attribute__((constructor)) static void VUInit(void) {
    @autoreleasepool {
        VULog = os_log_create("it.viva.uikit", "inject");
        if (access("/var/jb/usr/lib/VivaUIKit.off", F_OK) == 0 || !VUNativeCanvas()) return;
        if (objc_getClass("UIKBScreenTraits")) {
            VUDone = VUInstall() || YES;
            return;
        }
        // UIKitCore not loaded yet (inserted libraries come first): hook once it is
        _dyld_register_func_for_add_image(VUImageAdded);
    }
}
