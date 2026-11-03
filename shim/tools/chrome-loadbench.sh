#!/bin/zsh
# chrome-loadbench.sh <tag> [env...]: fresh test Chrome (build bundle), YouTube for 30 s, then the site for 30 s.
# Prints the pipeline-cost stats per 5 s and totals; full log in exp/log-<tag>.txt, captures in exp/load-<tag>-*.png.
cd ~/metal-shim
tag=$1; shift
LOG="apps/Google Chrome.log"
pkill -TERM -f "home-Chrome-test/profile"; sleep 3
NOBG=(--disable-backgrounding-occluded-windows --disable-renderer-backgrounding --disable-background-timer-throttling)
env TSMTL_STATS=1 "$@" tools/shim-run.sh "$PWD/apps/Google Chrome.app" --system --model iMac19,1 -- --disable-gpu-sandbox $NOBG \
  --user-data-dir=$PWD/apps/home-Chrome-test/profile --use-mock-keychain --no-first-run --remote-debugging-port=9222 \
  --window-size=1400,1000 "https://www.youtube.com/" >/dev/null 2>&1
for i in {1..60}; do curl -s localhost:9222/json/version >/dev/null && break; sleep 0.5; done
sleep 30
tools/cdp-probe.sh --target youtube shot exp/load-$tag-yt.png >/dev/null
tools/cdp-probe.sh --target youtube nav "https://www.odontoiatriasempioneroma.it/" >/dev/null
sleep 30
tools/cdp-probe.sh --target sempione shot exp/load-$tag-site.png >/dev/null
cp "$LOG" exp/log-$tag.txt
pkill -TERM -f "home-Chrome-test/profile"
grep 'stats/5s' exp/log-$tag.txt | sed -E 's/.*\[TSMtl ([0-9]+)\].*draws=([0-9]+).*translations=([0-9]+) disk cache hits=([0-9]+) program links=([0-9]+) program hits=([0-9]+).*gpu-queue busy ms=([0-9]+).*pipelines=([0-9]+).*pipeline create ms=([0-9]+) link ms=([0-9]+) warm-up ms=([0-9]+) translate ms=([0-9]+) variant links=([0-9]+).*/pid\1 draws=\2 tr=\3 hits=\4 links=\5 phits=\6 busy=\7 pipes=\8 create=\9ms link=\10ms warm=\11ms trans=\12ms var=\13/' > exp/load-$tag.txt
cat exp/load-$tag.txt
awk '{for(i=2;i<=NF;i++){split($i,a,"=");gsub("ms","",a[2]);s[a[1]]+=a[2]}} END{printf "TOTAL"; for(k in s) printf " %s=%d", k, s[k]; print ""}' exp/load-$tag.txt
