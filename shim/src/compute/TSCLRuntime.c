// TeraScale Compute - OpenCL runtime: share-group context, GL object cache, one submission per compute run.
// See TSCLRuntime.h for the measurements behind the design.
#include "TSCLRuntime.h"
#include "TSCLApi.h"
#include <dispatch/dispatch.h>
#include <stdatomic.h>
#include <mach/mach_time.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    GLuint name;
    GLenum target;
    GLint level;
    cl_mem mem;
    uint64_t acquiredRun;   // run that acquired it; == rt->run while the run is open
} TSCLEntry;

struct TSCLRuntime {
    TSCLRuntimeConfig config;
    cl_context context;
    cl_device_id device;
    cl_command_queue queue;
    // GL objects wrapped so far, found through an open-addressing table of entry indices + 1 (C2: apps with
    // many buffers made the linear scan grow with every dispatch).
    TSCLEntry *entries;
    size_t entryCount, entryCapacity;
    uint32_t *slots;
    size_t slotCount;   // power of two, > 2 * entryCount
    bool levels;        // some entry wraps a mip level other than 0 (Forget must scan)
    uint64_t generation;
    // Current run: open between the first dispatch and the next GL command.
    bool inRun;
    uint64_t run;
    cl_mem *acquired;
    cl_uint acquiredCount, acquiredCapacity;
    cl_event runEvent;      // completes after the last ended run (asynchronous ends: from the join on)
    // Asynchronous end of run: the release (the submission) runs on `submitter` while the GPU queue goes on
    // encoding GL; TSCLRuntimeWaitSubmitted joins it before the GPU queue flushes GL.
    dispatch_queue_t submitter;
    dispatch_group_t submitting;
    bool submitPending;
    uint64_t asyncMicros;   // written by the submitter, read after the join
    cl_int asyncError;
    cl_event asyncEvent;    // the asynchronous end's run event, written by the submitter, moved to runEvent at the join
    TSCLStats stats;
    _Atomic uint64_t gpuNanos;   // profiling callbacks run on CL threads
};

static void TSCLLog(TSCLRuntime *rt, TSCLLogLevel level, const char *fmt, ...) {
    if (!rt->config.log) return;
    char msg[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof msg, fmt, ap);
    va_end(ap);
    rt->config.log(rt->config.logContext, level, msg);
}

static uint64_t TSCLMicros(void) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    return mach_absolute_time() * tb.numer / tb.denom / 1000;
}

TSCLRuntime *TSCLRuntimeCreate(const TSCLRuntimeConfig *config) {
    TSCLRuntime *rt = calloc(1, sizeof *rt);
    if (!rt) return NULL;
    rt->config = *config;
    rt->submitter = dispatch_queue_create("com.terascale.mtlshim.compute.submit", DISPATCH_QUEUE_SERIAL);
    rt->submitting = dispatch_group_create();
    cl_context_properties props[] = { CL_CONTEXT_PROPERTY_USE_CGL_SHAREGROUP_APPLE, (cl_context_properties)config->shareGroup, 0 };
    cl_int err;
    rt->context = clCreateContext(props, 0, NULL, NULL, NULL, &err);
    if (!rt->context) {
        TSCLLog(rt, TSCLLogError, "clCreateContext on the CGL share group failed: %d", err);
        free(rt);
        return NULL;
    }
    // The share group holds the GPU behind the core's GL context (only that one on this Mac); prefer a GPU anyway.
    cl_device_id devices[8];
    size_t size = 0;
    clGetContextInfo(rt->context, CL_CONTEXT_DEVICES, sizeof devices, devices, &size);
    for (size_t i = 0; i < size / sizeof(cl_device_id); i++) {
        cl_device_type type = 0;
        clGetDeviceInfo(devices[i], CL_DEVICE_TYPE, sizeof type, &type, NULL);
        if (!rt->device || (type & CL_DEVICE_TYPE_GPU)) rt->device = devices[i];
    }
    rt->queue = rt->device ? clCreateCommandQueue(rt->context, rt->device, config->profiling ? CL_QUEUE_PROFILING_ENABLE : 0, &err) : NULL;
    if (!rt->queue) {
        TSCLLog(rt, TSCLLogError, "no CL queue on the share group (%zu devices): %d", size / sizeof(cl_device_id), err);
        clReleaseContext(rt->context);
        free(rt);
        return NULL;
    }
    return rt;
}

