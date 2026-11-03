#!/bin/zsh
# chrome-passlog.sh <tag> [env...]: bf4 in a fresh test Chrome with TSMTL_PASS_LOG=1, 8 captures 2 s apart;
# times in exp/shots-<tag>.txt, log in exp/log-<tag>.txt, sheet in docs/findings-2026-10-31/b3/<tag>-sheet.png.
# With TSMTL_DRAW_TRACE=<file holding 100000> the whole run is traced (every card pass covered).
cd ~/metal-shim
tag=$1; shift
S=$PWD/docs/findings-2026-10-31/b3
LOG="apps/Google Chrome.log"
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
pkill -TERM -f "home-Chrome-test/profile"; sleep 3
NOBG=(--disable-backgrounding-occluded-windows --disable-renderer-backgrounding --disable-background-timer-throttling)
echo "launch $(now)" > exp/shots-$tag.txt
env TSMTL_PASS_LOG=1 TSMTL_STATS=1 "$@" tools/shim-run.sh "$PWD/apps/Google Chrome.app" --system --model iMac19,1 -- --disable-gpu-sandbox $NOBG \
  --user-data-dir=$PWD/apps/home-Chrome-test/profile --use-mock-keychain --no-first-run --remote-debugging-port=9222 \
  --window-size=1400,1000 "file://$PWD/tests/web/bf4.html" >/dev/null 2>&1
for i in {1..40}; do curl -s localhost:9222/json/version >/dev/null && break; sleep 0.5; done
echo "ready $(now)" >> exp/shots-$tag.txt
sleep 1
for i in {1..8}; do
  t=$(now); tools/cdp-probe.sh --target bf4 shot $S/$tag-$i.png >/dev/null; echo "shot $i $t $(now)" >> exp/shots-$tag.txt; sleep 2
done
cp "$LOG" exp/log-$tag.txt
pkill -TERM -f "home-Chrome-test/profile"
tools/sheet $S/$tag-sheet.png 4 450 $S/$tag-{1..8}.png
cat exp/shots-$tag.txt
grep '^\[TSPass\].*896x384' exp/log-$tag.txt
