// Statistics screens: a menu (Stat) and live tables for CPU, RAM, GPU and the MaliMetal driver.
#import "VMApp.h"

// ---- Live table: sections rebuilt at every sample ----------------------------------------------------------------------
// Section: {title, footer, rows}. Row: {t: title, d: value, s: subtitle, bar: 0..1, color, action: block, mono: @YES}.

@interface VMLiveTable : UITableViewController
@property (nonatomic, copy) NSArray<NSDictionary *> *sections;
@property (nonatomic, strong, nullable) VMSparkView *spark;
@property (nonatomic) BOOL wantsProcesses;
- (NSArray<NSDictionary *> *)buildSections;   // subclasses
- (void)updateSpark;                          // subclasses
@end

@implementation VMLiveTable

- (instancetype)init { return [super initWithStyle:UITableViewStyleInsetGrouped]; }

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.estimatedRowHeight = 50;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
}

- (void)addSpark:(UIColor *)color max:(double)max {
    self.spark = [[VMSparkView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 150)];
    self.spark.color = color;
    self.spark.maxValue = max;
    self.tableView.tableHeaderView = self.spark;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    VMStats *st = VMStats.shared;
    if (self.wantsProcesses) st.wantProcesses = YES;
    [st retainSampling];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(statsUpdated) name:VMStatsDidUpdateNotification object:nil];
    [self statsUpdated];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [NSNotificationCenter.defaultCenter removeObserver:self name:VMStatsDidUpdateNotification object:nil];
    if (self.wantsProcesses) VMStats.shared.wantProcesses = NO;
    [VMStats.shared releaseSampling];
}

- (void)statsUpdated {
    self.sections = [self buildSections];
    [self updateSpark];
    [self.tableView reloadData];
}

- (NSArray<NSDictionary *> *)buildSections { return @[]; }
- (void)updateSpark {}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return (NSInteger)self.sections.count; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return (NSInteger)[self.sections[s][@"rows"] count]; }
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s { return self.sections[s][@"title"]; }
- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s { return self.sections[s][@"footer"]; }

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *r = self.sections[ip.section][@"rows"][ip.row];
    BOOL sub = r[@"s"] != nil;
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:sub ? UITableViewCellStyleSubtitle : UITableViewCellStyleValue1
                                                reuseIdentifier:nil];
    c.textLabel.text = r[@"t"];
    c.textLabel.numberOfLines = 0;
    if ([r[@"mono"] boolValue]) c.textLabel.font = VMMono(14);
    if (sub) {
        c.detailTextLabel.text = r[@"s"];
        c.detailTextLabel.numberOfLines = 0;
        c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    } else if (!r[@"bar"]) {
        c.detailTextLabel.text = r[@"d"];
    }
    if (r[@"bar"] || (sub && r[@"d"])) {
        BOOL bar = r[@"bar"] != nil;
        UIView *acc = [[UIView alloc] initWithFrame:CGRectMake(0, 0, bar ? 170 : 110, 28)];
        UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(bar ? 112 : 0, 0, bar ? 58 : 110, 28)];
        l.text = r[@"d"];
        l.textAlignment = NSTextAlignmentRight;
        l.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightRegular];
        l.textColor = UIColor.secondaryLabelColor;
        l.adjustsFontSizeToFitWidth = YES;
        [acc addSubview:l];
        if (bar) {
            VMBarView *b = [[VMBarView alloc] initWithFrame:CGRectMake(0, 0, 104, 28)];
            b.fraction = [r[@"bar"] doubleValue];
            if (r[@"color"]) b.color = r[@"color"];
            [acc addSubview:b];
        }
        c.accessoryView = acc;
    }
    if (r[@"action"]) {
        if (!r[@"bar"] && !(sub && r[@"d"])) c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        if ([r[@"tint"] boolValue]) c.textLabel.textColor = self.view.tintColor;
    } else {
        c.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    void (^a)(void) = self.sections[ip.section][@"rows"][ip.row][@"action"];
    if (a) a();
}

@end

