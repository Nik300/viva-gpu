#!/bin/bash
# Builds the Viva Metal driver for the phone (iOS 16, arm64): Mesa (Panfrost only, no LLVM), libdrm-xnu + vgpu
# (IOKit back-end), the vmg back-end and the Objective-C driver, packaged as VivaMTLDriver.bundle for
# /System/Library/Extensions (MetalPluginName = VivaMTLDriver, MetalPluginClassName = VMDevice), plus the test
# binaries to run on the phone. Needs an iOS SDK (Xcode): `xcrun --sdk iphoneos --show-sdk-path`.
# Not run yet: this Mac has only the Command Line Tools.
#
# Usage: ios/build.sh [all|mesa|driver|tests]      output: ios/out/
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
GPU="$(cd "$HERE/.." && pwd)"
OUT="$HERE/out"
SDK="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)"
if [ -z "$SDK" ]; then
  echo "ios/build.sh: no iOS SDK (install Xcode and run xcode-select -s /Applications/Xcode.app)" >&2
  exit 1
fi
CC="${VIVA_CCACHE:+$VIVA_CCACHE }$(xcrun --sdk iphoneos -f clang)"
TARGET="-target arm64-apple-ios16.0 -isysroot $SDK"
mkdir -p "$OUT"

mesa() {
  # Host tools (mesa_clc, vtn_bindgen2, panfrost_compile) come from the macOS build.
  [ -x "$GPU/mesa/build-macos/src/panfrost/clc/panfrost_compile" ] || bash "$GPU/mesa/build.sh" macos-nosmoke
  sed -e "s|@IOS_SDK@|$SDK|" -e "s|@GPU@|$GPU|" "$GPU/mesa/cross/ios-arm64.ini" > "$OUT/ios-arm64.ini.new"
  if [ -n "${VIVA_CCACHE:-}" ]; then
    # meson does not wrap cross compilers with ccache, and ccache cannot see through xcrun: use the real compiler
    # paths (the SDK comes from -isysroot in the flags).
    local clang clangxx
    clang="$(xcrun --sdk iphoneos -f clang)"; clangxx="$(xcrun --sdk iphoneos -f clang++)"
    sed -i '' -e "s|^c = .*|c = ['$VIVA_CCACHE', '$clang']|" -e "s|^cpp = .*|cpp = ['$VIVA_CCACHE', '$clangxx']|" \
        -e "s|^objc = .*|objc = ['$VIVA_CCACHE', '$clang']|" "$OUT/ios-arm64.ini.new"
  fi
  # Keep the old file (and its date) when nothing changed, so meson does not reconfigure.
  if cmp -s "$OUT/ios-arm64.ini.new" "$OUT/ios-arm64.ini"; then rm "$OUT/ios-arm64.ini.new"; else mv "$OUT/ios-arm64.ini.new" "$OUT/ios-arm64.ini"; fi
  export PATH="$GPU/.venv/bin:$GPU/mesa/build-macos/src/compiler/clc:$GPU/mesa/build-macos/src/compiler/spirv:$GPU/mesa/build-macos/src/panfrost/clc:$PATH"
  local B="$GPU/mesa/build-ios"
  [ -f "$B/build.ninja" ] || "$GPU/.venv/bin/meson" setup "$B" "$GPU/mesa/src" --cross-file "$OUT/ios-arm64.ini" \
      -Dgallium-drivers=panfrost -Dvulkan-drivers= -Dllvm=disabled -Ddraw-use-llvm=false -Dplatforms= \
      -Dopengl=false -Dgles1=disabled -Dgles2=disabled -Degl=disabled -Dglx=disabled -Dgbm=disabled \
      -Dmesa-clc=system -Dprecomp-compiler=system -Dshader-cache=disabled -Dzstd=disabled -Dexpat=disabled
  # Same targets as the macOS build minus llvmpipe (see mesa/build.sh mesa_libs).
  local targets
  targets="$(bash "$GPU/mesa/build.sh" fn mesa_libs 2>/dev/null | grep -v -i 'llvmpipe\|gallivm\|null_sw' || true)"
  "$GPU/.venv/bin/ninja" -C "$B" $targets
  mkdir -p "$OUT/lib"
  rm -f "$OUT/lib/libmesa_viva.a"
  local libs=()
  for t in $targets; do [ -f "$B/$t" ] && libs+=("$B/$t") || echo "missing $t"; done
  echo "combining ${#libs[@]} archives"
  for l in "${libs[@]}"; do echo "  $(ar t "$l" 2>/dev/null | wc -l | tr -d ' ') ${l#$B/}"; done
  # The bundle links the individual archives (ld64 is order independent); the combined one is for the artifact.
  printf '%s\n' "${libs[@]}" > "$OUT/lib/mesa-libs.txt"
  xcrun --sdk iphoneos libtool -static -o "$OUT/lib/libmesa_viva.a" "${libs[@]}"
  echo "libmesa_viva.a: $(ar t "$OUT/lib/libmesa_viva.a" | wc -l) members"
  nm "$OUT/lib/libmesa_viva.a" 2>/dev/null | grep -c " T _nir_builder_init_simple_shader" || echo "nir_builder_init_simple_shader MISSING"
}

