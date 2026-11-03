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

# Write to a temporary name, check that every block is covered, then rename: an interrupted conversion must not
# leave a truncated OUT.simg (fastboot then fails with "Failed reading from userdata").
python3 "$img2simg" "$out.img" "$out.simg.part"
python3 - "$out.simg.part" <<'PY'
import os, struct, sys
f = open(sys.argv[1], 'rb'); m, _, _, hs, cs, bs, tb, tc, _ = struct.unpack('<IHHHHIIII', f.read(28))
f.seek(hs); n = 0
for _ in range(tc):
    h = f.read(cs)
    if len(h) < cs: sys.exit('truncated sparse image')
    t, _, b, tot = struct.unpack('<HHII', h); f.seek(tot - cs, 1); n += b
if m != 0xed26ff3a or n != tb or f.tell() != os.path.getsize(sys.argv[1]): sys.exit('invalid sparse image')
print('sparse image ok: %d blocks' % n)
PY
mv "$out.simg.part" "$out.simg"
chown "${SUDO_USER:-root}" "$out.img" "$out.simg" 2>/dev/null || true
ls -la "$out.img" "$out.simg"
echo "flash: fastboot -S 512M flash userdata $out.simg"
echo "(the conversion takes a few minutes: run it in a terminal, not through a short-lived command)"
