// TeraScale Metal Shim - public entry point (Phase 1: in-process, no IORegistry).
#pragma once
#import <Metal/Metal.h>

#ifdef __cplusplus
extern "C" {
#endif
// Returns a Metal device backed by the OpenGL 4.1 shim, or nil on failure.
id<MTLDevice> TSMtlCreateDevice(void) NS_RETURNS_RETAINED;
#ifdef __cplusplus
}
#endif

#ifdef __OBJC__
#ifdef __cplusplus
extern "C"
#endif
// Registers the GLSL used for the Metal function with this name (see the shader ABI in
// TSMtlPipeline.m). Phase 3 fills this automatically from AIR; tests and apps can
// provide hand-written GLSL meanwhile.
void TSMtlRegisterGLSL(NSString *functionName, NSString *source);
#endif
