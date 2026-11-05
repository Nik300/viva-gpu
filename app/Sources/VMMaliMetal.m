// MaliMetal: the driver's environment file (vmg.env in VivaMTLDriver.bundle). Every process that loads the driver
// reads it at start (without overriding its own environment): backboardd after a restart, apps when they open.
#import "VMApp.h"

NSNotificationName const VMFlagsDidChangeNotification = @"VMFlagsDidChangeNotification";

@implementation VMMaliMetalViewController {
    NSArray<NSDictionary *> *_groups;           // catalog: {group, subpage?, items: [{key, type, title, desc, invert?, ...}]}
    NSSet<NSString *> *_known;
    NSMutableArray<NSString *> *_lines;         // file as read (comments and unknown lines are kept)
    NSMutableDictionary<NSString *, NSString *> *_values;   // active KEY=VALUE
    NSArray<NSString *> *_extraKeys;            // active keys that are not in the catalog
    BOOL _dirty;
    BOOL _readable;
}

enum { SecState, SecFirstGroup };

- (void)viewDidLoad {
    [super viewDidLoad];
    _groups = [VMSystem loadJSON:@"malimetal-flags"];
    NSMutableSet *k = [NSMutableSet set];
    for (NSDictionary *g in _groups) for (NSDictionary *i in g[@"items"]) [k addObject:i[@"key"]];
    _known = k;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Salva" style:UIBarButtonItemStyleDone
                                                                             target:self action:@selector(save)];
    self.tableView.estimatedRowHeight = 64;
    UIRefreshControl *rc = [UIRefreshControl new];
    [rc addTarget:self action:@selector(pullRefresh:) forControlEvents:UIControlEventValueChanged];
    self.refreshControl = rc;
    [self load];
}

- (void)pullRefresh:(UIRefreshControl *)rc {
    if (_dirty) {
        [rc endRefreshing];
        VMConfirm(self, @"Scartare le modifiche?", @"Ricarica vmg.env dal disco.", @"Ricarica", YES, ^{ [self load]; });
        return;
    }
    [self load];
    [rc endRefreshing];
}

- (void)load {
    NSString *text = [NSString stringWithContentsOfFile:VM_ENV_PATH encoding:NSUTF8StringEncoding error:nil];
    _readable = text != nil;
    _lines = [[(text ?: @"") componentsSeparatedByString:@"\n"] mutableCopy];
    if (_lines.count && [_lines.lastObject isEqualToString:@""]) [_lines removeLastObject];
    _values = [NSMutableDictionary dictionary];
    for (NSString *l in _lines) {
        NSString *key, *value;
        if ([self parseLine:l key:&key value:&value]) _values[key] = value;
    }
    _dirty = NO;
    [self refreshState];
}

// KEY=VALUE as load_env_file reads it (vmg_screen.c): '#' lines and lines without '=' are ignored.
- (BOOL)parseLine:(NSString *)line key:(NSString **)key value:(NSString **)value {
    if ([line hasPrefix:@"#"]) return NO;
    NSRange eq = [line rangeOfString:@"="];
    if (eq.location == NSNotFound || eq.location == 0) return NO;
    *key = [line substringToIndex:eq.location];
    *value = [line substringFromIndex:eq.location + 1];
    return YES;
}

- (void)refreshState {
    NSMutableArray *extra = [NSMutableArray array];
    for (NSString *k in [_values.allKeys sortedArrayUsingSelector:@selector(compare:)])
        if (![_known containsObject:k]) [extra addObject:k];
    _extraKeys = extra;
    self.navigationItem.rightBarButtonItem.enabled = _dirty;
    [self.tableView reloadData];
    [NSNotificationCenter.defaultCenter postNotificationName:VMFlagsDidChangeNotification object:self];
}

- (BOOL)dirty { return _dirty; }
- (NSString *)flagValue:(NSString *)key { return _values[key]; }

- (void)setFlagValues:(NSDictionary<NSString *, id> *)values {
    [values enumerateKeysAndObjectsUsingBlock:^(NSString *k, id v, BOOL *stop) {
        if ([v isKindOfClass:NSString.class] && [v length]) self->_values[k] = v; else [self->_values removeObjectForKey:k];
    }];
    _dirty = YES;
    [self refreshState];
}

- (void)setValue:(NSString *)value forFlag:(NSString *)key {
    if (value.length) _values[key] = value; else [_values removeObjectForKey:key];
    _dirty = YES;
    [self refreshState];
}

