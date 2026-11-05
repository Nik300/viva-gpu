// MaliMetal › Compilatore ISA (AIR → Valhall): the ISA compiler's flags (a subpage of the vmg.env editor, with a master
// switch), the compatibility check (the path generates Mali-G57 code only) and the test cases of
// driver/tests/isa_cases.m with their panel (ISA GPU, NIR GPU, CPU reference, difference map, timings).
// docs/ANALISI-ISA-DIRETTA-2026-11-04.md §2.
#import "VMApp.h"
#import <Metal/Metal.h>
#include "tests/isa_cases.h"

static NSString *const kIsaWarning = @"Questo compilatore genera codice macchina esclusivamente per la GPU Mali-G57 MC2 "
    @"(Valhall v9, MediaTek Helio G96). Su qualsiasi altra GPU va lasciato spento.";
static NSString *const VMIsaRunDidChangeNotification = @"VMIsaRunDidChangeNotification";

// The process's Metal device (the Viva driver on the phone). Loaded once: it is also the one the tests run on.
static id<MTLDevice> VMIsaDevice(void) {
    static id<MTLDevice> dev;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ dev = MTLCreateSystemDefaultDevice(); });
    return dev;
}

BOOL VMIsaCompatible(NSString **name) {
    NSString *gpu = VMIsaDevice().name;
    BOOL ok = gpu && [gpu rangeOfString:@"Mali-G57" options:NSCaseInsensitiveSearch].location != NSNotFound;
    // The driver's statistics pages may publish the GPU product id (0x9093 = Mali-G57).
    for (VMDriverProc *p in VMStats.shared.driverProcs)
        if (!ok && p.gpuProductId == 0x9093) { ok = YES; if (!gpu) gpu = @"Mali-G57 (id 0x9093)"; }
    if (name) *name = gpu ?: @"nessun dispositivo Metal";
    return ok;
}

static UIColor *VMOkColor(BOOL ok) { return ok ? UIColor.systemGreenColor : UIColor.systemRedColor; }

// ---- Results of the test cases (one run = ISA mode + NIR mode) -----------------------------------------------------------

@interface VMIsaRun : NSObject
@property (nonatomic) BOOL done, running;
@property (nonatomic) isa_result isaRes, nirRes;
@property (nonatomic, strong, nullable) NSData *isaRGBA, *nirRGBA, *isaDiff, *nirDiff;
@end
@implementation VMIsaRun
@end

static NSMutableDictionary<NSNumber *, VMIsaRun *> *VMIsaRuns(void) {
    static NSMutableDictionary *runs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ runs = [NSMutableDictionary dictionary]; });
    return runs;
}

// Runs case i in both modes on one serial queue (the runner changes process-wide environment variables).
static void VMIsaRunCase(int i) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("viva.isa.tests", DISPATCH_QUEUE_SERIAL); });
    VMIsaRun *r = VMIsaRuns()[@(i)] ?: [VMIsaRun new];
    if (r.running) return;
    r.running = YES;
    VMIsaRuns()[@(i)] = r;
    [NSNotificationCenter.defaultCenter postNotificationName:VMIsaRunDidChangeNotification object:@(i)];
    dispatch_async(q, ^{
        const isa_case *c = &isa_cases[i];
        size_t n = (size_t)c->w * c->h;
        NSMutableData *ii = [NSMutableData dataWithLength:n * 4], *ni = [NSMutableData dataWithLength:n * 4];
        NSMutableData *id_ = [NSMutableData dataWithLength:n * sizeof(float)], *nd = [NSMutableData dataWithLength:n * sizeof(float)];
        isa_result a = isa_run_case(VMIsaDevice(), c, ISA_MODE_ISA, ii.mutableBytes, id_.mutableBytes);
        isa_result b = isa_run_case(VMIsaDevice(), c, ISA_MODE_NIR, ni.mutableBytes, nd.mutableBytes);
        dispatch_async(dispatch_get_main_queue(), ^{
            r.isaRes = a; r.nirRes = b;
            r.isaRGBA = ii; r.nirRGBA = ni; r.isaDiff = id_; r.nirDiff = nd;
            r.done = YES;
            r.running = NO;
            [NSNotificationCenter.defaultCenter postNotificationName:VMIsaRunDidChangeNotification object:@(i)];
        });
    });
}

