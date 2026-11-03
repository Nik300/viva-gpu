// Moves the mouse pointer (real mouse-moved events, so apps see hover) and optionally clicks.
// Usage: mouse x y [click]   (global display coordinates, origin top-left). Needs Accessibility permission
// for the calling terminal only to click; moving works without.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 3) { fprintf(stderr, "usage: mouse x y [click]\n"); return 2; }
    CGPoint p = CGPointMake(atof(argv[1]), atof(argv[2]));
    CGEventRef mv = CGEventCreateMouseEvent(NULL, kCGEventMouseMoved, p, kCGMouseButtonLeft);
    CGEventPost(kCGHIDEventTap, mv);
    CFRelease(mv);
    if (argc > 3 && !strcmp(argv[3], "click")) {
        usleep(50000);
        CGEventRef d = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseDown, p, kCGMouseButtonLeft);
        CGEventRef u = CGEventCreateMouseEvent(NULL, kCGEventLeftMouseUp, p, kCGMouseButtonLeft);
        CGEventPost(kCGHIDEventTap, d); usleep(30000); CGEventPost(kCGHIDEventTap, u);
        CFRelease(d); CFRelease(u);
    }
} return 0; }
