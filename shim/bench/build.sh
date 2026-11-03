#!/bin/zsh
# Builds the optimization benchmarks described in docs/OTTIMIZZAZIONE.md into build/bench.
# Shim-based ones link build/libTSMetal.dylib (run `make` first); the others are pure GL.
#   gpubench   GPU time of today's translated GLSL vs. the target GLSL (GL_TIME_ELAPSED)
#   attrib     same shaders: LLVM clean-up passes + today's emitter (separates the two effects)
#   cpubench   CPU cost of the Metal -> GL command translation (ui | passes | bigcb | uploads | views | profile)
#   glfloor    pure-GL floor of the cpubench "ui" workload (full state vs. dirty-only)
#   passfloor  FBO/VAO creation per render pass vs. cached
#   fmabench   fma() vs. a*b+c on this GPU
#   glprobe    GL extensions and limits;  passprobe  LLVM passes available in the system libLLVM
set -e
HERE="${0:A:h}"
ROOT="${HERE:h}"
OUT="$ROOT/build/bench"
mkdir -p "$OUT"
shim=(-I"$ROOT/src" -L"$ROOT/build" -lTSMetal -Wl,-rpath,"$ROOT/build" -framework Metal)
for b in gpubench attrib cpubench passprobe; do
  clang -fobjc-arc -O1 -Wno-everything "${shim[@]}" "$HERE/$b.m" -framework Foundation -framework OpenGL -o "$OUT/$b"
done
for b in glprobe glfloor passfloor fmabench; do
  clang -fobjc-arc -O2 -Wno-everything "$HERE/$b.m" -framework Foundation -framework OpenGL -o "$OUT/$b"
done
echo "built: $(ls "$OUT" | tr '\n' ' ')"