static NSString *VMIsaSummary(VMIsaRun *r) {
    if (!r) return @"non eseguito";
    if (r.running) return @"in corso…";
    return [NSString stringWithFormat:@"ISA %@ · NIR %@ · %.2f / %.2f ms", r.isaRes.ok ? @"ok" : @"ko", r.nirRes.ok ? @"ok" : @"ko",
            r.isaRes.gpu_ms, r.nirRes.gpu_ms];
}

static NSString *VMLetterTitle(unichar l) {
    switch (l) {
    case 'A': return @"A · Infrastruttura";
    case 'B': return @"B · Stadi, ingressi e uscite";
    case 'C': return @"C · Memoria";
    case 'D': return @"D · Texture e sampler";
    case 'E': return @"E · ALU e libreria matematica";
    case 'F': return @"F · Subgroup e quad";
    case 'G': return @"G · Lacune di oggi";
    }
    return [NSString stringWithCharacters:&l length:1];
}

// ---- Images --------------------------------------------------------------------------------------------------------------

static UIImage *VMImageRGBA(NSData *rgba, int w, int h) {
    if (rgba.length < (NSUInteger)w * h * 4) return nil;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef dp = CGDataProviderCreateWithCFData((__bridge CFDataRef)rgba);
    CGImageRef img = CGImageCreate((size_t)w, (size_t)h, 8, 32, (size_t)w * 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrderDefault,
                                   dp, NULL, false, kCGRenderingIntentDefault);
    UIImage *u = img ? [UIImage imageWithCGImage:img] : nil;
    CGImageRelease(img);
    CGDataProviderRelease(dp);
    CGColorSpaceRelease(cs);
    return u;
}

// error / tolerance per pixel: black = equal, green = within tolerance, red = out, grey = not checked.
static UIImage *VMDiffImage(NSData *diff, int w, int h) {
    if (diff.length < (NSUInteger)w * h * sizeof(float)) return nil;
    const float *d = diff.bytes;
    NSMutableData *rgba = [NSMutableData dataWithLength:(NSUInteger)w * h * 4];
    uint8_t *p = rgba.mutableBytes;
    for (int i = 0; i < w * h; i++, p += 4) {
        float q = d[i];
        if (q < 0) { p[0] = p[1] = p[2] = 90; }
        else if (q > 1) { p[0] = 255; p[1] = 40; p[2] = 40; }
        else { p[0] = 0; p[1] = q > 0 ? (uint8_t)(50 + 150 * q) : 0; p[2] = 0; }
        p[3] = 255;
    }
    return VMImageRGBA(rgba, w, h);
}

static UIImageView *VMPixelView(void) {
    UIImageView *v = [UIImageView new];
    v.contentMode = UIViewContentModeScaleAspectFit;
    v.layer.magnificationFilter = kCAFilterNearest;
    v.backgroundColor = UIColor.tertiarySystemFillColor;
    v.translatesAutoresizingMaskIntoConstraints = NO;
    return v;
}

// ---- Panel of one case ------------------------------------------------------------------------------------------------------

@interface VMIsaPanelViewController : UIViewController
- (instancetype)initWithCase:(int)index;
@end

@implementation VMIsaPanelViewController {
    int _index;
    UILabel *_status, *_metrics, *_notes;
    UIImageView *_isaView, *_nirView, *_cpuView, *_diffView;
    UISegmentedControl *_diffMode;
    UIButton *_run;
}

- (instancetype)initWithCase:(int)index {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _index = index;
        self.title = [NSString stringWithFormat:@"Test %s", isa_cases[index].id];
    }
    return self;
}

