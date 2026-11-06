// VivaIsland.dylib: SpringBoard tweak. Shows the USB "Viva Link" state in the Dynamic Island.
//
// Loaded by SpringBoard through an LC_LOAD_WEAK_DYLIB added by tweak/inject.sh (no Substrate/ElleKit on the phone).
// kern.viva_linkstate is polled every second on a background GCD timer; on 0/1 -> 2 the island shows "Viva Link · USB"
// for 3 s (the system alerting duration), then a compact indicator while the link stays up; it goes away with the link.
//
// Two presenters (docs/DYNAMIC-ISLAND.md):
//  - element: real SystemAperture elements, the way SpringBoard shows charging/ringer notices on iOS 16.7
//    (SBUISystemApertureContentProvider + SBAlertProvidedContentElement / SBActivityProvidedContentElement,
//    -[SBSystemApertureController registerElement:] -> SAUIElementAssertion). Every class and selector is checked
//    before use; any failure switches to the overlay.
//  - overlay: a pass-through window over the island drawing a black pill (spring animation), the automatic fallback.
// All UI work runs on the main queue, every private call inside @try. A crash guard (VI_SAFETY_FILE) turns the
// element path off after VI_SAFETY_LIMIT SpringBoard deaths right after a registration.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>
#import <os/log.h>
#import <sys/sysctl.h>
#import <errno.h>
#import <unistd.h>
#import "VivaIsland.h"

static os_log_t VILog;
#define VILOG(fmt, ...) os_log(VILog, fmt, ##__VA_ARGS__)

// ---- Private API, declared only for typed message sends (always behind respondsToSelector / NSClassFromString) ------

@protocol VIPrivateSelectors <NSObject>
@optional
// SpringBoard
- (id)systemApertureControllerForMainDisplay;
- (id)embeddedDisplayWindowScene;
// SBSystemApertureController (SAElementRegistering)
- (id)registerElement:(id)element;
- (CGRect)defaultIslandFrameInCoordinateSpace:(id)space;
// SAAssertion / SAInvalidatable
- (void)invalidateWithReason:(NSString *)reason;
- (BOOL)isValid;
- (void)addInvalidationBlock:(void (^)(id a, id b))block;
// SBUISystemApertureContentProvider / SBUISystemApertureCustomContentProvider
- (void)setLeadingContentViewProvider:(id)p;
- (void)setTrailingContentViewProvider:(id)p;
- (void)setMinimalContentViewProvider:(id)p;
- (id)initWithView:(UIView *)view;
// SBSystemApertureProvidedContentElement
- (id)initWithIdentifier:(id)identifier contentProvider:(id)provider;
- (void)setMinimumSupportedLayoutMode:(NSInteger)mode;
@end

// SAUILayoutMode (SBUISystemApertureLayoutModeDescription, 20H392): 1 inactive, 2 minimal, 3 compact, 4 custom.
enum { VILayoutMinimal = 2, VILayoutCompact = 3 };

// ---- Small helpers ---------------------------------------------------------------------------------------------------

static BOOL VIPrefBool(NSString *key, BOOL def) {
    CFStringRef domain = CFSTR(VI_DOMAIN);
    CFPreferencesAppSynchronize(domain);
    id v = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, domain));
    if (!v) {   // cfprefsd unreachable or domain not cached: the plist itself (SpringBoard runs as mobile)
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/" VI_DOMAIN ".plist"];
        v = d[key];
    }
    return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : def;
}

// kern.viva_linkstate; -1 when the sysctl is missing (treated as 0).
static int VIReadLinkState(void) {
    int v = 0;
    size_t len = sizeof v;
    if (sysctlbyname(VI_SYSCTL, &v, &len, NULL, 0) != 0) return -1;
    return v;
}

static int VISafetyCount(void) {
    NSString *s = [NSString stringWithContentsOfFile:@VI_SAFETY_FILE encoding:NSUTF8StringEncoding error:nil];
    return s ? MAX(1, s.intValue) : 0;
}