static NSDictionary *Row(NSString *t, NSString *d) { return @{@"t": t ?: @"", @"d": d ?: @"—"}; }
static NSString *Pct(double f) { return [NSString stringWithFormat:@"%.0f%%", f * 100]; }
static NSString *Num(double v) {
    if (v >= 1e9) return [NSString stringWithFormat:@"%.2f G", v / 1e9];
    if (v >= 1e6) return [NSString stringWithFormat:@"%.2f M", v / 1e6];
    if (v >= 1e4) return [NSString stringWithFormat:@"%.1f k", v / 1e3];
    return [NSString stringWithFormat:@"%.0f", v];
}
static NSString *Rate(double v) { return v < 10 && v > 0 ? [NSString stringWithFormat:@"%.1f/s", v] : [Num(v) stringByAppendingString:@"/s"]; }
static NSString *VMDuration(double s) {
    long t = (long)s;
    if (t >= 86400) return [NSString stringWithFormat:@"%ldg %ldh %ldm", t / 86400, t % 86400 / 3600, t % 3600 / 60];
    if (t >= 3600) return [NSString stringWithFormat:@"%ldh %ldm", t / 3600, t % 3600 / 60];
    return [NSString stringWithFormat:@"%ldm %lds", t / 60, t % 60];
}
static UIColor *LoadColor(double f) {
    return f > 0.85 ? UIColor.systemRedColor : f > 0.6 ? UIColor.systemOrangeColor : UIColor.systemGreenColor;
}

// ---- CPU ---------------------------------------------------------------------------------------------------------------

@interface VMCPUTable : VMLiveTable
@end
@implementation VMCPUTable
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"CPU";
    self.wantsProcesses = YES;
    [self addSpark:UIColor.systemGreenColor max:100];
}
- (void)updateSpark {
    VMStats *s = VMStats.shared;
    self.spark.values = s.cpuHistory;
    self.spark.caption = [NSString stringWithFormat:@"Utilizzo totale %@", Pct(s.cpuTotal)];
}
- (NSArray *)buildSections {
    VMStats *s = VMStats.shared;
    NSMutableArray *cores = [NSMutableArray array];
    NSUInteger n = s.coreLoad.count;
    for (NSUInteger i = 0; i < n; i++) {
        double f = s.coreLoad[i].doubleValue;
        // MT6781: cores 0-5 Cortex-A55, 6-7 Cortex-A76.
        NSString *kind = n == 8 ? (i < 6 ? @"A55 · efficienza" : @"A76 · prestazioni") : @"";
        [cores addObject:@{@"t": [NSString stringWithFormat:@"Core %lu", (unsigned long)i], @"s": kind, @"d": Pct(f),
                           @"bar": @(f), @"color": LoadColor(f)}];
    }
    NSArray *procs = [s.processes sortedArrayUsingComparator:^NSComparisonResult(VMProcSample *a, VMProcSample *b) {
        return a.cpuPercent > b.cpuPercent ? NSOrderedAscending : a.cpuPercent < b.cpuPercent ? NSOrderedDescending : NSOrderedSame;
    }];
    NSMutableArray *top = [NSMutableArray array];
    for (VMProcSample *p in procs) {
        if (top.count >= 15) break;
        [top addObject:@{@"t": p.name, @"s": [NSString stringWithFormat:@"pid %d · %@", p.pid, VMBytes(p.footprint)],
                         @"d": [NSString stringWithFormat:@"%.1f%%", p.cpuPercent], @"bar": @(MIN(p.cpuPercent / 100, 1)),
                         @"color": LoadColor(p.cpuPercent / 100)}];
    }
    return @[
        @{@"title": @"Utilizzo", @"rows": @[
            @{@"t": @"Totale", @"d": Pct(s.cpuTotal), @"bar": @(s.cpuTotal), @"color": LoadColor(s.cpuTotal)},
            Row(@"Utente", Pct(s.cpuUser)), Row(@"Sistema", Pct(s.cpuSystem)),
            @{@"t": @"Carico medio", @"s": @"1 / 5 / 15 minuti", @"d": [NSString stringWithFormat:@"%.2f %.2f %.2f", s.load1, s.load5, s.load15]},
            Row(@"Core attivi", [NSString stringWithFormat:@"%lu", (unsigned long)n]),
            Row(@"Processi", s.processes.count ? [NSString stringWithFormat:@"%lu", (unsigned long)s.processes.count] : @"…"),
            Row(@"Acceso da", VMDuration(s.uptime))]},
        @{@"title": @"Core (Helio G96)", @"rows": cores},
        @{@"title": @"Processi per CPU", @"footer": @"Percentuale di un core, aggiornata ogni 2 secondi.",
          @"rows": top.count ? top : @[Row(@"Lettura…", @"")]},
    ];
}
@end

// ---- RAM ---------------------------------------------------------------------------------------------------------------

