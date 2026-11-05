// Viva Manager: MaliMetal flags (vmg.env), boot-args of the next boot, SpringBoard settings, statistics.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

#define VM_ENV_PATH @"/System/Library/Extensions/VivaMTLDriver.bundle/vmg.env"

// ---- System access (VMSystem.m) --------------------------------------------------------------------------------------

@interface VMSystem : NSObject
// Runs the setuid helper in the app bundle. Returns its exit status (-1: could not start it). Blocking: call it off
// the main thread (VMRunHelper below does).
+ (int)runHelper:(NSArray<NSString *> *)args input:(nullable NSString *)input output:(NSString *_Nullable *_Nullable)output;
+ (nullable NSString *)sysctlString:(const char *)name;
+ (BOOL)sysctlExists:(const char *)name;
+ (int64_t)sysctlInt:(const char *)name;
// kern.viva_link (KA1): the reply, or nil with *err = errno (ENOENT: kernel without KA1; EPERM: needs root).
+ (nullable NSString *)link:(NSString *)command error:(int *_Nullable)err;
+ (NSArray *)loadJSON:(NSString *)name;
@end

// Helper on a background queue, completion on the main queue.
void VMRunHelper(NSArray<NSString *> *args, NSString *_Nullable input, void (^completion)(int status, NSString *output));

// ---- UI helpers (VMUI.m) ---------------------------------------------------------------------------------------------

typedef void (^VMTextCompletion)(NSString *_Nullable value);   // nil = cancelled

void VMEditText(UIViewController *vc, NSString *title, NSString *_Nullable message, NSString *_Nullable value,
                NSString *_Nullable placeholder, UIKeyboardType keyboard, VMTextCompletion done);
void VMConfirm(UIViewController *vc, NSString *title, NSString *_Nullable message, NSString *action, BOOL destructive,
               dispatch_block_t done);
void VMAlert(UIViewController *vc, NSString *title, NSString *_Nullable message);
void VMToast(UIViewController *vc, NSString *text);
NSString *VMBytes(double bytes);
UIFont *VMMono(CGFloat size);

@interface VMSwitch : UISwitch
@property (nonatomic, copy, nullable) void (^onChange)(BOOL on);
@end

// A line chart of the last N values (0..max), drawn with CoreGraphics.
@interface VMSparkView : UIView
@property (nonatomic, copy) NSArray<NSNumber *> *values;
@property (nonatomic) double maxValue;          // 0 = from the data
@property (nonatomic, strong) UIColor *color;
@property (nonatomic, copy, nullable) NSString *caption;
@end

// Horizontal bar 0..1, for per-core load and memory parts.
@interface VMBarView : UIView
@property (nonatomic) double fraction;
@property (nonatomic, strong) UIColor *color;
@end

// A plain text screen (raw link replies, file contents), optionally editable.
@interface VMTextViewController : UIViewController
- (instancetype)initWithTitle:(NSString *)title text:(NSString *)text editable:(BOOL)editable
                         save:(nullable void (^)(NSString *text))save;
@property (nonatomic, copy, nullable) NSString *(^reload)(void);   // pull to refresh
@end

// ---- Screens ---------------------------------------------------------------------------------------------------------

// vmg.env editor. The model (catalog values, unsaved changes) is shared with subpages such as the ISA compiler's.
extern NSNotificationName const VMFlagsDidChangeNotification;   // values edited, loaded or saved
@interface VMMaliMetalViewController : UITableViewController
@property (nonatomic, readonly) BOOL dirty;
- (nullable NSString *)flagValue:(NSString *)key;
- (void)setFlagValues:(NSDictionary<NSString *, id> *)values;     // one change for many keys; NSNull / @"" removes
- (void)presentSaveFrom:(UIViewController *)vc item:(nullable UIBarButtonItem *)item;   // "Salvare vmg.env?"
- (UITableViewCell *)cellForFlag:(NSDictionary *)item enabled:(BOOL)enabled;           // a catalog row
- (void)editFlag:(NSDictionary *)item from:(UIViewController *)vc source:(UIView *)source;
@end

