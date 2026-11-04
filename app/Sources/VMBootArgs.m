// Boot Args: the kernel command line of the next boot. It lives in the SWEETXNU payload inside boot_b; the kernel
// rewrites it through kern.viva_nextbootargs (KA2 in docs/RICHIESTE-KERNEL.md). Without KA2 the helper keeps the line
// in /private/var/root/viva-next-bootargs, for viva-mkboot.sh (VIVA_CMDLINE) on the Mac.
#import "VMApp.h"

@implementation VMBootArgsViewController {
    NSArray<NSDictionary *> *_groups;
    NSSet<NSString *> *_known;
    NSString *_current;                     // kern.bootargs
    NSString *_source;                      // "kernel" | "file" | "none" | nil (loading)
    NSMutableArray<NSString *> *_tokens;    // next boot, in order
    NSString *_saved;                       // what was last read/written
    NSArray<NSString *> *_extraTokens;
}

enum { SecCurrent, SecNext, SecActions, SecFirstGroup };

static NSString *VMArgKey(NSString *token) {
    NSString *k = [token componentsSeparatedByString:@"="].firstObject;
    return [k hasPrefix:@"-"] ? [k substringFromIndex:1] : k;
}

static NSString *VMCatalogKey(NSDictionary *item) {
    NSString *k = item[@"key"];
    return [k hasPrefix:@"-"] ? [k substringFromIndex:1] : k;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _groups = [VMSystem loadJSON:@"bootargs"];
    NSMutableSet *k = [NSMutableSet set];
    for (NSDictionary *g in _groups) for (NSDictionary *i in g[@"items"]) [k addObject:VMCatalogKey(i)];
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
    [self load];
    [rc endRefreshing];
}

- (NSArray<NSString *> *)split:(NSString *)line {
    NSMutableArray *t = [NSMutableArray array];
    for (NSString *s in [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet])
        if (s.length) [t addObject:s];
    return t;
}

- (NSString *)line { return [_tokens componentsJoinedByString:@" "]; }

- (BOOL)dirty { return _saved && ![self.line isEqualToString:_saved]; }

- (void)load {
    _current = [VMSystem sysctlString:"kern.bootargs"] ?: @"";
    _source = nil;
    [self refreshState];
    VMRunHelper(@[@"bootargs-get"], nil, ^(int status, NSString *out) {
        NSArray *lines = [out componentsSeparatedByString:@"\n"];
        NSString *src = status == 0 && lines.count ? lines[0] : @"none";
        NSString *next = status == 0 && lines.count > 1 ? lines[1] : @"";
        if (status != 0) VMToast(self, [@"Helper: " stringByAppendingString:out]);
        self->_source = src;
        if (!next.length) next = self->_current;   // nothing saved yet: start from this boot
        self->_tokens = [[self split:next] mutableCopy];
        self->_saved = self.line;
        if ([src isEqualToString:@"none"]) self->_saved = @"";   // never saved: Salva stays on
        [self refreshState];
    });
}

- (void)refreshState {
    NSMutableArray *extra = [NSMutableArray array];
    for (NSString *t in _tokens) if (![_known containsObject:VMArgKey(t)]) [extra addObject:t];
    _extraTokens = extra;
    self.navigationItem.rightBarButtonItem.enabled = _tokens != nil && self.dirty;
    [self.tableView reloadData];
}

- (NSInteger)indexOfKey:(NSString *)key {
    for (NSUInteger i = 0; i < _tokens.count; i++) if ([VMArgKey(_tokens[i]) isEqualToString:key]) return (NSInteger)i;
    return -1;
}

- (NSString *)valueOf:(NSDictionary *)item present:(BOOL *)present {
    NSInteger i = [self indexOfKey:VMCatalogKey(item)];
    *present = i >= 0;
    if (i < 0) return nil;
    NSString *t = _tokens[i];
    NSRange eq = [t rangeOfString:@"="];
    return eq.location == NSNotFound ? @"" : [t substringFromIndex:eq.location + 1];
}

// value nil: remove; flags ("-x") are written without a value.
- (void)setItem:(NSDictionary *)item value:(NSString *)value {
    NSString *key = VMCatalogKey(item);
    NSInteger i = [self indexOfKey:key];
    NSString *token = nil;
    if (value) token = [item[@"type"] isEqualToString:@"flag"] ? item[@"key"] : [NSString stringWithFormat:@"%@=%@", key, value];
    if (i >= 0) {
        if (token) _tokens[i] = token; else [_tokens removeObjectAtIndex:i];
        // XNU uses the first match: drop later duplicates.
        for (NSInteger j = (NSInteger)_tokens.count - 1; j > i; j--)
            if ([VMArgKey(_tokens[j]) isEqualToString:key]) [_tokens removeObjectAtIndex:j];
    } else if (token) {
        [_tokens addObject:token];
    }
    [self refreshState];
}