- (UILabel *)label:(UIFont *)font {
    UILabel *l = [UILabel new];
    l.font = font;
    l.numberOfLines = 0;
    return l;
}

- (UIView *)tile:(UIImageView *)v caption:(NSString *)caption aspect:(CGFloat)aspect {
    UILabel *l = [self label:[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold]];
    l.text = caption;
    l.textAlignment = NSTextAlignmentCenter;
    l.textColor = UIColor.secondaryLabelColor;
    [v.heightAnchor constraintEqualToAnchor:v.widthAnchor multiplier:aspect].active = YES;
    UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:@[v, l]];
    s.axis = UILayoutConstraintAxisVertical;
    s.spacing = 4;
    return s;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    const isa_case *c = &isa_cases[_index];
    CGFloat aspect = (CGFloat)c->h / c->w;

    UIScrollView *sv = [UIScrollView new];
    sv.translatesAutoresizingMaskIntoConstraints = NO;
    sv.alwaysBounceVertical = YES;
    [self.view addSubview:sv];
    UIStackView *st = [UIStackView new];
    st.axis = UILayoutConstraintAxisVertical;
    st.spacing = 12;
    st.translatesAutoresizingMaskIntoConstraints = NO;
    [sv addSubview:st];
    UILayoutGuide *g = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [sv.topAnchor constraintEqualToAnchor:g.topAnchor], [sv.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [sv.leadingAnchor constraintEqualToAnchor:g.leadingAnchor], [sv.trailingAnchor constraintEqualToAnchor:g.trailingAnchor],
        [st.topAnchor constraintEqualToAnchor:sv.contentLayoutGuide.topAnchor constant:16],
        [st.bottomAnchor constraintEqualToAnchor:sv.contentLayoutGuide.bottomAnchor constant:-24],
        [st.leadingAnchor constraintEqualToAnchor:sv.frameLayoutGuide.leadingAnchor constant:16],
        [st.trailingAnchor constraintEqualToAnchor:sv.frameLayoutGuide.trailingAnchor constant:-16],
    ]];

    UILabel *title = [self label:[UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]];
    title.text = [NSString stringWithFormat:@"%s  %s", c->id, c->title];
    [st addArrangedSubview:title];
    char only[256];
    const char *o = isa_case_only(c, only, sizeof only);
    UILabel *env = [self label:VMMono(11)];
    env.textColor = UIColor.secondaryLabelColor;
    env.text = [NSString stringWithFormat:@"ISA: VMG_ISA=1 VMG_ISA_STRICT=1%@%@\nNIR: VMG_ISA=0 · %d×%d · %d ripetizioni per il tempo",
                o ? @" VMG_ISA_ONLY=" : @"", o ? @(o) : @"", c->w, c->h, ISA_TIMING_RUNS];
    [st addArrangedSubview:env];
    _status = [self label:[UIFont systemFontOfSize:20 weight:UIFontWeightBold]];
    [st addArrangedSubview:_status];

    _isaView = VMPixelView(); _nirView = VMPixelView(); _cpuView = VMPixelView();
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[
        [self tile:_isaView caption:@"ISA (GPU)" aspect:aspect], [self tile:_nirView caption:@"NIR (GPU)" aspect:aspect],
        [self tile:_cpuView caption:@"CPU (riferimento)" aspect:aspect]]];
    row.distribution = UIStackViewDistributionFillEqually;
    row.spacing = 8;
    row.alignment = UIStackViewAlignmentTop;
    [st addArrangedSubview:row];

    _diffMode = [[UISegmentedControl alloc] initWithItems:@[@"Differenze ISA", @"Differenze NIR"]];
    _diffMode.selectedSegmentIndex = 0;
    [_diffMode addTarget:self action:@selector(refresh) forControlEvents:UIControlEventValueChanged];
    [st addArrangedSubview:_diffMode];
    _diffView = VMPixelView();
    [_diffView.heightAnchor constraintEqualToAnchor:_diffView.widthAnchor multiplier:aspect].active = YES;
    [st addArrangedSubview:_diffView];
    UILabel *legend = [self label:[UIFont systemFontOfSize:12]];
    legend.textColor = UIColor.secondaryLabelColor;
    legend.text = @"Nero = uguale · verde = entro la tolleranza · rosso = fuori tolleranza · grigio = non controllato. "
                  @"Immagini ingrandite senza filtro; i valori fuori da 0…1 sono riscalati, gli interi mostrano il byte basso.";
    [st addArrangedSubview:legend];

    _metrics = [self label:VMMono(13)];
    [st addArrangedSubview:_metrics];
    _notes = [self label:[UIFont systemFontOfSize:13]];
    _notes.textColor = UIColor.secondaryLabelColor;
    [st addArrangedSubview:_notes];

    _run = [UIButton buttonWithType:UIButtonTypeSystem];
    [_run setTitle:@"Esegui di nuovo" forState:UIControlStateNormal];
    _run.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    [_run addTarget:self action:@selector(runAgain) forControlEvents:UIControlEventTouchUpInside];
    [st addArrangedSubview:_run];

    NSMutableData *cpu = [NSMutableData dataWithLength:(NSUInteger)c->w * c->h * 4];
    isa_cpu_reference(c, cpu.mutableBytes);
    _cpuView.image = VMImageRGBA(cpu, c->w, c->h);

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(runChanged:) name:VMIsaRunDidChangeNotification object:nil];
    if (!VMIsaRuns()[@(_index)] && VMIsaCompatible(NULL)) VMIsaRunCase(_index);
    [self refresh];
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)runChanged:(NSNotification *)n { if ([n.object intValue] == _index) [self refresh]; }

