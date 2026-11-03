#!/bin/zsh
# TeraScale Swift in the driver bundle: System.Swift policy, per-app entry, kill switch, env override, validation flag.
# Uses a temporary configuration (TSMTL_CONFIG_DIR) and the bundle in build/; TSMTL_LOG=1 copies the log to stderr.
ROOT=${0:A:h:h:h}; OUT=$ROOT/build/swift; BUNDLE=$ROOT/build/TeraScaleMTLDriver.bundle/Contents/MacOS/TeraScaleMTLDriver
mkdir -p $OUT; cc -O1 -Wall $ROOT/tests/swift/bundlehost.c -o $OUT/bundlehost || exit 1
CFG=$(mktemp -d); export TSMTL_CONFIG_DIR=$CFG TSMTL_LOG=1
fail=0
policy() { cat > $CFG/policy.plist <<P
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>System</key><dict><key>Swift</key><dict>$1</dict></dict></dict></plist>
P
}
expect() {   # name, expected "on/off reason", expected hooks
    local out=$($OUT/bundlehost $BUNDLE 2>&1)
    local line=$(print -r -- "$out" | grep -o "\(on\|off\) bundlehost pid=[0-9]* reason=[a-z-]* hooks=[0-9] validate=[01]" | head -1)
    local ans=$(print -r -- "$out" | grep "^answers")
    if [[ "$line" == *"$2"* && "$ans" == "answers ok hooks=$3"* ]]; then echo "  ok   $1: $line"
    else echo "  FAIL $1: wanted '$2' hooks=$3, got '$line' / '$ans'"; fail=1; fi
}
rm -f $CFG/policy.plist;                                       expect "no policy (on by default)" "reason=default hooks=3" 3
policy "";                                                     expect "no System.Swift.Enabled" "reason=default hooks=3" 3
policy "<key>Enabled</key><false/>";                           expect "global off"     "reason=global hooks=0" 0
policy "<key>Enabled</key><true/>";                            expect "global on"      "reason=global hooks=3 validate=0" 3
policy "<key>Enabled</key><true/><key>Validate</key><true/>";  expect "validation"     "validate=1" 3
policy "<key>Enabled</key><true/><key>Apps</key><dict><key>proc:bundlehost</key><dict><key>Enabled</key><false/></dict></dict>"
                                                               expect "app entry off"  "reason=list hooks=0" 0
policy "<key>Enabled</key><false/><key>Apps</key><dict><key>proc:bundlehost</key><dict><key>Enabled</key><true/></dict></dict>"
                                                               expect "app entry on"   "reason=list hooks=3" 3
policy "<key>Enabled</key><true/>"; mkdir -p $CFG/TeraScaleSwift; touch $CFG/TeraScaleSwift/DISABLE
                                                               expect "kill switch"    "reason=kill-switch hooks=0" 0
rm -f $CFG/TeraScaleSwift/DISABLE; policy "<key>Enabled</key><false/>"
TSMTL_SWIFT=1                                                  expect "env override"   "reason=env hooks=3" 3
rm -rf $CFG
[[ $fail == 0 ]] && echo "ok: policy, per-app entry, kill switch, env"
exit $fail
