// Statistics sampler: CPU (host_processor_info), RAM (host_statistics64), processes (helper), GPU and display (kernel,
// kern.viva_link: KA1), MaliMetal driver (one page per process in /private/var/tmp/vmg-stats, ../driver/vmg_shm_stats.h).
// Samples once per second while a statistics screen holds it.
#import "VMApp.h"
#include "vmg_shm_stats.h"
#include <errno.h>
#include <mach/mach.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/sysctl.h>
#include <time.h>

NSNotificationName const VMStatsDidUpdateNotification = @"VMStatsDidUpdate";

@implementation VMProcSample
@end
@implementation VMDriverProc
@end

// uapi selector names, by index (gpu/uapi/viva_gpu_uapi.h).
static NSString *const kCallNames[] = {
    @"GET_VERSION", @"GET_PARAM", @"CREATE_BO", @"MMAP_BO", @"GET_BO_OFFSET", @"GEM_CLOSE", @"SUBMIT", @"WAIT_BO",
    @"MADVISE", @"SYNCOBJ_CREATE", @"SYNCOBJ_DESTROY", @"SYNCOBJ_WAIT", @"SYNCOBJ_RESET", @"SYNCOBJ_SIGNAL",
    @"IMPORT_IOSURFACE", @"SYNC_BO", @"QUERY_BO_INFO", @"JM_CTX_CREATE", @"JM_CTX_DESTROY", @"SYNCOBJ_TRANSFER",
    @"IMPORT_USERPTR", @"SUBMIT_BATCH", @"SURFACE_PROMISE"};
#define kCallCount (sizeof kCallNames / sizeof kCallNames[0])

static void VMPush(NSMutableArray *a, double v) {
    [a addObject:@(v)];
    if (a.count > 120) [a removeObjectAtIndex:0];
}

// First capture group of pattern in text.
static NSString *VMRx(NSString *text, NSString *pattern) {
    if (!text) return nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (!m || m.numberOfRanges < 2 || [m rangeAtIndex:1].location == NSNotFound) return nil;
    return [text substringWithRange:[m rangeAtIndex:1]];
}

static NSDictionary *VMParseKV(NSString *text) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    for (NSString *l in [text componentsSeparatedByString:@"\n"]) {
        NSRange eq = [l rangeOfString:@"="];
        if (eq.location == NSNotFound || eq.location == 0 || [l containsString:@" "]) continue;
        d[[l substringToIndex:eq.location]] = [l substringFromIndex:eq.location + 1];
    }
    return d;
}

