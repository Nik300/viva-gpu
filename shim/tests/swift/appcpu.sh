#!/bin/zsh
# CPU of a cold app launch after N seconds, with and without TeraScale Swift (build/libTSSwift.dylib injected).
# Usage: tests/swift/appcpu.sh [seconds] [executable]: 3 runs per side, alternated; counters in build/swift/appcpu.log.
# Executables without hardened runtime only (DYLD_INSERT_LIBRARIES).
ROOT=${0:A:h:h:h}
SECS=${1:-15}
EXE=${2:-"/Applications/TeraScale Metal.app/Contents/MacOS/TeraScaleMetal"}
NAME=${EXE:t}
cpu() {   # ps TIME (m:ss.ss) -> seconds
    local t=$(LC_ALL=C ps -o time= -p $1 | tr -d ' ')
    echo $t | awk -F: '{ print ($1 * 60) + $2 }'
}
mkdir -p $ROOT/build/swift
for mode in off on off on off on; do
    pkill -x $NAME; sleep 1
    if [[ $mode == on ]]; then
        TSSWIFT_STATS=$SECS DYLD_INSERT_LIBRARIES=$ROOT/build/libTSSwift.dylib "$EXE" > /dev/null 2>> $ROOT/build/swift/appcpu.log &
    else
        TSSWIFT_OFF=1 DYLD_INSERT_LIBRARIES=$ROOT/build/libTSSwift.dylib "$EXE" > /dev/null 2>&1 &
    fi
    pid=$!
    sleep $SECS
    echo "$mode $(cpu $pid)"
    kill $pid 2>/dev/null; wait $pid 2>/dev/null
done
