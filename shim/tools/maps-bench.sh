#!/bin/zsh
# Maps pan benchmark: (re)launches the Maps copy with the shim and stats, switches to the 3D view,
# pans with scroll events for ~10 s and prints the shim statistics of that window plus CPU time.
# Usage: maps-bench.sh [extra env assignments...]   e.g. maps-bench.sh TSMTL_NO_PASSES=1
#        NOSIDEBAR=1 hides the (blurred) sidebar first.
SHIM_DIR="${0:A:h:h}"
pkill -TERM -f "apps/Maps.app/Contents/MacOS/Maps"; sleep 2
# Same starting view every run: restore the saved window/scene state captured in apps/maps-bench-state.
STATE="$SHIM_DIR/apps/home-Maps/Library/Saved Application State/com.apple.Maps~iosmac.savedState"
if [[ -d "$SHIM_DIR/apps/maps-bench-state" ]]; then rm -rf "$STATE"; cp -R "$SHIM_DIR/apps/maps-bench-state" "$STATE"; fi
for a in "$@"; do export "$a"; done
# --system: the build's bundle through the simulated registry, so an installed driver cannot load next to it.
TSMTL_STATS=1 "$SHIM_DIR/tools/shim-run.sh" /System/Applications/Maps.app --system --no-entitlements --home >/dev/null
P=$(pgrep -f "apps/Maps.app/Contents/MacOS/Maps")
until "$SHIM_DIR/tools/winid" $P | grep -q .; do sleep 1; done
sleep 8
osascript -e 'tell application "System Events" to set frontmost of process "Maps" to true' >/dev/null
sleep 1
if ! osascript -e 'tell application "System Events" to tell process "Maps" to get name of every menu item of menu 1 of menu bar item 5 of menu bar 1' | grep -q "Mostra mappa 2D"; then
  osascript -e 'tell application "System Events" to tell process "Maps" to click (first menu item of menu 1 of menu bar item 5 of menu bar 1 whose name contains "3D")' >/dev/null
fi
if [[ -n $NOSIDEBAR ]]; then
  osascript -e 'tell application "System Events" to tell process "Maps" to click (first menu item of menu 1 of menu bar item 5 of menu bar 1 whose name contains "barra laterale")' >/dev/null
fi
sleep 6
LOG="$SHIM_DIR/apps/Maps.log"
N0=$(grep -c "stats/5s" "$LOG")
T0=$(ps -o time= -p $P)
# Pan with pixel scroll events at 125 Hz over the map (input never limits the frame rate).
B=$("$SHIM_DIR/tools/winid" $P | head -1)
X=$(echo "$B" | sed -E 's/.*X = ([0-9]+).*/\1/'); Y=$(echo "$B" | sed -E 's/.*Y = ([0-9]+).*/\1/')
"$SHIM_DIR/tools/mouse" $((X + 600)) $((Y + 400))
"$SHIM_DIR/tools/scroll" 6 3 625 8; "$SHIM_DIR/tools/scroll" -6 -3 625 8
sleep 1
T1=$(ps -o time= -p $P)
echo "CPU time $T0 -> $T1"
grep "stats/5s" "$LOG" | tail -n +$((N0 + 1)) | sed 's/.*stats\/5s: //'