static void VISafetyWrite(int count) {
    NSString *path = @VI_SAFETY_FILE;
    if (count <= 0) { unlink(path.fileSystemRepresentation); return; }
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:nil];
    [[NSString stringWithFormat:@"%d\n", count] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

static UIImage *VISymbol(NSString *name, CGFloat size) {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:size weight:UIImageSymbolWeightSemibold];
    for (NSString *n in @[name ?: @"", @"cable.connector", @"bolt.horizontal.fill", @"bolt.fill"]) {
        UIImage *i = n.length ? [UIImage systemImageNamed:n withConfiguration:cfg] : nil;
        if (i) return [i imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    }
    return nil;
}

// ---- What to show ----------------------------------------------------------------------------------------------------

@interface VINotice : NSObject
@property (nonatomic, copy) NSString *title, *detail, *subtitle, *compactText, *symbol;
@property (nonatomic, strong) UIColor *color;
@property (nonatomic) BOOL persistent;   // compact indicator after the notice, until -hide
@end
@implementation VINotice
@end

@protocol VIPresenter <NSObject>
- (BOOL)show:(VINotice *)notice;   // NO: could not show (the caller falls back)
- (void)hide;
@end

// ---- Island content views --------------------------------------------------------------------------------------------

// A fixed-size view (icon and/or text) for the leading/trailing/minimal slots. SystemApertureUI sizes provided views
// with systemLayoutSizeFittingSize:, so the size is pinned with constraints, like SBPowerAlertElement's trailing view.
@interface VIContentView : UIView
- (instancetype)initWithSymbol:(nullable NSString *)symbol text:(nullable NSString *)text color:(UIColor *)color
                     textColor:(UIColor *)textColor fontSize:(CGFloat)fontSize;
@end

@implementation VIContentView {
    UIImageView *_icon;
    UILabel *_label;
    CGSize _size;
}

- (instancetype)initWithSymbol:(NSString *)symbol text:(NSString *)text color:(UIColor *)color textColor:(UIColor *)textColor
                      fontSize:(CGFloat)fontSize {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    self.userInteractionEnabled = NO;
    self.backgroundColor = UIColor.clearColor;
    CGFloat w = 0, h = 0;
    if (symbol) {
        _icon = [[UIImageView alloc] initWithImage:VISymbol(symbol, fontSize + 1)];
        _icon.tintColor = color;
        _icon.contentMode = UIViewContentModeScaleAspectFit;
        CGSize s = _icon.image ? _icon.image.size : CGSizeMake(fontSize + 4, fontSize + 4);
        _icon.frame = (CGRect){CGPointZero, s};
        [self addSubview:_icon];
        w = s.width;
        h = s.height;
    }
    if (text.length) {
        _label = [UILabel new];
        _label.text = text;
        _label.font = [UIFont systemFontOfSize:fontSize weight:UIFontWeightSemibold];
        _label.textColor = textColor;
        [_label sizeToFit];
        CGSize s = _label.bounds.size;
        w += (w > 0 ? 6 : 0) + ceil(s.width);
        h = MAX(h, ceil(s.height));
        [self addSubview:_label];
    }
    _size = CGSizeMake(MAX(w, 1), MAX(h, 1));
    self.bounds = (CGRect){CGPointZero, _size};
    NSLayoutConstraint *cw = [self.widthAnchor constraintEqualToConstant:_size.width];
    NSLayoutConstraint *ch = [self.heightAnchor constraintEqualToConstant:_size.height];
    cw.priority = ch.priority = UILayoutPriorityRequired - 1;   // never fights the container's own frame
    [NSLayoutConstraint activateConstraints:@[cw, ch]];
    return self;
}

- (CGSize)intrinsicContentSize { return _size; }
- (CGSize)sizeThatFits:(CGSize)size { return _size; }

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat x = 0;
    if (_icon) {
        CGSize s = _icon.bounds.size;
        _icon.frame = CGRectMake(0, floor((b.size.height - s.height) / 2), s.width, s.height);
        x = s.width + 6;
    }
    if (_label) {
        CGSize s = _label.bounds.size;
        _label.frame = CGRectMake(x, floor((b.size.height - s.height) / 2), MAX(0, b.size.width - x), s.height);
    }
}

@end

// ---- Presenter 1: system aperture elements --------------------------------------------------------------------------