@interface VMRAMTable : VMLiveTable
@end
@implementation VMRAMTable
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"RAM";
    self.wantsProcesses = YES;
    [self addSpark:UIColor.systemBlueColor max:100];
}
- (void)updateSpark {
    VMStats *s = VMStats.shared;
    double used = s.memActive + s.memWired + s.memCompressed;
    self.spark.values = s.memHistory;
    self.spark.caption = [NSString stringWithFormat:@"Usata %@ di %@", VMBytes(used), VMBytes(s.memTotal)];
}
- (NSArray *)buildSections {
    VMStats *s = VMStats.shared;
    double total = MAX(s.memTotal, 1);
    NSDictionary *(^part)(NSString *, NSString *, uint64_t, UIColor *) = ^(NSString *t, NSString *sub, uint64_t b, UIColor *c) {
        return @{@"t": t, @"s": sub, @"d": VMBytes(b), @"bar": @(b / total), @"color": c};
    };
    double used = s.memActive + s.memWired + s.memCompressed;
    NSArray *procs = [s.processes sortedArrayUsingComparator:^NSComparisonResult(VMProcSample *a, VMProcSample *b) {
        return a.footprint > b.footprint ? NSOrderedAscending : a.footprint < b.footprint ? NSOrderedDescending : NSOrderedSame;
    }];
    NSMutableArray *top = [NSMutableArray array];
    for (VMProcSample *p in procs) {
        if (top.count >= 15) break;
        [top addObject:@{@"t": p.name, @"s": [NSString stringWithFormat:@"pid %d · residente %@", p.pid, VMBytes(p.resident)],
                         @"d": VMBytes(p.footprint), @"bar": @(p.footprint / total), @"color": UIColor.systemBlueColor}];
    }
    return @[
        @{@"title": @"Memoria", @"rows": @[
            @{@"t": @"Usata", @"d": VMBytes(used), @"bar": @(used / total), @"color": LoadColor(used / total)},
            Row(@"Totale", VMBytes(s.memTotal)),
            Row(@"Disponibile (memorystatus)", s.memoryLevel >= 0 ? [NSString stringWithFormat:@"%d%%", s.memoryLevel] : nil)]},
        @{@"title": @"Composizione", @"rows": @[
            part(@"Wired", @"Kernel e memoria bloccata", s.memWired, UIColor.systemRedColor),
            part(@"Attiva", @"Usata di recente dai processi", s.memActive, UIColor.systemOrangeColor),
            part(@"Inattiva", @"Recuperabile (cache)", s.memInactive, UIColor.systemYellowColor),
            part(@"Compressa", @"Occupata dal compressore", s.memCompressed, UIColor.systemPurpleColor),
            part(@"Speculativa", @"Letture anticipate", s.memSpeculative, UIColor.systemTealColor),
            part(@"Purgeable", @"Liberabile dalle app", s.memPurgeable, UIColor.systemIndigoColor),
            part(@"Libera", @"", s.memFree, UIColor.systemGreenColor)]},
        @{@"title": @"Paginazione", @"rows": @[
            Row(@"Pagina", VMBytes(s.pageSize)), Row(@"Page-in", Num(s.pageins)), Row(@"Page-out", Num(s.pageouts)),
            Row(@"Compressioni", Num(s.compressions)), Row(@"Decompressioni", Num(s.decompressions)),
            Row(@"Swap in / out", [NSString stringWithFormat:@"%@ / %@", Num(s.swapins), Num(s.swapouts)])]},
        @{@"title": @"Processi per memoria", @"footer": @"Footprint fisico (come lo conta jetsam).",
          @"rows": top.count ? top : @[Row(@"Lettura…", @"")]},
    ];
}
@end

// ---- GPU ---------------------------------------------------------------------------------------------------------------

@interface VMGPUTable : VMLiveTable
@end
@implementation VMGPUTable
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"GPU";
    [self addSpark:UIColor.systemPinkColor max:100];
}
- (void)updateSpark {
    VMStats *s = VMStats.shared;
    if (s.gpuKernelStats) {
        self.spark.values = s.gpuLoadHistory;
        self.spark.caption = [NSString stringWithFormat:@"Carico DVFS %@%% · %@ MHz", s.gpu[@"load_pct"] ?: @"—", s.gpu[@"mhz"] ?: @"—"];
    } else {
        self.spark.values = s.driverBusyHistory;
        self.spark.caption = [NSString stringWithFormat:@"Occupazione stimata dal driver %@", Pct(s.driverGpuBusy)];
    }
}

