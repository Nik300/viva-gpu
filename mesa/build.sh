#!/usr/bin/env bash
# Build Mesa (llvmpipe + panfrost/Valhall, static) for the ios-viva project.
#
#   ./build.sh macos         full build: venv, fetch+patch, configure, build,
#                            package out/macos, libdrm-xnu, smoke test
#   ./build.sh macos-nosmoke same without running the smoke test
#   ./build.sh clean         remove build-macos and out/ (keeps src and venv)
#   ./build.sh distclean     also remove src/
#   ./build.sh fn STEP...    run individual steps (configure_macos, build_macos, ...)
#
# Env: JOBS (default 8), LLVM_PREFIX (default /opt/homebrew/opt/llvm)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GPU="$(cd "$HERE/.." && pwd)"
VENV="$GPU/.venv"
SRC="$HERE/src"
LIBDRM="$GPU/libdrm-xnu"
MESA_TAG="mesa-26.2.6"
MESA_URL="https://gitlab.freedesktop.org/mesa/mesa.git"
JOBS="${JOBS:-8}"
LLVM_PREFIX="${LLVM_PREFIX:-/opt/homebrew/opt/llvm}"
BREW="${BREW_PREFIX:-/opt/homebrew}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- venv
setup_venv() {
  if [ ! -x "$VENV/bin/meson" ] || [ ! -x "$VENV/bin/ninja" ] || \
     ! "$VENV/bin/python3" -c 'import mako, yaml, packaging' 2>/dev/null; then
    log "creating venv $VENV"
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q --disable-pip-version-check \
      meson ninja mako pyyaml packaging
  fi
  export PATH="$VENV/bin:/usr/bin:/bin:/usr/sbin:/sbin:$BREW/bin"   # meson picks up ccache from $BREW/bin
}

# ------------------------------------------------------- host prerequisites
check_host() {
  [ -x "$LLVM_PREFIX/bin/llvm-config" ] || die "LLVM not found at $LLVM_PREFIX (brew install llvm)"
  # panfrost needs mesa_clc (clang + SPIRV-LLVM-Translator + SPIRV-Tools) at
  # build time to precompile the libpan OpenCL kernels.
  for f in spirv-llvm-translator spirv-tools zstd pkgconf; do
    [ -d "$BREW/opt/$f" ] || die "missing brew formula: $f (brew install $f)"
  done
}

