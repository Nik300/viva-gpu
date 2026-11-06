#!/bin/bash
# Installs app/out/VivaManager.tar on the phone over the USB link (fork/tools/viva-link.py, vivad):
# /var/jb/Applications/VivaManager.app, vmhelper setuid root, registered with uicache. The SpringBoard tweak in the
# bundle goes to /var/jb/usr/lib/VivaIsland.dylib and its script to /var/jb/usr/libexec/vi-sb.sh (SpringBoard loads
# the dylib only once patched: docs/DYNAMIC-ISLAND.md; a running SpringBoard keeps the old copy until it restarts).
#   app/install.sh [TAR]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TAR="${1:-$HERE/out/VivaManager.tar}"
LINK="${VIVA_LINK:-$HERE/../../fork/tools/viva-link.py}"
python3 "$LINK" push "$TAR" /private/var/mobile/VivaManager.tar 644
# vivad takes one command per line: everything on one line.
python3 "$LINK" run -- /var/jb/bin/sh -c "export PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/usr/bin:/bin:/usr/sbin; \
cd /var/jb/Applications && rm -rf VivaManager.app && tar xf /private/var/mobile/VivaManager.tar && \
chown -R root:wheel VivaManager.app && chmod 4755 VivaManager.app/vmhelper && rm -f /private/var/mobile/VivaManager.tar && \
uicache -p /var/jb/Applications/VivaManager.app && ls -l VivaManager.app/vmhelper"
# vivad lines are cut at ~480 characters: the tweak goes in separate short commands.
A=/var/jb/Applications/VivaManager.app
python3 "$LINK" run -- /var/jb/bin/cp $A/VivaIsland.dylib /var/jb/usr/lib/VivaIsland.dylib.new
python3 "$LINK" run -- /var/jb/bin/mv -f /var/jb/usr/lib/VivaIsland.dylib.new /var/jb/usr/lib/VivaIsland.dylib
python3 "$LINK" run -- /var/jb/bin/mkdir -p /var/jb/usr/libexec
python3 "$LINK" run -- /var/jb/bin/cp $A/vi-sb.sh /var/jb/usr/libexec/vi-sb.sh
python3 "$LINK" run -- /var/jb/bin/sh -c "PATH=/var/jb/usr/bin:/var/jb/bin chmod 755 /var/jb/usr/lib/VivaIsland.dylib /var/jb/usr/libexec/vi-sb.sh"