// The human-readable "gpu" reply (VivaGPU.cpp linkCommand) when the kernel has no "gpu kv".
static NSDictionary *VMParseGPUText(NSString *t) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    void (^put)(NSString *, NSString *) = ^(NSString *k, NSString *v) { if (v) d[k] = v; };
    put(@"powered", [VMRx(t, @"gpu: (on|off)") isEqualToString:@"on"] ? @"1" : VMRx(t, @"gpu: (on|off)") ? @"0" : nil);
    put(@"mode", VMRx(t, @"mode (\\d+)"));
    put(@"gpu_id", VMRx(t, @"id (0x[0-9a-f]+)"));
    put(@"mhz", VMRx(t, @"OPP (\\d+) MHz"));
    put(@"jobs", VMRx(t, @"jobs (\\d+)"));
    put(@"running", VMRx(t, @"running (\\d+/\\d+)"));
    put(@"queued", VMRx(t, @"queued (\\d+/\\d+)"));
    put(@"job_faults", VMRx(t, @"job faults (\\d+)"));
    put(@"mmu_faults", VMRx(t, @"MMU faults (\\d+)"));
    put(@"heap_grows", VMRx(t, @"heap grows (\\d+)"));
    put(@"gpu_faults", VMRx(t, @"GPU faults (\\d+)"));
    put(@"timeouts", VMRx(t, @"timeouts (\\d+)"));
    put(@"resets", VMRx(t, @"resets (\\d+)"));
    put(@"mem_kib", VMRx(t, @"memory: (-?\\d+) KiB"));
    put(@"mem_peak_kib", VMRx(t, @"peak (-?\\d+) KiB"));
    put(@"mem_limit_mib", VMRx(t, @"limit (\\d+) MiB"));
    put(@"mem_proc_mib", VMRx(t, @"(\\d+) MiB per process"));
    put(@"mem_refusals", VMRx(t, @"(\\d+) refusals"));
    put(@"dvfs", [VMRx(t, @"dvfs (on|off)") isEqualToString:@"on"] ? @"1" : VMRx(t, @"dvfs (on|off)") ? @"0" : nil);
    put(@"opp_min_mhz", VMRx(t, @"dvfs \\w+ \\((\\d+)\\.\\."));
    put(@"opp_max_mhz", VMRx(t, @"dvfs \\w+ \\(\\d+\\.\\.(\\d+) MHz"));
    put(@"load_pct", VMRx(t, @"load (\\d+)%"));
    put(@"dvfs_ups", VMRx(t, @"(\\d+) up"));
    put(@"dvfs_downs", VMRx(t, @"(\\d+) down"));
    put(@"dvfs_boosts", VMRx(t, @"(\\d+) display boosts"));
    // Per process: "  name[pid]: N KiB in N BOs, N KiB imported, ..."
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
        @"^\\s+(\\S+)\\[(\\d+)\\]: (-?\\d+) KiB in (\\d+) BOs, (-?\\d+) KiB imported" options:NSRegularExpressionAnchorsMatchLines error:nil];
    for (NSTextCheckingResult *m in [re matchesInString:t options:0 range:NSMakeRange(0, t.length)]) {
        NSString *pid = [t substringWithRange:[m rangeAtIndex:2]];
        d[[NSString stringWithFormat:@"proc.%@.name", pid]] = [t substringWithRange:[m rangeAtIndex:1]];
        d[[NSString stringWithFormat:@"proc.%@.kib", pid]] = [t substringWithRange:[m rangeAtIndex:3]];
        d[[NSString stringWithFormat:@"proc.%@.bos", pid]] = [t substringWithRange:[m rangeAtIndex:4]];
        d[[NSString stringWithFormat:@"proc.%@.imported_kib", pid]] = [t substringWithRange:[m rangeAtIndex:5]];
    }
    return d;
}

static NSDictionary *VMParseDispText(NSString *t) {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    void (^put)(NSString *, NSString *) = ^(NSString *k, NSString *v) { if (v) d[k] = v; };
    put(@"width", VMRx(t, @"display (\\d+)x"));
    put(@"height", VMRx(t, @"display \\d+x(\\d+)"));
    put(@"scanout", [VMRx(t, @"scanout (on|off)") isEqualToString:@"on"] ? @"1" : VMRx(t, @"scanout (on|off)") ? @"0" : nil);
    put(@"frames_scanned", VMRx(t, @"(\\d+) frames scanned out"));
    put(@"frames_copied", VMRx(t, @"frames scanned out, (\\d+) copied"));
    put(@"copy_avg_us", VMRx(t, @"copies: \\d+, avg (\\d+) us"));
    put(@"gpu_waits", VMRx(t, @"(\\d+) vsyncs waited for the GPU"));
    put(@"frames_forced", VMRx(t, @"(\\d+) frames shown anyway"));
    put(@"lat_swap_gpu_avg_us", VMRx(t, @"SwapEnd -> GPU done avg (\\d+)"));
    put(@"lat_chosen_screen_avg_us", VMRx(t, @"chosen -> on screen avg (\\d+)"));
    put(@"early_shown", VMRx(t, @"(\\d+) frames shown before their tick"));
    return d;
}

@interface VMStats ()
@property (nonatomic, readwrite) NSArray<NSNumber *> *coreLoad;
@property (nonatomic, readwrite) double cpuTotal, cpuUser, cpuSystem;
@property (nonatomic, readwrite) uint64_t memTotal, memFree, memActive, memInactive, memWired, memCompressed, memSpeculative,
    memPurgeable, pageSize, pageins, pageouts, compressions, decompressions, swapins, swapouts;
@property (nonatomic, readwrite) int memoryLevel;
@property (nonatomic, readwrite) NSArray<VMProcSample *> *processes;
@property (nonatomic, readwrite) BOOL gpuKernelStats;
@property (nonatomic, readwrite) NSDictionary *gpu, *disp;
@property (nonatomic, readwrite) double gpuJobsPerSecond, displayFps, driverGpuBusy, uptime, load1, load5, load15;
@property (nonatomic, readwrite) NSArray<VMDriverProc *> *driverProcs;
@end

