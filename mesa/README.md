# Mesa for ios-viva (Gallium llvmpipe + panfrost/Valhall, static)

Pinned version: **Mesa `mesa-26.2.6`** (shallow clone from
https://gitlab.freedesktop.org/mesa/mesa.git into `src/`, gitignored).

## Build (macOS host)

```sh
brew install llvm spirv-llvm-translator spirv-tools zstd pkgconf   # once
gpu/mesa/build.sh macos
```

What the script does:
1. Creates `gpu/.venv` (pip: meson, ninja, mako, pyyaml, packaging).
2. Clones `mesa-26.2.6` into `src/` if it is missing, and applies `patches/*.patch` in
   order (patches already applied are skipped; one that does neither is an error).
3. Builds `gpu/libdrm-xnu/out/libdrm-xnu.a` (stub libdrm; pkg-config file
   `gpu/libdrm-xnu/pkgconfig/libdrm.pc`, used through `PKG_CONFIG_PATH`).
4. Configures `build-macos/` (release, `-g0`, `b_ndebug=true`, static, no
   GL/EGL/GLX/GBM/Vulkan, `gallium-drivers=llvmpipe,panfrost`, brew LLVM 23
   shared, zstd+zlib) with `cross/macos-native.ini`.
5. Builds explicit ninja targets (the list is in `mesa_libs()` in build.sh) and
   merges them with `libtool -static` into `out/macos/lib/libmesa_viva.a`.
6. Copies headers to `out/macos/include/{src,build}` and writes
   `out/macos/cflags.txt` / `ldflags.txt`.
7. Regenerates `gpu/libdrm-xnu/SYMBOLS.txt`, then builds and runs `tests/smoke`.

Other modes: `macos-nosmoke`, `clean` (removes the build dir, out/ and the
libdrm-xnu output), `distclean` (also removes `src/`), and `fn <step>...`
(runs single steps, e.g. `./build.sh fn build_macos package_macos`).
`JOBS` (default 8) and `LLVM_PREFIX` can be overridden from the environment.

A clean full build takes about 1 minute on 8 cores. Disk use: src 0.5 GB, build-macos 160 MB,
out 45 MB.

## What is in libmesa_viva.a (~26 MB)

util (+c11, simd, blake3, xmlconfig, parson), compiler, NIR, vtn (SPIR-V→NIR),
isaspec, gallium auxiliary, sw/null winsys, **llvmpipe**, **panfrost**
gallium driver + per-arch libs v4..v14 (`libpanfrost-vN`, `libpan-arch-vN`,
`libpan-format-vN`, `libpandecode-arch-vN`), panfrost lib/kmod/model/perf/
shared/genxml decode, the Bifrost/Valhall compiler (+ Midgard, which the
compiler library references) and disassemblers, and the panfrost DRM winsys.
libdrm-xnu is **not** included: link it separately.

## Consuming

```sh
cc $(cat out/macos/cflags.txt) -c foo.c
cc foo.o $(cat out/macos/ldflags.txt) -o foo
```

- `cflags.txt`: `-std=c11`, the global Mesa `-D` defines (taken from the real
  compile command; some change struct layouts, e.g. `NDEBUG`,
  `HAVE_STRUCT_TIMESPEC`), and `-I` paths for pipe headers (`src/include`,
  `src/gallium/include`), gallium auxiliary, util, compiler, NIR including the
  generated `nir_opcodes.h`, `nir_intrinsics.h`, `nir_builder_opcodes.h` (in
  `include/build/src/compiler/nir`), panfrost and genxml.
- Driver entry headers: `llvmpipe/lp_public.h`, `panfrost/pan_public.h`
  (both found through `-I.../src/gallium/drivers`), and `sw/null/null_sw_winsys.h`
  (found through `-I.../src/gallium/winsys`).
- `ldflags.txt`: libmesa_viva.a, libdrm-xnu.a,
  `-L$(brew llvm)/lib -lLLVM-23` + rpath, `-lzstd -lz -lc++ -lpthread -lm`.

See `tests/smoke.c` for a working example of (a) an llvmpipe screen and context on
the null winsys that clears a render target and reads it back, and (b) a
nir_builder fragment shader compiled with the Valhall compiler for a Mali-G57
(`gpu_id 0x90930000`, through the preprocess / lower_io / postprocess /
`pan_shader_compile` sequence of `pan_shader.c`).

## Patches (`patches/`)

| Patch | Purpose |
|---|---|
| 0001-meson-darwin-libdrm.patch | Find libdrm (libdrm-xnu) on darwin when panfrost is enabled. Skip global `HAVE_LIBDRM` and `u_sync_provider.c` there |
| 0002-panfrost-kmod-no-eventfd.patch | ENOSYS stubs for eventfd/timerfd/sched_setscheduler in panfrost_kmod.c (perf counters) |

To add a patch: edit `src/`, then run
`git -C src diff -- <files> > patches/NNNN-name.patch` and add a one-line
description at the top. Write each problem and its fix in `NOTES.md`.

## libdrm-xnu

`gpu/libdrm-xnu/`: `include/xf86drm.h`, `include/xf86drmMode.h` and
`include/libdrm/{drm,drm_mode,drm_fourcc}.h` come from libdrm 2.4.134 (MIT).
`panfrost_drm.h` and `panthor_drm.h` come from Mesa's drm-uapi (MIT).
`src/xf86drm_stub.c` stubs the 15 symbols in `SYMBOLS.txt` (ENOSYS or NULL).
Regenerate the list with `collect-symbols.sh`.

## iOS arm64 build (later; not possible here, since there is no iOS SDK)

- Template: `cross/ios-arm64.ini` (target `arm64-apple-ios16.0`, meson
  `system=darwin`, `subsystem=ios`; fill in the SDK path).
- **No LLVM and no llvmpipe on iOS** (JIT is not allowed, and there is no LLVM for the target): use
  `-Dgallium-drivers=panfrost -Dllvm=disabled -Ddraw-use-llvm=false`.
- Panfrost still needs the precompiled libpan kernels. Use the host tools from
  `build-macos` with `-Dmesa-clc=system -Dprecomp-compiler=system`, and put
  `build-macos/src/compiler/clc/mesa_clc`, `.../spirv/vtn_bindgen2` and
  `build-macos/src/panfrost/clc/panfrost_compile` on PATH. With
  `mesa-clc=system`, CLC (and so LLVM) is not required for the target.
- libdrm-xnu must be cross-built for arm64-apple-ios16.0 and found through
  `pkg_config_libdir`, and its stubs replaced by the IOKit implementation.
- The same two patches apply (they key on `darwin` / `__APPLE__`). Expect
  more iOS-specific issues (for example `os_mmap` on the device fd, and the
  disk cache path; consider `-Dshader-cache=disabled`).
- Use `libtool -static` again to produce `libmesa_viva.a` for iOS.