- (void)link:(NSString *)cmd {
    VMRunHelper(@[@"link", cmd], nil, ^(int status, NSString *out) {
        if (status != 0) VMAlert(self, cmd, out);
        else VMToast(self, out.length > 160 ? [out substringToIndex:160] : out);
    });
}

- (void)linkSequence:(NSArray<NSString *> *)cmds {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSString *last = @"";
        int status = 0;
        for (NSString *c in cmds) {
            NSMutableArray *args = [@[@"link"] mutableCopy];
            [args addObjectsFromArray:[c componentsSeparatedByString:@" "]];
            NSString *out = nil;
            status = [VMSystem runHelper:args input:nil output:&out];
            last = out ?: @"";
            if (status != 0) break;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (status != 0) VMAlert(self, @"GPU", last); else VMToast(self, last);
        });
    });
}

- (void)chooseFrequency {
    NSString *t = [VMSystem link:@"gpu freq" error:NULL] ?: @"";
    NSString *table = [t componentsSeparatedByString:@"table (MHz):"].lastObject;
    NSMutableArray *opps = [NSMutableArray array];
    for (NSString *x in [table componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet])
        if (x.intValue > 0 && ![opps containsObject:x]) [opps addObject:x];
    if (!opps.count) opps = [@[@"300", @"400", @"550", @"700", @"850", @"950"] mutableCopy];
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Frequenza della GPU"
        message:@"Fissa spegne il DVFS fino al prossimo riavvio (o finché scegli Automatica)." preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:@"Automatica (DVFS)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        // After "gpu freq X" the DVFS takes X as its floor: back to 300 first.
        [self linkSequence:@[@"gpu dvfs off", @"gpu freq 300", @"gpu dvfs on"]];
    }]];
    for (NSString *o in opps) {
        [a addAction:[UIAlertAction actionWithTitle:[o stringByAppendingString:@" MHz fissi"] style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *x) { [self linkSequence:@[@"gpu dvfs off", [@"gpu freq " stringByAppendingString:o]]]; }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Annulla" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.sourceView = self.view;
    [self presentViewController:a animated:YES completion:nil];
}

- (void)showRaw:(NSString *)cmd {
    NSString *(^get)(void) = ^NSString * {
        int err = 0;
        return [VMSystem link:cmd error:&err] ?: [NSString stringWithFormat:@"kern.viva_link: %s", strerror(err)];
    };
    VMTextViewController *t = [[VMTextViewController alloc] initWithTitle:cmd text:get() editable:NO save:nil];
    t.reload = get;
    [self.navigationController pushViewController:t animated:YES];
}

- (NSArray *)buildSections {
    VMStats *s = VMStats.shared;
    NSDictionary *g = s.gpu, *d = s.disp;
    __weak typeof(self) ws = self;
    NSMutableArray *sections = [NSMutableArray array];
    // Driver-side numbers exist without the kernel too.
    double mem = 0, cb = 0;
    for (VMDriverProc *p in s.driverProcs) { mem += [p.totals[@"allocated_bytes"] doubleValue]; cb += [p.rates[@"command_buffers"] doubleValue]; }
    NSArray *driverRows = @[
        @{@"t": @"Occupazione (stima)", @"d": Pct(s.driverGpuBusy), @"bar": @(s.driverGpuBusy), @"color": LoadColor(s.driverGpuBusy)},
        Row(@"Command buffer", Rate(cb)),
        Row(@"Risorse Metal allocate", VMBytes(mem)),
        Row(@"Processi con MaliMetal", [NSString stringWithFormat:@"%lu", (unsigned long)s.driverProcs.count])];
    if (!s.gpuKernelStats) {
        [sections addObject:@{@"title": @"Kernel", @"footer": @"Le statistiche del kernel (frequenza, DVFS, job, errori, memoria, display) "
                                  @"richiedono la sysctl kern.viva_link (richiesta KA1 in gpu/docs/RICHIESTE-KERNEL.md).",
                              @"rows": @[Row(@"Mali-G57 MC2", @"non disponibili")]}];
        [sections addObject:@{@"title": @"Dal driver MaliMetal", @"rows": driverRows}];
        return sections;
    }
    BOOL on = [g[@"powered"] isEqualToString:@"1"];
    double load = [g[@"load_pct"] doubleValue] / 100;
    [sections addObject:@{@"title": @"Mali-G57 MC2", @"rows": @[
        Row(@"Stato", on ? @"Accesa" : @"Spenta"),
        Row(@"Frequenza", g[@"mhz"] ? [g[@"mhz"] stringByAppendingString:@" MHz"] : nil),
        Row(@"Intervallo DVFS", g[@"opp_min_mhz"] ? [NSString stringWithFormat:@"%@–%@ MHz", g[@"opp_min_mhz"], g[@"opp_max_mhz"]] : nil),
        Row(@"DVFS", [g[@"dvfs"] isEqualToString:@"1"] ? @"Attivo" : @"Spento"),
        @{@"t": @"Carico", @"d": Pct(load), @"bar": @(load), @"color": LoadColor(load)},
        Row(@"Cambi su / giù / boost", [NSString stringWithFormat:@"%@ / %@ / %@", g[@"dvfs_ups"] ?: @"—", g[@"dvfs_downs"] ?: @"—", g[@"dvfs_boosts"] ?: @"—"]),
        Row(@"ID", g[@"gpu_id"])]}];
    [sections addObject:@{@"title": @"Lavoro", @"rows": @[
        Row(@"Job", Rate(s.gpuJobsPerSecond)), Row(@"Job totali", Num([g[@"jobs"] doubleValue])),
        Row(@"In esecuzione / in coda", [NSString stringWithFormat:@"%@ · %@", g[@"running"] ?: @"—", g[@"queued"] ?: @"—"]),
        Row(@"Crescite dell'heap", g[@"heap_grows"])]}];
    [sections addObject:@{@"title": @"Errori", @"rows": @[
        Row(@"Job fault", g[@"job_faults"]), Row(@"MMU fault", g[@"mmu_faults"]), Row(@"GPU fault", g[@"gpu_faults"]),
        Row(@"Timeout", g[@"timeouts"]), Row(@"Reset", g[@"resets"])]}];
    double kib = [g[@"mem_kib"] doubleValue], lim = [g[@"mem_limit_mib"] doubleValue] * 1024;
    NSMutableArray *memRows = [@[
        @{@"t": @"Memoria GPU", @"d": VMBytes(kib * 1024), @"bar": @(lim > 0 ? kib / lim : 0), @"color": UIColor.systemPinkColor},
        Row(@"Picco", VMBytes([g[@"mem_peak_kib"] doubleValue] * 1024)),
        Row(@"Limite totale / per processo", [NSString stringWithFormat:@"%@ / %@ MiB", g[@"mem_limit_mib"] ?: @"—", g[@"mem_proc_mib"] ?: @"—"]),
        Row(@"Allocazioni rifiutate", g[@"mem_refusals"])] mutableCopy];
    for (NSString *k in [g.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        if (![k hasPrefix:@"proc."] || ![k hasSuffix:@".name"]) continue;
        NSString *pid = [k componentsSeparatedByString:@"."][1];
        NSString *p = [@"proc." stringByAppendingString:pid];
        [memRows addObject:@{@"t": g[k], @"s": [NSString stringWithFormat:@"pid %@ · %@ BO · importati %@", pid,
                                                 g[[p stringByAppendingString:@".bos"]] ?: @"—",
                                                 VMBytes([g[[p stringByAppendingString:@".imported_kib"]] doubleValue] * 1024)],
                             @"d": VMBytes([g[[p stringByAppendingString:@".kib"]] doubleValue] * 1024)}];
    }
    [sections addObject:@{@"title": @"Memoria", @"rows": memRows}];
    [sections addObject:@{@"title": @"Display", @"rows": @[
        Row(@"Frame al secondo", [NSString stringWithFormat:@"%.1f", s.displayFps]),
        Row(@"Risoluzione", d[@"width"] ? [NSString stringWithFormat:@"%@×%@", d[@"width"], d[@"height"]] : nil),
        Row(@"Scanout diretto", [d[@"scanout"] isEqualToString:@"1"] ? @"Sì" : @"No"),
        Row(@"Frame scanout / copiati", [NSString stringWithFormat:@"%@ / %@", Num([d[@"frames_scanned"] doubleValue]), Num([d[@"frames_copied"] doubleValue])]),
        Row(@"Copia media", d[@"copy_avg_us"] ? [d[@"copy_avg_us"] stringByAppendingString:@" µs"] : nil),
        Row(@"Attese della GPU / frame forzati", [NSString stringWithFormat:@"%@ / %@", d[@"gpu_waits"] ?: @"—", d[@"frames_forced"] ?: @"—"]),
        Row(@"SwapEnd → GPU finita", d[@"lat_swap_gpu_avg_us"] ? [d[@"lat_swap_gpu_avg_us"] stringByAppendingString:@" µs"] : nil),
        Row(@"Scelto → a schermo", d[@"lat_chosen_screen_avg_us"] ? [d[@"lat_chosen_screen_avg_us"] stringByAppendingString:@" µs"] : nil)]}];
    [sections addObject:@{@"title": @"Dal driver MaliMetal", @"rows": driverRows}];
    [sections addObject:@{@"title": @"Controlli", @"footer": @"Valgono fino al prossimo riavvio (per sempre: Boot Args).", @"rows": @[
        @{@"t": @"Frequenza…", @"tint": @YES, @"action": ^{ [ws chooseFrequency]; }},
        @{@"t": [g[@"dvfs"] isEqualToString:@"1"] ? @"Spegni il DVFS" : @"Accendi il DVFS", @"tint": @YES,
          @"action": ^{ [ws link:[g[@"dvfs"] isEqualToString:@"1"] ? @"gpu dvfs off" : @"gpu dvfs on"]; }},
        @{@"t": @"Azzera contatori di chiamate e latenze", @"tint": @YES,
          @"action": ^{ [ws linkSequence:@[@"gpu calls reset", @"gpu lat reset", @"disp lat reset"]]; }}]}];
    NSMutableArray *raw = [NSMutableArray array];
    for (NSString *c in @[@"gpu", @"gpu calls", @"gpu lat", @"gpu freq", @"gpu clocks", @"disp", @"bat"])
        [raw addObject:@{@"t": c, @"mono": @YES, @"action": ^{ [ws showRaw:c]; }}];
    [sections addObject:@{@"title": @"Testo completo dal kernel", @"rows": raw}];
    return sections;
}
@end

// ---- MaliMetal driver ----------------------------------------------------------------------------------------------------

@interface VMDriverProcTable : VMLiveTable
@property (nonatomic) int pid;
@end
@implementation VMDriverProcTable
- (void)viewDidLoad {
    [super viewDidLoad];
    [self addSpark:UIColor.systemIndigoColor max:0];
}
- (VMDriverProc *)proc {
    for (VMDriverProc *p in VMStats.shared.driverProcs) if (p.pid == self.pid) return p;
    return nil;
}
- (void)updateSpark {
    VMDriverProc *p = self.proc;
    NSMutableArray *v = [self.spark.values mutableCopy] ?: [NSMutableArray array];
    [v addObject:@([p.rates[@"command_buffers"] doubleValue])];
    if (v.count > 120) [v removeObjectAtIndex:0];
    self.spark.values = v;
    self.spark.caption = [NSString stringWithFormat:@"Command buffer/s %.1f", [p.rates[@"command_buffers"] doubleValue]];
}
- (NSArray *)buildSections {
    VMDriverProc *p = self.proc;
    if (!p) return @[@{@"title": @"", @"rows": @[Row(@"Processo terminato", @"")]}];
    self.title = p.name;
    NSDictionary *t = p.totals, *r = p.rates;
    double cbs = [t[@"command_buffers"] doubleValue], cbr = [r[@"command_buffers"] doubleValue];
    double lat = cbr > 0 ? [r[@"latency_ns"] doubleValue] / cbr / 1e6 : (cbs > 0 ? [t[@"latency_ns"] doubleValue] / cbs / 1e6 : 0);
    double gpu = cbr > 0 ? [r[@"gpu_ns"] doubleValue] / cbr / 1e6 : 0;
    double hits = [t[@"air_cache_hits"] doubleValue], miss = [t[@"air_cache_misses"] doubleValue];
    NSDictionary *(^both)(NSString *, NSString *) = ^(NSString *title, NSString *k) {
        return @{@"t": title, @"s": [NSString stringWithFormat:@"totale %@", Num([t[k] doubleValue])], @"d": Rate([r[k] doubleValue])};
    };
    NSMutableArray *calls = [NSMutableArray array];
    for (NSDictionary *c in [p.calls sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
             return [b[@"total"] compare:a[@"total"]]; }])
        [calls addObject:@{@"t": c[@"name"], @"mono": @YES, @"s": [NSString stringWithFormat:@"totale %@", Num([c[@"total"] doubleValue])],
                           @"d": Rate([c[@"rate"] doubleValue])}];
    return @[
        @{@"title": @"Processo", @"rows": @[
            Row(@"PID", [NSString stringWithFormat:@"%d", p.pid]),
            Row(@"Ultimo aggiornamento", [NSString stringWithFormat:@"%.1f s fa", p.ageSeconds]),
            @{@"t": @"Build del driver", @"s": p.build, @"mono": @NO}]},
        @{@"title": @"Command buffer", @"rows": @[
            both(@"Command buffer", @"command_buffers"),
            Row(@"Latenza media (commit → fine)", [NSString stringWithFormat:@"%.2f ms", lat]),
            Row(@"Latenza massima (ultimo secondo)", [NSString stringWithFormat:@"%.2f ms", [t[@"latency_max_ns"] doubleValue] / 1e6]),
            Row(@"Tempo GPU per command buffer", [NSString stringWithFormat:@"%.2f ms", gpu]),
            @{@"t": @"Occupazione GPU", @"d": Pct(MIN([r[@"gpu_ns"] doubleValue] / 1e9, 1)), @"bar": @(MIN([r[@"gpu_ns"] doubleValue] / 1e9, 1)),
              @"color": UIColor.systemPinkColor},
            @{@"t": @"Riesecuzione + flush (CPU)", @"d": Pct(MIN([r[@"replay_ns"] doubleValue] / 1e9, 1)),
              @"bar": @(MIN([r[@"replay_ns"] doubleValue] / 1e9, 1)), @"color": UIColor.systemOrangeColor}]},
        @{@"title": @"Encoder", @"rows": @[
            both(@"Render pass", @"passes"), both(@"Draw", @"draws"), both(@"Dispatch compute", @"dispatches"),
            both(@"Attese di nextDrawable ≥ 2 ms", @"drawable_blocks"),
            Row(@"Tempo in nextDrawable", [NSString stringWithFormat:@"%.1f ms/s", [r[@"drawable_waits_us"] doubleValue] / 1e3])]},
        @{@"title": @"Pipeline e shader", @"rows": @[
            Row(@"Pipeline create", Num([t[@"pipelines"] doubleValue])),
            Row(@"Pipeline di ripiego", Num([t[@"fallback_pipelines"] doubleValue])),
            Row(@"Compute senza percorso", Num([t[@"compute_rejected"] doubleValue])),
            Row(@"Cache traduzioni (hit/miss)", [NSString stringWithFormat:@"%@ / %@ (%.0f%%)", Num(hits), Num(miss),
                                                  hits + miss > 0 ? 100 * hits / (hits + miss) : 0])]},
        @{@"title": @"Memoria e kernel", @"rows": @[
            Row(@"Risorse Metal allocate", VMBytes([t[@"allocated_bytes"] doubleValue])),
            both(@"Job GPU inviati", @"jobs")]},
        @{@"title": @"Chiamate al kernel", @"rows": calls.count ? calls : @[Row(@"Nessuna", @"")]},
    ];
}
@end

@interface VMDriverTable : VMLiveTable
@end
@implementation VMDriverTable
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"MaliMetal";
    [self addSpark:UIColor.systemIndigoColor max:0];
}
- (void)updateSpark {
    VMStats *s = VMStats.shared;
    self.spark.values = s.driverCbHistory;
    double cb = s.driverCbHistory.lastObject.doubleValue;
    self.spark.caption = [NSString stringWithFormat:@"Command buffer/s %.0f (tutti i processi)", cb];
}
- (NSArray *)buildSections {
    VMStats *s = VMStats.shared;
    double cb = 0, draws = 0, passes = 0, jobs = 0, mem = 0, calls = 0, lat = 0;
    for (VMDriverProc *p in s.driverProcs) {
        cb += [p.rates[@"command_buffers"] doubleValue];
        draws += [p.rates[@"draws"] doubleValue];
        passes += [p.rates[@"passes"] doubleValue];
        jobs += [p.rates[@"jobs"] doubleValue];
        lat += [p.rates[@"latency_ns"] doubleValue];
        mem += [p.totals[@"allocated_bytes"] doubleValue];
        for (NSDictionary *c in p.calls) calls += [c[@"rate"] doubleValue];
    }
    __weak typeof(self) ws = self;
    NSMutableArray *procs = [NSMutableArray array];
    for (VMDriverProc *p in s.driverProcs) {
        int pid = p.pid;
        double pcb = [p.rates[@"command_buffers"] doubleValue];
        [procs addObject:@{@"t": p.name,
            @"s": [NSString stringWithFormat:@"pid %d · %@ · GPU %@ · %@ draw/s", pid, VMBytes([p.totals[@"allocated_bytes"] doubleValue]),
                   Pct(MIN([p.rates[@"gpu_ns"] doubleValue] / 1e9, 1)), Num([p.rates[@"draws"] doubleValue])],
            @"d": pcb > 0 ? [NSString stringWithFormat:@"%.0f cb/s", pcb] : @"inattivo",
            @"action": ^{
                VMDriverProcTable *d = [VMDriverProcTable new];
                d.pid = pid;
                [ws.navigationController pushViewController:d animated:YES];
            }}];
    }
    return @[
        @{@"title": @"Tutti i processi", @"rows": @[
            @{@"t": @"Occupazione GPU (stima)", @"d": Pct(s.driverGpuBusy), @"bar": @(s.driverGpuBusy), @"color": LoadColor(s.driverGpuBusy)},
            Row(@"Command buffer", Rate(cb)), Row(@"Render pass", Rate(passes)), Row(@"Draw", Rate(draws)),
            Row(@"Job GPU", Rate(jobs)), Row(@"Chiamate al kernel", Rate(calls)),
            Row(@"Latenza media", cb > 0 ? [NSString stringWithFormat:@"%.2f ms", lat / cb / 1e6] : nil),
            Row(@"Risorse Metal allocate", VMBytes(mem)),
            Row(@"Build del driver", s.driverProcs.firstObject.build.length > 12 ? [s.driverProcs.firstObject.build substringToIndex:12] : s.driverProcs.firstObject.build)]},
        @{@"title": @"Processi", @"footer": @"Ogni processo aggiorna i suoi contatori al massimo una volta al secondo mentre disegna "
              @"(/private/var/tmp/vmg-stats). Richiede il driver con le statistiche per Viva Manager.",
          @"rows": procs.count ? procs : @[Row(@"Nessun processo pubblica statistiche", @"")]},
    ];
}
@end

