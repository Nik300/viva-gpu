// Prints the CGWindowID of the on-screen windows owned by a process name or pid. Usage: winid "Name" | winid <pid>
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
int main(int argc, char **argv) { @autoreleasepool {
    NSArray *list = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID));
    int pid = argc > 1 ? atoi(argv[1]) : 0;
    for (NSDictionary *w in list) {
        BOOL match = argc > 1 && (pid > 0 ? [w[(id)kCGWindowOwnerPID] intValue] == pid
                                          : [w[(id)kCGWindowOwnerName] isEqualToString:@(argv[1])]);
        if (match && [w[(id)kCGWindowLayer] intValue] == 0)
            printf("%d %s\n", [w[(id)kCGWindowNumber] intValue], [[w[(id)kCGWindowBounds] description] stringByReplacingOccurrencesOfString:@"\n" withString:@" "].UTF8String);
    }
} return 0; }
