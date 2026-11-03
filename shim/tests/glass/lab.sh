#!/bin/zsh
# TeraScale Glass in the lab (docs/PIANO-GLASS.md): the glass scene rendered by CoreAnimation's OpenGL renderer in a copy
# of tools/caglass named WindowServer (so Moraea's patches are active), with the component, against the same scene from
# CoreAnimation's Metal renderer on the shim. Fails if more than 2% of the pixels differ by more than 8/255.
set -euo pipefail
ROOT=${0:A:h:h:h}
WORK=$(mktemp -d /tmp/tsglass.XXXXXX)
trap 'rm -rf $WORK' EXIT
mkdir -p $WORK/cfg $WORK/lab
$ROOT/tools/glassgen -o $WORK/cfg/glass | grep -v "^glassgen: wrote"
/usr/libexec/PlistBuddy -c "Add :System dict" -c "Add :System:Glass dict" -c "Add :System:Glass:Enabled bool true" $WORK/cfg/policy.plist >/dev/null
cp $ROOT/tools/caglass $WORK/lab/WindowServer
# The context is found as in WindowServer, through Moraea's renderer hook (no CGLCreateContext interposer).
#   3 frames: shape computed in the shader (cg9m_gbs); 10: shape from CoreAnimation's SDF texture (cg9m_gbt);
#   late: programs linked before the hook, rebuilt in place with their uniform locations and values kept.
for run in 3 10 late; do
  frames=${run/late/3}
  CAGLASS_FRAMES=$frames DYLD_INSERT_LIBRARIES=$ROOT/build/libTSMetalInject.dylib $ROOT/tools/caglass $WORK/apple.png glass >/dev/null 2>&1
  rm -f $WORK/cfg/TeraScaleGlass/starts
  late=; [[ $run == late ]] && late=10
  TSGLASS_LATE_TEST=$late TSMTL_CONFIG_DIR=$WORK/cfg DYLD_INSERT_LIBRARIES=$ROOT/build/libTSMetal.dylib CAGLASS_OGL=1 \
    CAGLASS_FRAMES=$frames $WORK/lab/WindowServer $WORK/tsglass.png glass >/dev/null 2>&1
  replaced=$(/usr/libexec/PlistBuddy -c "Print :Replaced" $WORK/cfg/TeraScaleGlass/status.plist)
  read pct n total <<< "$(IMGDIFF_THRESHOLD=8 $ROOT/tools/imgdiff $WORK/apple.png $WORK/tsglass.png)"
  print "$run: $replaced Moraea programs on Apple's shader, $pct% of the pixels differ from Apple's (> 8/255)"
  (( replaced >= 1 && pct < 2.0 )) || { print "FAIL"; exit 1 }
done
print "ok"
