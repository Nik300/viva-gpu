#!/bin/bash
# Builds a userdata image for viva with the Viva Metal driver installed:
#   /System/Library/Extensions/VivaMTLDriver.bundle   (Metal loads it once the kernel publishes VivaGPUAccelerator)
#   /private/var/root/viva-tests/                     (vmprobe, test_vgpu, compute, ... from ios/build.sh)
#
#   sudo ios/mkuserdata.sh BASE.img DIST OUT          (DIST = the CI artifact "viva-gpu-ios", unpacked)
#
# BASE.img is never modified: OUT.img is an APFS clone of it (no space until written), mounted read/write, filled,
# detached, then converted to OUT.simg (Android sparse) for `fastboot flash userdata OUT.simg`. A full image is
# required: the phone's userdata already differs from BASE.img (iOS writes on every boot), so a block delta
# against BASE.img would corrupt the HFS+ volume. Flashing resets iOS to the image's state (slow first boot).
set -euo pipefail
[[ $# -eq 3 ]] || { sed -n '2,13p' "$0"; exit 2; }
[[ $EUID == 0 ]] || { echo "run with sudo (files must be owned by root)" >&2; exit 1; }
base=$1 dist=$2 out=$3
here=$(cd "$(dirname "$0")" && pwd)
img2simg="$here/../../fork/tools/viva-img2simg.py"
[[ -f $base ]] || { echo "no base image $base" >&2; exit 1; }
[[ -d $dist/VivaMTLDriver.bundle ]] || { echo "$dist has no VivaMTLDriver.bundle" >&2; exit 1; }
[[ -f $img2simg ]] || { echo "missing $img2simg" >&2; exit 1; }
[[ ! -e $out.img && ! -e $out.simg ]] || { echo "refusing to overwrite $out.img / $out.simg" >&2; exit 1; }

cp -c "$base" "$out.img"            # APFS clone: instant, shares blocks with the base
mnt=$(mktemp -d /tmp/viva-userdata.XXXXXX)
dev=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nobrowse -owners on -mountpoint "$mnt" "$out.img" | awk 'NR==1{print $1}')
trap 'hdiutil detach "$dev" >/dev/null 2>&1 || true; rmdir "$mnt" 2>/dev/null || true' EXIT
[[ -d $mnt/System/Library/Extensions ]] || { echo "$out.img does not look like the iOS root" >&2; exit 1; }

ext="$mnt/System/Library/Extensions/VivaMTLDriver.bundle"
rm -rf "$ext"
cp -R "$dist/VivaMTLDriver.bundle" "$ext"
chown -R root:wheel "$ext"
chmod -R u=rwX,go=rX "$ext"
tests="$mnt/private/var/root/viva-tests"
mkdir -p "$tests"
[[ -d $dist/tests ]] && cp -R "$dist/tests/." "$tests/"
chown -R root:wheel "$tests"
chmod -R u=rwx,go=rx "$tests"
echo "installed:"; ls -la "$ext" "$tests"
sync
hdiutil detach "$dev"
trap - EXIT
rmdir "$mnt" 2>/dev/null || true

python3 "$img2simg" "$out.img" "$out.simg"
chown "${SUDO_USER:-root}" "$out.img" "$out.simg" 2>/dev/null || true
ls -la "$out.img" "$out.simg"
echo "flash: fastboot -S 512M flash userdata $out.simg"
