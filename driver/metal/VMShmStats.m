// Statistics page for Viva Manager (app/): one page per process in VMG_SHM_STATS_DIR/<pid>, layout in
// ../vmg_shm_stats.h. Counters that already exist (gTSMtlStats, vgpu calls, AIR cache) are copied in at most once per
// second, from command buffer completion; command buffer times are summed here. No timer: an idle process costs nothing.
// On the Mac only with VMG_SHM_STATS=1 (tests).
#import "VMPrivate.h"
#include "../vmg_shm_stats.h"
#include "../vmg.h"
#include "../../vgpu/vgpu.h"
#include <fcntl.h>
#include <sys/sysctl.h>
#include <TargetConditionals.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static vmg_shm_stats *g_page;
static _Atomic uint64_t g_cbs, g_gpu, g_latency, g_latency_max, g_replay;   // mach_absolute_time units
static _Atomic uint64_t g_next_update;                                       // mach_absolute_time
static pthread_mutex_t g_update_lock = PTHREAD_MUTEX_INITIALIZER;
static mach_timebase_info_data_t g_tb;

static uint64_t VMAbsToNs(uint64_t t) { return t * g_tb.numer / g_tb.denom; }

static void VMShmStatsUnlink(void) {
    char path[128];
    snprintf(path, sizeof path, VMG_SHM_STATS_DIR "/%d", getpid());
    unlink(path);
}

void VMShmStatsInit(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        if (getenv("VMG_NO_SHM_STATS")) return;
#if !TARGET_OS_IPHONE
        if (!getenv("VMG_SHM_STATS")) return;   // Mac tests: only on request
#endif
        mach_timebase_info(&g_tb);
        // Sticky and world-writable like /tmp: backboardd (mobile), root daemons and apps all create their page here.
        mode_t old = umask(0);
        mkdir(VMG_SHM_STATS_DIR, 01777);
        char path[128];
        snprintf(path, sizeof path, VMG_SHM_STATS_DIR "/%d", getpid());
        unlink(path);   // a page left by an earlier process with the same pid (owned by someone else: open fails)
        int fd = open(path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
        umask(old);
        if (fd < 0) return;
        size_t size = (sizeof(vmg_shm_stats) + 4095) & ~(size_t)4095;
        if (ftruncate(fd, (off_t)size) != 0) { close(fd); unlink(path); return; }
        void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
        close(fd);
        if (p == MAP_FAILED) { unlink(path); return; }
        vmg_shm_stats *s = p;
        s->version = VMG_SHM_STATS_VERSION;
        s->size = sizeof *s;
        s->pid = (uint32_t)getpid();
        struct kinfo_proc kp;
        size_t len = sizeof kp;
        int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
        if (sysctl(mib, 4, &kp, &len, NULL, 0) == 0 && len == sizeof kp)
            s->pid_start_us = (uint64_t)kp.kp_proc.p_starttime.tv_sec * 1000000ull + (uint64_t)kp.kp_proc.p_starttime.tv_usec;
        strlcpy(s->process, getprogname(), sizeof s->process);
        strlcpy(s->driver_build, vmg_driver_build_id(), sizeof s->driver_build);
        s->updated_ns = clock_gettime_nsec_np(CLOCK_REALTIME);
        __atomic_store_n(&s->magic, VMG_SHM_STATS_MAGIC, __ATOMIC_RELEASE);
        g_page = s;
        gTSMtlStatsOn |= TSStatsByLease;   // draws, passes, ... are counted from now on
        atexit(VMShmStatsUnlink);
    });
}

static void VMShmStatsUpdate(void) {
    vmg_shm_stats *s = g_page;
    __atomic_store_n(&s->seq, s->seq + 1, __ATOMIC_RELEASE);   // odd: being written
    s->command_buffers = atomic_load_explicit(&g_cbs, memory_order_relaxed);
    s->gpu_ns = VMAbsToNs(atomic_load_explicit(&g_gpu, memory_order_relaxed));
    s->latency_ns = VMAbsToNs(atomic_load_explicit(&g_latency, memory_order_relaxed));
    s->latency_max_ns = VMAbsToNs(atomic_exchange_explicit(&g_latency_max, 0, memory_order_relaxed));
    s->replay_ns = VMAbsToNs(atomic_load_explicit(&g_replay, memory_order_relaxed));
#define STAT(x) atomic_load_explicit(&gTSMtlStats[x], memory_order_relaxed)
    s->passes = STAT(TSStatPasses);
    s->draws = STAT(TSStatDraws);
    s->dispatches = STAT(TSStatDispatches);
    s->presents = STAT(TSStatPresents);
    s->drawable_waits_us = STAT(TSStatDrawableWaitMicros);
    s->drawable_blocks = STAT(TSStatDrawableBlocks);
    s->pipelines = STAT(TSStatPipelines);
    s->fallback_pipelines = STAT(TSStatFallbacks);
    s->compute_rejected = STAT(TSStatComputeRejected);
#undef STAT
    s->allocated_bytes = atomic_load_explicit(&gTSMtlAllocatedBytes, memory_order_relaxed);
    vmg_air_cache_stats(&s->air_cache_hits, &s->air_cache_misses);
    vmg_isa_counters(&s->isa_functions, &s->isa_fallbacks, &s->isa_compile_us, s->isa_last_fallback, sizeof s->isa_last_fallback);
    s->gpu_product_id = vmg_gpu_product_id();
    vmg_bounds_counters(&s->bounded_draws, &s->bounded_kpx, &s->clear_draws);
    uint64_t calls[VGPU_SEL_COUNT];
    vgpu_counters(calls, &s->jobs);
    for (unsigned i = 0; i < VGPU_SEL_COUNT && i < VMG_SHM_STATS_CALLS; i++) s->calls[i] = calls[i];
    if (strcmp(s->driver_build, "unknown") == 0) strlcpy(s->driver_build, vmg_driver_build_id(), sizeof s->driver_build);
    s->updated_ns = clock_gettime_nsec_np(CLOCK_REALTIME);
    __atomic_store_n(&s->seq, s->seq + 1, __ATOMIC_RELEASE);   // even: consistent
}

void VMShmStatsCommandBuffer(uint64_t commit, uint64_t start, uint64_t flushed, uint64_t done) {
    if (!g_page) return;
    atomic_fetch_add_explicit(&g_cbs, 1, memory_order_relaxed);
    if (flushed && done > flushed) atomic_fetch_add_explicit(&g_gpu, done - flushed, memory_order_relaxed);
    if (flushed > start) atomic_fetch_add_explicit(&g_replay, flushed - start, memory_order_relaxed);
    if (commit && done > commit) {
        uint64_t l = done - commit;
        atomic_fetch_add_explicit(&g_latency, l, memory_order_relaxed);
        uint64_t m = atomic_load_explicit(&g_latency_max, memory_order_relaxed);
        while (l > m && !atomic_compare_exchange_weak_explicit(&g_latency_max, &m, l, memory_order_relaxed, memory_order_relaxed)) {}
    }
    uint64_t next = atomic_load_explicit(&g_next_update, memory_order_relaxed);
    if (done < next || pthread_mutex_trylock(&g_update_lock) != 0) return;
    atomic_store_explicit(&g_next_update, done + NSEC_PER_SEC * g_tb.denom / g_tb.numer, memory_order_relaxed);
    VMShmStatsUpdate();
    pthread_mutex_unlock(&g_update_lock);
}
