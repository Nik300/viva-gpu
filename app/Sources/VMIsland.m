// Dynamic Island: settings of the SpringBoard tweak VivaIsland.dylib (../tweak/VivaIsland.m), which shows the USB
// "Viva Link" state in the island. Preferences in it.viva.island (CFPreferences as mobile, read by SpringBoard), Darwin
// notifications for "preferences changed" and "Test isola", the tweak's state from its notify state word.
#import "VMApp.h"
#import <notify.h>
#import <signal.h>
#import "../tweak/VivaIsland.h"

static id VMIslandPref(NSString *key) {
    return CFBridgingRelease(CFPreferencesCopyValue((__bridge CFStringRef)key, CFSTR(VI_DOMAIN), kCFPreferencesCurrentUser,
                                                    kCFPreferencesAnyHost));
}

static void VMIslandSetPref(NSString *key, id value) {
    CFPreferencesSetValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, CFSTR(VI_DOMAIN),
                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize(CFSTR(VI_DOMAIN), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    notify_post(VI_NOTIFY_PREFS);
}

static BOOL VMIslandBool(NSString *key, BOOL def) {
    id v = VMIslandPref(key);
    return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : def;
}

// The tweak's status word; 0 when SpringBoard runs without it.
static uint64_t VMIslandStatus(void) {
    static int token;
    static BOOL ok;
    if (!ok) ok = notify_register_check(VI_NOTIFY_STATUS, &token) == NOTIFY_STATUS_OK;
    uint64_t s = 0;
    if (ok) notify_get_state(token, &s);
    int pid = VI_STATUS_PID(s);
    if (pid <= 0 || (kill(pid, 0) != 0 && errno != EPERM)) return 0;   // stale: that SpringBoard is gone
    return s;
}

// YES when the SpringBoard binary on disk has the load command (the path string is in its header).
static BOOL VMSpringBoardPatched(void) {
    NSFileHandle *f = [NSFileHandle fileHandleForReadingAtPath:@VI_SPRINGBOARD_PATH];
    NSData *head = [f readDataOfLength:64 * 1024];
    [f closeFile];
    NSData *needle = [@VI_DYLIB_PATH dataUsingEncoding:NSUTF8StringEncoding];
    return head.length && [head rangeOfData:needle options:0 range:NSMakeRange(0, head.length)].location != NSNotFound;
}

static int VMIslandGuardCount(void) {
    NSString *s = [NSString stringWithContentsOfFile:@VI_SAFETY_FILE encoding:NSUTF8StringEncoding error:nil];
    return s ? MAX(1, s.intValue) : 0;
}

@implementation VMIslandViewController {
    NSTimer *_timer;
}

enum { SecState, SecSettings, SecActions, SecCount };
enum { RowTweak, RowLink, RowSpringBoard, RowDylib, RowGuard };

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Dynamic Island";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    CFPreferencesSynchronize(CFSTR(VI_DOMAIN), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    [self.tableView reloadData];
    __weak typeof(self) ws = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *t) {
        [ws.tableView reloadSections:[NSIndexSet indexSetWithIndex:SecState] withRowAnimation:UITableViewRowAnimationNone];
    }];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_timer invalidate];
    _timer = nil;
}

