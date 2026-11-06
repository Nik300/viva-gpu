#!/bin/bash
# Adds LC_LOAD_WEAK_DYLIB <dylib> to a copy of the phone's SpringBoard and re-signs it ad hoc with the original
# identifier and entitlements (the viva kernel treats every signed binary on the root fs as a platform binary).
# Weak: if the dylib is missing SpringBoard starts as before. Runs on the Mac; never talks to the phone.
#
#   app/tweak/inject.sh SPRINGBOARD_IN [OUT] [DYLIB_PATH]
#     SPRINGBOARD_IN  pulled from the phone: viva-link.py pull /System/Library/CoreServices/SpringBoard.app/SpringBoard X
#     OUT             default: app/out/SpringBoard.patched
#     DYLIB_PATH      default: /var/jb/usr/lib/VivaIsland.dylib
# Install/restore on the phone: docs/DYNAMIC-ISLAND.md ("Installazione"), tweak/vi-sb.sh.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
IN="${1:?usage: inject.sh SPRINGBOARD_IN [OUT] [DYLIB_PATH]}"
OUT="${2:-$HERE/../out/SpringBoard.patched}"
DYLIB="${3:-/var/jb/usr/lib/VivaIsland.dylib}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

[ -f "$IN" ] || { echo "inject.sh: $IN not found" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")"

# 1. Identity of the original signature.
ID="$(codesign -dv "$IN" 2>&1 | sed -n 's/^Identifier=//p')"
[ -n "$ID" ] || { echo "inject.sh: $IN is not signed (no identifier)" >&2; exit 1; }
codesign -d --entitlements - --xml "$IN" > "$TMP/ent.plist" 2>/dev/null || true
if ! plutil -lint "$TMP/ent.plist" >/dev/null 2>&1; then           # older codesign: ':-' prints the XML plist
  codesign -d --entitlements :- "$IN" > "$TMP/ent.plist" 2>/dev/null
fi
plutil -lint "$TMP/ent.plist" >/dev/null || { echo "inject.sh: could not extract the entitlements" >&2; exit 1; }
NENT="$(python3 -c 'import plistlib,sys; print(len(plistlib.load(open(sys.argv[1],"rb"))))' "$TMP/ent.plist")"
echo "original: identifier $ID, $NENT entitlements"

# 2. Unsigned copy, then the load command.
cp "$IN" "$TMP/SpringBoard"
chmod u+w "$TMP/SpringBoard"
codesign --remove-signature "$TMP/SpringBoard"
python3 - "$TMP/SpringBoard" "$DYLIB" <<'PY'
import struct, sys
path, dylib = sys.argv[1], sys.argv[2]
data = bytearray(open(path, 'rb').read())
magic, = struct.unpack_from('<I', data, 0)
if magic != 0xfeedfacf:
    sys.exit('inject: not a thin 64-bit little-endian Mach-O (magic %#x)' % magic)
cputype, cpusub, filetype, ncmds, sizeofcmds, flags, _ = struct.unpack_from('<iiIIIII', data, 4)
HDR = 32
LC_SEGMENT_64, LC_REQ_DYLD = 0x19, 0x80000000
LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT, LC_LOAD_UPWARD, LC_LAZY = 0xc, 0x18 | LC_REQ_DYLD, 0x1f | LC_REQ_DYLD, 0x23 | LC_REQ_DYLD, 0x20
first_data = len(data)          # lowest file offset of section/segment content: the room ends there
off = HDR
for _ in range(ncmds):
    cmd, size = struct.unpack_from('<II', data, off)
    if cmd in (LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_REEXPORT, LC_LOAD_UPWARD, LC_LAZY):
        name_off, = struct.unpack_from('<I', data, off + 8)
        name = bytes(data[off + name_off: off + size]).split(b'\0')[0].decode()
        if name == dylib:
            sys.exit('inject: %s already has a load command for %s' % (path, dylib))
    if cmd == LC_SEGMENT_64:
        segname = data[off + 8: off + 24].rstrip(b'\0').decode()
        fileoff, filesize = struct.unpack_from('<QQ', data, off + 40)
        nsects, = struct.unpack_from('<I', data, off + 64)
        if filesize and fileoff and segname != '__PAGEZERO':
            first_data = min(first_data, fileoff)
        for i in range(nsects):
            s = off + 72 + i * 80
            sect_off, = struct.unpack_from('<I', data, s + 48)
            sflags, = struct.unpack_from('<I', data, s + 64)
            if sect_off and (sflags & 0xff) not in (0x1, 0xc, 0x12):   # skip zerofill / gb zerofill / tlv zerofill
                first_data = min(first_data, sect_off)
    off += size
end = HDR + sizeofcmds
assert off == end, 'load commands do not add up'
name = dylib.encode() + b'\0'
cmdsize = (24 + len(name) + 7) & ~7
room = first_data - end
print('header: %d load commands, %d bytes, room %d bytes, new command %d bytes' % (ncmds, sizeofcmds, room, cmdsize))
if room < cmdsize:
    sys.exit('inject: not enough header padding (%d < %d)' % (room, cmdsize))
if any(data[end:end + cmdsize]):
    sys.exit('inject: header padding is not zero')
# dylib_command: cmd, cmdsize, name.offset, timestamp, current_version, compatibility_version. Compatibility 0 asks
# for nothing (a dylib whose compatibility version is lower than the one recorded here would be refused).
lc = struct.pack('<IIIIII', LC_LOAD_WEAK_DYLIB, cmdsize, 24, 2, 0x10000, 0) + name
lc += b'\0' * (cmdsize - len(lc))
data[end:end + cmdsize] = lc
struct.pack_into('<II', data, 16, ncmds + 1, sizeofcmds + cmdsize)
open(path, 'wb').write(data)
PY

# 3. Ad-hoc signature with the original identifier and entitlements.
codesign -f -s - -i "$ID" --entitlements "$TMP/ent.plist" "$TMP/SpringBoard"

# 4. Checks: the load command, the identifier, the entitlements unchanged.
otool -l "$TMP/SpringBoard" | grep -A3 LC_LOAD_WEAK_DYLIB | grep -q "name $DYLIB " || { echo "inject.sh: load command missing" >&2; exit 1; }
NID="$(codesign -dv "$TMP/SpringBoard" 2>&1 | sed -n 's/^Identifier=//p')"
[ "$NID" = "$ID" ] || { echo "inject.sh: identifier changed: $NID" >&2; exit 1; }
codesign -d --entitlements - --xml "$TMP/SpringBoard" > "$TMP/ent2.plist" 2>/dev/null || codesign -d --entitlements :- "$TMP/SpringBoard" > "$TMP/ent2.plist"
python3 -c 'import plistlib,sys; a,b=(plistlib.load(open(f,"rb")) for f in sys.argv[1:]); sys.exit(a!=b)' \
  "$TMP/ent.plist" "$TMP/ent2.plist" || { echo "inject.sh: entitlements differ after signing" >&2; exit 1; }
codesign -v "$TMP/SpringBoard"
cp "$TMP/SpringBoard" "$OUT"
echo "ok: $OUT (LC_LOAD_WEAK_DYLIB $DYLIB, identifier $ID, entitlements preserved)"
otool -L "$OUT" | sed 1d
