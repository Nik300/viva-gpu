#!/bin/zsh
# TeraScale Compute: the cached app copies (apps/) with and without compute (TSMTL_COMPUTE=1/0), alternating
# rounds. Per run: launch to first window, CPU time and RSS over a fixed window after warm-up, the shim's
# per-5 s statistics over that window (TSMTL_STATS=1) and the compute lines of the log (which kernels ran how).
# Usage: compute-bench.sh [rounds] [app...]   apps: Preview FindMy "System Settings" GridCraft "ArtCraft Launcher"
# Output: one line per run, then a summary per app (means of the runs) on stdout; raw logs in apps/bench-compute/.
SHIM_DIR="${0:A:h:h}"
export LC_ALL=C
ROUNDS=${1:-2}; shift 2>/dev/null
typeset -A SRC OPTS
SRC=(Preview /System/Applications/Preview.app  FindMy /System/Applications/FindMy.app
     "System Settings" "/System/Applications/System Settings.app"  GridCraft /Applications/GridCraft.app
     "ArtCraft Launcher" "/Applications/ArtCraft Launcher.app")
OPTS=(Preview "--system --home"  FindMy "--no-entitlements --home --fake-entitlements com.apple.findmy."
      "System Settings" "--no-entitlements"  GridCraft ""  "ArtCraft Launcher" "--system")
APPS=("$@")
(( ${#APPS} )) || APPS=(Preview FindMy "System Settings" GridCraft "ArtCraft Launcher")
WARM=${WARM:-12}; WINDOW=${WINDOW:-10}
OUT="$SHIM_DIR/apps/bench-compute"; mkdir -p "$OUT"

secs() { awk -F: '{ if (NF == 3) print $1 * 3600 + $2 * 60 + $3; else if (NF == 2) print $1 * 60 + $2; else print $1 }' <<< "${1// /}" }
field() { sed -nE "s/.* $1=([0-9.]+).*/\\1/p" }   # value of "<name>=" in a stats line
avg() { awk '{ s += $1; n++ } END { if (n) printf "%.1f", s / n; else printf "-" }' }

run_one() {   # run_one <app> <0|1> -> one result line
  local app=$1 mode=$2 name=${SRC[$1]:t}
  local exe="$SHIM_DIR/apps/$name/Contents/MacOS/$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$SHIM_DIR/apps/$name/Contents/Info.plist")"
  pkill -TERM -f "$exe" 2>/dev/null; sleep 1; pkill -KILL -f "$exe" 2>/dev/null; sleep 1
  local log="$SHIM_DIR/apps/${name:r}.log"
  local t0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  TSMTL_STATS=1 TSMTL_COMPUTE=$mode "$SHIM_DIR/tools/shim-run.sh" "${SRC[$app]}" ${=OPTS[$app]} >/dev/null 2>&1
  local pid=""
  for i in {1..100}; do pid=$(pgrep -f "$exe" | head -1); [[ -n $pid ]] && break; sleep 0.1; done
  local tw=""
  for i in {1..300}; do
    if [[ -n $pid ]] && "$SHIM_DIR/tools/winid" $pid | grep -q .; then tw=$(perl -MTime::HiRes=time -e 'printf "%.3f", time'); break; fi
    sleep 0.1
  done
  local launch=$([[ -n $tw ]] && echo "$tw - $t0" | bc || echo "-")
  sleep $WARM
  local n0=$(grep -c "stats/5s" "$log") c0=$(secs "$(ps -o time= -p $pid 2>/dev/null)")
  sleep $WINDOW
  local c1=$(secs "$(ps -o time= -p $pid 2>/dev/null)") rss=$(( $(ps -o rss= -p $pid 2>/dev/null || echo 0) / 1024 ))
  local stats=$(grep "stats/5s" "$log" | tail -n +$((n0 + 1)))
  local draws=$(print -r -- "$stats" | field draws | avg) busy=$(print -r -- "$stats" | field "gpu-queue busy ms" | avg)
  local disp=$(print -r -- "$stats" | field dispatches | avg) runs=$(print -r -- "$stats" | field "cl runs" | avg)
  local cpu=$(echo "($c1 - $c0) / $WINDOW * 100" | bc -l)
  local ocl=$(grep -c "OpenCL context on" "$log") gl=$(grep -c "runs as a GL pass" "$log") cl=$(grep -c "runs on OpenCL" "$log")
  local rej=$(grep -c "does not run" "$log") unimpl=$(grep -c "TSMtlComputeEncoder" "$log")
  cp "$log" "$OUT/${name:r}-compute$mode-$(date +%H%M%S).log"
  pkill -TERM -f "$exe" 2>/dev/null; sleep 1; pkill -KILL -f "$exe" 2>/dev/null
  printf "%s|%s|%s|%.1f|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n" "$app" $mode $launch $cpu $rss $draws $busy $disp $runs $ocl $gl $cl $rej $unimpl
}

RESULTS=()
for app in $APPS; do
  [[ -n ${SRC[$app]} ]] || { echo "unknown app $app" >&2; continue; }
  [[ -d "$SHIM_DIR/apps/${SRC[$app]:t}" ]] || { echo "no cached copy of $app" >&2; continue; }
  for r in $(seq 1 $ROUNDS); do
    for mode in 0 1; do
      line=$(run_one "$app" $mode)
      RESULTS+=("$line")
      echo "$line" | awk -F'|' '{ printf "%-18s compute=%s launch=%ss cpu=%s%% rss=%sMB draws/5s=%s gpuBusyMs/5s=%s dispatch/5s=%s clRuns/5s=%s openclCtx=%s glKernels=%s clKernels=%s refused=%s unimpl=%s\n", $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14 }'
    done
  done
done
echo "== summary (mean of $ROUNDS runs)"
printf '%s\n' "${RESULTS[@]}" | awk -F'|' '
  { k = $1 "|" $2; n[k]++; L[k] += $3; C[k] += $4; R[k] += $5; D[k] += $6; B[k] += $7; X[k] += $8; Q[k] += $9; O[k] = $10; G[k] = $11; K[k] = $12; J[k] = $13; U[k] = $14 }
  END { for (k in n) { split(k, a, "|"); printf "%-18s %-9s launch %5.2f s  cpu %5.1f %%  rss %5.0f MB  draws/5s %6.0f  gpuBusy %6.1f ms/5s  dispatch/5s %5.0f  clRuns/5s %4.0f  [OpenCL ctx %s, GL kernels %s, CL kernels %s, refused %s, unimpl %s]\n",
        a[1], (a[2] == 1 ? "CON" : "SENZA"), L[k]/n[k], C[k]/n[k], R[k]/n[k], D[k]/n[k], B[k]/n[k], X[k]/n[k], Q[k]/n[k], O[k], G[k], K[k], J[k], U[k] } }' | sort