- (NSString *)serialize {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *written = [NSMutableSet set];
    for (NSString *l in _lines) {
        NSString *key, *value;
        if (![self parseLine:l key:&key value:&value]) { [out addObject:l]; continue; }
        if ([written containsObject:key] || !_values[key]) continue;   // removed (or a duplicate line)
        [out addObject:[NSString stringWithFormat:@"%@=%@", key, _values[key]]];
        [written addObject:key];
    }
    for (NSString *k in [_values.allKeys sortedArrayUsingSelector:@selector(compare:)])
        if (![written containsObject:k]) [out addObject:[NSString stringWithFormat:@"%@=%@", k, _values[k]]];
    return [[out componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"];
}

- (void)writeText:(NSString *)text from:(UIViewController *)vc then:(void (^)(BOOL ok))then {
    VMRunHelper(@[@"env-write"], text, ^(int status, NSString *output) {
        if (status != 0) {
            VMAlert(vc, @"vmg.env non salvato", output);
            then(NO);
            return;
        }
        [self load];
        then(YES);
    });
}

- (void)save { [self presentSaveFrom:self item:self.navigationItem.rightBarButtonItem]; }

- (void)presentSaveFrom:(UIViewController *)vc item:(UIBarButtonItem *)item {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Salvare vmg.env?"
        message:@"I flag valgono per i processi che caricano il driver da adesso. Il compositore (backboardd) li legge "
                @"solo quando riparte: lo schermo resta nero per circa 30 secondi."
        preferredStyle:UIAlertControllerStyleActionSheet];
    NSString *text = [self serialize];
    [a addAction:[UIAlertAction actionWithTitle:@"Salva e riavvia backboardd" style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction *x) {
        [self writeText:text from:vc then:^(BOOL ok) { if (ok) [self restartBackboarddFrom:vc]; }];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Salva soltanto" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [self writeText:text from:vc then:^(BOOL ok) { if (ok) VMToast(vc, @"vmg.env salvato"); }];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Annulla" style:UIAlertActionStyleCancel handler:nil]];
    a.popoverPresentationController.barButtonItem = item;
    [vc presentViewController:a animated:YES completion:nil];
}

- (void)restartBackboardd { [self restartBackboarddFrom:self]; }

- (void)restartBackboarddFrom:(UIViewController *)vc {
    VMRunHelper(@[@"restart", @"backboardd"], nil, ^(int status, NSString *output) {
        if (status != 0) VMAlert(vc, @"backboardd non riavviato", output);
    });
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return SecFirstGroup + (NSInteger)_groups.count + 1; }

- (BOOL)isExtraSection:(NSInteger)s { return s == SecFirstGroup + (NSInteger)_groups.count; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == SecState) return 4;
    if ([self isExtraSection:s]) return (NSInteger)_extraKeys.count + 1;
    if (_groups[s - SecFirstGroup][@"subpage"]) return 1;   // one row that opens the group's own screen
    return (NSInteger)[_groups[s - SecFirstGroup][@"items"] count];
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (s == SecState) return @"Driver Metal (Mali-G57 MC2)";
    if ([self isExtraSection:s]) return @"Altre variabili nel file";
    return _groups[s - SecFirstGroup][@"group"];
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == SecState)
        return _readable ? @"I flag spenti vengono tolti dal file: il driver controlla solo se la variabile esiste."
                         : @"vmg.env non esiste o non è leggibile: verrà creato al primo salvataggio.";
    if ([self isExtraSection:s]) return @"Scorri a sinistra per togliere una variabile.";
    return nil;
}

