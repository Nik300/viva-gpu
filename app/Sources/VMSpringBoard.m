// SpringBoard: its defaults (com.apple.springboard and the domains it reads), from the catalog extracted from
// SpringBoardFoundation's BSAbstractDefaultDomain subclasses (springboard-keys.json), plus every value saved in the
// domain. Written through cfprefsd as user mobile; SpringBoard reads most of them at start: "Riavvia SpringBoard".
#import "VMApp.h"

#define SB_DOMAIN @"com.apple.springboard"

// ---- Shared: reading, writing and showing one key --------------------------------------------------------------------

static id VMPrefGet(NSString *key, NSString *domain) {
    return CFBridgingRelease(CFPreferencesCopyValue((__bridge CFStringRef)key, (__bridge CFStringRef)domain,
                                                    kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
}

static void VMPrefSet(NSString *key, NSString *domain, id value) {
    CFPreferencesSetValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, (__bridge CFStringRef)domain,
                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize((__bridge CFStringRef)domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
}

static NSString *VMPrefDescribe(id v) {
    if (!v || v == NSNull.null) return @"—";
    if ([v isKindOfClass:NSNumber.class]) {
        if (CFGetTypeID((__bridge CFTypeRef)v) == CFBooleanGetTypeID()) return [v boolValue] ? @"YES" : @"NO";
        return [v stringValue];
    }
    if ([v isKindOfClass:NSString.class]) return [NSString stringWithFormat:@"\"%@\"", v];
    if ([v isKindOfClass:NSData.class]) return [NSString stringWithFormat:@"<dati, %lu byte>", (unsigned long)[v length]];
    if ([v isKindOfClass:NSArray.class]) return [NSString stringWithFormat:@"[array, %lu elementi]", (unsigned long)[v count]];
    if ([v isKindOfClass:NSDictionary.class]) return [NSString stringWithFormat:@"{dizionario, %lu chiavi}", (unsigned long)[v count]];
    if ([v isKindOfClass:NSDate.class]) return [v description];
    return [v description];
}

static NSString *VMPrefType(id v) {
    if ([v isKindOfClass:NSNumber.class]) {
        if (CFGetTypeID((__bridge CFTypeRef)v) == CFBooleanGetTypeID()) return @"bool";
        return CFNumberIsFloatType((__bridge CFNumberRef)v) ? @"double" : @"int";
    }
    if ([v isKindOfClass:NSString.class]) return @"string";
    return @"other";
}

static NSString *VMGroupTitle(NSString *cls) {
    static NSDictionary *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @{@"LockScreen": @"Schermata di blocco", @"HomeScreen": @"Home", @"SoftwareUpdate": @"Aggiornamento software",
                  @"Icon": @"Icone", @"Power": @"Batteria e alimentazione", @"MultiUser": @"Multiutente",
                  @"AlwaysOn": @"Always On", @"Security": @"Sicurezza", @"InCallPresentation": @"Chiamate",
                  @"Accessibility": @"Accessibilità", @"Rotation": @"Rotazione", @"FloatingDock": @"Dock",
                  @"StatusBar": @"Barra di stato", @"RecentDisplayItems": @"Elementi recenti", @"Miscellaneous": @"Varie",
                  @"PIP": @"Picture in Picture", @"BiometricAuthentication": @"Face ID / Touch ID",
                  @"StateDump": @"Dump dello stato", @"Testing": @"Test", @"SystemAperture": @"Dynamic Island",
                  @"Workspace": @"Workspace", @"ExternalDisplay": @"Display esterno", @"Sound": @"Suoni",
                  @"Application": @"Applicazioni", @"Thermal": @"Temperatura", @"VoiceControl": @"Controllo vocale",
                  @"Setup": @"Configurazione iniziale", @"AppSwitcher": @"Multitasking", @"CameraHardwareButton": @"Tasto fotocamera",
                  @"Gesture": @"Gesti", @"Analytics": @"Analisi", @"WallpaperLegacy": @"Sfondo (vecchio)", @"Boot": @"Avvio",
                  @"IdleTimer": @"Blocco automatico e oscuramento", @"Hardware": @"Hardware", @"CornerGesture": @"Gesti dagli angoli",
                  @"SOS": @"SOS", @"NotificationCenter": @"Centro Notifiche", @"Demo": @"Demo", @"Notification": @"Notifiche",
                  @"Usage": @"Utilizzo"};
    });
    NSString *s = cls;
    if ([s hasPrefix:@"SBExternal"]) s = [@"Esterno: " stringByAppendingString:[[s substringFromIndex:10] stringByReplacingOccurrencesOfString:@"Defaults" withString:@""]];
    else {
        if ([s hasPrefix:@"SB"]) s = [s substringFromIndex:2];
        if ([s hasSuffix:@"Defaults"]) s = [s substringToIndex:s.length - 8];
        s = names[s] ?: s;
    }
    return s;
}

@interface VMSBKeyList : UITableViewController <UISearchResultsUpdating>
- (instancetype)initWithTitle:(NSString *)title items:(NSArray<NSDictionary *> *)items searchable:(BOOL)searchable;
@end

@implementation VMSBKeyList {
    NSArray<NSDictionary *> *_items, *_shown;
    UISearchController *_search;
}

- (instancetype)initWithTitle:(NSString *)title items:(NSArray<NSDictionary *> *)items searchable:(BOOL)searchable {
    if ((self = [super initWithStyle:UITableViewStyleInsetGrouped])) {
        self.title = title;
        _items = _shown = items;
        if (searchable) {
            _search = [[UISearchController alloc] initWithSearchResultsController:nil];
            _search.searchResultsUpdater = self;
            _search.obscuresBackgroundDuringPresentation = NO;
            _search.searchBar.placeholder = @"Cerca chiave o descrizione";
            self.navigationItem.searchController = _search;
            self.navigationItem.hidesSearchBarWhenScrolling = NO;
        }
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.tableView.estimatedRowHeight = 70;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.clockwise"]
        style:UIBarButtonItemStylePlain target:self action:@selector(respring)];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    CFPreferencesAppSynchronize((__bridge CFStringRef)SB_DOMAIN);
    [self.tableView reloadData];
}

- (void)respring {
    VMConfirm(self, @"Riavviare SpringBoard?", @"Applica le impostazioni modificate. Le app aperte vengono chiuse.", @"Riavvia", YES, ^{
        VMRunHelper(@[@"restart", @"SpringBoard"], nil, ^(int s, NSString *o) { if (s) VMAlert(self, @"SpringBoard", o); });
    });
}

- (void)updateSearchResultsForSearchController:(UISearchController *)sc {
    NSString *q = sc.searchBar.text;
    if (!q.length) { _shown = _items; [self.tableView reloadData]; return; }
    NSMutableArray *r = [NSMutableArray array];
    for (NSDictionary *i in _items) {
        for (NSString *f in @[@"key", @"title_it", @"desc_it"]) {
            if ([i[f] rangeOfString:q options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound) {
                [r addObject:i];
                break;
            }
        }
    }
    _shown = r;
    [self.tableView reloadData];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s { return (NSInteger)_shown.count; }

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    return @"Puntino blu = valore salvato. Scorri a sinistra per tornare al predefinito. Le modifiche valgono dopo il riavvio di SpringBoard (↻).";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *item = _shown[ip.row];
    NSString *key = item[@"key"], *domain = item[@"domain"] ?: SB_DOMAIN;
    id value = VMPrefGet(key, domain);
    NSString *type = item[@"type"] ?: (value ? VMPrefType(value) : @"other");
    id def = item[@"default"];
    if (def == NSNull.null) def = nil;
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    c.textLabel.numberOfLines = 0;
    c.detailTextLabel.numberOfLines = 0;
    NSString *title = item[@"title_it"] ?: key;
    if ([item[@"internal"] boolValue]) title = [title stringByAppendingString:@"  ·  interna"];
    c.textLabel.text = value ? [@"● " stringByAppendingString:title] : title;
    if (value) {
        NSMutableAttributedString *t = [[NSMutableAttributedString alloc] initWithString:c.textLabel.text];
        [t addAttribute:NSForegroundColorAttributeName value:self.view.tintColor range:NSMakeRange(0, 1)];
        c.textLabel.attributedText = t;
    }
    NSString *state = value ? [NSString stringWithFormat:@"%@ = %@", key, VMPrefDescribe(value)]
                            : [NSString stringWithFormat:@"%@ (predefinito: %@)", key, def ? VMPrefDescribe(def) : @"—"];
    if (![domain isEqualToString:SB_DOMAIN]) state = [NSString stringWithFormat:@"%@\n%@", domain, state];
    NSMutableAttributedString *d = [[NSMutableAttributedString alloc] initWithString:state attributes:@{
        NSFontAttributeName: VMMono(11), NSForegroundColorAttributeName: value ? self.view.tintColor : UIColor.secondaryLabelColor}];
    NSString *desc = item[@"desc_it"];
    if (desc.length)
        [d appendAttributedString:[[NSAttributedString alloc] initWithString:[@"\n" stringByAppendingString:desc]
            attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:13], NSForegroundColorAttributeName: UIColor.secondaryLabelColor}]];
    c.detailTextLabel.attributedText = d;
    if ([type isEqualToString:@"bool"]) {
        VMSwitch *sw = [VMSwitch new];
        sw.on = value ? [value boolValue] : [def boolValue];
        sw.onChange = ^(BOOL on) {
            VMPrefSet(key, domain, @(on));
            [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationNone];
        };
        c.accessoryView = sw;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if ([type isEqualToString:@"int"] || [type isEqualToString:@"double"] || [type isEqualToString:@"string"]) {
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else {
        c.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *item = _shown[ip.row];
    NSString *key = item[@"key"], *domain = item[@"domain"] ?: SB_DOMAIN;
    id value = VMPrefGet(key, domain);
    NSString *type = item[@"type"] ?: (value ? VMPrefType(value) : @"other");
    if (!([type isEqualToString:@"int"] || [type isEqualToString:@"double"] || [type isEqualToString:@"string"])) return;
    NSString *current = value ? ([value isKindOfClass:NSString.class] ? value : [value description]) : nil;
    id def = item[@"default"];
    NSString *placeholder = def && def != NSNull.null ? [def description] : nil;
    VMEditText(self, item[@"title_it"] ?: key, [NSString stringWithFormat:@"%@\n%@\n\nVuoto = predefinito.", key, item[@"desc_it"] ?: @""],
               current, placeholder, [type isEqualToString:@"string"] ? UIKeyboardTypeDefault : UIKeyboardTypeNumbersAndPunctuation,
               ^(NSString *v) {
        if (!v) return;
        id nv = nil;
        if (v.length) {
            if ([type isEqualToString:@"int"]) nv = @(v.longLongValue);
            else if ([type isEqualToString:@"double"]) nv = @([v stringByReplacingOccurrencesOfString:@"," withString:@"."].doubleValue);
            else nv = v;
        }
        VMPrefSet(key, domain, nv);
        [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationAutomatic];
    });
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *item = _shown[ip.row];
    NSString *key = item[@"key"], *domain = item[@"domain"] ?: SB_DOMAIN;
    if (!VMPrefGet(key, domain)) return nil;
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Predefinito"
        handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
            VMPrefSet(key, domain, nil);
            [tv reloadRowsAtIndexPaths:@[ip] withRowAnimation:UITableViewRowAnimationAutomatic];
            done(YES);
        }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

@end

// ---- Main screen -----------------------------------------------------------------------------------------------------

@implementation VMSpringBoardViewController {
    NSArray<NSDictionary *> *_catalog;
    NSArray<NSString *> *_groups;                          // class names, ordered by title
    NSDictionary<NSString *, NSArray *> *_byGroup;
    BOOL _showInternal;
}

enum { SecActions, SecAll, SecGroups };

- (void)viewDidLoad {
    [super viewDidLoad];
    _catalog = [VMSystem loadJSON:@"springboard-keys"];
    [self rebuild];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    CFPreferencesAppSynchronize((__bridge CFStringRef)SB_DOMAIN);
    [self.tableView reloadData];
}

- (NSArray<NSDictionary *> *)visible {
    NSMutableArray *r = [NSMutableArray array];
    for (NSDictionary *i in _catalog) if (_showInternal || ![i[@"internal"] boolValue]) [r addObject:i];
    return r;
}

- (void)rebuild {
    NSMutableDictionary *by = [NSMutableDictionary dictionary];
    for (NSDictionary *i in self.visible) {
        NSString *g = i[@"group"] ?: @"Altro";
        if (!by[g]) by[g] = [NSMutableArray array];
        [by[g] addObject:i];
    }
    _byGroup = by;
    _groups = [by.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [VMGroupTitle(a) localizedCaseInsensitiveCompare:VMGroupTitle(b)];
    }];
    [self.tableView reloadData];
}

// Keys saved in the domain that the catalog does not describe.
- (NSArray<NSDictionary *> *)savedItems {
    NSArray *keys = CFBridgingRelease(CFPreferencesCopyKeyList((__bridge CFStringRef)SB_DOMAIN, kCFPreferencesCurrentUser,
                                                               kCFPreferencesAnyHost)) ?: @[];
    NSMutableDictionary *cat = [NSMutableDictionary dictionary];
    for (NSDictionary *i in _catalog) if ([i[@"domain"] ?: SB_DOMAIN isEqualToString:SB_DOMAIN]) cat[i[@"key"]] = i;
    NSMutableArray *r = [NSMutableArray array];
    for (NSString *k in [keys sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)])
        [r addObject:cat[k] ?: @{@"key": k, @"domain": SB_DOMAIN}];
    return r;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 3; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == SecActions) return 2;
    if (s == SecAll) return 3;
    return (NSInteger)_groups.count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return @[@"", @"Impostazioni", @"Per categoria"][s];
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == SecActions) return @"Le chiavi interne servono a test e debug di Apple: alcune possono rendere SpringBoard instabile.";
    if (s == SecAll) return [NSString stringWithFormat:@"%lu chiavi da 51 classi di SpringBoard (iOS 16.7). Valori salvati: "
                                                      @"tutto ciò che è scritto in com.apple.springboard.", (unsigned long)_catalog.count];
    return nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    if (ip.section == SecActions) {
        if (ip.row == 0) {
            c.textLabel.text = @"Riavvia SpringBoard";
            c.textLabel.textColor = UIColor.systemOrangeColor;
            c.imageView.image = [UIImage systemImageNamed:@"arrow.clockwise.circle.fill"];
            c.imageView.tintColor = UIColor.systemOrangeColor;
        } else {
            c.textLabel.text = @"Mostra chiavi interne";
            VMSwitch *sw = [VMSwitch new];
            sw.on = _showInternal;
            __weak typeof(self) ws = self;
            sw.onChange = ^(BOOL on) {
                typeof(self) s = ws;
                if (!s) return;
                s->_showInternal = on;
                [s rebuild];
            };
            c.accessoryView = sw;
            c.selectionStyle = UITableViewCellSelectionStyleNone;
        }
        return c;
    }
    c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    if (ip.section == SecAll) {
        NSArray *t = @[@"Tutte le impostazioni", @"Valori salvati", @"Aggiungi o modifica una chiave…"];
        c.textLabel.text = t[ip.row];
        if (ip.row == 0) c.detailTextLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)self.visible.count];
        if (ip.row == 1) c.detailTextLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)self.savedItems.count];
        if (ip.row == 2) c.accessoryType = UITableViewCellAccessoryNone, c.textLabel.textColor = self.view.tintColor;
        return c;
    }
    NSString *g = _groups[ip.row];
    c.textLabel.text = VMGroupTitle(g);
    NSUInteger saved = 0;
    for (NSDictionary *i in _byGroup[g]) if (VMPrefGet(i[@"key"], i[@"domain"] ?: SB_DOMAIN)) saved++;
    c.detailTextLabel.text = saved ? [NSString stringWithFormat:@"%lu · %lu salvate", (unsigned long)[_byGroup[g] count], (unsigned long)saved]
                                   : [NSString stringWithFormat:@"%lu", (unsigned long)[_byGroup[g] count]];
    return c;
}