- (void)save {
    NSString *line = self.line;
    if (line.length >= 608) { VMAlert(self, @"Troppo lunga", @"La riga dei boot-arg deve stare in 607 caratteri."); return; }
    if ([self indexOfKey:@"rd"] < 0 || [self indexOfKey:@"vivausb"] < 0) {
        VMConfirm(self, @"Attenzione", @"Mancano rd= o vivausb=: il telefono potrebbe non avviare iOS o perdere il link USB. Salvare comunque?",
                  @"Salva", YES, ^{ [self doSave:line]; });
        return;
    }
    [self doSave:line];
}

- (void)doSave:(NSString *)line {
    VMRunHelper(@[@"bootargs-set"], line, ^(int status, NSString *out) {
        if (status != 0) { VMAlert(self, @"Boot-arg non salvati", out); return; }
        self->_saved = line;
        self->_source = [out hasPrefix:@"kernel"] ? @"kernel" : @"file";
        [self refreshState];
        if ([self->_source isEqualToString:@"kernel"])
            VMToast(self, @"Salvati in boot_b: valgono dal prossimo riavvio");
        else
            VMAlert(self, @"Salvati nel file",
                    @"Il kernel non ha ancora kern.viva_nextbootargs (richiesta KA2): la riga è in "
                    @"/private/var/root/viva-next-bootargs. Si applica rigenerando l'immagine di boot (VIVA_CMDLINE).");
    });
}

- (void)rebootNow {
    NSString *msg = self.dirty ? @"Ci sono modifiche non salvate: andranno perse." : @"Il telefono si riavvia subito.";
    VMConfirm(self, @"Riavviare ora?", msg, @"Riavvia", YES, ^{
        VMRunHelper(@[@"reboot"], nil, ^(int status, NSString *out) {
            if (status != 0) VMAlert(self, @"Riavvio non riuscito", out);
        });
    });
}

#pragma mark - Table

- (NSInteger)extraSection { return SecFirstGroup + (NSInteger)_groups.count; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return _tokens ? self.extraSection + 1 : SecActions; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == SecCurrent) return 1;
    if (s == SecNext) return 2;
    if (s == SecActions) return 3;
    if (s == self.extraSection) return (NSInteger)_extraTokens.count + 1;
    return (NSInteger)[_groups[s - SecFirstGroup][@"items"] count];
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    if (s == SecCurrent) return @"Avvio attuale";
    if (s == SecNext) return @"Prossimo avvio";
    if (s == SecActions) return nil;
    if (s == self.extraSection) return @"Altri argomenti";
    return _groups[s - SecFirstGroup][@"group"];
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == SecNext) {
        if (!_source) return @"Lettura…";
        if ([_source isEqualToString:@"kernel"]) return @"Letti e scritti dal kernel nel payload di boot_b.";
        return @"Il kernel non ha kern.viva_nextbootargs (KA2): la riga viene salvata in /private/var/root/viva-next-bootargs.";
    }
    if (s == SecFirstGroup + (NSInteger)_groups.count - 1)
        return @"Questi servono ad avviare iOS sul telefono: si modificano solo con conferma.";
    return nil;
}

