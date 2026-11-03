#!/bin/zsh
# chrome-ref.sh <tag>: same captures as chrome-ab.sh from the --disable-gpu reference instance (port 9223)
S=${TS_SHOTS:-/tmp}
tag=$1
cd ~/metal-shim
pkill -TERM -f "home-Chrome-ref/profile"; sleep 3
NOBG=(--disable-backgrounding-occluded-windows --disable-renderer-backgrounding --disable-background-timer-throttling)
"$PWD/apps/Google Chrome.app/Contents/MacOS/Google Chrome" --user-data-dir=$PWD/apps/home-Chrome-ref/profile \
  --disable-gpu --disable-gpu-compositing --disable-gpu-sandbox $NOBG --use-mock-keychain --no-first-run --remote-debugging-port=9223 \
  --window-size=1400,1000 "${URL:-https://www.odontoiatriasempioneroma.it/}" >/dev/null 2>&1 &
for i in {1..40}; do curl -s localhost:9223/json/version >/dev/null && break; sleep 0.5; done
sleep 8
i=0
for y in 0 800 1600 2400 3200 4000; do
  i=$((i+1)); tools/cdp-probe.sh --port 9223 --target ${TARGET:-sempione} eval "window.scrollTo(0,$y)" wait 2.5 shot $S/$tag-$i.png >/dev/null
done
tools/sheet $S/$tag-sheet.png 3 600 $S/$tag-{1..6}.png
pkill -TERM -f "home-Chrome-ref/profile"
