// Test-only helper, never part of the shim: Apple apps such as Find My abort when they cannot
// read their own Apple-only entitlements, which AMFI refuses on an ad-hoc re-signed copy.
// DYLD_INSERT_LIBRARIES=build/libTSEntSpoof.dylib TS_FAKE_ENTITLEMENTS=prefix1,prefix2 makes
// SecTaskCopyValueForEntitlement answer true for matching keys. Daemons still check the real
// signature, so the services behind those entitlements keep refusing the copy.
#import <Foundation/Foundation.h>
#import <Security/Security.h>

#define TS_INTERPOSE(replacement, replacee) \
    __attribute__((used)) static const struct { const void *r; const void *e; } ts_interpose_##replacee \
    __attribute__((section("__DATA,__interpose"))) = { (const void *)&replacement, (const void *)&replacee };

static BOOL TSFaked(CFStringRef key) {
    static NSArray<NSString *> *prefixes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        const char *v = getenv("TS_FAKE_ENTITLEMENTS");
        prefixes = v ? [@(v) componentsSeparatedByString:@","] : @[];
    });
    for (NSString *p in prefixes) if (p.length && [(__bridge NSString *)key hasPrefix:p]) return YES;
    return NO;
}

static CFTypeRef TSCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error) {
    if (entitlement && TSFaked(entitlement)) return CFRetain(kCFBooleanTrue);
    return SecTaskCopyValueForEntitlement(task, entitlement, error);
}

TS_INTERPOSE(TSCopyValueForEntitlement, SecTaskCopyValueForEntitlement)