# Rebuild OUT only when it is missing or older than any of the following files (incremental CI runs).
stale() {
  local out=$1; shift
  [ -f "$out" ] || return 0
  local f
  for f in "$@"; do [ "$f" -nt "$out" ] && return 0; done
  return 1
}

driver() {
  local CF
  CF="$(sed -e 's/-std=[a-z0-9]*//' "$GPU/mesa/out/macos/cflags.txt" | tr '\n' ' ' | sed "s|$GPU/mesa/out/macos/include/build|$GPU/mesa/build-ios|g; s|-DHAVE_LLVMPIPE||; s|-DDRAW_LLVM_AVAILABLE=1||; s|-DLLVM_IS_SHARED=1||")"
  local OBJ="$OUT/obj"; mkdir -p "$OBJ"
  local vh=("$GPU/vgpu/vgpu.h" "$GPU/vgpu/iokit_compat.h" "$GPU/uapi/viva_gpu_uapi.h")
  local dh=("$GPU/driver/vmg.h" "$GPU/driver/vmg_internal.h" "$GPU/driver/vmg_llvm.h")
  for f in "$GPU/libdrm-xnu/src/xf86drm_xnu.c" "$GPU/vgpu/vgpu.c" "$GPU/vgpu/vgpu_mock.c" "$GPU/vgpu/vgpu_iokit.c"; do
    local o="$OBJ/$(basename "${f%.c}").o"
    stale "$o" "$f" "${vh[@]}" || continue
    echo "cc $(basename "$f")"
    $CC $TARGET -O2 -g -Wall -Wno-four-char-constants -I"$GPU/libdrm-xnu/include" -I"$GPU/libdrm-xnu/include/libdrm" -c "$f" -o "$o"
  done
  for f in vmg_air vmg_screen vmg_exec; do
    stale "$OBJ/$f.o" "$GPU/driver/$f.c" "${dh[@]}" "${vh[@]}" || continue
    echo "cc $f.c"
    $CC $TARGET -std=gnu11 -O2 -g -DVMG_HAVE_LLVMPIPE=0 $CF -I"$GPU/driver" -c "$GPU/driver/$f.c" -o "$OBJ/$f.o"
  done
  if stale "$OBJ/vmg_formats.o" "$GPU/driver/vmg_formats.m" "${dh[@]}"; then
    echo "cc vmg_formats.m"
    $CC $TARGET -fobjc-arc -O2 -g -DVMG_HAVE_LLVMPIPE=0 $CF -c "$GPU/driver/vmg_formats.m" -o "$OBJ/vmg_formats.o"
  fi
  local B="$OUT/VivaMTLDriver.bundle"
  rm -rf "$B"; mkdir -p "$B"
  $CC $TARGET -fobjc-arc -O2 -g -bundle -Wno-deprecated-declarations -I"$GPU/driver/metal" -I"$GPU/driver" \
      "$GPU"/driver/metal/*.m "$OBJ"/*.o $(cat "$OUT/lib/mesa-libs.txt") -lz -lc++ \
      -framework Foundation -framework Metal -framework IOSurface -framework IOKit -framework QuartzCore -framework CoreGraphics \
      -o "$B/VivaMTLDriver"
  sed "s/BUILD_VERSION/$(date +%Y%m%d.%H%M)/" "$HERE/Info.plist" > "$B/Info.plist"
  rm -rf "$OUT/VivaMTLDriver.dSYM"; [ -d "$B/VivaMTLDriver.dSYM" ] && mv "$B/VivaMTLDriver.dSYM" "$OUT/"   # symbols stay off the phone
  codesign -s - -f "$B"
  echo "bundle: $B"
}

tests() {
  local T="$OUT/tests"; mkdir -p "$T"
  $CC $TARGET -O2 -g "$GPU/vgpu/test_vgpu.c" "$GPU/vgpu/vgpu.c" "$GPU/vgpu/vgpu_mock.c" "$GPU/vgpu/vgpu_iokit.c" \
      -framework IOKit -framework IOSurface -framework CoreFoundation -o "$T/test_vgpu"
  # metal-shim's tests against the installed driver: on the phone Metal finds VMDevice through the kernel
  # service; TSMtlCreateDevice comes from a small shim that returns MTLCreateSystemDefaultDevice().
  echo '#import <Metal/Metal.h>
id<MTLDevice> TSMtlCreateDevice(void) { return MTLCreateSystemDefaultDevice(); }
void TSMtlRegisterGLSL(id a, id b) {}' > "$OUT/obj/tsdevice.m"
  for t in phase1 phase2:phase3 translate uploads; do   # SOURCE:NAME (phase2.m is the Mac's "phase3")
    src=${t%%:*} name=${t##*:}
    $CC $TARGET -fobjc-arc -O1 -g -I"$HERE/compat" -I"$GPU/shim/src" -DTS_SOURCE_DIR=\"/var/root/viva-tests\" \
        "$GPU/shim/tests/$src.m" "$OUT/obj/tsdevice.m" -framework Foundation -framework Metal -framework IOSurface \
        -framework CoreGraphics -framework ImageIO -framework UIKit -o "$T/$name" || echo "($name does not build for iOS)"
  done
  $CC $TARGET -fobjc-arc -O1 -g "$HERE/vmprobe.m" -framework Foundation -framework Metal -o "$T/vmprobe"
  $CC $TARGET -fobjc-arc -O1 -g "$GPU/driver/tests/compute.m" "$OUT/obj/tsdevice.m" -framework Foundation -framework Metal -o "$T/compute"
  $CC $TARGET -fobjc-arc -O1 -g "$GPU/driver/tests/ca.m" "$OUT/obj/tsdevice.m" -framework Foundation -framework Metal \
      -framework QuartzCore -framework CoreGraphics -framework ImageIO -framework CoreText -framework UniformTypeIdentifiers \
      -framework IOSurface -o "$T/ca"
  # vctl: drives the UI (touches, home, launching apps) for tests on real screens; entitlements for HID dispatch.
  $CC $TARGET -fobjc-arc -O1 -g "$HERE/vctl.m" -framework Foundation -framework IOKit -framework IOSurface -framework CoreGraphics -framework ImageIO -o "$T/vctl"
  for f in "$T"/*; do [ "$f" = "$T/vctl" ] || codesign -s - -f "$f"; done
  codesign -s - -f --entitlements "$HERE/vctl.entitlements" "$T/vctl"
}

case "${1:-all}" in
  mesa) mesa ;; driver) driver ;; tests) tests ;;
  all) mesa; driver; tests ;;
  *) echo "usage: $0 [all|mesa|driver|tests]" >&2; exit 2 ;;
esac
