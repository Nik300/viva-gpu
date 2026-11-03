// Posts key presses to the frontmost app: keys <keycode> <count> [interval ms] (123 left, 124 right, 125 down, 126 up).
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 3) { fprintf(stderr, "usage: keys keycode count [interval_ms]\n"); return 2; }
    CGKeyCode k = (CGKeyCode)atoi(argv[1]);
    int n = atoi(argv[2]), ms = argc > 3 ? atoi(argv[3]) : 30;
    for (int i = 0; i < n; i++) {
        CGEventRef d = CGEventCreateKeyboardEvent(NULL, k, true), u = CGEventCreateKeyboardEvent(NULL, k, false);
        CGEventPost(kCGHIDEventTap, d); usleep(ms * 500); CGEventPost(kCGHIDEventTap, u); usleep(ms * 500);
        CFRelease(d); CFRelease(u);
    }
} return 0; }
