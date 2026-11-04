#import "VMApp.h"

void VMEditText(UIViewController *vc, NSString *title, NSString *message, NSString *value, NSString *placeholder,
                UIKeyboardType keyboard, VMTextCompletion done) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *f) {
        f.text = value;
        f.placeholder = placeholder;
        f.keyboardType = keyboard;
        f.autocorrectionType = UITextAutocorrectionTypeNo;
        f.autocapitalizationType = UITextAutocapitalizationTypeNone;
        f.clearButtonMode = UITextFieldViewModeWhileEditing;
        f.font = VMMono(15);
    }];
    [a addAction:[UIAlertAction actionWithTitle:@"Annulla" style:UIAlertActionStyleCancel
                                        handler:^(UIAlertAction *x) { done(nil); }]];
    __weak UIAlertController *wa = a;
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *t = [wa.textFields.firstObject.text
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        done(t ?: @"");
    }]];
    [vc presentViewController:a animated:YES completion:nil];
}

void VMConfirm(UIViewController *vc, NSString *title, NSString *message, NSString *action, BOOL destructive,
               dispatch_block_t done) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"Annulla" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:action
                                          style:destructive ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) { done(); }]];
    [vc presentViewController:a animated:YES completion:nil];
}

void VMAlert(UIViewController *vc, NSString *title, NSString *message) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:message
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [vc presentViewController:a animated:YES completion:nil];
}

void VMToast(UIViewController *vc, NSString *text) {
    UIView *host = vc.view.window ?: vc.view;
    UILabel *l = [UILabel new];
    l.text = text;
    l.numberOfLines = 0;
    l.textAlignment = NSTextAlignmentCenter;
    l.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    l.textColor = UIColor.labelColor;
    l.backgroundColor = UIColor.secondarySystemBackgroundColor;
    l.layer.cornerRadius = 14;
    l.layer.masksToBounds = YES;
    CGFloat w = MIN(host.bounds.size.width - 48, 340);
    CGSize s = [l sizeThatFits:CGSizeMake(w - 32, CGFLOAT_MAX)];
    l.frame = CGRectMake((host.bounds.size.width - w) / 2, host.bounds.size.height - host.safeAreaInsets.bottom - 110,
                         w, s.height + 24);
    l.alpha = 0;
    [host addSubview:l];
    [UIView animateWithDuration:0.2 animations:^{ l.alpha = 1; } completion:^(BOOL f) {
        [UIView animateWithDuration:0.3 delay:2.2 options:0 animations:^{ l.alpha = 0; }
                         completion:^(BOOL g) { [l removeFromSuperview]; }];
    }];
}

NSString *VMBytes(double b) {
    if (b < 0) return @"—";
    if (b < 1024) return [NSString stringWithFormat:@"%.0f B", b];
    if (b < 1024 * 1024) return [NSString stringWithFormat:@"%.1f KB", b / 1024];
    if (b < 1024.0 * 1024 * 1024) return [NSString stringWithFormat:@"%.1f MB", b / 1024 / 1024];
    return [NSString stringWithFormat:@"%.2f GB", b / 1024 / 1024 / 1024];
}

UIFont *VMMono(CGFloat size) { return [UIFont monospacedSystemFontOfSize:size weight:UIFontWeightRegular]; }

@implementation VMSwitch
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) [self addTarget:self action:@selector(changed) forControlEvents:UIControlEventValueChanged];
    return self;
}
- (void)changed { if (self.onChange) self.onChange(self.on); }
@end

