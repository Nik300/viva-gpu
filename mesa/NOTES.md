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

## Things that compiled without changes but matter at runtime

- **BO mapping** goes through `os_mmap(NULL, size, prot, MAP_SHARED, dev->fd,
  mmap_offset)` in `pan_kmod.h` (`pan_kmod_bo_mmap`), not through libdrm. The
  mmap offset comes from `DRM_IOCTL_PANFROST_MMAP_BO` sent through `drmIoctl`.
  On XNU the fd is not a DRM node: the shim must give an fd that can be mmapped
  at those offsets, or `os_mmap` must be redirected.
- `pan_kmod.c` uses `lseek(fd, 0, SEEK_END)` on dma-buf fds to get the imported
  size (`drmPrimeFDToHandle` path).
- Every panfrost ioctl goes through `pan_kmod_ioctl()` -> `drmIoctl()`. That
  function is the main entry point to implement in libdrm-xnu (DRM_IOCTL_PANFROST_*
  for JM v9; panthor/CSF is not used on G57).
- Panthor's DMA_BUF_IOCTL_{IM,EX}PORT_SYNC_FILE also go through drmIoctl; they
  are not needed for G57 (JM).
- Linux uapi headers for panfrost come from Mesa's own `include/drm-uapi/`; the
  copies in libdrm-xnu/include/libdrm are for other consumers (shim, kernel side).
- `panfrost_create_screen` was not tested: it needs a kernel.
- Valhall compiler: `pan_shader_compile()` works with only a gpu_id (no
  device). G57 = `0x90930000` (GPU_ID register upper half 0x9093: arch 9.0,
  product major 3).