- (void)runAgain { VMIsaRunCase(_index); }

- (void)refresh {
    const isa_case *c = &isa_cases[_index];
    VMIsaRun *r = VMIsaRuns()[@(_index)];
    NSString *gpu;
    BOOL compatible = VMIsaCompatible(&gpu);
    _run.enabled = compatible && !r.running;
    if (!compatible) {
        _status.text = [NSString stringWithFormat:@"GPU rilevata: %@ — non compatibile, test disattivati", gpu];
        _status.textColor = UIColor.systemRedColor;
        _status.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    } else if (!r.done) {
        _status.text = r.running ? @"In corso…" : @"Non eseguito";
        _status.textColor = UIColor.secondaryLabelColor;
    } else {
        _status.text = [NSString stringWithFormat:@"%@%@", r.isaRes.ok ? @"ISA ok" : @"ISA ko", r.nirRes.ok ? @" · NIR ok" : @" · NIR ko"];
        _status.textColor = VMOkColor(r.isaRes.ok);
    }
    if (!r.done) {
        _metrics.text = nil;
        _notes.text = c->mac_note ? [NSString stringWithFormat:@"Sul Mac (llvmpipe): %s", c->mac_note] : nil;
        return;
    }
    _isaView.image = VMImageRGBA(r.isaRGBA, c->w, c->h);
    _nirView.image = VMImageRGBA(r.nirRGBA, c->w, c->h);
    _diffView.image = VMDiffImage(_diffMode.selectedSegmentIndex == 0 ? r.isaDiff : r.nirDiff, c->w, c->h);
    _metrics.text = [NSString stringWithFormat:@"errore massimo  ISA %.3g · NIR %.3g\nfuori tolleranza  ISA %.2f%% · NIR %.2f%%\n"
                                               @"ISA %.3f ms / NIR %.3f ms",
                     r.isaRes.max_err, r.nirRes.max_err, r.isaRes.pct_bad, r.nirRes.pct_bad, r.isaRes.gpu_ms, r.nirRes.gpu_ms];
    NSMutableArray *notes = [NSMutableArray array];
    if (r.isaRes.note[0]) [notes addObject:[NSString stringWithFormat:@"ISA: %s", r.isaRes.note]];
    if (r.nirRes.note[0]) [notes addObject:[NSString stringWithFormat:@"NIR: %s", r.nirRes.note]];
    if (c->mac_note) [notes addObject:[NSString stringWithFormat:@"Noto sul Mac (llvmpipe): %s", c->mac_note]];
    _notes.text = [notes componentsJoinedByString:@"\n"];
}

