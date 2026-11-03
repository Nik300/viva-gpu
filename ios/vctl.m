// vctl: drives the phone's UI from the USB link (viva-link.py run -- /private/var/root/viva-tests/vctl ...), so the
// driver can be tested on real screens without anyone holding the phone.
//   vctl open BUNDLE-ID              launch / bring an app to the front (com.apple.Preferences, ...)
//   vctl tap X Y                     one finger, X Y in 0..1 of the screen (portrait, origin top left)
//   vctl swipe X1 Y1 X2 Y2 [MS]      drag (default 300 ms)
//   vctl home                        the home button
// Touches are digitizer events dispatched into backboardd's HID event system (private IOKit HID API, entitlement
// com.apple.private.hid.client.event-dispatch, see vctl.entitlements); apps open through SpringBoardServices.
#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <unistd.h>

typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;
IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef);
void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef, IOHIDEventRef);
IOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef, uint64_t ts, uint32_t transducer, uint32_t index, uint32_t identity,
                                             uint32_t mask, uint32_t buttons, double x, double y, double z, double tip,
                                             double barrel, Boolean range, Boolean touch, uint32_t options);
IOHIDEventRef IOHIDEventCreateDigitizerFingerEvent(CFAllocatorRef, uint64_t ts, uint32_t index, uint32_t identity, uint32_t mask,
                                                   double x, double y, double z, double tip, double twist, Boolean range,
                                                   Boolean touch, uint32_t options);
IOHIDEventRef IOHIDEventCreateKeyboardEvent(CFAllocatorRef, uint64_t ts, uint32_t page, uint32_t usage, Boolean down, uint32_t flags);
void IOHIDEventAppendEvent(IOHIDEventRef parent, IOHIDEventRef child, uint32_t options);
void IOHIDEventSetIntegerValue(IOHIDEventRef, uint32_t field, long value);
void IOHIDEventSetSenderID(IOHIDEventRef, uint64_t);

enum { kHand = 3, kRange = 1, kTouch = 2, kPosition = 4, kIdentity = 32 };
#define kDigitizerIsDisplayIntegrated ((11u << 16) | 25)   // kIOHIDEventTypeDigitizer, field 25
static const uint64_t kSender = 0x000000010000027Full;      // a digitizer-like sender id

static IOHIDEventSystemClientRef client(void) {
    static IOHIDEventSystemClientRef c;
    if (!c) c = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    return c;
}

static void send(IOHIDEventRef e) {
    IOHIDEventSetSenderID(e, kSender);
    IOHIDEventSystemClientDispatchEvent(client(), e);
    CFRelease(e);
}

static void finger(double x, double y, bool down, bool moved) {
    uint64_t ts = mach_absolute_time();
    uint32_t mask = (moved ? kPosition : kRange | kTouch | kIdentity);
    IOHIDEventRef hand = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault, ts, kHand, 0, 0, mask, 0, x, y, 0, 0, 0,
                                                        down, down, 0);
    IOHIDEventSetIntegerValue(hand, kDigitizerIsDisplayIntegrated, 1);
    IOHIDEventRef f = IOHIDEventCreateDigitizerFingerEvent(kCFAllocatorDefault, ts, 1, 2, mask, x, y, 0, down ? 1 : 0, 0,
                                                           down, down, 0);
    IOHIDEventAppendEvent(hand, f, 0);
    CFRelease(f);
    send(hand);
}

static void drag(double x1, double y1, double x2, double y2, int ms) {
    finger(x1, y1, true, false);
    int steps = ms > 0 ? ms / 16 : 0;
    for (int i = 1; i <= steps; i++) {
        usleep(16000);
        double t = (double)i / steps;
        finger(x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, true, true);
    }
    usleep(50000);
    finger(x2, y2, false, false);
}

static void key(uint32_t page, uint32_t usage) {
    send(IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(), page, usage, true, 0));
    usleep(80000);
    send(IOHIDEventCreateKeyboardEvent(kCFAllocatorDefault, mach_absolute_time(), page, usage, false, 0));
}

static int open_app(NSString *bundle) {
    void *sbs = dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
    int (*launch)(CFStringRef, Boolean) = sbs ? (int (*)(CFStringRef, Boolean))dlsym(sbs, "SBSLaunchApplicationWithIdentifier") : NULL;
    if (launch) {
        int r = launch((__bridge CFStringRef)bundle, false);
        if (r == 0) return 0;
        fprintf(stderr, "SBSLaunchApplicationWithIdentifier: %d, trying LSApplicationWorkspace\n", r);
    }
    Class ws = NSClassFromString(@"LSApplicationWorkspace");
    id w = [ws performSelector:@selector(defaultWorkspace)];
    BOOL ok = [w respondsToSelector:@selector(openApplicationWithBundleID:)] &&
              ((BOOL (*)(id, SEL, id))[w methodForSelector:@selector(openApplicationWithBundleID:)])(w, @selector(openApplicationWithBundleID:), bundle);
    return ok ? 0 : 1;
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 2) {
        fprintf(stderr, "usage: vctl open BUNDLE | tap X Y | swipe X1 Y1 X2 Y2 [MS] | home   (X Y in 0..1)\n");
        return 2;
    }
    const char *cmd = argv[1];
    if (!strcmp(cmd, "open") && argc == 3) return open_app(@(argv[2]));
    if (!strcmp(cmd, "tap") && argc == 4) { drag(atof(argv[2]), atof(argv[3]), atof(argv[2]), atof(argv[3]), 0); usleep(100000); return 0; }
    if (!strcmp(cmd, "swipe") && argc >= 6) {
        drag(atof(argv[2]), atof(argv[3]), atof(argv[4]), atof(argv[5]), argc > 6 ? atoi(argv[6]) : 300);
        usleep(100000);
        return 0;
    }
    if (!strcmp(cmd, "home")) { key(0x0c, 0x40); return 0; }   // consumer page, Menu (the home button)
    fprintf(stderr, "vctl: unknown command %s\n", cmd);
    return 2;
} }
