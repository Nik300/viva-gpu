#!/bin/bash
# Builds Viva Manager for the phone (iOS 16, arm64): app/out/VivaManager.app and app/out/VivaManager.tar.
# Needs an iOS SDK (Xcode; CI: .github/workflows/app.yml). `app/build.sh check` only type-checks the sources against
# the macOS SDK's Mac Catalyst UIKit (works with the Command Line Tools).
# Install on the phone: app/install.sh (USB link).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/out"
SRC=("$HERE"/Sources/*.m "$HERE/../driver/tests/isa_cases.m")   # ISA test cases, shared with the isatest CLI
CFLAGS=(-fobjc-arc -O2 -g -Wall -Wextra -Wno-unused-parameter -I"$HERE/../driver")

if [ "${1:-}" = check ]; then
  SDK="$(xcrun --show-sdk-path)"
  for f in "${SRC[@]}"; do
    clang -target arm64-apple-ios16.0-macabi -isysroot "$SDK" -iframework "$SDK/System/iOSSupport/System/Library/Frameworks" \
      "${CFLAGS[@]}" -fsyntax-only "$f"
  done
  clang -target arm64-apple-macos13 -Wall -Wextra -fsyntax-only "$HERE/helper/vmhelper.c"
  echo "check: ok"
  exit 0
fi

SDK="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || true)"
[ -n "$SDK" ] || { echo "app/build.sh: no iOS SDK (Xcode)" >&2; exit 1; }
CC="$(xcrun --sdk iphoneos -f clang)"
T=(-target arm64-apple-ios16.0 -isysroot "$SDK")
APP="$OUT/VivaManager.app"
rm -rf "$APP"
mkdir -p "$APP"
"$CC" "${T[@]}" "${CFLAGS[@]}" "${SRC[@]}" -framework UIKit -framework Foundation -framework CoreGraphics -framework Metal -framework QuartzCore -o "$APP/VivaManager"
"$CC" "${T[@]}" -O2 -Wall -Wextra "$HERE/helper/vmhelper.c" -o "$APP/vmhelper"
cp "$HERE/Info.plist" "$APP/Info.plist"
plutil -convert binary1 "$APP/Info.plist"
cp "$HERE"/Resources/*.json "$HERE"/Resources/icons/*.png "$APP/"
printf 'APPL????' > "$APP/PkgInfo"
rm -rf "$OUT"/*.dSYM; mv "$APP"/*.dSYM "$OUT"/ 2>/dev/null || true   # clang -g puts them next to the binaries
codesign -s - -f "$APP/vmhelper"
codesign -s - -f --entitlements "$HERE/VivaManager.entitlements" "$APP"
(cd "$OUT" && rm -f VivaManager.tar && tar cf VivaManager.tar VivaManager.app)
ls -l "$APP" "$OUT/VivaManager.tar"