@implementation VMStats {
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    int _holders;
    // Previous samples (queue only).
    NSArray<NSArray<NSNumber *> *> *_prevTicks;
    NSDictionary<NSNumber *, NSArray<NSNumber *> *> *_prevProcs;   // pid -> [cpu_ns, t_ns]
    uint64_t _prevProcsAt, _lastProcsAt;
    NSMutableDictionary<NSNumber *, NSDictionary *> *_prevPages;    // pid -> {t, totals, rates}
    double _prevJobs, _prevFrames, _prevLinkAt;
    NSMutableArray *_cpuH, *_memH, *_gpuLoadH, *_gpuMHzH, *_fpsH, *_cbH, *_busyH;
}

+ (instancetype)shared {
    static VMStats *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [VMStats new]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("viva.manager.stats", DISPATCH_QUEUE_SERIAL);
        _cpuH = [NSMutableArray array]; _memH = [NSMutableArray array]; _gpuLoadH = [NSMutableArray array];
        _gpuMHzH = [NSMutableArray array]; _fpsH = [NSMutableArray array]; _cbH = [NSMutableArray array];
        _busyH = [NSMutableArray array];
        _prevPages = [NSMutableDictionary dictionary];
        _coreLoad = @[]; _processes = @[]; _driverProcs = @[]; _gpu = @{}; _disp = @{};
        _memoryLevel = -1;
    }
    return self;
}

- (NSArray<NSNumber *> *)cpuHistory { return [_cpuH copy]; }
- (NSArray<NSNumber *> *)memHistory { return [_memH copy]; }
- (NSArray<NSNumber *> *)gpuLoadHistory { return [_gpuLoadH copy]; }
- (NSArray<NSNumber *> *)gpuMHzHistory { return [_gpuMHzH copy]; }
- (NSArray<NSNumber *> *)fpsHistory { return [_fpsH copy]; }
- (NSArray<NSNumber *> *)driverCbHistory { return [_cbH copy]; }
- (NSArray<NSNumber *> *)driverBusyHistory { return [_busyH copy]; }

- (void)retainSampling {
    if (_holders++ > 0) return;
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0), NSEC_PER_SEC, NSEC_PER_SEC / 20);
    __weak typeof(self) ws = self;
    dispatch_source_set_event_handler(_timer, ^{ [ws sample]; });
    dispatch_resume(_timer);
}

- (void)releaseSampling {
    if (_holders == 0 || --_holders > 0) return;
    dispatch_source_cancel(_timer);
    _timer = nil;
}

static uint64_t VMNow(void) { return clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW); }