@implementation VMSparkView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.contentMode = UIViewContentModeRedraw;
        _color = UIColor.systemBlueColor;
        _values = @[];
    }
    return self;
}
- (void)setValues:(NSArray<NSNumber *> *)values { _values = [values copy]; [self setNeedsDisplay]; }
- (void)setCaption:(NSString *)caption { _caption = [caption copy]; [self setNeedsDisplay]; }
- (void)drawRect:(CGRect)rect {
    CGRect r = CGRectInset(self.bounds, 16, 10);
    UIBezierPath *frame = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.bounds, 8, 4) cornerRadius:12];
    [UIColor.secondarySystemGroupedBackgroundColor setFill];
    [frame fill];
    // Grid: quarters.
    [[UIColor.separatorColor colorWithAlphaComponent:0.5] setStroke];
    for (int i = 1; i < 4; i++) {
        UIBezierPath *g = [UIBezierPath bezierPath];
        CGFloat y = CGRectGetMinY(r) + r.size.height * i / 4;
        [g moveToPoint:CGPointMake(CGRectGetMinX(r), y)];
        [g addLineToPoint:CGPointMake(CGRectGetMaxX(r), y)];
        g.lineWidth = 0.5;
        [g stroke];
    }
    NSUInteger n = self.values.count;
    double max = self.maxValue;
    if (max <= 0) for (NSNumber *v in self.values) max = MAX(max, v.doubleValue);
    if (max <= 0) max = 1;
    const NSUInteger slots = 120;   // samples across the width
    if (n >= 2) {
        UIBezierPath *line = [UIBezierPath bezierPath];
        CGFloat step = r.size.width / (slots - 1);
        CGFloat x0 = CGRectGetMaxX(r) - step * (MIN(n, slots) - 1);
        NSUInteger first = n > slots ? n - slots : 0;
        for (NSUInteger i = first; i < n; i++) {
            double v = MIN(MAX(self.values[i].doubleValue / max, 0), 1);
            CGPoint p = CGPointMake(x0 + step * (i - first), CGRectGetMaxY(r) - v * r.size.height);
            if (i == first) [line moveToPoint:p]; else [line addLineToPoint:p];
        }
        UIBezierPath *fill = [line copy];
        [fill addLineToPoint:CGPointMake(CGRectGetMaxX(r), CGRectGetMaxY(r))];
        [fill addLineToPoint:CGPointMake(x0, CGRectGetMaxY(r))];
        [fill closePath];
        [[self.color colorWithAlphaComponent:0.15] setFill];
        [fill fill];
        [self.color setStroke];
        line.lineWidth = 2;
        line.lineJoinStyle = kCGLineJoinRound;
        [line stroke];
    }
    if (self.caption) {
        NSDictionary *attr = @{NSFontAttributeName: [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold],
                               NSForegroundColorAttributeName: UIColor.secondaryLabelColor};
        [self.caption drawAtPoint:CGPointMake(CGRectGetMinX(r) + 4, CGRectGetMinY(r)) withAttributes:attr];
    }
}
@end

@implementation VMBarView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.contentMode = UIViewContentModeRedraw;
        _color = UIColor.systemGreenColor;
    }
    return self;
}
- (void)setFraction:(double)fraction { _fraction = MIN(MAX(fraction, 0), 1); [self setNeedsDisplay]; }
- (void)drawRect:(CGRect)rect {
    CGRect b = self.bounds;
    CGFloat h = 8, y = (b.size.height - h) / 2;
    UIBezierPath *track = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, y, b.size.width, h) cornerRadius:h / 2];
    [UIColor.tertiarySystemFillColor setFill];
    [track fill];
    if (self.fraction > 0) {
        CGFloat w = MAX(h, b.size.width * self.fraction);
        UIBezierPath *bar = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, y, w, h) cornerRadius:h / 2];
        [self.color setFill];
        [bar fill];
    }
}
@end

@implementation VMTextViewController {
    NSString *_text;
    BOOL _editable;
    void (^_save)(NSString *);
    UITextView *_tv;
}
- (instancetype)initWithTitle:(NSString *)title text:(NSString *)text editable:(BOOL)editable save:(void (^)(NSString *))save {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        self.title = title;
        _text = [text copy];
        _editable = editable;
        _save = [save copy];
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    _tv = [[UITextView alloc] initWithFrame:self.view.bounds];
    _tv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tv.font = VMMono(13);
    _tv.text = _text;
    _tv.editable = _editable;
    _tv.autocorrectionType = UITextAutocorrectionTypeNo;
    _tv.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _tv.smartQuotesType = UITextSmartQuotesTypeNo;
    _tv.smartDashesType = UITextSmartDashesTypeNo;
    _tv.alwaysBounceVertical = YES;
    _tv.textContainerInset = UIEdgeInsetsMake(12, 10, 12, 10);
    [self.view addSubview:_tv];
    if (_save) {
        self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Fine" style:UIBarButtonItemStyleDone
                                                                                 target:self action:@selector(done)];
    }
    if (self.reload) {
        UIRefreshControl *rc = [UIRefreshControl new];
        [rc addTarget:self action:@selector(refresh:) forControlEvents:UIControlEventValueChanged];
        _tv.refreshControl = rc;
    }
}
- (void)refresh:(UIRefreshControl *)rc {
    NSString *(^reload)(void) = self.reload;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *t = reload();
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_tv.text = t;
            [rc endRefreshing];
        });
    });
}
- (void)done {
    _save(_tv.text ?: @"");
    [self.navigationController popViewControllerAnimated:YES];
}
@end
