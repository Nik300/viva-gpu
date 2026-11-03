// IOKit user API: the iOS SDK ships IOKit.framework without headers. When <IOKit/IOKitLib.h> is missing, declare
// the few functions and constants the Viva GPU client and the Metal driver use (stable since iOS 2 / macOS 10.0).
#pragma once
#include <mach/mach.h>
#include <stdint.h>
// IOConnectTrap2 is exported by IOKit on iOS too, but the iOS SDK's IOKitLib.h marks it unavailable: declared here
// under another name bound to the same symbol.
#ifdef __cplusplus
extern "C"
#endif
kern_return_t vgpu_IOConnectTrap2(mach_port_t connect, uint32_t index, uintptr_t p1, uintptr_t p2) __asm__("_IOConnectTrap2");
#if __has_include(<IOKit/IOKitLib.h>)
#include <IOKit/IOKitLib.h>
#else
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef mach_port_t io_object_t;
typedef io_object_t io_service_t;
typedef io_object_t io_connect_t;
typedef io_object_t io_registry_entry_t;
typedef kern_return_t IOReturn;
typedef uint32_t IOOptionBits;
#define kIOMainPortDefault ((mach_port_t)0)
#define kIOReturnSuccess       KERN_SUCCESS
#define iokit_common_err(r)    (0xe0000000 | (r))
#define kIOReturnError         iokit_common_err(0x2bc)
#define kIOReturnNoMemory      iokit_common_err(0x2bd)
#define kIOReturnNoResources   iokit_common_err(0x2be)
#define kIOReturnBadArgument   iokit_common_err(0x2c2)
#define kIOReturnNotPrivileged iokit_common_err(0x2c1)
#define kIOReturnUnsupported   iokit_common_err(0x2c7)
#define kIOReturnIOError       iokit_common_err(0x2ca)
#define kIOReturnBusy          iokit_common_err(0x2d5)
#define kIOReturnTimeout       iokit_common_err(0x2d6)
#define kIOReturnNotPermitted  iokit_common_err(0x2e2)
#define kIOReturnNoDevice      iokit_common_err(0x2c0)
#define kIOReturnNotFound      iokit_common_err(0x2f0)
#define kIOReturnAborted       iokit_common_err(0x2eb)
#define kIOMapAnywhere 0x00000001
CFMutableDictionaryRef IOServiceMatching(const char *name);
io_service_t IOServiceGetMatchingService(mach_port_t mainPort, CFDictionaryRef matching);
kern_return_t IOServiceOpen(io_service_t service, task_port_t owningTask, uint32_t type, io_connect_t *connect);
kern_return_t IOServiceClose(io_connect_t connect);
kern_return_t IOObjectRelease(io_object_t object);
kern_return_t IORegistryEntryGetRegistryEntryID(io_registry_entry_t entry, uint64_t *entryID);
kern_return_t IOConnectCallStructMethod(mach_port_t connection, uint32_t selector, const void *inputStruct,
                                        size_t inputStructCnt, void *outputStruct, size_t *outputStructCnt);
kern_return_t IOConnectMapMemory64(io_connect_t connect, uint32_t memoryType, task_port_t intoTask,
                                   mach_vm_address_t *atAddress, mach_vm_size_t *ofSize, IOOptionBits options);
kern_return_t IOConnectUnmapMemory64(io_connect_t connect, uint32_t memoryType, task_port_t fromTask,
                                     mach_vm_address_t atAddress);
#ifdef __cplusplus
}
#endif
#endif
