#!/bin/zsh
# Runs an app with the TeraScale Metal shim injected, without touching the system:
#   1. copies the .app into ~/metal-shim/apps (the original is never modified),
#   2. re-signs only the copy ad-hoc without hardened runtime, so dyld honours
#      DYLD_INSERT_LIBRARIES (entitlements are kept unless --no-entitlements),
#   3. launches the copy with build/libTSMetalInject.dylib and TSMTL_LOG=1.
# Apple apps (Maps, Find My) carry Apple-only entitlements that AMFI refuses on an ad-hoc signature:
# use --no-entitlements, plus --home so preferences and caches go to apps/home-<name>, not ~/Library.
# Copies register with LaunchServices under the original bundle id; when done testing, remove with
#   lsregister -u ~/metal-shim/apps/<App>.app   (lsregister lives in LaunchServices.framework/Support)
# Usage: shim-run.sh /Applications/Some.app [--no-entitlements] [--home] [--fresh] [--no-shim]
#                    [--model <hw.model>] [--fake-entitlements <prefix,...>] [--cl-probe] [-- app arguments]
#   --no-shim runs the same copy without the shim (baseline).
#   --model sets TSMTL_MACHINE_MODEL (Chrome: ANGLE refuses Metal on iMac12,1 by model; iMac19,1 works).
#   --fake-entitlements adds build/libTSEntSpoof.dylib (Find My: com.apple.findmy.).
#   --system goes through Metal.framework's own driver discovery instead of the interposer, as after the
#   Phase 4 install: build/libTSRegSim.dylib fakes the kext's IOAccelerator properties and points the
#   bundle lookup at build/TeraScaleMTLDriver.bundle; the copy is enabled in apps/system-config/policy.plist.
#   --cl-probe adds build/libTSCLProbe.dylib: 2 s after launch it runs OpenCL and the compute runtime inside the
#   app (sandbox included) and writes [TSCLProbe] lines to the log (TeraScale Compute, C0.2).
#   --compute / --no-compute: TeraScale Compute on / off for the copy (TSMTL_COMPUTE=1/0, which wins over the policy;
#   with --system the copy's entry in apps/system-config/policy.plist under System.Compute is set too).
set -e
SHIM_DIR="${0:A:h:h}"
APP="${1:?usage: shim-run.sh /path/to/App.app [options] [-- args]}"
shift
KEEP_ENT=1; FRESH=0; HOME_DIR=; SHIM=1; FAKE_ENT=; SYSTEM=0; CL_PROBE=0
while (( $# )); do
  opt=$1; shift
  case "$opt" in
    --) break ;;
    --no-shim) SHIM=0 ;;
    --system) SYSTEM=1 ;;
    --cl-probe) CL_PROBE=1 ;;
    --compute) export TSMTL_COMPUTE=1 ;;
    --no-compute) export TSMTL_COMPUTE=0 ;;
    --model) export TSMTL_MACHINE_MODEL="${1:?--model needs a value}"; shift ;;
    --fake-entitlements) FAKE_ENT="${1:?--fake-entitlements needs a value}"; shift ;;
    --no-entitlements) KEEP_ENT=0 ;;
    --fresh) FRESH=1 ;;
    --home) HOME_DIR=1 ;;
    *) echo "unknown option $opt" >&2; exit 2 ;;
  esac
done
# whatever is left in $@ goes to the app
NAME="${APP:t}"
COPY="$SHIM_DIR/apps/$NAME"
INJECT="$SHIM_DIR/build/libTSMetalInject.dylib"
[[ -f "$INJECT" ]] || { echo "build first: make -C $SHIM_DIR" >&2; exit 1; }

if [[ $FRESH == 1 || ! -d "$COPY" ]]; then
  echo "copying $APP -> $COPY"
  rm -rf "$COPY"
  mkdir -p "$SHIM_DIR/apps"
  cp -R "$APP" "$COPY"
  # App extensions of a copy would register with pluginkit next to the originals (Find My widgets,
  # notification services): a test copy keeps none.
  rm -rf "$COPY"/Contents/PlugIns/*.appex(N)
  xattr -cr "$COPY"   # codesign refuses Finder info / resource forks carried over from a DMG
  if [[ $KEEP_ENT == 1 ]]; then
    codesign --force --deep --sign - --options 0 --preserve-metadata=entitlements "$COPY"
  else
    codesign --force --deep --sign - --options 0 "$COPY"
  fi
fi

EXE="$COPY/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$COPY/Contents/Info.plist")"
LOG="$SHIM_DIR/apps/${NAME:r}.log"
if [[ -n $HOME_DIR ]]; then
  HOME_DIR="$SHIM_DIR/apps/home-${NAME:r}"
  mkdir -p "$HOME_DIR"
  export CFFIXED_USER_HOME="$HOME_DIR"
fi
echo "launching $EXE$([[ $SHIM == 1 ]] || echo " without shim") (log: $LOG${HOME_DIR:+, home: $HOME_DIR})"
if [[ $SHIM == 1 && $SYSTEM == 0 && -d /Library/GPUBundles/TeraScaleMTLDriver.bundle ]]; then
  # The installed driver can load in the same process as the injected copy (two sets of TSMtl classes).
  echo "warning: the system driver is installed; disable this app in tsmtl (tsmtl disable <id>) or use --system" >&2
fi
if [[ $SYSTEM == 1 ]]; then
  INJECT="$SHIM_DIR/build/libTSRegSim.dylib"
  export TSMTL_SIM_BUNDLE="$SHIM_DIR/build/TeraScaleMTLDriver.bundle"
  export TSMTL_CONFIG_DIR="$SHIM_DIR/apps/system-config"
  mkdir -p "$TSMTL_CONFIG_DIR"
  ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$COPY/Contents/Info.plist")
  P="$TSMTL_CONFIG_DIR/policy.plist"
  [[ -f $P ]] || plutil -create xml1 "$P"
  plutil -replace Version -integer 1 "$P"
  plutil -replace AutoEnable -bool YES "$P"
  plutil -extract Apps raw "$P" >/dev/null 2>&1 || plutil -insert Apps -dictionary "$P"
  plutil -replace "Apps.${ID//./\.}" -json '{"Enabled":true}' "$P"
  if [[ -n ${TSMTL_COMPUTE:-} ]]; then
    plutil -extract System raw "$P" >/dev/null 2>&1 || plutil -insert System -dictionary "$P"
    plutil -extract System.Compute raw "$P" >/dev/null 2>&1 || plutil -insert System.Compute -json '{"Enabled":false,"Apps":{}}' "$P"
    plutil -replace "System.Compute.Apps.${ID//./\.}" -json "{\"Enabled\":$([[ $TSMTL_COMPUTE == 0 ]] && echo false || echo true)}" "$P"
  fi
fi
if [[ -n $FAKE_ENT ]]; then
  INJECT="$INJECT:$SHIM_DIR/build/libTSEntSpoof.dylib"
  export TS_FAKE_ENTITLEMENTS="$FAKE_ENT"
fi
if [[ $CL_PROBE == 1 ]]; then
  [[ -f "$SHIM_DIR/build/libTSCLProbe.dylib" ]] || { echo "build first: make -C $SHIM_DIR compute" >&2; exit 1; }
  INJECT="$INJECT:$SHIM_DIR/build/libTSCLProbe.dylib"
fi
if [[ $SHIM == 1 ]]; then
  DYLD_INSERT_LIBRARIES="$INJECT" TSMTL_LOG=1 "$EXE" "$@" > "$LOG" 2>&1 &
else
  "$EXE" "$@" > "$LOG" 2>&1 &
fi
echo "pid $!"