- (UITableViewCell *)cellWithStyle:(UITableViewCellStyle)style {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:style reuseIdentifier:nil];
    c.textLabel.numberOfLines = 0;
    c.detailTextLabel.numberOfLines = 0;
    return c;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    if (ip.section == SecCurrent || (ip.section == SecNext && ip.row == 0)) {
        UITableViewCell *c = [self cellWithStyle:UITableViewCellStyleDefault];
        c.textLabel.font = VMMono(12);
        c.textLabel.text = ip.section == SecCurrent ? _current : (_tokens ? self.line : @"…");
        if (ip.section == SecNext && self.dirty) c.textLabel.textColor = self.view.tintColor;
        return c;
    }
    if (ip.section == SecNext) {
        UITableViewCell *c = [self cellWithStyle:UITableViewCellStyleValue1];
        c.textLabel.text = @"Modifica a mano";
        c.detailTextLabel.text = [NSString stringWithFormat:@"%lu/607", (unsigned long)self.line.length];
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        return c;
    }
    if (ip.section == SecActions) {
        UITableViewCell *c = [self cellWithStyle:UITableViewCellStyleDefault];
        NSArray *t = @[@"Ripristina dall'avvio attuale", @"Annulla le modifiche", @"Riavvia ora"];
        c.textLabel.text = t[ip.row];
        c.textLabel.textColor = ip.row == 2 ? UIColor.systemRedColor : self.view.tintColor;
        return c;
    }
    if (ip.section == self.extraSection) {
        UITableViewCell *c = [self cellWithStyle:UITableViewCellStyleDefault];
        if (ip.row == (NSInteger)_extraTokens.count) {
            c.textLabel.text = @"Aggiungi argomento…";
            c.textLabel.textColor = self.view.tintColor;
        } else {
            c.textLabel.text = _extraTokens[ip.row];
            c.textLabel.font = VMMono(14);
        }
        return c;
    }
    NSDictionary *item = _groups[ip.section - SecFirstGroup][@"items"][ip.row];
    NSString *type = item[@"type"];
    BOOL present;
    NSString *value = [self valueOf:item present:&present];
    UITableViewCell *c = [self cellWithStyle:UITableViewCellStyleSubtitle];
    c.textLabel.text = [item[@"critical"] boolValue] ? [@"🔒 " stringByAppendingString:item[@"title"]] : item[@"title"];
    NSString *state;
    if ([type isEqualToString:@"flag"]) state = item[@"key"];
    else if (present) state = [NSString stringWithFormat:@"%@=%@%@", VMCatalogKey(item), value, item[@"unit"] ? [@" " stringByAppendingString:item[@"unit"]] : @""];
    else state = [NSString stringWithFormat:@"%@ non impostato%@", VMCatalogKey(item),
                  item[@"default"] ? [NSString stringWithFormat:@" (immagine: %@)", item[@"default"]] : @""];
    NSMutableAttributedString *d = [[NSMutableAttributedString alloc] initWithString:state attributes:@{
        NSFontAttributeName: VMMono(12),
        NSForegroundColorAttributeName: present ? self.view.tintColor : UIColor.secondaryLabelColor}];
    [d appendAttributedString:[[NSAttributedString alloc] initWithString:[@"\n" stringByAppendingString:item[@"desc"] ?: @""]
        attributes:@{NSFontAttributeName: [UIFont systemFontOfSize:13], NSForegroundColorAttributeName: UIColor.secondaryLabelColor}]];
    c.detailTextLabel.attributedText = d;
    BOOL critical = [item[@"critical"] boolValue];
    if (([type isEqualToString:@"flag"] || [type isEqualToString:@"bool01"]) && !critical) {
        VMSwitch *sw = [VMSwitch new];
        sw.on = [type isEqualToString:@"flag"] ? present : (present ? value.intValue != 0 : [item[@"default"] intValue] != 0);
        if ([type isEqualToString:@"bool01"] && !present) sw.alpha = 0.6;   // shows the image's value
        __weak typeof(self) ws = self;
        sw.onChange = ^(BOOL on) {
            if ([type isEqualToString:@"flag"]) [ws setItem:item value:on ? @"" : nil];
            else [ws setItem:item value:on ? @"1" : @"0"];
        };
        c.accessoryView = sw;
    } else {
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return c;
}

