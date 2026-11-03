#!/bin/zsh
# TeraScale Swift validation: the corpus answered by the runtime alone, by the accelerator in validation mode (every
# fast "no" checked against the runtime) and by the accelerator alone must print the same thing, with 0 mismatches.
set -e
ROOT=${0:A:h:h:h}; OUT=$ROOT/build/swift; SRC=$ROOT/tests/swift
mkdir -p $OUT; cd $OUT
if [[ ! -x corpus || $SRC/corpus.swift -nt corpus || $SRC/A.swift -nt corpus || $SRC/B.swift -nt corpus ]]; then
    echo "building the corpus (swiftc)"
    xcrun swiftc -O -emit-library -module-name A -emit-module -enable-library-evolution $SRC/A.swift -o libA.dylib 2>/dev/null
    xcrun swiftc -O -emit-library -module-name B -I. -L. -lA $SRC/B.swift -o libB.dylib 2>/dev/null
    xcrun swiftc -O -module-name Corpus -I. -L. -lA -Xlinker -rpath -Xlinker $OUT $SRC/corpus.swift -o corpus 2>/dev/null
fi
LIB=$ROOT/build/libTSSwift.dylib
./corpus $OUT/libB.dylib > runtime.txt
TSSWIFT_VALIDATE=1 TSSWIFT_STATS=0 DYLD_INSERT_LIBRARIES=$LIB ./corpus $OUT/libB.dylib > validate.txt 2> validate.err
TSSWIFT_STATS=0 DYLD_INSERT_LIBRARIES=$LIB ./corpus $OUT/libB.dylib > accel.txt 2> accel.err
fail=0
for f in validate accel; do
    if ! diff -q runtime.txt $f.txt > /dev/null; then echo "FAIL: $f differs from the runtime"; diff runtime.txt $f.txt | head -20; fail=1; fi
done
grep -h "fast no" validate.err accel.err | sed -E 's/; [0-9]+ protocols.*//' | cut -c1-260
grep -q "mismatches 0" validate.err || { echo "FAIL: mismatches in validation"; fail=1; }
grep -q "hooks 3" accel.err || { echo "FAIL: not hooked"; fail=1; }
n=$(grep -c ":" runtime.txt)
[[ $fail == 0 ]] && echo "ok: $n lines identical (runtime, validation, accelerator)"
exit $fail