// ---- Menu ----------------------------------------------------------------------------------------------------------------

@implementation VMStatsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.rowHeight = 64;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [VMStats.shared retainSampling];
    [NSNotificationCenter.defaultCenter addObserver:self.tableView selector:@selector(reloadData) name:VMStatsDidUpdateNotification object:nil];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [NSNotificationCenter.defaultCenter removeObserver:self.tableView name:VMStatsDidUpdateNotification object:nil];
    [VMStats.shared releaseSampling];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return 4; }

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return @"Aggiornate ogni secondo mentre sei in questa sezione.";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    VMStats *s = VMStats.shared;
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    NSArray *titles = @[@"CPU", @"RAM", @"GPU", @"MaliMetal"];
    NSArray *icons = @[@"cpu", @"memorychip", @"cube.transparent", @"square.stack.3d.up"];
    NSArray *colors = @[UIColor.systemGreenColor, UIColor.systemBlueColor, UIColor.systemPinkColor, UIColor.systemIndigoColor];
    c.textLabel.text = titles[ip.row];
    c.textLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    c.imageView.image = [UIImage systemImageNamed:icons[ip.row]];
    c.imageView.tintColor = colors[ip.row];
    double used = s.memActive + s.memWired + s.memCompressed;
    double cb = 0;
    for (VMDriverProc *p in s.driverProcs) cb += [p.rates[@"command_buffers"] doubleValue];
    switch (ip.row) {
    case 0: c.detailTextLabel.text = [NSString stringWithFormat:@"%@ · %lu core · carico %.2f", Pct(s.cpuTotal), (unsigned long)s.coreLoad.count, s.load1]; break;
    case 1: c.detailTextLabel.text = s.memTotal ? [NSString stringWithFormat:@"%@ usati di %@", VMBytes(used), VMBytes(s.memTotal)] : @"…"; break;
    case 2: c.detailTextLabel.text = s.gpuKernelStats
                ? [NSString stringWithFormat:@"%@ MHz · carico %@%% · %.0f fps", s.gpu[@"mhz"] ?: @"—", s.gpu[@"load_pct"] ?: @"—", s.displayFps]
                : [NSString stringWithFormat:@"Occupazione stimata %@ (kernel senza KA1)", Pct(s.driverGpuBusy)];
        break;
    case 3: c.detailTextLabel.text = [NSString stringWithFormat:@"%lu processi · %.0f command buffer/s", (unsigned long)s.driverProcs.count, cb]; break;
    }
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSArray *classes = @[VMCPUTable.class, VMRAMTable.class, VMGPUTable.class, VMDriverTable.class];
    UIViewController *vc = [classes[ip.row] new];
    [self.navigationController pushViewController:vc animated:YES];
}

@end