- (BOOL)guardTripped { return VMIslandGuardCount() >= VI_SAFETY_LIMIT; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return SecCount; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == SecState) return self.guardTripped ? 5 : 4;
    if (s == SecSettings) return 3;
    return 2;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return @[@"Stato", @"Avvisi nell'isola", @""][s];
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == SecState)
        return @"VivaIsland.dylib gira dentro SpringBoard: lo carica il binario di SpringBoard modificato da "
               @"app/tweak/inject.sh (vedi docs/DYNAMIC-ISLAND.md). Ripristino: vi-sb.sh restore.";
    if (s == SecSettings)
        return @"Viva Link: avviso esteso per 3 s quando lo strumento host si collega, poi un'icona compatta finché il "
               @"link resta attivo. «USB standard»: breve avviso quando si collega un computer senza lo strumento. "
               @"L'overlay è il ripiego (una pillola nera disegnata sopra l'isola) se l'isola di sistema non funziona.";
    return @"Il test mostra l'avviso Viva Link per qualche secondo anche senza cavo.";
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    c.selectionStyle = UITableViewCellSelectionStyleNone;
    if (ip.section == SecState) {
        uint64_t st = VMIslandStatus();
        if (ip.row == RowTweak) {
            c.textLabel.text = @"Tweak in SpringBoard";
            NSString *d = @"non caricato";
            UIColor *col = UIColor.secondaryLabelColor;
            if (st) {
                int mode = VI_STATUS_MODE(st), flags = VI_STATUS_FLAGS(st);
                d = mode == VI_MODE_ELEMENT ? @"isola di sistema" : mode == VI_MODE_OVERLAY ? @"overlay" :
                    mode == VI_MODE_OFF ? @"spento" : @"in avvio";
                if (mode == VI_MODE_OVERLAY && (flags & VI_FLAG_SAFETY)) d = @"overlay (protezione crash)";
                else if (mode == VI_MODE_OVERLAY && (flags & VI_FLAG_ELEMENT_FAILED)) d = @"overlay (isola non disponibile)";
                col = mode == VI_MODE_ELEMENT ? UIColor.systemGreenColor : mode == VI_MODE_OVERLAY ? UIColor.systemOrangeColor
                                                                                                 : UIColor.secondaryLabelColor;
            }
            c.detailTextLabel.text = d;
            c.detailTextLabel.textColor = col;
        } else if (ip.row == RowLink) {
            c.textLabel.text = @"Link USB";
            int64_t v = [VMSystem sysctlExists:VI_SYSCTL] ? [VMSystem sysctlInt:VI_SYSCTL] : -1;
            c.detailTextLabel.text = v == 2 ? @"Viva Link attivo" : v == 1 ? @"computer (standard)" : v == 0 ? @"nessun host"
                                   : @"sysctl assente (kernel senza 0182)";
            c.detailTextLabel.textColor = v == 2 ? UIColor.systemGreenColor : UIColor.secondaryLabelColor;
        } else if (ip.row == RowSpringBoard) {
            c.textLabel.text = @"SpringBoard";
            BOOL p = VMSpringBoardPatched();
            c.detailTextLabel.text = p ? @"modificato (carica il tweak)" : @"originale";
            c.detailTextLabel.textColor = p ? UIColor.systemGreenColor : UIColor.secondaryLabelColor;
        } else if (ip.row == RowDylib) {
            c.textLabel.text = @"VivaIsland.dylib";
            NSFileManager *fm = NSFileManager.defaultManager;
            BOOL on = [fm fileExistsAtPath:@VI_DYLIB_PATH], off = [fm fileExistsAtPath:@VI_DYLIB_PATH ".off"];
            c.detailTextLabel.text = on ? @"installata" : off ? @"disattivata (.off)" : @"assente";
            c.detailTextLabel.textColor = on ? UIColor.systemGreenColor : UIColor.secondaryLabelColor;
        } else {
            c.textLabel.text = @"Protezione crash attiva";
            c.textLabel.textColor = UIColor.systemRedColor;
            c.detailTextLabel.text = @"Riabilita isola";
            c.detailTextLabel.textColor = self.view.tintColor;
            c.selectionStyle = UITableViewCellSelectionStyleDefault;
        }
        return c;
    }
    if (ip.section == SecSettings) {
        NSArray *keys = @[@VI_KEY_ENABLED, @VI_KEY_STANDARD, @VI_KEY_FORCE_OVERLAY];
        NSArray *titles = @[@"Avviso Viva Link", @"Avviso «USB standard»", @"Forza overlay (ripiego)"];
        NSArray *defs = @[@YES, @NO, @NO];
        NSString *key = keys[ip.row];
        c.textLabel.text = titles[ip.row];
        VMSwitch *sw = [VMSwitch new];
        sw.on = VMIslandBool(key, [defs[ip.row] boolValue]);
        sw.onChange = ^(BOOL on) { VMIslandSetPref(key, @(on)); };
        c.accessoryView = sw;
        return c;
    }
    c.selectionStyle = UITableViewCellSelectionStyleDefault;
    if (ip.row == 0) {
        c.textLabel.text = @"Test isola";
        c.textLabel.textColor = self.view.tintColor;
        c.imageView.image = [UIImage systemImageNamed:@"cable.connector"];
    } else {
        c.textLabel.text = @"Riavvia SpringBoard";
        c.textLabel.textColor = UIColor.systemOrangeColor;
        c.imageView.image = [UIImage systemImageNamed:@"arrow.clockwise.circle.fill"];
        c.imageView.tintColor = UIColor.systemOrangeColor;
    }
    return c;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == SecState && ip.row == RowGuard) {
        VMConfirm(self, @"Riabilitare l'isola di sistema?", @"Il tweak l'aveva disattivata perché SpringBoard si è chiuso "
                  @"subito dopo aver mostrato l'avviso. Se succede di nuovo torna all'overlay.", @"Riabilita", NO, ^{
            unlink(VI_SAFETY_FILE);
            notify_post(VI_NOTIFY_PREFS);
            [self.tableView reloadData];
        });
        return;
    }
    if (ip.section != SecActions) return;
    if (ip.row == 0) {
        if (!VMIslandStatus()) {
            VMAlert(self, @"Tweak non caricato", @"SpringBoard non sta eseguendo VivaIsland.dylib: serve il binario modificato "
                    @"(app/tweak/inject.sh, poi vi-sb.sh install).");
            return;
        }
        notify_post(VI_NOTIFY_TEST);
        VMToast(self, @"Avviso inviato all'isola");
        return;
    }
    VMConfirm(self, @"Riavviare SpringBoard?", @"Le app aperte vengono chiuse.", @"Riavvia", YES, ^{
        VMRunHelper(@[@"restart", @"SpringBoard"], nil, ^(int s, NSString *o) { if (s) VMAlert(self, @"SpringBoard", o); });
    });
}

@end
