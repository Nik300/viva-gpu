#!/bin/zsh
# heavy-bisect.sh <tag> <heavy-mask> [cbs]: bf4 in a fresh test Chrome; capture before / during / after a heavy
# trace restricted to <heavy-mask> (TSMTL_DRAW_TRACE_HEAVY bits, see TSPrivate.h). Shots in $TS_SHOTS (default
# docs/findings-2026-10-31/b3), log copied to exp/log-<tag>.txt. PRE=1 arms the trace before launch, so it covers
# the startup passes (the bf4 card content pass is drawn at startup and then cached); shot A is then taken during it.
cd ~/metal-shim
tag=$1 mask=$2 cbs=${3:-150}
S=${TS_SHOTS:-$PWD/docs/findings-2026-10-31/b3}
mkdir -p $S
trig=/private/tmp/tsmtl-trig-$$
rm -f $trig
[[ -n $PRE ]] && echo $cbs > $trig
LOG="apps/Google Chrome.log"
pkill -TERM -f "home-Chrome-test/profile"; sleep 3
NOBG=(--disable-backgrounding-occluded-windows --disable-renderer-backgrounding --disable-background-timer-throttling)
env TSMTL_DRAW_TRACE=$trig TSMTL_DRAW_TRACE_HEAVY=$mask TSMTL_STATS=1 ${=EXTRA_ENV} \
  tools/shim-run.sh "$PWD/apps/Google Chrome.app" --system --model iMac19,1 -- --disable-gpu-sandbox $NOBG \
  --user-data-dir=$PWD/apps/home-Chrome-test/profile --use-mock-keychain --no-first-run --remote-debugging-port=9222 \
  --window-size=1400,1000 "file://$PWD/tests/web/bf4.html" >/dev/null 2>&1
for i in {1..40}; do curl -s localhost:9222/json/version >/dev/null && break; sleep 0.5; done
sleep 8
shot() { tools/cdp-probe.sh --target bf4 shot $S/$tag-$1.png >/dev/null; }
shot A
if [[ -z $PRE ]]; then echo $cbs > $trig; sleep 4; else sleep 1; fi
shot B
for i in {1..120}; do grep -q "(0 left)" "$LOG" && break; sleep 0.5; done
sleep 3
shot C
cp "$LOG" exp/log-$tag.txt
tools/sheet $S/$tag-sheet.png 3 600 $S/$tag-{A,B,C}.png
echo "card passes traced: $(grep -c ':896x384 load' exp/log-$tag.txt)"
echo "trace lines: $(grep -c '^\[TSDraw\]' exp/log-$tag.txt)  done: $(grep -c '(0 left)' exp/log-$tag.txt)"