- (void)sample {
    // ---- CPU
    natural_t ncpu = 0;
    processor_info_array_t info = NULL;
    mach_msg_type_number_t cnt = 0;
    NSMutableArray *ticks = [NSMutableArray array], *cores = [NSMutableArray array];
    double user = 0, sys = 0, total = 0;
    if (host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &ncpu, &info, &cnt) == KERN_SUCCESS) {
        processor_cpu_load_info_t l = (processor_cpu_load_info_t)info;
        for (natural_t i = 0; i < ncpu; i++) {
            NSArray *t = @[@(l[i].cpu_ticks[CPU_STATE_USER]), @(l[i].cpu_ticks[CPU_STATE_SYSTEM]),
                           @(l[i].cpu_ticks[CPU_STATE_IDLE]), @(l[i].cpu_ticks[CPU_STATE_NICE])];
            [ticks addObject:t];
            if (_prevTicks.count == ncpu) {
                NSArray *p = _prevTicks[i];
                double u = [t[0] doubleValue] - [p[0] doubleValue] + [t[3] doubleValue] - [p[3] doubleValue];
                double s = [t[1] doubleValue] - [p[1] doubleValue];
                double idle = [t[2] doubleValue] - [p[2] doubleValue];
                double all = u + s + idle;
                [cores addObject:@(all > 0 ? (u + s) / all : 0)];
                user += u; sys += s; total += all;
            }
        }
        vm_deallocate(mach_task_self(), (vm_address_t)info, cnt * sizeof(integer_t));
    }
    _prevTicks = ticks;

    // ---- RAM
    vm_statistics64_data_t vs = {0};
    mach_msg_type_number_t vcnt = HOST_VM_INFO64_COUNT;
    host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vs, &vcnt);
    vm_size_t page = 0;
    host_page_size(mach_host_self(), &page);
    uint64_t memsize = 0;
    size_t len = sizeof memsize;
    sysctlbyname("hw.memsize", &memsize, &len, NULL, 0);
    int level = -1;
    len = sizeof level;
    if (sysctlbyname("kern.memorystatus_level", &level, &len, NULL, 0) != 0) level = -1;
    struct timeval boot = {0};
    len = sizeof boot;
    sysctlbyname("kern.boottime", &boot, &len, NULL, 0);
    double loads[3] = {0};
    getloadavg(loads, 3);
    double load1 = loads[0], load5 = loads[1], load15 = loads[2];

    // ---- Processes (helper, every 2 s)
    NSArray *procs = nil;
    uint64_t now = VMNow();
    if (self.wantProcesses && now - _lastProcsAt >= 1900 * NSEC_PER_MSEC) {
        _lastProcsAt = now;
        NSString *out = nil;
        if ([VMSystem runHelper:@[@"procs"] input:nil output:&out] == 0) {
            NSMutableArray *list = [NSMutableArray array];
            NSMutableDictionary *prev = [NSMutableDictionary dictionary];
            double dt = _prevProcsAt ? (double)(now - _prevProcsAt) : 0;
            for (NSString *l in [out componentsSeparatedByString:@"\n"]) {
                NSArray *f = [l componentsSeparatedByString:@"\t"];
                if (f.count < 5) continue;
                VMProcSample *p = [VMProcSample new];
                p.pid = [f[0] intValue];
                p.name = f[1];
                uint64_t cpu = strtoull([f[2] UTF8String], NULL, 10);
                p.footprint = strtoull([f[3] UTF8String], NULL, 10);
                p.resident = strtoull([f[4] UTF8String], NULL, 10);
                NSArray *old = _prevProcs[@(p.pid)];
                if (old && dt > 0 && cpu >= [old[0] unsignedLongLongValue])
                    p.cpuPercent = (double)(cpu - [old[0] unsignedLongLongValue]) / dt * 100;
                prev[@(p.pid)] = @[@(cpu)];
                [list addObject:p];
            }
            _prevProcs = prev;
            _prevProcsAt = now;
            procs = list;
        }
    }

    // ---- GPU and display (kernel)
    int err = 0;
    NSString *g = [VMSystem link:@"gpu kv" error:&err];
    NSDictionary *gpu = nil, *disp = nil;
    BOOL kernel = g != nil;
    if (g) {
        gpu = VMParseKV(g);
        if (!gpu[@"mhz"]) gpu = VMParseGPUText([VMSystem link:@"gpu" error:NULL] ?: g);
        NSString *dk = [VMSystem link:@"disp kv" error:NULL];
        disp = dk ? VMParseKV(dk) : nil;
        if (!disp[@"frames_scanned"]) disp = VMParseDispText([VMSystem link:@"disp" error:NULL] ?: @"");
    }
    double t = now / 1e9, jobsRate = 0, fps = 0;
    if (gpu) {
        double jobs = [gpu[@"jobs"] doubleValue];
        double frames = [disp[@"frames_scanned"] doubleValue] + [disp[@"frames_copied"] doubleValue];
        if (_prevLinkAt > 0 && t > _prevLinkAt) {
            jobsRate = MAX(0, (jobs - _prevJobs) / (t - _prevLinkAt));
            fps = MAX(0, (frames - _prevFrames) / (t - _prevLinkAt));
        }
        _prevJobs = jobs; _prevFrames = frames; _prevLinkAt = t;
    }

    // ---- MaliMetal driver pages
    NSMutableArray *dprocs = [NSMutableArray array];
    double busy = 0, cbRate = 0;
    struct timespec rt;
    clock_gettime(CLOCK_REALTIME, &rt);
    uint64_t realNow = (uint64_t)rt.tv_sec * NSEC_PER_SEC + (uint64_t)rt.tv_nsec;
    NSMutableSet *seen = [NSMutableSet set];
    for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:@VMG_SHM_STATS_DIR error:nil]) {
        NSData *data = [NSData dataWithContentsOfFile:[@VMG_SHM_STATS_DIR stringByAppendingPathComponent:f]];
        if (data.length < sizeof(vmg_shm_stats)) continue;
        vmg_shm_stats s;
        memcpy(&s, data.bytes, sizeof s);
        if (s.magic != VMG_SHM_STATS_MAGIC || s.version < 1 || (s.seq & 1)) continue;
        if (kill((pid_t)s.pid, 0) != 0 && errno == ESRCH) continue;   // gone (crashed: no atexit)
        struct kinfo_proc kp;
        size_t kl = sizeof kp;
        int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, (int)s.pid};
        if (s.pid_start_us && sysctl(mib, 4, &kp, &kl, NULL, 0) == 0 && kl == sizeof kp &&
            (uint64_t)kp.kp_proc.p_starttime.tv_sec * 1000000ull + (uint64_t)kp.kp_proc.p_starttime.tv_usec != s.pid_start_us)
            continue;   // pid reused
        NSDictionary *totals = @{
            @"command_buffers": @(s.command_buffers), @"gpu_ns": @(s.gpu_ns), @"latency_ns": @(s.latency_ns),
            @"latency_max_ns": @(s.latency_max_ns), @"replay_ns": @(s.replay_ns), @"passes": @(s.passes), @"draws": @(s.draws),
            @"dispatches": @(s.dispatches), @"presents": @(s.presents), @"drawable_waits_us": @(s.drawable_waits_us),
            @"drawable_blocks": @(s.drawable_blocks), @"pipelines": @(s.pipelines), @"fallback_pipelines": @(s.fallback_pipelines),
            @"compute_rejected": @(s.compute_rejected), @"allocated_bytes": @(s.allocated_bytes),
            @"air_cache_hits": @(s.air_cache_hits), @"air_cache_misses": @(s.air_cache_misses), @"jobs": @(s.jobs)};
        NSString *isaLast = nil;
        uint32_t gpuProduct = 0;