// SAElementIdentifying for -[SBSystemApertureProvidedContentElement initWithIdentifier:contentProvider:] (it reads
// elementIdentifier and clientIdentifier from this object, like SBChargingSystemApertureElementProvider).
@interface VIElementIdentity : NSObject
@property (nonatomic, copy) NSString *elementIdentifier, *clientIdentifier;
@end
@implementation VIElementIdentity
@end

@interface VIElementPresenter : NSObject <VIPresenter>
+ (BOOL)available;
@end

@implementation VIElementPresenter {
    id _noticeElement, _noticeAssertion, _compactElement, _compactAssertion;
    VINotice *_notice;
    NSUInteger _gen;
    int _crashes;       // crash guard count found at start (deaths right after a registration)
}

- (instancetype)init {
    if ((self = [super init])) _crashes = VISafetyCount();
    return self;
}

+ (BOOL)available {
    Class provider = NSClassFromString(@"SBUISystemApertureContentProvider");
    Class custom = NSClassFromString(@"SBUISystemApertureCustomContentProvider");
    Class alert = NSClassFromString(@"SBAlertProvidedContentElement");
    Class activity = NSClassFromString(@"SBActivityProvidedContentElement");
    Class controller = NSClassFromString(@"SBSystemApertureController");
    SEL init = @selector(initWithIdentifier:contentProvider:);
    return provider && custom && alert && activity && controller &&
        [provider instancesRespondToSelector:@selector(setLeadingContentViewProvider:)] &&
        [provider instancesRespondToSelector:@selector(setTrailingContentViewProvider:)] &&
        [provider instancesRespondToSelector:@selector(setMinimalContentViewProvider:)] &&
        [custom instancesRespondToSelector:@selector(initWithView:)] &&
        [alert instancesRespondToSelector:init] && [activity instancesRespondToSelector:init] &&
        [controller instancesRespondToSelector:@selector(registerElement:)] &&
        [UIApplication.sharedApplication respondsToSelector:@selector(systemApertureControllerForMainDisplay)];
}

+ (id)controller {
    id app = UIApplication.sharedApplication;
    if (![app respondsToSelector:@selector(systemApertureControllerForMainDisplay)]) return nil;
    id c = [app systemApertureControllerForMainDisplay];
    Class cls = NSClassFromString(@"SBSystemApertureController");
    return (cls && [c isKindOfClass:cls] && [c respondsToSelector:@selector(registerElement:)]) ? c : nil;
}

static id VIProvided(UIView *view) {
    return [[NSClassFromString(@"SBUISystemApertureCustomContentProvider") alloc] initWithView:view];
}

- (id)makeElement:(NSString *)className identifier:(NSString *)ident leading:(UIView *)leading trailing:(UIView *)trailing
          minimal:(UIView *)minimal {
    id provider = [NSClassFromString(@"SBUISystemApertureContentProvider") new];
    [provider setLeadingContentViewProvider:VIProvided(leading)];
    [provider setTrailingContentViewProvider:VIProvided(trailing)];
    [provider setMinimalContentViewProvider:VIProvided(minimal)];
    VIElementIdentity *idn = [VIElementIdentity new];
    idn.elementIdentifier = ident;
    idn.clientIdentifier = @"com.apple.springboard";   // SBSystemApertureClientIdentifier()
    return [[NSClassFromString(className) alloc] initWithIdentifier:idn contentProvider:provider];
}

- (id)registerElement:(id)element {
    id controller = [VIElementPresenter controller];
    if (!controller || !element) return nil;
    // Armed with one more than the count found at start: dying before the disarm below counts once per launch.
    VISafetyWrite(_crashes + 1);
    id assertion = [controller registerElement:element];
    if (!assertion || ![assertion respondsToSelector:@selector(invalidateWithReason:)]) {
        VISafetyWrite(_crashes);
        return nil;
    }
    // SpringBoard is still alive a while after the registration (layout passes ran): not a crash cause.
    __weak typeof(self) ws = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) s = ws;
        if (s) s->_crashes = 0;
        VISafetyWrite(0);
    });
    return assertion;
}

static void VIInvalidate(id assertion, NSString *reason) {
    @try {
        if (assertion && (![assertion respondsToSelector:@selector(isValid)] || [assertion isValid]))
            [assertion invalidateWithReason:reason];
    } @catch (NSException *e) {
        VILOG("invalidate: %{public}@", e);
    }
}