@end

// ---- List of the cases -------------------------------------------------------------------------------------------------------

@interface VMIsaTestsViewController : UITableViewController
@end

@implementation VMIsaTestsViewController {
    NSArray<NSArray<NSNumber *> *> *_sections;   // case indexes by letter
    NSArray<NSString *> *_titles;
}

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Test ISA";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.tableView.estimatedRowHeight = 56;
    NSMutableArray *secs = [NSMutableArray array], *titles = [NSMutableArray array];
    unichar last = 0;
    for (int i = 0; i < isa_case_count; i++) {
        unichar l = (unichar)isa_cases[i].id[0];
        if (l != last) { [secs addObject:[NSMutableArray array]]; [titles addObject:VMLetterTitle(l)]; last = l; }
        [secs.lastObject addObject:@(i)];
    }
    _sections = secs;
    _titles = titles;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Esegui tutti" style:UIBarButtonItemStylePlain
                                                                             target:self action:@selector(runAll)];
    self.navigationItem.rightBarButtonItem.enabled = VMIsaCompatible(NULL);
    [NSNotificationCenter.defaultCenter addObserver:self.tableView selector:@selector(reloadData) name:VMIsaRunDidChangeNotification object:nil];
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self.tableView]; }

- (void)runAll { for (int i = 0; i < isa_case_count; i++) VMIsaRunCase(i); }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return (NSInteger)_sections.count + 1; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return s == 0 ? 1 : (NSInteger)_sections[s - 1].count;
}
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return s == 0 ? nil : _titles[s - 1]; }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s != 0) return nil;
    return @"Ogni caso disegna con una pipeline minima che usa una sola funzionalità della §4, forzata sul percorso ISA "
           @"(VMG_ISA_STRICT: se la funzione torna al percorso NIR il caso fallisce), poi sul percorso NIR, e la confronta "
           @"con il calcolo della CPU. Da riga di comando: /private/var/root/viva-tests/isatest [ID…].";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.textLabel.numberOfLines = 0;
    if (ip.section == 0) {
        NSString *gpu;
        BOOL ok = VMIsaCompatible(&gpu);
        int done = 0, isaOk = 0, nirOk = 0;
        for (VMIsaRun *r in VMIsaRuns().allValues) if (r.done) { done++; isaOk += r.isaRes.ok; nirOk += r.nirRes.ok; }
        c.textLabel.text = ok ? [NSString stringWithFormat:@"GPU rilevata: %@ — compatibile", gpu]
                              : [NSString stringWithFormat:@"GPU rilevata: %@ — non compatibile, test disattivati", gpu];
        c.textLabel.textColor = VMOkColor(ok);
        c.detailTextLabel.text = [NSString stringWithFormat:@"%d casi · eseguiti %d · ISA ok %d · NIR ok %d", isa_case_count, done, isaOk, nirOk];
        c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
        return c;
    }
    int i = _sections[ip.section - 1][ip.row].intValue;
    const isa_case *k = &isa_cases[i];
    VMIsaRun *r = VMIsaRuns()[@(i)];
    NSMutableAttributedString *t = [[NSMutableAttributedString alloc] initWithString:[NSString stringWithFormat:@"%-4s", k->id]
        attributes:@{NSFontAttributeName: VMMono(15)}];
    [t appendAttributedString:[[NSAttributedString alloc] initWithString:@(k->title) attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:15]}]];
    c.textLabel.attributedText = t;
    c.detailTextLabel.text = VMIsaSummary(r);
    c.detailTextLabel.font = VMMono(12);
    c.detailTextLabel.textColor = r.done ? VMOkColor(r.isaRes.ok) : UIColor.secondaryLabelColor;
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 0) return;
    // The panel also opens without a compatible GPU (CPU reference only, no run).
    int i = _sections[ip.section - 1][ip.row].intValue;
    [self.navigationController pushViewController:[[VMIsaPanelViewController alloc] initWithCase:i] animated:YES];
}

