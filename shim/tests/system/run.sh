#!/bin/zsh
# Phase 4 checks through Metal.framework's own driver discovery, with build/libTSRegSim.dylib standing in
# for the kext properties and the /Library/GPUBundles install (no system change). Prints N/M checks passed.
B=${0:A:h:h:h}/build
T=$(mktemp -d)
trap 'rm -rf $T' EXIT
pass=0 total=0
check() { (( total++ )); if eval "$2"; then (( pass++ )); else echo "FAIL: $1"; fi }
policy() {   # policy <dir> <id> <true|false>
  mkdir -p $1
  printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Version</key><integer>1</integer><key>AutoEnable</key><true/><key>Apps</key><dict><key>%s</key><dict><key>Enabled</key><%s/></dict></dict></dict></plist>' $2 $3 > $1/policy.plist
}
run() {   # run <bundle> <config dir> <exe> <expected devices>
  TSMTL_SIM_BUNDLE=$1 TSMTL_CONFIG_DIR=$2 DYLD_INSERT_LIBRARIES=$B/libTSRegSim.dylib $3 $4 2>/dev/null
}
policy $T/on proc:systest true
policy $T/off proc:systest false
policy $T/ws proc:WindowServer true
cp $B/systest $T/WindowServer

out=$(run $B/TeraScaleMTLDriver.bundle $T/on $B/systest 1)
check "enabled: one TSMtlDevice" '[[ $out == *"device class=TSMtlDevice"* && $out == *"devices=1"* ]]'
check "enabled: default device is the same object" '[[ $out == *"default=TSMtlDevice same=1"* ]]'
check "enabled: SkyLight display device is the same object" '[[ $out == *"display device=TSMtlDevice same=1"* ]]'
check "enabled: clear through a render pass" '[[ $out == *"clear pixel=64,128,255,255 status=4"* ]]'
out=$(run $B/TeraScaleMTLDriver.bundle $T/empty $B/systest 0)
check "outside the Applications folders: no device" '[[ $out == *"devices=0"* && $out == *"default=nil"* ]]'
out=$(run $B/TeraScaleMTLDriver.bundle $T/off $B/systest 0)
check "disabled in the list: no device" '[[ $out == *"devices=0"* ]]'
out=$(run $B/TeraScaleMTLDriver.bundle $T/ws $T/WindowServer 0)
check "WindowServer: never, even if listed" '[[ $out == *"devices=0"* ]]'
out=$(run none $T/on $B/systest 0)
check "bundle not installed: no device, no crash" '[[ $out == *"devices=0"* ]]'
# TeraScale Compute: System.Compute (global switch, per-app entry), TSMTL_COMPUTE overriding both; the old
# Experimental.Compute (drivers up to 0.9.0) still read when System.Compute is absent.
compute_policy() {   # compute_policy <dir> <global true|false> [<app entry true|false|""> [<parent key>]]
  mkdir -p $1
  local entry=""
  [[ -n ${3:-} ]] && entry="<key>proc:systest</key><dict><key>Enabled</key><$3/></dict>"
  printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>Version</key><integer>1</integer><key>AutoEnable</key><true/><key>Apps</key><dict><key>proc:systest</key><dict><key>Enabled</key><true/></dict></dict><key>%s</key><dict><key>Compute</key><dict><key>Enabled</key><%s/><key>Apps</key><dict>%s</dict></dict></dict></dict></plist>' ${4:-System} $2 "$entry" > $1/policy.plist
}
compute_policy $T/c-global true
compute_policy $T/c-except true false
compute_policy $T/c-app false true
compute_policy $T/c-legacy false "" Experimental
out=$(run $B/TeraScaleMTLDriver.bundle $T/on $B/systest 1)
check "compute: on by default (no System.Compute), kernel runs on OpenCL" '[[ $out == *"compute path=cl value=190"* ]]'
out=$(run $B/TeraScaleMTLDriver.bundle $T/c-legacy $B/systest 1)
check "compute: old Experimental.Compute still read (off for all apps)" '[[ $out == *"compute path=off value=0"* ]]'
out=$(run $B/TeraScaleMTLDriver.bundle $T/c-global $B/systest 1)
check "compute: on for all apps, kernel runs on OpenCL" '[[ $out == *"compute path=cl value=190"* ]]'
out=$(run $B/TeraScaleMTLDriver.bundle $T/c-except $B/systest 1)
check "compute: on for all apps, off for this one" '[[ $out == *"compute path=off value=0"* ]]'
out=$(run $B/TeraScaleMTLDriver.bundle $T/c-app $B/systest 1)
check "compute: off for all apps, on for this one" '[[ $out == *"compute path=cl value=190"* ]]'
out=$(TSMTL_COMPUTE=0 run $B/TeraScaleMTLDriver.bundle $T/c-app $B/systest 1)
check "compute: TSMTL_COMPUTE=0 wins over the policy" '[[ $out == *"compute path=off value=0"* ]]'
echo "$pass/$total checks passed"
(( pass == total ))
