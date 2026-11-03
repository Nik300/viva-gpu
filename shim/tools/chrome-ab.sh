#!/bin/zsh
# ab.sh <tag> [env assignments...]: fresh test Chrome on the site, captures at 0..4000 step 800, stats lines
# CHROME_EXTRA="--flag ..." adds Chrome flags.
S=${TS_SHOTS:-/tmp}
tag=$1; shift
cd ~/metal-shim
pkill -TERM -f "home-Chrome-test/profile"; sleep 3
NOBG=(--disable-backgrounding-occluded-windows --disable-renderer-backgrounding --disable-background-timer-throttling)
env "$@" TSMTL_STATS=1 tools/shim-run.sh "$PWD/apps/Google Chrome.app" --system --model iMac19,1 -- --disable-gpu-sandbox $NOBG ${=CHROME_EXTRA} \
  --user-data-dir=$PWD/apps/home-Chrome-test/profile --use-mock-keychain --no-first-run --remote-debugging-port=9222 \
  --window-size=1400,1000 "${URL:-https://www.odontoiatriasempioneroma.it/}" >/dev/null 2>&1
for i in {1..40}; do curl -s localhost:9222/json/version >/dev/null && break; sleep 0.5; done
sleep 8
i=0
for y in 0 800 1600 2400 3200 4000; do
  i=$((i+1)); ~/metal-shim/tools/cdp-probe.sh --target ${TARGET:-sempione} eval "window.scrollTo(0,$y)" wait 2.5 shot $S/$tag-$i.png >/dev/null
done
tools/sheet $S/$tag-sheet.png 3 600 $S/$tag-{1..6}.png
grep -i "rebind\|iosurface GL binds" "apps/Google Chrome.log" | tail -4