- (BOOL)show:(VINotice *)n {
    [self hide];
    NSUInteger gen = ++_gen;
    _notice = n;
    @try {
        UIColor *white = UIColor.whiteColor;
        UIView *leading = [[VIContentView alloc] initWithSymbol:n.symbol text:n.title color:n.color textColor:white fontSize:15];
        UIView *trailing = [[VIContentView alloc] initWithSymbol:nil text:n.detail color:n.color textColor:n.color fontSize:15];
        UIView *minimal = [[VIContentView alloc] initWithSymbol:n.symbol text:nil color:n.color textColor:white fontSize:13];
        id element = [self makeElement:@"SBAlertProvidedContentElement" identifier:@"it.viva.island.notice"
                               leading:leading trailing:trailing minimal:minimal];
        id assertion = [self registerElement:element];
        if (!assertion) { VILOG("notice: registerElement failed"); return NO; }
        _noticeElement = element;     // the aperture manager keeps elements weakly
        _noticeAssertion = assertion;
        // The alert lasts the system alerting duration (3 s, -[SBSystemApertureViewController
        // alertingDurationForHost:]); its end invalidates the element assertion. Then the compact indicator follows.
        __weak typeof(self) ws = self;
        if ([assertion respondsToSelector:@selector(addInvalidationBlock:)])
            [assertion addInvalidationBlock:^(id a, id b) {
                dispatch_async(dispatch_get_main_queue(), ^{ [ws noticeEnded:gen]; });
            }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [ws noticeEnded:gen];
        });
        VILOG("notice registered: %{public}@", element);
        return YES;
    } @catch (NSException *e) {
        VILOG("notice: %{public}@", e);
        [self hide];
        return NO;
    }
}

- (void)noticeEnded:(NSUInteger)gen {
    if (gen != _gen || !_noticeAssertion) return;
    id assertion = _noticeAssertion;
    _noticeAssertion = nil;
    VIInvalidate(assertion, @"VivaIsland notice done");
    _noticeElement = nil;
    if (!_notice.persistent) return;
    @try {
        VINotice *n = _notice;
        UIColor *white = UIColor.whiteColor;
        UIView *leading = [[VIContentView alloc] initWithSymbol:n.symbol text:nil color:n.color textColor:white fontSize:15];
        UIView *trailing = [[VIContentView alloc] initWithSymbol:nil text:n.compactText color:n.color textColor:n.color fontSize:13];
        UIView *minimal = [[VIContentView alloc] initWithSymbol:n.symbol text:nil color:n.color textColor:white fontSize:13];
        id element = [self makeElement:@"SBActivityProvidedContentElement" identifier:@"it.viva.island.link"
                               leading:leading trailing:trailing minimal:minimal];
        // Like other activities it may shrink to minimal next to another element (a minimal view is provided).
        if ([element respondsToSelector:@selector(setMinimumSupportedLayoutMode:)])
            [element setMinimumSupportedLayoutMode:VILayoutMinimal];
        id a = [self registerElement:element];
        if (!a) { VILOG("compact: registerElement failed"); return; }
        _compactElement = element;
        _compactAssertion = a;
    } @catch (NSException *e) {
        VILOG("compact: %{public}@", e);
    }
}

- (void)hide {
    _gen++;
    id na = _noticeAssertion, ca = _compactAssertion;
    _noticeAssertion = _compactAssertion = nil;
    VIInvalidate(na, @"VivaIsland hide");
    VIInvalidate(ca, @"VivaIsland hide");
    _noticeElement = _compactElement = nil;
}

@end

// ---- Presenter 2: overlay pill ---------------------------------------------------------------------------------------

@interface VIPassThroughWindow : UIWindow
@end
@implementation VIPassThroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }   // never takes a touch
- (BOOL)canBecomeKeyWindow { return NO; }
@end

@interface VIOverlayPresenter : NSObject <VIPresenter>
@end

@implementation VIOverlayPresenter {
    VIPassThroughWindow *_window;
    UIView *_pill, *_expanded, *_compact;
    UIImageView *_bigIcon, *_smallIcon;
    UILabel *_title, *_subtitle, *_compactLabel;
    CGRect _island;
    NSUInteger _gen;
}

