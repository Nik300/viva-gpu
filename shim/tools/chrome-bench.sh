#!/bin/zsh
# Chrome scroll benchmark: restarts the test instance with stats, loads a page, waits, then scrolls it
# with DevTools synthetic gestures for ~10 s and prints the shim statistics of that window.
# Usage: chrome-bench.sh [url]   (TSMTL_PROFILE=1 etc. pass through)
SHIM_DIR="${0:A:h:h}"
URL="${1:-https://www.youtube.com/}"
TSMTL_STATS=1 "$SHIM_DIR/tools/chrome-test.sh" "$URL" >/dev/null
LOG="$SHIM_DIR/apps/Google Chrome.log"
until python3 -I "$SHIM_DIR/tools/cdp.py" eval "document.readyState" 2>/dev/null | grep -q complete; do sleep 1; done
sleep 8
N0=$(grep -c "stats/5s" "$LOG")
python3 -I "$SHIM_DIR/tools/cdp.py" Input.synthesizeScrollGesture '{"x":600,"y":500,"yDistance":-3000,"speed":1200,"repeatCount":2,"repeatDelayMs":100}' \
  Input.synthesizeScrollGesture '{"x":600,"y":500,"yDistance":3000,"speed":1200,"repeatCount":2,"repeatDelayMs":100}' >/dev/null
sleep 5.5
grep "stats/5s" "$LOG" | tail -n +$((N0 + 1)) | sed 's/.*stats\/5s: //'
