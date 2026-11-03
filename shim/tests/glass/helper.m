// TeraScale Glass, app side, in a process like Chrome's GPU helper: AppKit is linked but the process never creates its
// NSApplication and may not connect to WindowServer. The driver bundle, which Metal loads there too, must leave it so:
// creating the application would connect, or throw where that is denied (Chrome: "GPU process isn't usable").
// Usage: helper <driver binary>   (exit 0: the process survived without an NSApplication)
#import <Foundation/Foundation.h>
#import <dlfcn.h>

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "usage: helper <driver binary>\n"); return 2; }
    @autoreleasepool {
        // Chrome's helpers deny themselves WindowServer connections before anything can open one.
        int (*deny)(bool) = (int (*)(bool))dlsym(RTLD_DEFAULT, "CGSSetDenyWindowServerConnections");
        if (!deny || deny(true) != 0) { fprintf(stderr, "helper: CGSSetDenyWindowServerConnections unavailable\n"); return 2; }
        if (!dlopen(argv[1], RTLD_NOW)) { fprintf(stderr, "helper: %s\n", dlerror()); return 2; }
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:1]];   // the bundle's main-queue work
        __unsafe_unretained id *app = (__unsafe_unretained id *)dlsym(RTLD_DEFAULT, "NSApp");
        printf("helper: %s\n", app && *app ? "the driver created an NSApplication" : "no NSApplication, as expected");
        return app && *app ? 1 : 0;
    }
}