// The island in window coordinates: SpringBoard's own frame when available, else the 2556 geometry
// (1125x2436 framebuffer: x 375-749, y 34-143 px = 125 x 36.7 pt at y 11.3 on a 375 pt wide screen).
- (CGRect)islandFrame {
    CGRect r = CGRectNull;
    @try {
        id c = [VIElementPresenter controller];
        if ([c respondsToSelector:@selector(defaultIslandFrameInCoordinateSpace:)])
            r = [c defaultIslandFrameInCoordinateSpace:_window];
    } @catch (NSException *e) {
        r = CGRectNull;
    }
    if (CGRectIsNull(r) || r.size.width < 60 || r.size.width > 260 || r.size.height < 20 || r.size.height > 60 || r.origin.y > 60) {
        CGFloat w = _window.bounds.size.width, s = w / 375.0;
        r = CGRectMake((w - 125 * s) / 2, 34.0 / 3 * s, 125 * s, 110.0 / 3 * s);
    }
    return r;
}

- (UIWindowScene *)scene:(CGFloat *)level {
    id app = UIApplication.sharedApplication;
    *level = UIWindowLevelStatusBar + 100;
    // Above the island: the window of SBSystemApertureController lives in its own high-level scene.
    @try {
        id c = [VIElementPresenter controller];
        Ivar iv = c ? class_getInstanceVariable(object_getClass(c), "_window") : NULL;
        id w = iv ? object_getIvar(c, iv) : nil;
        if ([w isKindOfClass:UIWindow.class] && [w windowScene]) {
            *level = [(UIWindow *)w windowLevel] + 1;
            return [w windowScene];
        }
    } @catch (NSException *e) {
    }
    if ([app respondsToSelector:@selector(embeddedDisplayWindowScene)]) {
        id s = [app embeddedDisplayWindowScene];
        if ([s isKindOfClass:UIWindowScene.class]) return s;
    }
    for (UIScene *s in [app connectedScenes])
        if ([s isKindOfClass:UIWindowScene.class]) return (UIWindowScene *)s;
    return nil;
}

- (BOOL)setUp {
    if (_window) return YES;
    CGFloat level;
    UIWindowScene *scene = [self scene:&level];
    if (!scene) return NO;
    _window = [[VIPassThroughWindow alloc] initWithWindowScene:scene];
    _window.frame = scene.screen.bounds;
    _window.windowLevel = level;
    _window.userInteractionEnabled = NO;
    _window.backgroundColor = UIColor.clearColor;
    _window.hidden = YES;

    _pill = [UIView new];
    _pill.backgroundColor = UIColor.blackColor;
    _pill.layer.cornerCurve = kCACornerCurveContinuous;
    _pill.clipsToBounds = YES;
    _pill.userInteractionEnabled = NO;
    [_window addSubview:_pill];

    _expanded = [UIView new];
    _compact = [UIView new];
    for (UIView *v in @[_expanded, _compact]) {
        v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [_pill addSubview:v];
    }
    _bigIcon = [UIImageView new];
    _bigIcon.contentMode = UIViewContentModeScaleAspectFit;
    _title = [UILabel new];
    _title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    _title.textColor = UIColor.whiteColor;
    _subtitle = [UILabel new];
    _subtitle.font = [UIFont systemFontOfSize:14];
    _subtitle.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    for (UIView *v in @[_bigIcon, _title, _subtitle]) [_expanded addSubview:v];
    _smallIcon = [UIImageView new];
    _smallIcon.contentMode = UIViewContentModeScaleAspectFit;
    _compactLabel = [UILabel new];
    _compactLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _compactLabel.textAlignment = NSTextAlignmentRight;
    for (UIView *v in @[_smallIcon, _compactLabel]) [_compact addSubview:v];
    return YES;
}

- (void)setPillFrame:(CGRect)f {
    _pill.frame = f;
    _pill.layer.cornerRadius = MIN(f.size.height / 2, 44);
}

- (CGRect)expandedFrame {
    CGFloat w = _window.bounds.size.width;
    return CGRectMake(11, _island.origin.y, w - 22, 72);
}

- (CGRect)compactFrame {
    return CGRectInset(_island, -30, 0);
}