- (void)editItem:(NSDictionary *)item from:(UITableViewCell *)cell {
    NSString *type = item[@"type"];
    BOOL present;
    NSString *value = [self valueOf:item present:&present];
    if ([type isEqualToString:@"choice"] || [type isEqualToString:@"bool01"] || [type isEqualToString:@"flag"]) {
        NSArray *options = [type isEqualToString:@"choice"] ? item[@"options"] : [type isEqualToString:@"flag"] ? @[@""] : @[@"0", @"1"];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:item[@"title"] message:item[@"desc"]
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSString *o in options) {
            NSString *t = o.length ? [NSString stringWithFormat:@"%@=%@", VMCatalogKey(item), o] : item[@"key"];
            if (present && [value isEqualToString:o]) t = [t stringByAppendingString:@"  ✓"];
            [a addAction:[UIAlertAction actionWithTitle:t style:UIAlertActionStyleDefault
                                                handler:^(UIAlertAction *x) { [self setItem:item value:o]; }]];
        }
        [a addAction:[UIAlertAction actionWithTitle:@"Togli dalla riga" style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *x) { [self setItem:item value:nil]; }]];
        [a addAction:[UIAlertAction actionWithTitle:@"Annulla" style:UIAlertActionStyleCancel handler:nil]];
        a.popoverPresentationController.sourceView = cell;
        a.popoverPresentationController.sourceRect = cell.bounds;
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    NSString *msg = [NSString stringWithFormat:@"%@%@\n\nVuoto = togli dalla riga.", item[@"desc"],
                     item[@"unit"] ? [NSString stringWithFormat:@" (%@)", item[@"unit"]] : @""];
    VMEditText(self, item[@"title"], msg, present ? value : item[@"default"], item[@"default"],
               [type isEqualToString:@"int"] ? UIKeyboardTypeNumbersAndPunctuation : UIKeyboardTypeASCIICapable, ^(NSString *v) {
        if (!v) return;
        [self setItem:item value:v.length ? v : nil];
    });
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    UITableViewCell *cell = [tv cellForRowAtIndexPath:ip];
    if (ip.section == SecCurrent) {
        UIPasteboard.generalPasteboard.string = _current;
        VMToast(self, @"Copiati negli appunti");
        return;
    }
    if (ip.section == SecNext) {
        if (!_tokens) return;
        if (ip.row == 0) {
            UIPasteboard.generalPasteboard.string = self.line;
            VMToast(self, @"Copiati negli appunti");
            return;
        }
        __weak typeof(self) ws = self;
        VMTextViewController *t = [[VMTextViewController alloc] initWithTitle:@"Boot-arg" text:self.line editable:YES
            save:^(NSString *text) {
                typeof(self) s = ws;
                if (!s) return;
                s->_tokens = [[s split:text] mutableCopy];
                [s refreshState];
            }];
        [self.navigationController pushViewController:t animated:YES];
        return;
    }
    if (ip.section == SecActions) {
        if (ip.row == 0) {
            _tokens = [[self split:_current] mutableCopy];
            [self refreshState];
        } else if (ip.row == 1) {
            _tokens = [[self split:_saved.length ? _saved : _current] mutableCopy];
            [self refreshState];
        } else {
            [self rebootNow];
        }
        return;
    }
    if (ip.section == self.extraSection) {
        if (ip.row == (NSInteger)_extraTokens.count) {
            VMEditText(self, @"Nuovo argomento", @"nome=valore oppure -flag", @"", @"vivagpufreq=400", UIKeyboardTypeASCIICapable,
                       ^(NSString *v) {
                for (NSString *t in [self split:v ?: @""]) [self->_tokens addObject:t];
                [self refreshState];
            });
            return;
        }
        NSString *old = _extraTokens[ip.row];
        VMEditText(self, @"Argomento", @"Vuoto = toglilo", old, nil, UIKeyboardTypeASCIICapable, ^(NSString *v) {
            if (!v) return;
            NSUInteger i = [self->_tokens indexOfObject:old];
            if (i == NSNotFound) return;
            if (v.length) self->_tokens[i] = v; else [self->_tokens removeObjectAtIndex:i];
            [self refreshState];
        });
        return;
    }
    NSDictionary *item = _groups[ip.section - SecFirstGroup][@"items"][ip.row];
    if ([item[@"critical"] boolValue]) {
        VMConfirm(self, @"Argomento critico", @"Un valore sbagliato può impedire l'avvio di iOS (si recupera solo riflashando "
                  @"boot_b dal Mac). Modificarlo?", @"Modifica", YES, ^{ [self editItem:item from:cell]; });
        return;
    }
    [self editItem:item from:cell];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    if (!_tokens || ip.section < SecFirstGroup) return nil;
    dispatch_block_t remove = nil;
    if (ip.section == self.extraSection) {
        if (ip.row >= (NSInteger)_extraTokens.count) return nil;
        NSString *t = _extraTokens[ip.row];
        remove = ^{ [self->_tokens removeObject:t]; [self refreshState]; };
    } else {
        NSDictionary *item = _groups[ip.section - SecFirstGroup][@"items"][ip.row];
        BOOL present;
        [self valueOf:item present:&present];
        if (!present || [item[@"critical"] boolValue]) return nil;
        remove = ^{ [self setItem:item value:nil]; };
    }
    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Togli"
        handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) { remove(); done(YES); }];
    return [UISwipeActionsConfiguration configurationWithActions:@[del]];
}

@end