void TSCLRuntimeDestroy(TSCLRuntime *rt) {
    if (!rt) return;
    TSCLRuntimeEndRun(rt);
    TSCLRuntimeWaitSubmitted(rt);
    clFinish(rt->queue);
    if (rt->runEvent) clReleaseEvent(rt->runEvent);
    for (size_t i = 0; i < rt->entryCount; i++) clReleaseMemObject(rt->entries[i].mem);
    free(rt->entries);
    free(rt->slots);
    free(rt->acquired);
    dispatch_release(rt->submitting);
    dispatch_release(rt->submitter);
    clReleaseCommandQueue(rt->queue);
    clReleaseContext(rt->context);
    free(rt);
}

cl_context TSCLRuntimeContext(TSCLRuntime *rt) { return rt->context; }
cl_device_id TSCLRuntimeDevice(TSCLRuntime *rt) { return rt->device; }
cl_command_queue TSCLRuntimeQueue(TSCLRuntime *rt) { return rt->queue; }
bool TSCLRuntimeInRun(const TSCLRuntime *rt) { return rt->inRun; }
TSCLStats TSCLRuntimeGetStats(const TSCLRuntime *rt) {
    TSCLStats s = rt->stats;
    s.gpuNanos = atomic_load_explicit(&((TSCLRuntime *)rt)->gpuNanos, memory_order_relaxed);
    return s;
}
bool TSCLRuntimeProfiling(const TSCLRuntime *rt) { return rt->config.profiling; }
uint64_t TSCLRuntimeGeneration(const TSCLRuntime *rt) { return rt->generation; }

// GL -> CL: the acquire needs the GL commands issued so far submitted first. Flushing here only moves the
// flush the command buffer would do anyway, and costs ~0.003 ms when nothing is pending.
static void TSCLOpenRun(TSCLRuntime *rt) {
    if (rt->inRun) return;
    TSCLRuntimeWaitSubmitted(rt);   // the previous run's release must be enqueued before this run's acquire
    glFlush();
    rt->inRun = true;
    rt->run++;
}

static size_t TSCLHash(GLuint name, GLenum target, GLint level) {
    uint64_t h = ((uint64_t)name << 32 | (uint64_t)target << 4 | (uint64_t)level) * 0x9E3779B97F4A7C15ull;
    return (size_t)(h >> 32);
}

static void TSCLSlotInsert(TSCLRuntime *rt, size_t index) {
    const TSCLEntry *e = &rt->entries[index];
    size_t mask = rt->slotCount - 1;
    for (size_t i = TSCLHash(e->name, e->target, e->level) & mask;; i = (i + 1) & mask)
        if (!rt->slots[i]) { rt->slots[i] = (uint32_t)index + 1; return; }
}

// Rebuilds the table for the current entries (after a removal, or to grow). false: out of memory (lookups
// then fall back to the scan).
static bool TSCLRehash(TSCLRuntime *rt) {
    size_t want = 64;
    while (want <= rt->entryCount * 2 + 2) want *= 2;
    if (want != rt->slotCount) {
        uint32_t *slots = calloc(want, sizeof *slots);
        if (!slots) { free(rt->slots); rt->slots = NULL; rt->slotCount = 0; return false; }
        free(rt->slots);
        rt->slots = slots;
        rt->slotCount = want;
    } else {
        memset(rt->slots, 0, want * sizeof *rt->slots);
    }
    for (size_t i = 0; i < rt->entryCount; i++) TSCLSlotInsert(rt, i);
    return true;
}

static TSCLEntry *TSCLLookup(TSCLRuntime *rt, const TSCLGLObject *o) {
    if (!rt->slots) {
        for (size_t i = 0; i < rt->entryCount; i++) {
            TSCLEntry *e = &rt->entries[i];
            if (e->name == o->name && e->target == o->target && e->level == o->level) return e;
        }
        return NULL;
    }
    size_t mask = rt->slotCount - 1;
    for (size_t i = TSCLHash(o->name, o->target, o->level) & mask; rt->slots[i]; i = (i + 1) & mask) {
        TSCLEntry *e = &rt->entries[rt->slots[i] - 1];
        if (e->name == o->name && e->target == o->target && e->level == o->level) return e;
    }
    return NULL;
}