- (void)layoutContent:(CGRect)expanded compact:(CGRect)compact {
    // Content frames are fixed to the target pill sizes; the pill clips them while it grows.
    _expanded.frame = (CGRect){CGPointZero, expanded.size};
    CGFloat h = expanded.size.height;
    _bigIcon.frame = CGRectMake(22, (h - 30) / 2 + 4, 30, 30);
    CGFloat tx = 66, tw = expanded.size.width - tx - 20;
    _title.frame = CGRectMake(tx, h / 2 - 17, tw, 22);
    _subtitle.frame = CGRectMake(tx, h / 2 + 7, tw, 18);
    if (!_subtitle.text.length) _title.frame = CGRectMake(tx, (h - 22) / 2 + 4, tw, 22);
    _compact.frame = (CGRect){CGPointZero, compact.size};
    CGFloat ch = compact.size.height;
    _smallIcon.frame = CGRectMake(12, (ch - 18) / 2, 18, 18);
    _compactLabel.frame = CGRectMake(compact.size.width - 12 - 40, (ch - 18) / 2, 40, 18);
}

- (BOOL)show:(VINotice *)n {
    if (![self setUp]) return NO;
    NSUInteger gen = ++_gen;
    _island = [self islandFrame];
    UIImage *big = VISymbol(n.symbol, 24), *small = VISymbol(n.symbol, 14);
    _bigIcon.image = big;
    _bigIcon.tintColor = n.color;
    _smallIcon.image = small;
    _smallIcon.tintColor = n.color;
    _title.text = n.detail.length ? [NSString stringWithFormat:@"%@ · %@", n.title, n.detail] : n.title;
    _subtitle.text = n.subtitle;
    _compactLabel.text = n.compactText;
    _compactLabel.textColor = n.color;
    CGRect expanded = [self expandedFrame], compact = [self compactFrame];
    [self layoutContent:expanded compact:compact];

    _window.hidden = NO;
    [self setPillFrame:_island];
    _pill.alpha = 1;
    _expanded.alpha = 0;
    _compact.alpha = 0;
    [UIView animateWithDuration:0.55 delay:0 usingSpringWithDamping:0.78 initialSpringVelocity:0.4
                        options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        [self setPillFrame:expanded];
    } completion:nil];
    [UIView animateWithDuration:0.25 delay:0.15 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        self->_expanded.alpha = 1;
    } completion:nil];

    __weak typeof(self) ws = self;
    BOOL persistent = n.persistent;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) s = ws;
        if (!s || s->_gen != gen) return;
        if (persistent) [s collapse];
        else [s hide];
    });
    return YES;
}

- (void)collapse {
    CGRect compact = [self compactFrame];
    [UIView animateWithDuration:0.15 animations:^{ self->_expanded.alpha = 0; }];
    [UIView animateWithDuration:0.5 delay:0.05 usingSpringWithDamping:0.82 initialSpringVelocity:0.2
                        options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        [self setPillFrame:compact];
    } completion:nil];
    [UIView animateWithDuration:0.2 delay:0.3 options:0 animations:^{ self->_compact.alpha = 1; } completion:nil];
}

- (void)hide {
    NSUInteger gen = ++_gen;
    if (!_window || _window.hidden) return;
    [UIView animateWithDuration:0.15 animations:^{
        self->_expanded.alpha = 0;
        self->_compact.alpha = 0;
    }];
    [UIView animateWithDuration:0.45 delay:0.05 usingSpringWithDamping:0.9 initialSpringVelocity:0
                        options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        [self setPillFrame:self->_island];
    } completion:^(BOOL finished) {
        if (self->_gen != gen) return;
        [UIView animateWithDuration:0.2 animations:^{ self->_pill.alpha = 0; } completion:^(BOOL f) {
            if (self->_gen == gen) self->_window.hidden = YES;
        }];
    }];
}

@end

// ---- Controller: polling, preferences, state machine ----------------------------------------------------------------

@interface VIController : NSObject
+ (instancetype)shared;
- (void)start;
@end

