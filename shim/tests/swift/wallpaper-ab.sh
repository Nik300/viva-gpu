#!/bin/zsh
# TeraScale Swift on Settings > Wallpaper (docs/OTTIMIZZAZIONE-SWIFT.md §11.5): cold opens of the page, alternating
# System.Swift off/on (3+3), CPU of the processes involved; then the phase-0 lines (H1) and the accelerator's counters.
# Needs the installed driver 0.12.0 or later. The user's policy.plist is restored at the end.
# Usage: tests/swift/wallpaper-ab.sh [seconds per run, default 25]
ROOT=${0:A:h:h:h}; DUR=${1:-25}; OUT=$ROOT/build/swift/wallpaper; mkdir -p $OUT
export LC_ALL=C
CFG=/Library/GPUBundles/TeraScaleMTLDriver.config
TSMTL="$ROOT/build/TeraScale Metal.app/Contents/MacOS/TeraScaleMetal"
v=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" /Library/GPUBundles/TeraScaleMTLDriver.bundle/Contents/Info.plist)
autoload is-at-least; is-at-least 0.12.0 $v || { echo "driver installato $v: serve 0.12.0 (zsh system/update.sh)"; exit 1; }
rm -f $OUT/summary.txt
cp $CFG/policy.plist $OUT/policy.backup
trap 'cp $OUT/policy.backup $CFG/policy.plist; echo "policy ripristinata"' EXIT
procs='System Settings|Wallpaper|WallpaperAerialsExtension|NeptuneOneWallpaper|DesktopSettings'
quit_all() {
    osascript -e 'quit app "System Settings"' 2>/dev/null; sleep 2
    for p in "System Settings" Wallpaper WallpaperAerialsExtension NeptuneOneWallpaper DesktopSettings; do pkill -x "$p"; done
    sleep 3
}
secs() { awk -F: '{ if (NF == 3) print $1 * 3600 + $2 * 60 + $3; else print $1 * 60 + $2 }' <<< "$1" }
t0=$(date "+%Y-%m-%d %H:%M:%S")
"$TSMTL" swift validate off > /dev/null
i=0
for side in off on off on off on; do
    i=$((i + 1)); "$TSMTL" swift $side > /dev/null
    quit_all
    (cd $OUT && rm -f run$i.before run$i.samples run$i.after && $ROOT/exp/airopt/wallpaper-measure.sh run$i $DUR > /dev/null 2>&1)
    # CPU used during the run by the processes of the page (all started cold, so their whole CPU time counts)
    total=0; vt=0
    while read pid cpu ct rss name; do
        s=$(secs $ct); b=$(awk -v p=$pid '$1 == p { print $3 }' $OUT/run$i.before); [[ -n $b ]] && s=$((s - $(secs $b)))
        if [[ $name == VTDecoder* ]]; then vt=$((vt + s)); elif [[ $name =~ "^($procs)" ]]; then total=$((total + s)); fi
    done < <(ps -axo pid=,%cpu=,cputime=,rss=,comm= | awk '{c=$5; for (k = 6; k <= NF; k++) c = c " " $k; sub(".*/", "", c); print $1, $2, $3, $4, c}' | grep -E "$procs|VTDecoder")
    printf "%-3s run %d: Swift processes %.1f s CPU, video decoder %.1f s\n" $side $i $total $vt | tee -a $OUT/summary.txt
done
quit_all
awk '{ s[$1] += $6; n[$1]++ } END { for (k in s) printf "media %s: %.2f s CPU (%d prove)\n", k, s[k] / n[k], n[k] }' $OUT/summary.txt | sort | tee -a $OUT/summary.txt
echo "--- fase 0 (H1) e contatori, dal log:"
/usr/bin/log show --start "$t0" --predicate 'subsystem == "com.terascale.mtlshim" AND category == "swift"' --style compact 2>/dev/null \
    | grep -E "System Settings|Wallpaper|Neptune|DesktopSettings" | sed -E 's/^[0-9-]+ ([0-9:]+)\.[0-9]+ .*\[com.terascale.mtlshim:swift\] /\1 /' | cut -c1-330 | tee $OUT/log.txt
