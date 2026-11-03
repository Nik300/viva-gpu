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
CC="xcrun --sdk iphoneos clang"
TARGET="-target arm64-apple-ios16.0 -isysroot $SDK"
mkdir -p "$OUT"

mesa() {
  # Host tools (mesa_clc, vtn_bindgen2, panfrost_compile) come from the macOS build.
  [ -x "$GPU/mesa/build-macos/src/panfrost/clc/panfrost_compile" ] || bash "$GPU/mesa/build.sh" macos-nosmoke
  sed -e "s|@IOS_SDK@|$SDK|" -e "s|@GPU@|$GPU|" "$GPU/mesa/cross/ios-arm64.ini" > "$OUT/ios-arm64.ini"
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
  libtool -static -o "$OUT/lib/libmesa_viva.a" $(cd "$B" && for t in $targets; do echo "$B/$t"; done) 2>/dev/null
}

driver() {
  local CF
  CF="$(sed -e 's/-std=[a-z0-9]*//' "$GPU/mesa/out/macos/cflags.txt" | tr '\n' ' ' | sed "s|$GPU/mesa/out/macos/include/build|$GPU/mesa/build-ios|g; s|-DHAVE_LLVMPIPE||; s|-DDRAW_LLVM_AVAILABLE=1||; s|-DLLVM_IS_SHARED=1||")"
  local OBJ="$OUT/obj"; mkdir -p "$OBJ"
  for f in "$GPU/libdrm-xnu/src/xf86drm_xnu.c" "$GPU/vgpu/vgpu.c" "$GPU/vgpu/vgpu_mock.c" "$GPU/vgpu/vgpu_iokit.c"; do
    $CC $TARGET -O2 -g -Wall -Wno-four-char-constants -I"$GPU/libdrm-xnu/include" -I"$GPU/libdrm-xnu/include/libdrm" \
        -c "$f" -o "$OBJ/$(basename "${f%.c}").o"
  done
  for f in vmg_air vmg_screen vmg_exec; do
    $CC $TARGET -std=gnu11 -O2 -g -DVMG_HAVE_LLVMPIPE=0 $CF -I"$GPU/driver" -c "$GPU/driver/$f.c" -o "$OBJ/$f.o"
  done
  $CC $TARGET -fobjc-arc -O2 -g -DVMG_HAVE_LLVMPIPE=0 $CF -c "$GPU/driver/vmg_formats.m" -o "$OBJ/vmg_formats.o"
  local B="$OUT/VivaMTLDriver.bundle"
  rm -rf "$B"; mkdir -p "$B"
  $CC $TARGET -fobjc-arc -O2 -g -bundle -Wno-deprecated-declarations -I"$GPU/driver/metal" -I"$GPU/driver" \
      "$GPU"/driver/metal/*.m "$OBJ"/*.o "$OUT/lib/libmesa_viva.a" -lz -lc++ \
      -framework Foundation -framework Metal -framework IOSurface -framework IOKit -framework QuartzCore -framework CoreGraphics \
      -o "$B/VivaMTLDriver"
  sed "s/BUILD_VERSION/$(date +%Y%m%d.%H%M)/" "$HERE/Info.plist" > "$B/Info.plist"
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
  for t in phase1 translate uploads; do
    $CC $TARGET -fobjc-arc -O1 -g -I"$GPU/shim/src" -DTS_SOURCE_DIR=\"/var/root/viva-tests\" "$GPU/shim/tests/$t.m" \
        "$OUT/obj/tsdevice.m" -framework Foundation -framework Metal -framework UIKit -o "$T/$t" || echo "($t needs porting: AppKit)"
  done
  $CC $TARGET -fobjc-arc -O1 -g "$HERE/vmprobe.m" -framework Foundation -framework Metal -o "$T/vmprobe"
  $CC $TARGET -fobjc-arc -O1 -g "$GPU/driver/tests/compute.m" "$OUT/obj/tsdevice.m" -framework Foundation -framework Metal -o "$T/compute"
  for f in "$T"/*; do codesign -s - -f "$f"; done
}

case "${1:-all}" in
  mesa) mesa ;; driver) driver ;; tests) tests ;;
  all) mesa; driver; tests ;;
  *) echo "usage: $0 [all|mesa|driver|tests]" >&2; exit 2 ;;
esac