@implementation VIController {
    dispatch_source_t _timer;
    dispatch_queue_t _pollQueue;
    int _polled;            // last raw value seen by the poller (poll queue)
    int _pendingLow;        // consecutive polls below 2 while the link is shown (poll queue)
    BOOL _missing;          // last sysctl result was ENOENT (poll queue)
    int _link;              // state applied on the main queue
    BOOL _enabled, _standard, _forceOverlay, _noSysctl;
    int _flags;
    id<VIPresenter> _presenter;
    VIElementPresenter *_element;
    VIOverlayPresenter *_overlay;
    int _statusToken;
    BOOL _statusOK;
    NSUInteger _testGen;
    BOOL _testing;
}

+ (instancetype)shared {
    static VIController *c;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ c = [VIController new]; });
    return c;
}

- (void)publishStatus {
    int mode = !_enabled ? VI_MODE_OFF
             : (_element && _presenter == (id<VIPresenter>)_element) ? VI_MODE_ELEMENT
             : _presenter ? VI_MODE_OVERLAY : VI_MODE_STARTING;
    int flags = _flags | (_noSysctl ? VI_FLAG_NO_SYSCTL : 0);
    if (_statusOK) notify_set_state(_statusToken, VI_STATUS(mode, _link, flags, getpid()));
}

- (void)loadPrefs {
    _enabled = VIPrefBool(@VI_KEY_ENABLED, YES);
    _standard = VIPrefBool(@VI_KEY_STANDARD, NO);
    _forceOverlay = VIPrefBool(@VI_KEY_FORCE_OVERLAY, NO);
    _flags = 0;     // a preferences change retries the system path
    BOOL elementOK = !_forceOverlay;
    if (elementOK && VISafetyCount() >= VI_SAFETY_LIMIT) {
        _flags |= VI_FLAG_SAFETY;
        elementOK = NO;
        VILOG("system aperture path disabled by the crash guard (%{public}s)", VI_SAFETY_FILE);
    }
    if (elementOK && !(_flags & VI_FLAG_ELEMENT_FAILED)) {
        if (!_element && [VIElementPresenter available]) _element = [VIElementPresenter new];
        if (!_element) _flags |= VI_FLAG_ELEMENT_FAILED;
    }
    id<VIPresenter> next = (elementOK && _element && !(_flags & VI_FLAG_ELEMENT_FAILED)) ? (id<VIPresenter>)_element : nil;
    if (!next) {
        if (!_overlay) _overlay = [VIOverlayPresenter new];
        next = _overlay;
    }
    if (_presenter && _presenter != next) [_presenter hide];
    _presenter = next;
}

- (VINotice *)linkNotice {
    VINotice *n = [VINotice new];
    n.title = @"Viva Link";
    n.detail = @"USB";
    n.subtitle = @"Strumento di debug collegato";
    n.compactText = @"USB";
    n.symbol = @"cable.connector";
    n.color = UIColor.systemGreenColor;
    n.persistent = YES;
    return n;
}

- (VINotice *)standardNotice {
    VINotice *n = [VINotice new];
    n.title = @"USB";
    n.detail = @"standard";
    n.subtitle = @"Computer collegato";
    n.compactText = @"USB";
    n.symbol = @"cable.connector";
    n.color = UIColor.systemGrayColor;
    n.persistent = NO;
    return n;
}

// Shows with the current presenter; an element failure switches to the overlay for good (until prefs change).
- (void)present:(VINotice *)n {
    BOOL ok = NO;
    @try {
        ok = [_presenter show:n];
    } @catch (NSException *e) {
        VILOG("show: %{public}@", e);
    }
    if (!ok && _presenter == _element && _element) {
        _flags |= VI_FLAG_ELEMENT_FAILED;
        [_element hide];
        if (!_overlay) _overlay = [VIOverlayPresenter new];
        _presenter = _overlay;
        @try { [_presenter show:n]; } @catch (NSException *e) { VILOG("overlay: %{public}@", e); }
    }
    [self publishStatus];
}

- (void)hidePresenters {
    @try { [_element hide]; } @catch (NSException *e) { VILOG("hide: %{public}@", e); }
    @try { [_overlay hide]; } @catch (NSException *e) { VILOG("hide: %{public}@", e); }
}

// Main queue. old/new: 0, 1, 2.
- (void)linkChangedFrom:(int)old to:(int)now {
    _link = now;
    _testing = NO;
    if (!_enabled) { [self publishStatus]; return; }
    if (now == 2) [self present:[self linkNotice]];
    else {
        [self hidePresenters];
        if (now == 1 && old == 0 && _standard) [self present:[self standardNotice]];
    }
    [self publishStatus];
}