- (UITableViewCell *)cellWithStyle:(UITableViewCellStyle)style {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:style reuseIdentifier:nil];
    c.textLabel.numberOfLines = 0;
    c.detailTextLabel.numberOfLines = 0;
    return c;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == SecState) {
        UITableViewCell *c = [self cellWithStyle:UITableViewCellStyleValue1];
        switch (ip.row) {
        case 0:
            c.textLabel.text = @"Flag attivi";
            c.detailTextLabel.text = [NSString stringWithFormat:@"%lu%@", (unsigned long)_values.count, _dirty ? @" · non salvati" : @""];
            c.selectionStyle = UITableViewCellSelectionStyleNone;
            break;
        case 1:
            c.textLabel.text = @"Modifica vmg.env a mano";
            c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            break;
        case 2:
            c.textLabel.text = @"Riavvia backboardd";
            c.textLabel.textColor = UIColor.systemOrangeColor;
            break;
        case 3:
            c.textLabel.text = @"Togli tutti i flag (predefiniti del driver)";
            c.textLabel.textColor = UIColor.systemRedColor;
            break;
        }
        return c;
    }
    if ([self isExtraSection:ip.section]) {
        UITableViewCell *c = [self cellWithStyle:UITableViewCellStyleSubtitle];
        if (ip.row == (NSInteger)_extraKeys.count) {
            c.textLabel.text = @"Aggiungi variabile…";
            c.textLabel.textColor = self.view.tintColor;
            return c;
        }
        NSString *k = _extraKeys[ip.row];
        c.textLabel.text = k;
        c.textLabel.font = VMMono(15);
        c.detailTextLabel.text = _values[k].length ? _values[k] : @"(vuoto)";
        c.detailTextLabel.font = VMMono(13);
        return c;
    }
    NSDictionary *group = _groups[ip.section - SecFirstGroup];
    if (group[@"subpage"]) {
        UITableViewCell *c = [self cellWithStyle:UITableViewCellStyleSubtitle];
        c.textLabel.text = group[@"group"];
        c.detailTextLabel.text = [self subpageSummary:group];
        c.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return c;
    }
    return [self cellForFlag:group[@"items"][ip.row] enabled:YES];
}

// The ISA compiler group: on/off and how many features are excluded.
- (NSString *)subpageSummary:(NSDictionary *)group {
    NSUInteger off = 0, set = 0;
    for (NSDictionary *i in group[@"items"]) {
        if (!_values[i[@"key"]]) continue;
        set++;
        if ([i[@"invert"] boolValue]) off++;
    }
    if (![group[@"subpage"] isEqualToString:@"isa"]) return [NSString stringWithFormat:@"%lu impostati", (unsigned long)set];
    NSString *on = _values[@"VMG_ISA"];
    if (!on.length || [on isEqualToString:@"0"]) return @"Spento: tutti gli shader passano da AIR → NIR → Panfrost";
    NSMutableString *t = [NSMutableString stringWithString:@"Acceso"];
    if (_values[@"VMG_ISA_ONLY"]) [t appendFormat:@" · solo %@", _values[@"VMG_ISA_ONLY"]];
    if (off) [t appendFormat:@" · %lu funzionalità sul percorso NIR", (unsigned long)off];
    if (_values[@"VMG_ISA_STRICT"]) [t appendString:@" · rigoroso"];
    return t;
}

