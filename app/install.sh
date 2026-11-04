#!/bin/bash
# Installs app/out/VivaManager.tar on the phone over the USB link (fork/tools/viva-link.py, vivad):
# /var/jb/Applications/VivaManager.app, vmhelper setuid root, registered with uicache.
#   app/install.sh [TAR]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TAR="${1:-$HERE/out/VivaManager.tar}"
LINK="${VIVA_LINK:-$HERE/../../fork/tools/viva-link.py}"
python3 "$LINK" push "$TAR" /private/var/mobile/VivaManager.tar 644
python3 "$LINK" run -- /var/jb/bin/sh -c '
set -e
export PATH=/var/jb/usr/bin:/var/jb/bin:/var/jb/usr/sbin:/usr/bin:/bin:/usr/sbin
cd /var/jb/Applications
rm -rf VivaManager.app
tar xf /private/var/mobile/VivaManager.tar
chown -R root:wheel VivaManager.app
chmod 755 VivaManager.app/VivaManager
chmod 4755 VivaManager.app/vmhelper
rm -f /private/var/mobile/VivaManager.tar
uicache -p /var/jb/Applications/VivaManager.app
ls -l VivaManager.app/vmhelper'