# ---------------------------------------------------------- fetch + patch
fetch_and_patch() {
  if [ ! -d "$SRC/.git" ]; then
    log "cloning $MESA_TAG"
    git clone -q --depth 1 --branch "$MESA_TAG" "$MESA_URL" "$SRC"
  fi
  local p
  for p in "$HERE"/patches/*.patch; do
    [ -e "$p" ] || continue
    if git -C "$SRC" apply --check "$p" 2>/dev/null; then
      log "applying $(basename "$p")"
      git -C "$SRC" apply "$p"
    elif git -C "$SRC" apply --check -R "$p" 2>/dev/null; then
      : # already applied
    else
      die "patch $(basename "$p") neither applies nor is already applied"
    fi
  done
}

# ------------------------------------------------------------ libdrm-xnu
build_libdrm_xnu() {
  # libdrm for XNU: libdrm-xnu/src/xf86drm_xnu.c on the vgpu client (IOKit back-end, or the in-process mock).
  log "building libdrm-xnu"
  mkdir -p "$LIBDRM/out"
  local objs=()
  for src in "$LIBDRM/src/xf86drm_xnu.c" "$GPU/vgpu/vgpu.c" "$GPU/vgpu/vgpu_mock.c" "$GPU/vgpu/vgpu_iokit.c"; do
    local o="$LIBDRM/out/$(basename "${src%.c}").o"
    cc -O2 -g -Wall -Wno-unused-parameter -Wno-four-char-constants -fPIC \
       -I"$LIBDRM/include" -I"$LIBDRM/include/libdrm" -c "$src" -o "$o"
    objs+=("$o")
  done
  rm -f "$LIBDRM/out/libdrm-xnu.a"
  libtool -static -o "$LIBDRM/out/libdrm-xnu.a" "${objs[@]}" 2>/dev/null
}

# ------------------------------------------------------------- configure
MESON_OPTS=(
  --buildtype=release -Ddefault_library=static -Db_ndebug=true
  -Dc_args=-g0 -Dcpp_args=-g0
  -Dplatforms= -Dgallium-drivers=llvmpipe,panfrost -Dvulkan-drivers=
  -Dopengl=false -Dgles1=disabled -Dgles2=disabled -Degl=disabled
  -Dglx=disabled -Dgbm=disabled
  -Dllvm=enabled -Dshared-llvm=enabled
  -Dexpat=disabled -Dxmlconfig=disabled -Dvalgrind=disabled
  -Dlibunwind=disabled -Dlmsensors=disabled -Dbuild-tests=false -Dtools=
  -Dvideo-codecs= -Dgallium-va=disabled -Dperfetto=false -Dhtml-docs=disabled
  -Dzstd=enabled -Dzlib=enabled -Dshader-cache=enabled
)

configure_macos() {
  local B="$HERE/build-macos"
  export PKG_CONFIG_PATH="$LIBDRM/pkgconfig:$BREW/lib/pkgconfig"
  if [ -f "$B/build.ninja" ]; then
    log "reconfiguring $B"
    meson setup --reconfigure "$B" "$SRC" --native-file "$HERE/cross/macos-native.ini" "${MESON_OPTS[@]}" >/dev/null
  else
    log "configuring $B"
    meson setup "$B" "$SRC" --native-file "$HERE/cross/macos-native.ini" "${MESON_OPTS[@]}" >/dev/null
  fi
}

# Static libraries that make up libmesa_viva.a (paths relative to build dir).
# Frontends are disabled, so these are built as explicit ninja targets.
mesa_libs() {
  cat <<'EOF'
src/c11/impl/libmesa_util_c11.a
src/util/libmesa_util.a
src/util/libmesa_util_simd.a
src/util/blake3/libblake3.a
src/util/libxmlconfig.a
src/util/libparson.a
src/compiler/libcompiler.a
src/compiler/nir/libnir.a
src/compiler/spirv/libvtn.a
src/compiler/isaspec/libisaspec.a
src/gallium/auxiliary/libgallium.a
src/gallium/winsys/sw/null/libws_null.a
src/gallium/drivers/llvmpipe/libllvmpipe.a
src/panfrost/shared/libpanfrost_shared.a
src/panfrost/model/libpanfrost_model_lib.a
src/panfrost/compiler/libpanfrost_compiler.a
src/panfrost/compiler/bifrost/libpanfrost_bifrost.a
src/panfrost/compiler/bifrost/libpanfrost_bifrost_disasm.a
src/panfrost/compiler/bifrost/valhall/libpanfrost_valhall_disasm.a
src/panfrost/compiler/midgard/libpanfrost_midgard.a
src/panfrost/compiler/midgard/libpanfrost_midgard_disasm.a
src/panfrost/genxml/libpanfrost_decode.a
src/panfrost/lib/libpanfrost_lib.a
src/panfrost/lib/kmod/libpankmod_lib.a
src/panfrost/perf/libpanfrost_perf.a
src/gallium/winsys/panfrost/drm/libpanfrostwinsys.a
src/gallium/drivers/panfrost/libpanfrost.a
EOF
  local v
  for v in 4 5 6 7 9 10 12 13 14; do
    echo "src/panfrost/genxml/libpandecode-arch-v$v.a"
    echo "src/panfrost/lib/libpan-arch-v$v.a"
    [ "$v" = 4 ] || echo "src/panfrost/lib/libpan-format-v$v.a"
    echo "src/gallium/drivers/panfrost/libpanfrost-v$v.a"
  done
}

build_macos() {
  local B="$HERE/build-macos"
  log "building ($JOBS jobs)"
  # shellcheck disable=SC2046
  ninja -C "$B" -j"$JOBS" ${NINJA_FLAGS:-} $(mesa_libs)
}

# --------------------------------------------------------------- package
package_macos() {
  local B="$HERE/build-macos" O="$HERE/out/macos"
  log "packaging $O"
  rm -rf "$O"; mkdir -p "$O/lib" "$O/include/src" "$O/include/build"

  local libs=() l
  while read -r l; do libs+=("$B/$l"); done < <(mesa_libs)
  # libtool warns about duplicate member names across archives; harmless.
  libtool -static -no_warning_for_no_symbols -o "$O/lib/libmesa_viva.a" "${libs[@]}" 2>/dev/null

  # Headers: copy whole trees, preserving paths relative to src/ and build/.
  ( cd "$SRC" && find include src/util src/c11 src/compiler src/gallium/include \
        src/gallium/auxiliary src/gallium/drivers/llvmpipe src/gallium/drivers/panfrost \
        src/gallium/winsys/sw/null src/gallium/winsys/panfrost src/panfrost \
        \( -name '*.h' -o -name '*.hpp' \) -print0 | \
      xargs -0 -I{} rsync -R -q {} "$O/include/src/" )
  ( cd "$B" && find src \( -name '*.h' \) -not -path '*.p/*' -print0 | \
      xargs -0 -I{} rsync -R -q {} "$O/include/build/" )

  local I="$O/include" defs
  # Global Mesa defines (struct layouts depend on some of them, e.g. NDEBUG,
  # HAVE_STRUCT_TIMESPEC): take them from a real compile command.
  defs="$("$VENV/bin/python3" - "$B/compile_commands.json" <<'PY'
import json, sys
skip = {'-DBUILDING_MESA', '-DGALLIUM_PANFROST', '-DVK_ENABLE_BETA_EXTENSIONS'}
for c in json.load(open(sys.argv[1])):
    if c['file'].endswith('drivers/panfrost/pan_shader.c'):
        print(' '.join(a for a in c['command'].split()
                       if a.startswith('-D') and a not in skip))
        break
PY
)"
  cat > "$O/cflags.txt" <<EOF
-std=c11 $defs
-I$I/src/include
-I$I/src/src
-I$I/build/src
-I$I/src/src/gallium/include
-I$I/src/src/gallium/auxiliary
-I$I/build/src/gallium/auxiliary
-I$I/src/src/gallium/drivers
-I$I/src/src/gallium/winsys
-I$I/src/src/compiler
-I$I/build/src/compiler
-I$I/src/src/compiler/nir
-I$I/build/src/compiler/nir
-I$I/src/src/panfrost
-I$I/build/src/panfrost
-I$I/src/src/panfrost/compiler
-I$I/build/src/panfrost/compiler
-I$I/src/src/panfrost/compiler/bifrost
-I$I/build/src/panfrost/compiler/bifrost
-I$I/src/src/panfrost/lib
-I$I/build/src/panfrost/lib
-I$I/src/src/panfrost/shared
-I$I/src/src/panfrost/model
-I$I/build/src/panfrost/genxml
EOF
  local llvm_libs
  llvm_libs="$("$LLVM_PREFIX/bin/llvm-config" --link-shared --ldflags --libs core 2>/dev/null | tr '\n' ' ')"
  cat > "$O/ldflags.txt" <<EOF
$O/lib/libmesa_viva.a
$LIBDRM/out/libdrm-xnu.a
$llvm_libs -Wl,-rpath,$LLVM_PREFIX/lib
-L$BREW/opt/zstd/lib -lzstd -lz -lc++ -lpthread -lm -framework IOKit -framework IOSurface -framework CoreFoundation
EOF
}

# ---------------------------------------------------------- smoke test
smoke_macos() {
  log "building + running smoke test"
  make -s -C "$HERE/tests" OUT="$HERE/out/macos" clean all
  "$HERE/tests/smoke"
}

case "${1:-}" in
  macos|macos-nosmoke)
    setup_venv; check_host; fetch_and_patch
    build_libdrm_xnu
    configure_macos; build_macos; package_macos
    "$LIBDRM/collect-symbols.sh"
    [ "$1" = macos ] && smoke_macos
    log "done: $HERE/out/macos"
    ;;
  fn) # developer helper: run individual steps, e.g. ./build.sh fn build_macos
    shift; setup_venv; for f in "$@"; do "$f"; done ;;
  clean) rm -rf "$HERE/build-macos" "$HERE/out" "$LIBDRM/out" ;;
  distclean) rm -rf "$HERE/build-macos" "$HERE/out" "$LIBDRM/out" "$SRC" ;;
  *) echo "usage: $0 macos|macos-nosmoke|clean|distclean" >&2; exit 2 ;;
esac