// A catalog row. "invert": the switch shows the feature, on = variable absent (VMG_ISA_NO_<ID> not set).
- (UITableViewCell *)cellForFlag:(NSDictionary *)item enabled:(BOOL)enabled {
    NSString *key = item[@"key"], *type = item[@"type"], *value = _values[key];
    BOOL invert = [item[@"invert"] boolValue];
    UITableViewCell *c = [self cellWithStyle:UITableViewCellStyleSubtitle];
    c.textLabel.text = item[@"title"];
    NSMutableAttributedString *d = [[NSMutableAttributedString alloc] initWithString:key
        attributes:@{NSFontAttributeName: VMMono(12), NSForegroundColorAttributeName: UIColor.secondaryLabelColor}];
    if (value && ![type isEqualToString:@"presence"])
        [d appendAttributedString:[[NSAttributedString alloc] initWithString:[@"=" stringByAppendingString:value]
            attributes:@{NSFontAttributeName: VMMono(12), NSForegroundColorAttributeName: self.view.tintColor}]];
    [d appendAttributedString:[[NSAttributedString alloc] initWithString:[@"\n" stringByAppendingString:item[@"desc"] ?: @""]
        attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:13], NSForegroundColorAttributeName: UIColor.secondaryLabelColor}]];
    c.detailTextLabel.attributedText = d;
    if ([type isEqualToString:@"presence"]) {
        VMSwitch *sw = [VMSwitch new];
        sw.on = invert ? value == nil : value != nil;
        sw.enabled = enabled;
        __weak typeof(self) ws = self;
        sw.onChange = ^(BOOL on) { [ws setValue:(on != invert) ? @"1" : nil forFlag:key]; };
        c.accessoryView = sw;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        if (!enabled) c.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    if (!enabled) {
        c.textLabel.textColor = UIColor.tertiaryLabelColor;
        c.contentView.alpha = 0.5;
    }
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == SecState) {
        if (ip.row == 1) {
            __weak typeof(self) ws = self;
            VMTextViewController *t = [[VMTextViewController alloc] initWithTitle:@"vmg.env" text:[self serialize] editable:YES
                save:^(NSString *text) {
                    typeof(self) s = ws;
                    if (!s) return;
                    [s writeText:text from:s then:^(BOOL ok) { if (ok) VMToast(s, @"vmg.env salvato"); }];
                }];
            [self.navigationController pushViewController:t animated:YES];
        } else if (ip.row == 2) {
            VMConfirm(self, @"Riavviare backboardd?", @"Lo schermo resta nero per circa 30 secondi, poi riparte anche SpringBoard.",
                      @"Riavvia", YES, ^{ [self restartBackboardd]; });
        } else if (ip.row == 3) {
            VMConfirm(self, @"Togliere tutti i flag?", @"I commenti restano. Ricordati di salvare.", @"Togli", YES, ^{
                [self->_values removeAllObjects];
                self->_dirty = YES;
                [self refreshState];
            });
        }
        return;
    }
    if ([self isExtraSection:ip.section]) {
        if (ip.row == (NSInteger)_extraKeys.count) {
            VMEditText(self, @"Nuova variabile", @"NOME=valore", @"", @"VMG_...=1", UIKeyboardTypeASCIICapable, ^(NSString *v) {
                NSString *k, *val;
                if (v.length && [self parseLine:v key:&k value:&val]) [self setValue:val.length ? val : @"1" forFlag:k];
            });
            return;
        }
        NSString *k = _extraKeys[ip.row];
        VMEditText(self, k, @"Valore vuoto = togli la variabile", _values[k], nil, UIKeyboardTypeASCIICapable,
                   ^(NSString *v) { if (v) [self setValue:v forFlag:k]; });
        return;
    }
    NSDictionary *group = _groups[ip.section - SecFirstGroup];
    if ([group[@"subpage"] isEqualToString:@"accel"]) {
        [self.navigationController pushViewController:[VMAccelViewController new] animated:YES];
        return;
    }
    if (group[@"subpage"]) {
        [self.navigationController pushViewController:[[VMIsaViewController alloc] initWithGroup:group flags:self] animated:YES];
        return;
    }
    [self editFlag:group[@"items"][ip.row] from:self source:[tv cellForRowAtIndexPath:ip]];
}

- (void)editFlag:(NSDictionary *)item from:(UIViewController *)vc source:(UIView *)source {
    NSString *key = item[@"key"], *type = item[@"type"];
    if ([type isEqualToString:@"presence"]) return;
    if ([type isEqualToString:@"choice"]) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:item[@"title"] message:item[@"desc"]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSString *o in item[@"options"]) {
            NSString *t = [NSString stringWithFormat:@"%@=%@%@", key, o, [_values[key] isEqualToString:o] ? @"  ✓" : @""];
            [a addAction:[UIAlertAction actionWithTitle:t style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *x) { [self setValue:o forFlag:key]; }]];
        }
        [a addAction:[UIAlertAction actionWithTitle:@"Non impostato" style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *x) { [self setValue:nil forFlag:key]; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Annulla" style:UIAlertActionStyleCancel handler:nil]];
        a.popoverPresentationController.sourceView = source;
        a.popoverPresentationController.sourceRect = source.bounds;
        [vc presentViewController:a animated:YES completion:nil];
        return;
    }
    VMEditText(vc, item[@"title"], [NSString stringWithFormat:@"%@\n\nVuoto = non impostato.", item[@"desc"] ?: @""], _values[key],
               item[@"placeholder"], [type isEqualToString:@"int"] ? UIKeyboardTypeNumberPad : UIKeyboardTypeASCIICapable,
               ^(NSString *v) { if (v) [self setValue:v forFlag:key]; });
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    NSString *key = nil;
    if ([self isExtraSection:ip.section] && ip.row < (NSInteger)_extraKeys.count) key = _extraKeys[ip.row];
    else if (ip.section >= SecFirstGroup && ![self isExtraSection:ip.section] && !_groups[ip.section - SecFirstGroup][@"subpage"]) {
        NSDictionary *item = _groups[ip.section - SecFirstGroup][@"items"][ip.row];
        if (_values[item[@"key"]]) key = item[@"key"];
    }
    if (!key) return nil;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Togli"
        handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) { [self setValue:nil forFlag:key]; done(YES); }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

@end
