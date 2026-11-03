// Posts pixel scroll-wheel events (trackpad-like panning) at the pointer: scroll dx dy count [interval ms].
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 4) { fprintf(stderr, "usage: scroll dx dy count [interval_ms]\n"); return 2; }
    int dx = atoi(argv[1]), dy = atoi(argv[2]), n = atoi(argv[3]), ms = argc > 4 ? atoi(argv[4]) : 8;
    for (int i = 0; i < n; i++) {
        CGEventRef e = CGEventCreateScrollWheelEvent(NULL, kCGScrollEventUnitPixel, 2, dy, dx);
        CGEventPost(kCGHIDEventTap, e);
        CFRelease(e);
        usleep(ms * 1000);
    }
} return 0; }
