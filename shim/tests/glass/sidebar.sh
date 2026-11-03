#!/bin/zsh
# TeraScale Glass, app sidebars (docs/PIANO-GLASS.md, "Barre laterali"), on the REAL WindowServer: a striped window,
# and above it a SwiftUI NavigationSplitView window (tests/glass/splitwin.swift) with the driver injected and a lab
# configuration that turns the glass on. The sidebar must show the stripes behind the window (blurred), not a flat
# gray. Opens windows on screen for a few seconds; needs the screen-recording permission of the terminal.
set -euo pipefail
ROOT=${0:A:h:h:h}
WORK=$ROOT/build/glasslab/sidebar
mkdir -p $WORK/cfg $WORK/cfg-off
python3 -I -c "import plistlib,sys; plistlib.dump({'System':{'Glass':{'Enabled':True}}},open(sys.argv[1],'wb'),fmt=plistlib.FMT_XML)" $WORK/cfg/policy.plist
# The baseline turns the glass off explicitly: Metal also loads the installed driver, whose sidebars follow the system policy.
python3 -I -c "import plistlib,sys; plistlib.dump({'System':{'Glass':{'Enabled':False}}},open(sys.argv[1],'wb'),fmt=plistlib.FMT_XML)" $WORK/cfg-off/policy.plist
swiftc -O $ROOT/tests/glass/splitwin.swift -o $WORK/splitwin 2>&1 | grep error || true
cc -fobjc-arc -framework Foundation -framework CoreGraphics -framework ImageIO -x objective-c - -o $WORK/stddev <<'C'
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
// stddev file x0 y0 x1 y1: standard deviation of the green channel in a rectangle (top-left origin)
int main(int c, char **v) { @autoreleasepool {
    CGImageSourceRef s = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(v[1])], NULL);
    CGImageRef im = CGImageSourceCreateImageAtIndex(s, 0, NULL); size_t W = CGImageGetWidth(im), H = CGImageGetHeight(im);
    uint8_t *p = calloc(W * H, 4); CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(p, W, H, 8, W * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(ctx, CGRectMake(0, 0, W, H), im);
    double s1 = 0, s2 = 0; long n = 0;
    for (int y = atoi(v[3]); y < atoi(v[5]); y++) for (int x = atoi(v[2]); x < atoi(v[4]); x++) { double g = p[(y * W + x) * 4 + 1]; s1 += g; s2 += g * g; n++; }
    printf("%.1f\n", sqrt(s2 / n - (s1 / n) * (s1 / n)));
} return 0; }
C
shot() {   # $1: output, rest: environment of the split window
  local out=$1; shift
  (CAGLASS_WINDOW=9 $ROOT/tools/caglass $WORK/x.png none >/dev/null 2>&1 &)
  sleep 1.5
  (env "$@" $WORK/splitwin 5 > $WORK/rect.txt 2>/dev/null &)
  sleep 3.5
  screencapture -x -R$(grep -o "rect [0-9,]*" $WORK/rect.txt | cut -d' ' -f2) $out
  sleep 5
}
shot $WORK/off.png TSMTL_CONFIG_DIR=$WORK/cfg-off
shot $WORK/on.png TSMTL_CONFIG_DIR=$WORK/cfg DYLD_INSERT_LIBRARIES=$ROOT/build/libTSMetal.dylib
off=$($WORK/stddev $WORK/off.png 20 220 130 400) on=$($WORK/stddev $WORK/on.png 20 220 130 400)   # below the list items
print "sidebar variation (green stddev): without $off, with TeraScale Glass $on"
(( on > 3 * (off + 1) )) && print ok || { print "FAIL: the sidebar does not show what is behind the window"; exit 1 }