static TSCLEntry *TSCLEntryFor(TSCLRuntime *rt, const TSCLGLObject *o, cl_int *err) {
    TSCLEntry *hit = TSCLLookup(rt, o);
    if (hit) return hit;
    // One cl_mem per GL object, read-write: CL 1.2 lets it be passed as a read_only or write_only image too.
    cl_mem mem = o->target ? clCreateFromGLTexture(rt->context, CL_MEM_READ_WRITE, o->target, o->level, o->name, err)
                           : clCreateFromGLBuffer(rt->context, CL_MEM_READ_WRITE, o->name, err);
    if (!mem) {
        TSCLLog(rt, TSCLLogError, "clCreateFromGL%s(name %u target 0x%x level %d) failed: %d", o->target ? "Texture" : "Buffer",
                o->name, o->target, o->level, *err);
        return NULL;
    }
    rt->stats.wraps++;
    if (rt->entryCount == rt->entryCapacity) {
        size_t cap = rt->entryCapacity ? rt->entryCapacity * 2 : 32;
        TSCLEntry *grown = realloc(rt->entries, cap * sizeof *grown);
        if (!grown) { clReleaseMemObject(mem); *err = CL_OUT_OF_HOST_MEMORY; return NULL; }
        rt->entries = grown;
        rt->entryCapacity = cap;
    }
    size_t index = rt->entryCount++;
    TSCLEntry *e = &rt->entries[index];
    *e = (TSCLEntry){ o->name, o->target, o->level, mem, 0 };
    if (o->level) rt->levels = true;
    if (rt->slotCount <= rt->entryCount * 2 + 2) TSCLRehash(rt);
    else TSCLSlotInsert(rt, index);
    return e;
}

cl_int TSCLRuntimeUse(TSCLRuntime *rt, const TSCLGLObject *objects, cl_uint count, cl_mem *out) {
    TSCLOpenRun(rt);
    cl_uint first = rt->acquiredCount;
    for (cl_uint i = 0; i < count; i++) {
        cl_int err = CL_SUCCESS;
        TSCLEntry *e = TSCLEntryFor(rt, &objects[i], &err);
        if (!e) { rt->stats.errors++; return err; }
        out[i] = e->mem;
        if (e->acquiredRun == rt->run) continue;
        if (rt->acquiredCount == rt->acquiredCapacity) {
            cl_uint cap = rt->acquiredCapacity ? rt->acquiredCapacity * 2 : 32;
            cl_mem *grown = realloc(rt->acquired, cap * sizeof *grown);
            if (!grown) { rt->stats.errors++; return CL_OUT_OF_HOST_MEMORY; }
            rt->acquired = grown;
            rt->acquiredCapacity = cap;
        }
        rt->acquired[rt->acquiredCount++] = e->mem;
        e->acquiredRun = rt->run;
    }
    // Acquiring incrementally costs the same as acquiring the whole run up front (clcost.m): nothing is submitted.
    if (rt->acquiredCount > first) {
        cl_int err = clEnqueueAcquireGLObjects(rt->queue, rt->acquiredCount - first, rt->acquired + first, 0, NULL, NULL);
        if (err != CL_SUCCESS) {
            TSCLLog(rt, TSCLLogError, "clEnqueueAcquireGLObjects(%u objects) failed: %d", rt->acquiredCount - first, err);
            rt->stats.errors++;
            // Not acquired: keep them out of the release.
            for (cl_uint i = first; i < rt->acquiredCount; i++)
                for (size_t j = 0; j < rt->entryCount; j++)
                    if (rt->entries[j].mem == rt->acquired[i]) rt->entries[j].acquiredRun = 0;
            rt->acquiredCount = first;
            return err;
        }
        rt->stats.acquires += rt->acquiredCount - first;
    }
    return CL_SUCCESS;
}

typedef struct {
    TSCLRuntime *rt;
    void (*done)(void *, uint64_t);
    void *ctx;
} TSCLTimed;

// CL thread: the kernel's event completed.
static void TSCLTimedDone(cl_event ev, cl_int status, void *p) {
    TSCLTimed *t = p;
    cl_ulong start = 0, end = 0;
    uint64_t nanos = 0;
    if (status == CL_COMPLETE && clGetEventProfilingInfo(ev, CL_PROFILING_COMMAND_START, sizeof start, &start, NULL) == CL_SUCCESS &&
        clGetEventProfilingInfo(ev, CL_PROFILING_COMMAND_END, sizeof end, &end, NULL) == CL_SUCCESS && end > start)
        nanos = end - start;
    atomic_fetch_add_explicit(&t->rt->gpuNanos, nanos, memory_order_relaxed);
    if (t->done) t->done(t->ctx, nanos);   // always called, so ctx can own a reference
    clReleaseEvent(ev);
    free(t);
}