#ifdef VMG_SHM_STATS_HAS_ISA
        // ISA compiler counters (VMG_ISA): pages from version 2 on.
        if (s.version >= 2) {
            NSMutableDictionary *t = [totals mutableCopy];
            t[@"isa_functions"] = @(s.isa_functions);
            t[@"isa_fallbacks"] = @(s.isa_fallbacks);
            t[@"isa_compile_us"] = @(s.isa_compile_us);
            totals = t;
            s.isa_last_fallback[sizeof s.isa_last_fallback - 1] = 0;
            if (s.isa_last_fallback[0]) isaLast = @(s.isa_last_fallback);
            gpuProduct = s.gpu_product_id;
        }
#endif
        NSMutableDictionary *calls = [NSMutableDictionary dictionary];
        for (unsigned i = 0; i < kCallCount && i < VMG_SHM_STATS_CALLS; i++) calls[kCallNames[i]] = @(s.calls[i]);
        NSDictionary *prev = _prevPages[@(s.pid)];
        NSDictionary *rates = prev[@"rates"] ?: @{};
        NSDictionary *callRates = prev[@"callRates"] ?: @{};
        uint64_t prevT = [prev[@"t"] unsignedLongLongValue];
        if (prev && s.updated_ns > prevT) {
            double dt = (s.updated_ns - prevT) / 1e9;
            NSMutableDictionary *r = [NSMutableDictionary dictionary], *cr = [NSMutableDictionary dictionary];
            NSDictionary *pt = prev[@"totals"], *pc = prev[@"calls"];
            for (NSString *k in totals) r[k] = @(MAX(0, ([totals[k] doubleValue] - [pt[k] doubleValue]) / dt));
            for (NSString *k in calls) cr[k] = @(MAX(0, ([calls[k] doubleValue] - [pc[k] doubleValue]) / dt));
            rates = r;
            callRates = cr;
        } else if (prev && realNow > s.updated_ns + 2500 * NSEC_PER_MSEC) {
            rates = @{};   // idle: the page is only updated while command buffers complete
            callRates = @{};
        }
        if (!prev || s.updated_ns > prevT)
            _prevPages[@(s.pid)] = @{@"t": @(s.updated_ns), @"totals": totals, @"calls": calls, @"rates": rates, @"callRates": callRates};
        else
            _prevPages[@(s.pid)] = @{@"t": prev[@"t"], @"totals": prev[@"totals"], @"calls": prev[@"calls"], @"rates": rates, @"callRates": callRates};
        [seen addObject:@(s.pid)];
        VMDriverProc *p = [VMDriverProc new];
        p.pid = (int)s.pid;
        s.process[sizeof s.process - 1] = 0;
        s.driver_build[sizeof s.driver_build - 1] = 0;
        p.name = @(s.process);
        p.build = @(s.driver_build);
        p.ageSeconds = realNow > s.updated_ns ? (realNow - s.updated_ns) / 1e9 : 0;
        p.totals = totals;
        p.rates = rates;
        p.isaLastFallback = isaLast;
        p.gpuProductId = gpuProduct;
        NSMutableArray *cl = [NSMutableArray array];
        for (unsigned i = 0; i < kCallCount; i++) {
            NSString *n = kCallNames[i];
            if ([calls[n] unsignedLongLongValue] == 0) continue;
            [cl addObject:@{@"name": n, @"total": calls[n], @"rate": callRates[n] ?: @0}];
        }
        p.calls = cl;
        [dprocs addObject:p];
        busy += [rates[@"gpu_ns"] doubleValue] / 1e9;
        cbRate += [rates[@"command_buffers"] doubleValue];
    }
    for (NSNumber *pid in _prevPages.allKeys) if (![seen containsObject:pid]) [_prevPages removeObjectForKey:pid];
    [dprocs sortUsingComparator:^NSComparisonResult(VMDriverProc *a, VMDriverProc *b) {
        double x = [a.rates[@"command_buffers"] doubleValue], y = [b.rates[@"command_buffers"] doubleValue];
        if (x != y) return x > y ? NSOrderedAscending : NSOrderedDescending;
        return [a.name compare:b.name];
    }];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (cores.count) {
            self.coreLoad = cores;
            self.cpuTotal = total > 0 ? (user + sys) / total : 0;
            self.cpuUser = total > 0 ? user / total : 0;
            self.cpuSystem = total > 0 ? sys / total : 0;
            VMPush(self->_cpuH, self.cpuTotal * 100);
        }
        self.pageSize = page;
        self.memTotal = memsize;
        self.memFree = (uint64_t)vs.free_count * page;
        self.memActive = (uint64_t)vs.active_count * page;
        self.memInactive = (uint64_t)vs.inactive_count * page;
        self.memWired = (uint64_t)vs.wire_count * page;
        self.memCompressed = (uint64_t)vs.compressor_page_count * page;
        self.memSpeculative = (uint64_t)vs.speculative_count * page;
        self.memPurgeable = (uint64_t)vs.purgeable_count * page;
        self.pageins = vs.pageins; self.pageouts = vs.pageouts;
        self.compressions = vs.compressions; self.decompressions = vs.decompressions;
        self.swapins = vs.swapins; self.swapouts = vs.swapouts;
        self.memoryLevel = level;
        if (memsize) VMPush(self->_memH, 100.0 * (self.memActive + self.memWired + self.memCompressed) / memsize);
        self.uptime = boot.tv_sec ? [NSDate date].timeIntervalSince1970 - boot.tv_sec : 0;
        self.load1 = load1; self.load5 = load5; self.load15 = load15;
        if (procs) self.processes = procs;
        self.gpuKernelStats = kernel;
        if (kernel) {
            self.gpu = gpu ?: @{};
            self.disp = disp ?: @{};
            self.gpuJobsPerSecond = jobsRate;
            self.displayFps = fps;
            VMPush(self->_gpuLoadH, [gpu[@"load_pct"] doubleValue]);
            VMPush(self->_gpuMHzH, [gpu[@"mhz"] doubleValue]);
            VMPush(self->_fpsH, fps);
        }
        self.driverProcs = dprocs;
        self.driverGpuBusy = MIN(busy, 1);
        VMPush(self->_cbH, cbRate);
        VMPush(self->_busyH, MIN(busy, 1) * 100);
        [NSNotificationCenter.defaultCenter postNotificationName:VMStatsDidUpdateNotification object:self];
    });
}

@end
