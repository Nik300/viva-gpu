#!/bin/zsh
# G1 (docs/OTTIMIZZAZIONE-COMPUTE.md, section 2): repeatable "Maps near a landmark" scenario, for A/B runs of
# TeraScale Compute. Launches the Maps copy with the shim from build/ (tools/shim-run.sh, statistics on), opens the
# landmark, then: 3D standard map, zoom in step by step, satellite, satellite 3D, pans. After each step it saves a
# window capture, and at the end prints the shim statistics of the run (one line per 5 s: dispatches, dispatches
# recorded/skipped/inert, cl runs, cl gpu ms, nextDrawable wait ms, ...) plus the compute log lines.
# Usage: maps-landmark.sh [--compute|--no-compute] [--place colosseo|duomo-milano|tour-eiffel|"lat,lon"] [--out dir]
#                         [extra env assignments...]
# Captures and logs go to apps/landmark-<place>-<compute|nocompute>-<time>/ (or --out). Compare two runs with
# tools/sheet / tools/imgdiff on the captures of the same step.
set -e
SHIM_DIR="${0:A:h:h}"
MODE=--compute; PLACE=colosseo; OUT=
while (( $# )); do
  case "$1" in
    --compute|--no-compute) MODE=$1; shift ;;
    --place) PLACE="${2:?--place needs a value}"; shift 2 ;;
    --out) OUT="${2:?--out needs a value}"; shift 2 ;;
    *=*) export "$1"; shift ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
case "$PLACE" in
  colosseo) LL=41.8902,12.4922 ;;
  duomo-milano) LL=45.4642,9.1916 ;;
  tour-eiffel) LL=48.8584,2.2945 ;;
  *,*) LL=$PLACE; PLACE=custom ;;
  *) echo "unknown place $PLACE" >&2; exit 2 ;;
esac
TAG=${MODE#--}; TAG=${TAG/-/}
OUT=${OUT:-"$SHIM_DIR/apps/landmark-$PLACE-$TAG-$(date +%H%M%S)"}
mkdir -p "$OUT"
LOG="$SHIM_DIR/apps/Maps.log"
COPY="$SHIM_DIR/apps/Maps.app"

pkill -TERM -f "apps/Maps.app/Contents/MacOS/Maps" || true; sleep 2
TSMTL_STATS=1 "$SHIM_DIR/tools/shim-run.sh" /System/Applications/Maps.app --no-entitlements --home $MODE >/dev/null
P=$(pgrep -f "apps/Maps.app/Contents/MacOS/Maps")
until "$SHIM_DIR/tools/winid" $P | grep -q .; do sleep 1; done
N0=$(grep -c "stats/5s" "$LOG" || true)
L0=$(wc -l < "$LOG")
sleep 6

front() { osascript -e 'tell application "System Events" to set frontmost of process "Maps" to true' >/dev/null; }
menu() {   # click the first item of the View menu (menu bar item 5) whose name contains $1
  osascript -e "tell application \"System Events\" to tell process \"Maps\" to click (first menu item of menu 1 of menu bar item 5 of menu bar 1 whose name contains \"$1\")" >/dev/null 2>&1 || true
}
has_menu() {
  osascript -e 'tell application "System Events" to tell process "Maps" to get name of every menu item of menu 1 of menu bar item 5 of menu bar 1' 2>/dev/null | grep -q "$1"
}
shot() {   # window capture after the map settled
  sleep ${2:-4}
  local W=$("$SHIM_DIR/tools/winid" $P | head -1 | cut -d' ' -f1)
  [[ -n $W ]] && screencapture -x -o -l $W "$OUT/$1.png"
  echo "$(date +%T) $1" >> "$OUT/steps.txt"
}
zoom() { for i in $(seq $1); do osascript -e 'tell application "System Events" to keystroke "+" using command down' >/dev/null; sleep 1.5; done; }
pan() {
  local B=$("$SHIM_DIR/tools/winid" $P | head -1)
  local X=$(echo "$B" | sed -E 's/.*X = ([0-9]+).*/\1/') Y=$(echo "$B" | sed -E 's/.*Y = ([0-9]+).*/\1/')
  "$SHIM_DIR/tools/mouse" $((X + 600)) $((Y + 400))
  "$SHIM_DIR/tools/scroll" 4 2 250 8; "$SHIM_DIR/tools/scroll" -4 -2 250 8
}

# 1. the landmark on the standard map (URL: ll = centre, z = zoom, t = m standard / k satellite)
open -a "$COPY" "maps://?ll=$LL&z=16&t=m"; front; shot 01-standard 8
# 2. 3D, then closer and closer (buildings, then the landmark's own model)
has_menu "Mostra mappa 2D" || menu "3D"
shot 02-standard-3d
zoom 2; shot 03-standard-3d-zoom2
zoom 2; shot 04-standard-3d-zoom4
pan; shot 05-standard-3d-pan 2
# 3. satellite and satellite 3D from close
open -a "$COPY" "maps://?ll=$LL&z=17&t=k"; front; shot 06-satellite 10
has_menu "Mostra mappa 2D" || menu "3D"
zoom 2; shot 07-satellite-3d-zoom2 8
pan; shot 08-satellite-3d-pan 2

{
  echo "== $PLACE ($LL), compute ${MODE#--}, $(date)"
  echo "== shim statistics (per 5 s)"
  grep "stats/5s" "$LOG" | tail -n +$((N0 + 1)) | sed 's/.*stats\/5s: //'
  echo "== OpenCL kernels (GPU time per 5 s)"
  tail -n +$((L0 + 1)) "$LOG" | grep "cl kernel" || echo "(none)"
  echo "== compute log"
  tail -n +$((L0 + 1)) "$LOG" | grep "compute:" | sort | uniq -c | sort -rn | head -40 || true
} | tee "$OUT/summary.txt"
echo "captures and summary in $OUT"