- (void)test {
    if (!_enabled) {
        VILOG("test ignored: disabled");
        return;
    }
    NSUInteger gen = ++_testGen;
    _testing = YES;
    [self present:[self linkNotice]];
    // Back to the real state after 3 s notice + 6 s compact.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self->_testGen != gen || !self->_testing) return;
        self->_testing = NO;
        if (self->_link != 2) [self hidePresenters];
    });
}

- (void)prefsChanged {
    BOOL was = _enabled;
    id<VIPresenter> old = _presenter;
    [self loadPrefs];
    if (!_enabled) [self hidePresenters];
    else if ((!was || old != _presenter) && _link == 2) [self present:[self linkNotice]];
    [self updateTimer];
    [self publishStatus];
}

// Poll queue: 1 s, cheap (one sysctl). Showing is immediate; hiding needs two readings below 2 (debounce).
- (void)poll {
    int raw = VIReadLinkState();
    BOOL missing = raw < 0;
    int v = (raw < 0 || raw > 2) ? 0 : raw;
    int prev = _polled;
    if (missing != _missing) {
        _missing = missing;
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_noSysctl = missing;
            [self publishStatus];
        });
    }
    if (v == prev) { _pendingLow = 0; return; }
    if (prev == 2 && v < 2 && ++_pendingLow < 2) return;
    _pendingLow = 0;
    _polled = v;
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            [self linkChangedFrom:prev to:v];
        } @catch (NSException *e) {
            VILOG("link change: %{public}@", e);
        }
    });
}

- (void)updateTimer {
    if (_enabled && !_timer) {
        _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _pollQueue);
        dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0), 1 * NSEC_PER_SEC, 250 * NSEC_PER_MSEC);
        __weak typeof(self) ws = self;
        dispatch_source_set_event_handler(_timer, ^{ [ws poll]; });
        dispatch_resume(_timer);
    } else if (!_enabled && _timer) {
        dispatch_source_cancel(_timer);
        _timer = nil;
        dispatch_async(_pollQueue, ^{ self->_polled = 0; self->_pendingLow = 0; });
        _link = 0;
    }
}

- (void)start {
    _pollQueue = dispatch_queue_create("it.viva.island.poll", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,
                                                                                                       QOS_CLASS_UTILITY, 0));
    _statusOK = notify_register_check(VI_NOTIFY_STATUS, &_statusToken) == NOTIFY_STATUS_OK;
    int t;
    __weak typeof(self) ws = self;
    notify_register_dispatch(VI_NOTIFY_TEST, &t, dispatch_get_main_queue(), ^(int token) {
        @try { [ws test]; } @catch (NSException *e) { VILOG("test: %{public}@", e); }
    });
    notify_register_dispatch(VI_NOTIFY_PREFS, &t, dispatch_get_main_queue(), ^(int token) {
        @try { [ws prefsChanged]; } @catch (NSException *e) { VILOG("prefs: %{public}@", e); }
    });
    [self loadPrefs];
    [self publishStatus];
    [self updateTimer];
    VILOG("started: presenter %{public}@, flags 0x%x", NSStringFromClass([(NSObject *)_presenter class]), _flags);
}

@end

// ---- Entry point -----------------------------------------------------------------------------------------------------

static void VIStartOnce(NSString *why) {
    static BOOL started;
    if (started) return;
    started = YES;
    VILOG("start (%{public}@)", why);
    @try {
        [[VIController shared] start];
    } @catch (NSException *e) {
        VILOG("start: %{public}@", e);
    }
}

__attribute__((constructor)) static void VIInit(void) {
    @autoreleasepool {
        VILog = os_log_create("it.viva.island", "tweak");
        if (strcmp(getprogname(), "SpringBoard") != 0) return;
        // SBSystemApertureController exists once SpringBoard has finished launching (window scenes are up): start 3 s
        // after UIApplicationDidFinishLaunching, or 30 s after the main queue first runs if that never arrives.
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil
                                                         queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                VIStartOnce(@"launched");
            });
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            VIStartOnce(@"timeout");
        });
        VILOG("loaded in SpringBoard[%d]", getpid());
    }
}
