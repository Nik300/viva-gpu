// Per-process driver statistics for Viva Manager (app/): every process that opens the Metal driver keeps one page in
// VMG_SHM_STATS_DIR/<pid> (MAP_SHARED, mode 0666), updated at most once per second from command buffer completion.
// No timers: an idle process leaves its last values (updated_ns tells how old they are). Readers check that the pid
// is still alive (kill(pid, 0) != ESRCH) and that pid_start matches (pids are reused). VMG_NO_SHM_STATS=1: off.
// Layout changes bump VMG_SHM_STATS_VERSION; fields are only appended.
#ifndef VMG_SHM_STATS_H
#define VMG_SHM_STATS_H
#include <stdint.h>

#define VMG_SHM_STATS_DIR     "/private/var/tmp/vmg-stats"
#define VMG_SHM_STATS_MAGIC   0x534d4756u   // 'VGMS'
#define VMG_SHM_STATS_VERSION 1
#define VMG_SHM_STATS_CALLS   32            // >= VGPU_SEL_COUNT (uapi selectors, by index)

typedef struct {
    uint32_t magic, version, size, pid;
    uint64_t pid_start_us;          // process start (kinfo_proc p_starttime, in us): detects pid reuse
    char     process[64];           // getprogname()
    char     driver_build[48];      // translation cache id (driver build)
    uint64_t updated_ns;            // CLOCK_REALTIME of the last update
    uint64_t seq;                   // incremented after every update (odd while writing)

    // Command buffers, completed: totals since the process started.
    uint64_t command_buffers;
    uint64_t gpu_ns;                // flush -> completion, summed (time the GPU worked on our command buffers)
    uint64_t latency_ns;            // commit -> completion, summed
    uint64_t latency_max_ns;        // worst since the previous update
    uint64_t replay_ns;             // replay + flush on the GPU queue (CPU side)

    // Encoders (counted while stats are on: always, unless VMG_NO_SHM_STATS).
    uint64_t passes, draws, dispatches, presents, drawable_waits_us, drawable_blocks;
    uint64_t pipelines, fallback_pipelines, compute_rejected;

    // Memory and caches.
    int64_t  allocated_bytes;       // Metal resources of every device of the process
    uint64_t air_cache_hits, air_cache_misses;

    // Kernel (vgpu) calls by uapi selector, and GPU jobs submitted.
    uint64_t jobs;
    uint64_t calls[VMG_SHM_STATS_CALLS];
} vmg_shm_stats;

#endif
