// Fraction of pixels that differ between two captures, to count broken Chrome captures against
// the --disable-gpu reference instead of judging contact sheets by eye.
// Usage: imgdiff a.png b.png [mask.png]   prints "<percent> <differing> <total>"
//        IMGDIFF_THRESHOLD=n: a pixel differs when any channel differs by more than n (default 48).
//        mask.png (optional): differing pixels in red over a dimmed copy of b.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static uint8_t *TSLoadRGBA(const char *path, size_t w, size_t h) {
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(path)], NULL);
    if (!src) return NULL;
    CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!img) return NULL;
    uint8_t *px = calloc(w * h, 4);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, w, h, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
    CGContextRelease(ctx); CGColorSpaceRelease(cs); CGImageRelease(img);
    return px;
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 3) { fprintf(stderr, "usage: imgdiff a.png b.png [mask.png]\n"); return 2; }
    CGImageSourceRef s0 = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(argv[1])], NULL);
    CGImageRef first = s0 ? CGImageSourceCreateImageAtIndex(s0, 0, NULL) : NULL;
    if (!first) { fprintf(stderr, "imgdiff: cannot read %s\n", argv[1]); return 2; }
    size_t w = CGImageGetWidth(first), h = CGImageGetHeight(first);
    CGImageRelease(first); CFRelease(s0);
    uint8_t *a = TSLoadRGBA(argv[1], w, h), *b = TSLoadRGBA(argv[2], w, h);
    if (!a || !b) { fprintf(stderr, "imgdiff: cannot read %s\n", a ? argv[2] : argv[1]); return 2; }
    int threshold = getenv("IMGDIFF_THRESHOLD") ? atoi(getenv("IMGDIFF_THRESHOLD")) : 48;
    size_t differing = 0;
    for (size_t i = 0; i < w * h; i++) {
        uint8_t *p = a + i * 4, *q = b + i * 4;
        BOOL diff = abs(p[0] - q[0]) > threshold || abs(p[1] - q[1]) > threshold || abs(p[2] - q[2]) > threshold;
        differing += diff;
        if (argc > 3) {   // reuse b as the mask
            if (diff) { q[0] = 255; q[1] = 0; q[2] = 0; }
            else { q[0] = q[0] / 3 + 170; q[1] = q[1] / 3 + 170; q[2] = q[2] / 3 + 170; }
        }
    }
    printf("%.2f %zu %zu\n", 100.0 * differing / (w * h), differing, w * h);
    if (argc > 3) {
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(b, w, h, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGImageRef out = CGBitmapContextCreateImage(ctx);
        CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(argv[3])],
                                                                    (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
        CGImageDestinationAddImage(dst, out, NULL);
        CGImageDestinationFinalize(dst);
        CFRelease(dst); CGImageRelease(out); CGContextRelease(ctx); CGColorSpaceRelease(cs);
    }
    free(a); free(b);
    return 0;
} }
