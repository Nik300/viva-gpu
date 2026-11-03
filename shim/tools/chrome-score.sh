#!/bin/zsh
# chrome-score.sh <ref tag> <tag>...: % of differing pixels per capture against the reference (+ mask PNGs)
S=${TS_SHOTS:-/tmp}
ref=$1; shift
for t in "$@"; do
  line="$t:"
  for i in {1..6}; do line="$line $(~/metal-shim/tools/imgdiff $S/$ref-$i.png $S/$t-$i.png $S/$t-mask-$i.png | cut -d' ' -f1)"; done
  echo "$line"
done