// ---- ISA compiler (VMIsa.m): settings subpage of MaliMetal, test cases (driver/tests/isa_cases.m) and their panel --------

@interface VMIsaViewController : UITableViewController
- (instancetype)initWithGroup:(NSDictionary *)group flags:(VMMaliMetalViewController *)flags;
@end
// The ISA path generates Mali-G57 (Valhall v9) code only: YES when the GPU in use is that one. *name: what was found.
BOOL VMIsaCompatible(NSString *_Nullable *_Nullable name);
@interface VMBootArgsViewController : UITableViewController
@end
@interface VMSpringBoardViewController : UITableViewController
@end
@interface VMStatsViewController : UITableViewController
@end

// ---- Statistics (VMStats.m) ------------------------------------------------------------------------------------------

extern NSNotificationName const VMStatsDidUpdateNotification;

@interface VMProcSample : NSObject
@property (nonatomic) int pid;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) double cpuPercent;        // of one core
@property (nonatomic) uint64_t footprint, resident;
@end

@interface VMDriverProc : NSObject
@property (nonatomic) int pid;
@property (nonatomic, copy) NSString *name, *build;
@property (nonatomic) double ageSeconds;        // since the process last updated its page
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *totals;   // counters (vmg_shm_stats fields)
@property (nonatomic, copy) NSDictionary<NSString *, NSNumber *> *rates;    // per second, since the previous sample
@property (nonatomic, copy) NSArray<NSDictionary *> *calls;                 // {name, total, rate}
@property (nonatomic, copy, nullable) NSString *isaLastFallback;            // "function: reason" (driver with ISA stats)
@property (nonatomic) uint32_t gpuProductId;                                // 0: not published
@end

@interface VMStats : NSObject
+ (instancetype)shared;
@property (nonatomic) BOOL wantProcesses;      // sample the process list (helper) every 2 s
- (void)retainSampling;                        // sampling runs while someone holds it
- (void)releaseSampling;

// CPU
@property (nonatomic, readonly) NSArray<NSNumber *> *coreLoad;   // 0..1 per core
@property (nonatomic, readonly) double cpuTotal, cpuUser, cpuSystem;
@property (nonatomic, readonly) NSArray<NSNumber *> *cpuHistory; // percent
// RAM (bytes)
@property (nonatomic, readonly) uint64_t memTotal, memFree, memActive, memInactive, memWired, memCompressed,
    memSpeculative, memPurgeable, pageSize;
@property (nonatomic, readonly) uint64_t pageins, pageouts, compressions, decompressions, swapins, swapouts;
@property (nonatomic, readonly) int memoryLevel;                 // kern.memorystatus_level (% available), -1 unknown
@property (nonatomic, readonly) NSArray<NSNumber *> *memHistory; // percent used
// Processes (wantProcesses)
@property (nonatomic, readonly) NSArray<VMProcSample *> *processes;
// GPU (kernel, KA1)
@property (nonatomic, readonly) BOOL gpuKernelStats;              // kern.viva_link answers
@property (nonatomic, readonly) NSDictionary<NSString *, NSString *> *gpu;   // "gpu kv" (or parsed from "gpu")
@property (nonatomic, readonly) NSDictionary<NSString *, NSString *> *disp;  // "disp kv" (or parsed from "disp")
@property (nonatomic, readonly) double gpuJobsPerSecond, displayFps;
@property (nonatomic, readonly) NSArray<NSNumber *> *gpuLoadHistory, *gpuMHzHistory, *fpsHistory;
// MaliMetal driver (pages in /private/var/tmp/vmg-stats)
@property (nonatomic, readonly) NSArray<VMDriverProc *> *driverProcs;
@property (nonatomic, readonly) double driverGpuBusy;             // 0..1, sum over processes of GPU time / wall time
@property (nonatomic, readonly) NSArray<NSNumber *> *driverCbHistory, *driverBusyHistory;
// System
@property (nonatomic, readonly) double uptime;
@property (nonatomic, readonly) double load1, load5, load15;
@end

NS_ASSUME_NONNULL_END