@end

// ---- Settings subpage -----------------------------------------------------------------------------------------------------

@implementation VMIsaViewController {
    NSDictionary *_group;
    __weak VMMaliMetalViewController *_flags;
    NSArray<NSDictionary *> *_general;                 // VMG_ISA, STRICT, TRACE, ONLY
    NSArray<NSArray<NSDictionary *> *> *_features;     // VMG_ISA_NO_<ID> by letter
    NSArray<NSString *> *_featureTitles;
}

enum { SecWarning, SecMaster, SecGeneral, SecTests, SecFirstFeature };

- (instancetype)initWithGroup:(NSDictionary *)group flags:(VMMaliMetalViewController *)flags {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        _group = group;
        _flags = flags;
        self.title = @"Compilatore ISA";
        NSMutableArray *general = [NSMutableArray array], *features = [NSMutableArray array], *titles = [NSMutableArray array];
        unichar last = 0;
        for (NSDictionary *i in group[@"items"]) {
            NSString *k = i[@"key"];
            if (![i[@"invert"] boolValue] || ![k hasPrefix:@"VMG_ISA_NO_"]) { [general addObject:i]; continue; }
            unichar l = [k characterAtIndex:11];
            if (l != last) { [features addObject:[NSMutableArray array]]; [titles addObject:VMLetterTitle(l)]; last = l; }
            [features.lastObject addObject:i];
        }
        _general = general;
        _features = features;
        _featureTitles = titles;
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.tableView.estimatedRowHeight = 60;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Salva" style:UIBarButtonItemStyleDone
                                                                             target:self action:@selector(save)];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(flagsChanged) name:VMFlagsDidChangeNotification object:nil];
    [self flagsChanged];
}

- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }

- (void)flagsChanged {
    self.navigationItem.rightBarButtonItem.enabled = _flags.dirty;
    [self.tableView reloadData];
}

- (void)save { [_flags presentSaveFrom:self item:self.navigationItem.rightBarButtonItem]; }

- (BOOL)isaOn {
    NSString *v = [_flags flagValue:@"VMG_ISA"];
    return v.length && ![v isEqualToString:@"0"];
}

// Master switch: on = VMG_ISA=1 with every feature on the ISA path (no VMG_ISA_NO_*, no VMG_ISA_ONLY).
- (BOOL)allOn {
    if (!self.isaOn || [_flags flagValue:@"VMG_ISA_ONLY"]) return NO;
    for (NSArray *s in _features) for (NSDictionary *i in s) if ([_flags flagValue:i[@"key"]]) return NO;
    return YES;
}

