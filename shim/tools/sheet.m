// Contact sheet of PNG frames with their index, to review burst captures in one image.
// Usage: sheet out.png <columns> <cell width> frame1.png frame2.png ...
//        SHEET_CROP=x,y,w,h crops every frame first (source pixels, origin top-left).
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <CoreText/CoreText.h>
int main(int argc, char **argv) { @autoreleasepool {
    if (argc < 5) { fprintf(stderr, "usage: sheet out.png cols cellwidth frames...\n"); return 2; }
    int cols = atoi(argv[2]), cw = atoi(argv[3]), n = argc - 4;
    CGImageRef first = NULL;
    CGImageSourceRef s0 = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(argv[4])], NULL);
    first = CGImageSourceCreateImageAtIndex(s0, 0, NULL);
    CGRect crop = CGRectNull;
    if (getenv("SHEET_CROP")) {
        double x, y, w, h;
        if (sscanf(getenv("SHEET_CROP"), "%lf,%lf,%lf,%lf", &x, &y, &w, &h) == 4) crop = CGRectMake(x, y, w, h);
    }
    double srcW = CGRectIsNull(crop) ? CGImageGetWidth(first) : crop.size.width, srcH = CGRectIsNull(crop) ? CGImageGetHeight(first) : crop.size.height;
    int ch = (int)(cw * srcH / srcW);
    int rows = (n + cols - 1) / cols;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(NULL, cols * cw, rows * ch, 8, 0, cs, kCGImageAlphaPremultipliedLast);
    CGContextSetRGBFillColor(ctx, 1, 1, 1, 1);
    CGContextFillRect(ctx, CGRectMake(0, 0, cols * cw, rows * ch));
    CTFontRef font = CTFontCreateWithName(CFSTR("Helvetica-Bold"), 18, NULL);
    for (int i = 0; i < n; i++) {
        CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(argv[4 + i])], NULL);
        if (!src) continue;
        CGImageRef img = CGImageSourceCreateImageAtIndex(src, 0, NULL);
        if (!CGRectIsNull(crop)) { CGImageRef c = CGImageCreateWithImageInRect(img, crop); CGImageRelease(img); img = c; }
        CGRect r = CGRectMake((i % cols) * cw, (rows - 1 - i / cols) * ch, cw - 2, ch - 2);
        CGContextDrawImage(ctx, r, img);
        NSAttributedString *label = [[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@"%d", i + 1]
            attributes:@{ (id)kCTFontAttributeName: (__bridge id)font, (id)kCTForegroundColorAttributeName: (__bridge id)CGColorCreateSRGB(1, 0, 0, 1) }];
        CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)label);
        CGContextSetTextPosition(ctx, r.origin.x + 4, r.origin.y + r.size.height - 20);
        CTLineDraw(line, ctx);
        CFRelease(line); CGImageRelease(img); CFRelease(src);
    }
    CGImageRef out = CGBitmapContextCreateImage(ctx);
    CGImageDestinationRef dst = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:@(argv[1])], CFSTR("public.png"), 1, NULL);
    CGImageDestinationAddImage(dst, out, NULL);
    CGImageDestinationFinalize(dst);
} return 0; }
