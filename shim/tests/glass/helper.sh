#!/bin/zsh
# TeraScale Glass, app side (src/TSGlassSidebar.m) in a process like Chrome's GPU helper (tests/glass/helper.m): the
# driver bundle, with System.Glass on, must not give that process an NSApplication.
set -euo pipefail
ROOT=${0:A:h:h:h}
WORK=$(mktemp -d /tmp/tsglass-helper.XXXXXX)
trap 'rm -rf $WORK' EXIT
/usr/libexec/PlistBuddy -c "Add :System dict" -c "Add :System:Glass dict" -c "Add :System:Glass:Enabled bool true" $WORK/policy.plist >/dev/null
TSMTL_CONFIG_DIR=$WORK $ROOT/build/glasshelper $ROOT/build/TeraScaleMTLDriver.bundle/Contents/MacOS/TeraScaleMTLDriver
