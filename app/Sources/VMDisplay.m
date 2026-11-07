// Display: panel refresh 60 / 120 Hz / automatic (kernel 0189, `disp hz` through vmhelper link; boot-arg vivapanelhz
// for the next boots through vmhelper bootargs-set). State from `disp kv` (read-only, no helper).
#import "VMApp.h"

enum { SecRate, SecState, SecCount };

@implementation VMDisplayViewController {
    NSDictionary<NSString *, NSString *> *_kv;     // disp kv (nil: kernel without it)
    NSString *_error;
}

- (instancetype)init {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) self.title = @"Display";
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    UIRefreshControl *rc = [UIRefreshControl new];
    [rc addTarget:self action:@selector(pullRefresh:) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = rc;
    [self reload];
}

- (void)pullRefresh:(UIRefreshControl *)rc { [self reload]; [rc endRefreshing]; }

- (void)reload {
    int err = 0;
    NSString *out = [VMSystem link:@"disp kv" error:&err];
    NSMutableDictionary *kv = [NSMutableDictionary dictionary];
    for (NSString *l in [out componentsSeparatedByString:@"\n"]) {
        NSRange eq = [l rangeOfString:@"="];
        if (eq.location != NSNotFound) kv[[l substringToIndex:eq.location]] = [l substringFromIndex:eq.location + 1];
    }
    _kv = kv[@"panel_hz"] ? kv : nil;
    _error = out ? nil : [NSString stringWithFormat:@"kern.viva_link: %s", strerror(err)];
    [self.tableView reloadData];
}

// 60, 120 or 1 (auto) from disp kv.
- (int)mode { return _kv ? [_kv[@"hz_mode"] intValue] : 60; }

- (void)setMode:(int)mode {
    NSString *arg = mode == 1 ? @"auto" : mode == 120 ? @"120" : @"60";
    VMRunHelper(@[@"link", @"disp", @"hz", arg], nil, ^(int status, NSString *out) {
        if (status != 0) { VMAlert(self, @"Frequenza non cambiata", out); [self reload]; return; }
        // The switch happens at the next vsync tick: read the state back a moment later.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ [self reload]; });
        [self persist:mode];
    });
}

// vivapanelhz in the next boot's command line (absent = 60).
- (void)persist:(int)mode {
    VMRunHelper(@[@"bootargs-get"], nil, ^(int status, NSString *out) {
        NSArray *lines = [out componentsSeparatedByString:@"\n"];
        NSString *line = status == 0 && lines.count > 1 && [lines[1] length] ? lines[1] : [VMSystem sysctlString:"kern.bootargs"];
        NSMutableArray *tokens = [NSMutableArray array];
        for (NSString *t in [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet])
            if (t.length && ![t hasPrefix:@"vivapanelhz="]) [tokens addObject:t];
        if (mode != 60) [tokens addObject:[NSString stringWithFormat:@"vivapanelhz=%d", mode]];
        VMRunHelper(@[@"bootargs-set"], [tokens componentsJoinedByString:@" "], ^(int s, NSString *o) {
            VMToast(self, s == 0 ? @"Applicato e salvato per i prossimi avvii" : @"Applicato (non salvato nei boot-arg)");
        });
    });
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return SecCount; }

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return s == SecRate ? @"Frequenza di aggiornamento" : @"Stato";
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s != SecRate) return nil;
    if (!_kv) return _error ?: @"Il kernel in esecuzione non ha il cambio di frequenza (patch 0189).";
    return @"120 Hz: il pannello e il vsync di CoreAnimation vanno al doppio (scroll e animazioni più fluide dove la GPU ce la fa, "
           @"più consumo). Automatica: 120 Hz mentre lo schermo disegna, 60 Hz dopo mezzo secondo fermo o a schermo spento.";
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return s == SecRate ? 1 : 3; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    if (ip.section == SecRate) {
        UISegmentedControl *seg = [[UISegmentedControl alloc] initWithItems:@[@"60 Hz", @"120 Hz", @"Automatica"]];
        int m = [self mode];
        seg.selectedSegmentIndex = m == 120 ? 1 : m == 1 ? 2 : 0;
        seg.enabled = _kv != nil;
        [seg addTarget:self action:@selector(segChanged:) forControlEvents:UIControlEventValueChanged];
        seg.translatesAutoresizingMaskIntoConstraints = NO;
        [c.contentView addSubview:seg];
        [NSLayoutConstraint activateConstraints:@[
            [seg.leadingAnchor constraintEqualToAnchor:c.contentView.layoutMarginsGuide.leadingAnchor],
            [seg.trailingAnchor constraintEqualToAnchor:c.contentView.layoutMarginsGuide.trailingAnchor],
            [seg.topAnchor constraintEqualToAnchor:c.contentView.topAnchor constant:8],
            [seg.bottomAnchor constraintEqualToAnchor:c.contentView.bottomAnchor constant:-8],
        ]];
        return c;
    }
    NSArray *titles = @[@"Pannello ora", @"Cambi di frequenza", @"Cambi falliti"];
    NSArray *keys = @[@"panel_hz", @"hz_switches", @"hz_failures"];
    c.textLabel.text = titles[ip.row];
    NSString *v = _kv[keys[ip.row]];
    c.detailTextLabel.text = !v ? @"—" : ip.row == 0 ? [v stringByAppendingString:@" Hz"] : v;
    return c;
}

- (void)segChanged:(UISegmentedControl *)seg {
    [self setMode:seg.selectedSegmentIndex == 1 ? 120 : seg.selectedSegmentIndex == 2 ? 1 : 60];
}

@end