cl_int TSCLRuntimeDispatch(TSCLRuntime *rt, cl_kernel kernel, cl_uint dims, const size_t *offset,
                           const size_t *global, const size_t *local) {
    return TSCLRuntimeDispatchTimed(rt, kernel, dims, offset, global, local, NULL, NULL);
}

cl_int TSCLRuntimeDispatchTimed(TSCLRuntime *rt, cl_kernel kernel, cl_uint dims, const size_t *offset, const size_t *global,
                                const size_t *local, void (*done)(void *ctx, uint64_t gpuNanos), void *ctx) {
    TSCLOpenRun(rt);
    // Events only while someone measures: each one is a driver object and a callback.
    cl_event ev = NULL;
    cl_int err = clEnqueueNDRangeKernel(rt->queue, kernel, dims, offset, global, local, 0, NULL, rt->config.profiling && done ? &ev : NULL);
    if (ev) {
        TSCLTimed *t = malloc(sizeof *t);
        if (t) *t = (TSCLTimed){ rt, done, ctx };
        if (!t || clSetEventCallback(ev, CL_COMPLETE, TSCLTimedDone, t) != CL_SUCCESS) { free(t); clReleaseEvent(ev); ev = NULL; }
    }
    if (!ev && done && err == CL_SUCCESS) done(ctx, 0);
    if (err != CL_SUCCESS) {
        TSCLLog(rt, TSCLLogError, "clEnqueueNDRangeKernel(%u dims, %zu x %zu x %zu) failed: %d", dims, global[0],
                dims > 1 ? global[1] : 1, dims > 2 ? global[2] : 1, err);
        rt->stats.errors++;
        return err;
    }
    rt->stats.dispatches++;
    return CL_SUCCESS;
}

// CL -> GL: the release is the run's only submission. GL commands issued after it (the next pass, the command
// buffer's completion fence) execute after the kernels on the GPU, so nothing waits here.
// How the end of a run gets an event that completes after its kernels (TSCL_FLUSH_MODE, A/B):
//   0 "release" (default): the release returns the event, then clFlush. Without a flush a run can stay
//     CL_SUBMITTED for good (scratchpad probe, 2026-11-02);
//   1 "marker": plain release, a marker returns the event, then clFlush;
//   2 "deferred": plain release and marker, no flush here; whoever waits for the event flushes the queue from
//     another thread (TSCLRuntimeKickEvent).
// Measured (tests/compute/dispatchbench.m, 1000-dispatch runs): the release itself flushes and waits for the
// driver's queue, i.e. for the previous run, in all three modes (0 and 2: ~21 ms per ~12 ms-GPU run, 1: worse),
// and so did 0.6.0 (5-20 ms per run). Backpressure when CL is GPU-bound; moving the release off the GPU queue
// (TSCLRuntimeEndRunAsync) is the lever left.
static int TSCLFlushMode(void) {
    static int mode = -1;
    if (mode < 0) mode = getenv("TSCL_FLUSH_MODE") ? atoi(getenv("TSCL_FLUSH_MODE")) : 0;
    return mode;
}

static cl_int TSCLSubmit(TSCLRuntime *rt, cl_mem *objects, cl_uint count, cl_event *done) {
    cl_int err = CL_SUCCESS;
    int mode = done ? TSCLFlushMode() : 1;
    if (count) {
        err = clEnqueueReleaseGLObjects(rt->queue, count, objects, 0, NULL, mode == 0 ? done : NULL);
        if (err != CL_SUCCESS) TSCLLog(rt, TSCLLogError, "clEnqueueReleaseGLObjects(%u objects) failed: %d", count, err);
    }
    if (done && (mode != 0 || !count)) clEnqueueMarkerWithWaitList(rt->queue, 0, NULL, done);   // in order: after the run
    if (mode != 2 || !done) clFlush(rt->queue);
    return err;
}

