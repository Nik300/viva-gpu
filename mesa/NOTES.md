# Mesa port notes (mesa-26.2.6 on macOS / Darwin)

Log of problems hit while building llvmpipe + panfrost on Darwin, and how they
were fixed. Patches live in `patches/`, applied in order by `build.sh`.

## Environment / toolchain

1. **No meson/ninja/mako**: installed with pip into `gpu/.venv` (`build.sh`).
2. **Panfrost requires mesa_clc**: `with_gallium_panfrost` turns on
   `with_driver_using_cl`, so the build needs clang (libclang-cpp), LLVM,
   SPIRV-LLVM-Translator and SPIRV-Tools to precompile the libpan OpenCL
   kernels (`panfrost_compile`, host tool). Fix: `brew install
   spirv-llvm-translator spirv-tools` (both match brew LLVM 23). No libclc needed.
3. **LLVM 23.1.4 works** with Mesa 26.2.6 llvmpipe as is: no llvm@20 needed.
   Brew LLVM is shared-only, so consumers link `-lLLVM-23` (see ldflags.txt).
4. **`llvm-ar` not found at ninja time**: with brew llvm on PATH at configure
   time meson picked `llvm-ar`. Fix: `cross/macos-native.ini` pins
   `llvm-config` and `ar=/usr/bin/ar`; brew llvm is never put on PATH.
5. System bison 2.3 is too old for GLSL, but GLSL is not built (opengl=false).

## Source fixes

### 0001-meson-darwin-libdrm.patch
- **Problem**: `system_has_kms_drm` is false on darwin, so `dep_libdrm` is
  forced to `null_dep`; panfrost's `#include <xf86drm.h>` then fails.
- **Fix**: on darwin with panfrost enabled, look libdrm up via pkg-config (our
  `libdrm-xnu`).
- **Follow-up problem**: a found libdrm adds global `-DHAVE_LIBDRM`, which turns
  on Linux-only paths: llvmpipe dma-buf/sync_file fences (`ppoll`,
  `linux/dma-buf.h`), `util/u_sync_provider.c` (redefinition vs its inline
  fallback), u_screen DRM caps.
- **Fix**: on darwin do not define `HAVE_LIBDRM`, and do not build
  `u_sync_provider.c`. Panfrost includes xf86drm.h directly so it does not need it.
  `gallium/auxiliary/renderonly` still builds (it uses drmIoctl/drmPrime*).

### 0002-panfrost-kmod-no-eventfd.patch
- **Problem**: `panfrost_kmod.c` (perf-counter sampling thread) uses
  `sys/eventfd.h`, `sys/timerfd.h` and `sched_setscheduler()`, none of which
  exist on XNU.
- **Fix**: under `#ifdef __APPLE__`, inline stubs that fail with ENOSYS, so
  `panfrost_kmod_perf_create()` fails cleanly (no perf counters on XNU for now).

### 0003-panfrost-xnu-bo-map.patch
- **Problem**: Panfrost maps BOs with `os_mmap(..., dev->fd, mmap_offset)`; on XNU
  the fd is not a DRM node and cannot be mmapped.
- **Fix**: under `__APPLE__`, `pan_kmod_bo_mmap`/munmap go through libdrm-xnu's
  `drmMap`/`drmUnmap`, which call `IOConnectMapMemory64` with the BO's token.

### 0004-panfrost-gfx-compute.patch
- **Problem**: with Panfrost as the only gallium driver and no GL/Vulkan front
  end, meson leaves out parts of NIR and the gallium compute helpers that the
  Metal driver needs (iOS has no CLC either).
- **Fix**: build them whenever Panfrost is enabled.

### 0005-panfrost-xnu-fences-idle-seq.patch
- **Problem**: Panfrost's fences export and import sync files, emulated on XNU
  with several kernel calls each; and `panfrost_bo_wait` always asked the kernel.
- **Fix**: a fence is a syncobj from a pool, filled with `SYNCOBJ_TRANSFER` in one
  call. Each BO remembers the sequence number of its last submit; when the
  completion page shows that submit finished, the wait returns without
  `WAIT_BO`.

### 0006-panfrost-precompiled-shader.patch
- **Problem**: shaders compiled by the driver's AIR → Valhall ISA compiler must
  enter Gallium like any other shader.
- **Fix**: new `src/panfrost/compiler/pan_isa_hooks.h`. The driver creates a
  "shell" NIR shader (stage and I/O only); `pan_shader.c` asks the hooks for the
  binary, `pan_shader_info` and varying layout instead of compiling it.

## Things that compiled without changes but matter at runtime

- **BO mapping** went through `os_mmap(NULL, size, prot, MAP_SHARED, dev->fd,
  mmap_offset)` in `pan_kmod.h` (`pan_kmod_bo_mmap`), not through libdrm: patch
  0003 redirects it.
- `pan_kmod.c` uses `lseek(fd, 0, SEEK_END)` on dma-buf fds to get the imported
  size (`drmPrimeFDToHandle` path).
- Every panfrost ioctl goes through `pan_kmod_ioctl()` -> `drmIoctl()`. That
  function is the main entry point to implement in libdrm-xnu (DRM_IOCTL_PANFROST_*
  for JM v9; panthor/CSF is not used on G57).
- Panthor's DMA_BUF_IOCTL_{IM,EX}PORT_SYNC_FILE also go through drmIoctl; they
  are not needed for G57 (JM).
- Linux uapi headers for panfrost come from Mesa's own `include/drm-uapi/`; the
  copies in libdrm-xnu/include/libdrm are for other consumers (shim, kernel side).
- `panfrost_create_screen` runs on the phone against the kernel driver and on the Mac against the mock.
- Valhall compiler: `pan_shader_compile()` works with only a gpu_id (no
  device). G57 = `0x90930000` (GPU_ID register upper half 0x9093: arch 9.0,
  product major 3).
