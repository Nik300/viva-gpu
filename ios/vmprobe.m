// vmprobe: on the phone, loads /System/Library/Extensions/VivaMTLDriver.bundle directly and creates VMDevice
// (without Metal.framework's device lookup), then asks Metal for the system device. Checks dyld, symbols, libLLVM
// and the kernel connection one by one. Usage: vmprobe [bundle path]
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dlfcn.h>

int main(int argc, char **argv) { @autoreleasepool {
    NSString *path = argc > 1 ? @(argv[1]) : @"/System/Library/Extensions/VivaMTLDriver.bundle";
    NSBundle *b = [NSBundle bundleWithPath:path];
    NSError *e = nil;
    if (![b loadAndReturnError:&e]) { printf("load %s: %s\n", path.UTF8String, e.description.UTF8String); return 1; }
    Class cls = [b classNamed:@"VMDevice"];
    printf("bundle loaded, VMDevice %s, principal %s\n", cls ? "found" : "MISSING", NSStringFromClass([b principalClass]).UTF8String);
    void *llvm = dlopen("/usr/lib/libLLVM.dylib", RTLD_NOW | RTLD_LOCAL);
    printf("libLLVM: %s\n", llvm ? "ok" : dlerror());
    id dev = cls ? [[cls alloc] performSelector:@selector(initWithAcceleratorPort:) withObject:nil] : nil;
    printf("VMDevice: %s\n", dev ? [[dev name] UTF8String] : "nil (no kernel service yet? see the device log)");
    id<MTLDevice> sys = MTLCreateSystemDefaultDevice();
    printf("MTLCreateSystemDefaultDevice: %s\n", sys ? sys.name.UTF8String : "nil");
    return 0;
} }