- (void)addKey {
    VMEditText(self, @"Chiave di com.apple.springboard", @"Scrivi NOME=valore. Valori: YES/NO, numeri, altrimenti stringa. "
               @"Solo NOME apre l'editor della chiave se esiste già.", @"", @"SBExampleKey=YES", UIKeyboardTypeASCIICapable, ^(NSString *v) {
        if (!v.length) return;
        NSRange eq = [v rangeOfString:@"="];
        NSString *k = eq.location == NSNotFound ? v : [v substringToIndex:eq.location];
        if (eq.location == NSNotFound) {
            VMSBKeyList *l = [[VMSBKeyList alloc] initWithTitle:k items:@[@{@"key": k, @"domain": SB_DOMAIN}] searchable:NO];
            [self.navigationController pushViewController:l animated:YES];
            return;
        }
        NSString *s = [v substringFromIndex:eq.location + 1];
        id value = s;
        NSScanner *sc = [NSScanner scannerWithString:s];
        long long ll;
        double d;
        if ([s caseInsensitiveCompare:@"YES"] == NSOrderedSame || [s caseInsensitiveCompare:@"true"] == NSOrderedSame) value = @YES;
        else if ([s caseInsensitiveCompare:@"NO"] == NSOrderedSame || [s caseInsensitiveCompare:@"false"] == NSOrderedSame) value = @NO;
        else if ([sc scanLongLong:&ll] && sc.isAtEnd) value = @(ll);
        else if ((sc = [NSScanner scannerWithString:s]) && [sc scanDouble:&d] && sc.isAtEnd) value = @(d);
        VMPrefSet(k, SB_DOMAIN, value);
        VMToast(self, [NSString stringWithFormat:@"%@ = %@ (riavvia SpringBoard)", k, VMPrefDescribe(value)]);
        [self.tableView reloadData];
    });
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    UIViewController *next = nil;
    if (ip.section == SecActions) {
        if (ip.row == 0)
            VMConfirm(self, @"Riavviare SpringBoard?", @"Applica le impostazioni modificate. Le app aperte vengono chiuse.", @"Riavvia", YES, ^{
                VMRunHelper(@[@"restart", @"SpringBoard"], nil, ^(int s, NSString *o) { if (s) VMAlert(self, @"SpringBoard", o); });
            });
        return;
    }
    if (ip.section == SecAll) {
        if (ip.row == 0) next = [[VMSBKeyList alloc] initWithTitle:@"Tutte" items:self.visible searchable:YES];
        else if (ip.row == 1) next = [[VMSBKeyList alloc] initWithTitle:@"Valori salvati" items:self.savedItems searchable:YES];
        else { [self addKey]; return; }
    } else {
        NSString *g = _groups[ip.row];
        next = [[VMSBKeyList alloc] initWithTitle:VMGroupTitle(g) items:_byGroup[g] searchable:[_byGroup[g] count] > 12];
    }
    [self.navigationController pushViewController:next animated:YES];
}

@end
