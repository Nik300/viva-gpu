#!/bin/zsh
# Restarts the instrumented Chrome test instance (separate profile, DevTools on :9222) with the shim.
# Usage: chrome-test.sh [url] ; extra TSMTL_* variables are passed through from the environment.
SHIM_DIR="${0:A:h:h}"
pkill -TERM -f "apps/Google Chrome.app/Contents/MacOS/Google Chrome"
for i in {1..20}; do pgrep -f "apps/Google Chrome.app" >/dev/null || break; sleep 0.5; done
pkill -KILL -f "apps/Google Chrome.app"   # slow shutdowns are not what we test
"$SHIM_DIR/tools/shim-run.sh" "/Volumes/Google Chrome/Google Chrome.app" --no-entitlements --model iMac19,1 -- \
  --user-data-dir=$SHIM_DIR/apps/home-Chrome-test/profile --use-mock-keychain --no-first-run --remote-debugging-port=9222 \
  "${1:-about:blank}" | tail -1