void TSCLRuntimeKickEvent(cl_event event) {
    static _Atomic bool kicking;
    cl_command_queue q = NULL;
    if (TSCLFlushMode() != 2 || atomic_exchange(&kicking, true)) return;   // one flush in flight is enough: it covers every earlier command
    if (clGetEventInfo(event, CL_EVENT_COMMAND_QUEUE, sizeof q, &q, NULL) != CL_SUCCESS || !q) { atomic_store(&kicking, false); return; }
    clRetainCommandQueue(q);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        clFlush(q);
        clReleaseCommandQueue(q);
        atomic_store(&kicking, false);
    });
}

void TSCLRuntimeEndRun(TSCLRuntime *rt) {
    if (!rt->inRun) return;
    uint64_t start = TSCLMicros();
    cl_event done = NULL;
    if (TSCLSubmit(rt, rt->acquired, rt->acquiredCount, &done) != CL_SUCCESS) rt->stats.errors++;
    if (done) {
        if (rt->runEvent) clReleaseEvent(rt->runEvent);   // the queue is in order: the newer event implies the older
        rt->runEvent = done;
    }
    rt->acquiredCount = 0;
    rt->inRun = false;
    rt->stats.runs++;
    rt->stats.submitMicros += TSCLMicros() - start;
}

void TSCLRuntimeEndRunAsync(TSCLRuntime *rt) {
    if (!rt->inRun) return;
    TSCLRuntimeWaitSubmitted(rt);
    cl_uint count = rt->acquiredCount;
    cl_mem *objects = count ? malloc(count * sizeof *objects) : NULL;
    if (count && !objects) { TSCLRuntimeEndRun(rt); return; }
    if (count) memcpy(objects, rt->acquired, count * sizeof *objects);
    rt->acquiredCount = 0;
    rt->inRun = false;
    rt->stats.runs++;
    rt->submitPending = true;
    dispatch_group_async(rt->submitting, rt->submitter, ^{
        uint64_t start = TSCLMicros();
        cl_event done = NULL;
        rt->asyncError = TSCLSubmit(rt, objects, count, &done);
        rt->asyncEvent = done;
        rt->asyncMicros = TSCLMicros() - start;
        free(objects);
    });
}

cl_event TSCLRuntimeTakeRunEvent(TSCLRuntime *rt) {
    cl_event e = rt->runEvent;
    rt->runEvent = NULL;
    return e;
}

void TSCLRuntimeWaitSubmitted(TSCLRuntime *rt) {
    if (!rt->submitPending) return;
    uint64_t start = TSCLMicros();
    dispatch_group_wait(rt->submitting, DISPATCH_TIME_FOREVER);
    rt->submitPending = false;
    if (rt->asyncEvent) {
        if (rt->runEvent) clReleaseEvent(rt->runEvent);   // in order: the newer event implies the older
        rt->runEvent = rt->asyncEvent;
        rt->asyncEvent = NULL;
    }
    rt->stats.submitMicros += rt->asyncMicros;
    rt->stats.blockedMicros += TSCLMicros() - start;
    if (rt->asyncError != CL_SUCCESS) rt->stats.errors++;
}

static void TSCLRemove(TSCLRuntime *rt, size_t i) {
    TSCLEntry *e = &rt->entries[i];
    if (rt->inRun && e->acquiredRun == rt->run) TSCLRuntimeEndRun(rt);
    clReleaseMemObject(e->mem);
    rt->entries[i] = rt->entries[--rt->entryCount];
}

// Called before every re-specification of any GL object while OpenCL is active, most of which compute never
// wrapped: the common case (level 0) is one table lookup.
void TSCLRuntimeForget(TSCLRuntime *rt, GLuint name, GLenum target) {
    if (!rt->entryCount) return;
    TSCLRuntimeWaitSubmitted(rt);   // a pending release may still name the object
    bool removed = false;
    if (rt->slots && !rt->levels) {
        TSCLGLObject o = { name, target, 0 };
        TSCLEntry *e = TSCLLookup(rt, &o);
        if (e) { TSCLRemove(rt, (size_t)(e - rt->entries)); removed = true; }
    } else {
        for (size_t i = 0; i < rt->entryCount;) {
            TSCLEntry *e = &rt->entries[i];
            if (e->name != name || e->target != target) { i++; continue; }
            TSCLRemove(rt, i);
            removed = true;
        }
    }
    if (removed) {
        rt->generation++;
        if (rt->slots) TSCLRehash(rt);
    }
}