- (void)setAll:(BOOL)on {
    NSMutableDictionary *v = [NSMutableDictionary dictionary];
    if (on) {
        v[@"VMG_ISA"] = @"1";
        v[@"VMG_ISA_ONLY"] = NSNull.null;
        for (NSArray *s in _features) for (NSDictionary *i in s) v[i[@"key"]] = NSNull.null;
    } else {
        v[@"VMG_ISA"] = NSNull.null;   // everything back to AIR -> NIR -> Panfrost; the per-feature choices stay
    }
    [_flags setFlagValues:v];
    [_flags presentSaveFrom:self item:self.navigationItem.rightBarButtonItem];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return SecFirstFeature + (NSInteger)_features.count; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    switch (s) {
    case SecWarning: return 2;
    case SecMaster: return 1;
    case SecGeneral: return (NSInteger)_general.count;
    case SecTests: return 1;
    }
    return (NSInteger)_features[s - SecFirstFeature].count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    switch (s) {
    case SecWarning: return @"Avviso";
    case SecMaster: return @"Interruttore rapido";
    case SecGeneral: return @"Generale e debug";
    case SecTests: return @"Verifica";
    }
    return _featureTitles[s - SecFirstFeature];
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == SecMaster)
        return @"Acceso: VMG_ISA=1 e tutte le funzionalità sul percorso ISA. Spento: tutto torna al percorso AIR → NIR → "
               @"Panfrost. Non tocca la modalità rigorosa né la traccia. Come gli altri flag vale per i processi che partono "
               @"dopo il salvataggio (backboardd: riavvio).";
    if (s == SecFirstFeature)
        return @"Acceso = la funzionalità passa dal percorso ISA. Spento (VMG_ISA_NO_<ID>=1) = ogni funzione che la usa torna "
               @"al percorso NIR. Le funzionalità valgono solo con l'interruttore generale acceso.";
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSString *gpu;
    BOOL ok = VMIsaCompatible(&gpu);
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.textLabel.numberOfLines = 0;
    c.detailTextLabel.numberOfLines = 0;
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    if (ip.section == SecWarning) {
        if (ip.row == 0) {
            c.textLabel.text = kIsaWarning;
            c.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
            c.imageView.image = [UIImage systemImageNamed:@"exclamationmark.triangle.fill"];
            c.imageView.tintColor = UIColor.systemOrangeColor;
        } else {
            c.textLabel.text = ok ? [NSString stringWithFormat:@"GPU rilevata: %@ — compatibile", gpu]
                                  : [NSString stringWithFormat:@"GPU rilevata: %@ — non compatibile, impostazioni disattivate", gpu];
            c.textLabel.textColor = VMOkColor(ok);
            c.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
            c.imageView.image = [UIImage systemImageNamed:ok ? @"checkmark.seal.fill" : @"xmark.octagon.fill"];
            c.imageView.tintColor = VMOkColor(ok);
        }
        return c;
    }
    if (ip.section == SecMaster) {
        BOOL all = self.allOn;
        c.textLabel.text = @"Tutto acceso / spento";
        c.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        NSUInteger off = 0;
        for (NSArray *s in _features) for (NSDictionary *i in s) if ([_flags flagValue:i[@"key"]]) off++;
        c.detailTextLabel.text = all ? @"Acceso: tutte le funzionalità sul percorso ISA"
            : !self.isaOn ? @"Spento: tutti gli shader sul percorso NIR"
            : [NSString stringWithFormat:@"Parziale: %lu funzionalità sul percorso NIR%@", (unsigned long)off,
               [_flags flagValue:@"VMG_ISA_ONLY"] ? @", VMG_ISA_ONLY impostato" : @""];
        c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        VMSwitch *sw = [VMSwitch new];
        sw.on = all;
        sw.enabled = ok;
        __weak typeof(self) ws = self;
        sw.onChange = ^(BOOL on) { [ws setAll:on]; };
        c.accessoryView = sw;
        if (!ok) c.contentView.alpha = 0.5;
        return c;
    }
    if (ip.section == SecTests) {
        c.textLabel.text = @"Test ISA";
        c.detailTextLabel.text = ok ? [NSString stringWithFormat:@"%d casi: GPU con il percorso ISA, GPU con il percorso NIR e CPU",
                                       isa_case_count]
                                    : @"Non eseguibili su questa GPU";
        c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        c.imageView.image = [UIImage systemImageNamed:@"checklist"];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        c.selectionStyle = UITableViewCellSelectionStyleDefault;
        return c;
    }
    NSDictionary *item = ip.section == SecGeneral ? _general[ip.row] : _features[ip.section - SecFirstFeature][ip.row];
    UITableViewCell *f = [_flags cellForFlag:item enabled:ok];
    return f ?: c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == SecTests) {
        [self.navigationController pushViewController:[VMIsaTestsViewController new] animated:YES];
        return;
    }
    if (!VMIsaCompatible(NULL)) return;   // greyed out: nothing to edit on another GPU
    if (ip.section == SecGeneral) [_flags editFlag:_general[ip.row] from:self source:[tv cellForRowAtIndexPath:ip]];
}

@end
