// TeraScale Compute - OpenCL runtime of the compute extension: CL context on the core's CGL share group,
// GL object wrapping and the GL <-> CL handoff (docs/PIANO-COMPUTE.md, "Passaggio GL<->CL").
//
// Measured on the HD 6750M (tests/compute/clcost.m, roundtrip.m): every CL submission costs the issuing thread
// ~0.15-0.25 ms whatever it carries, clEnqueueReleaseGLObjects is itself a submission and never waits for
// the kernel, and GL commands issued after it run after the CL work on the GPU (one command stream). So:
//   - consecutive dispatches form one *run*: GL objects are acquired as dispatches need them and all
//     released together when the run ends, i.e. one submission per run instead of one per dispatch;
//   - the run ends right before the next GL command (render, blit, upload) or the command buffer's GL fence;
//   - nobody waits for CL: the core's completion fence (B2), issued after the run, signals after the kernels.
// Not thread-safe: every call happens on the core's GPU queue, with the core's GL context current.
#pragma once
#ifndef CL_SILENCE_DEPRECATION
#define CL_SILENCE_DEPRECATION 1
#endif
#ifndef GL_SILENCE_DEPRECATION
#define GL_SILENCE_DEPRECATION 1
#endif
#include <OpenCL/opencl.h>
#include <OpenGL/OpenGL.h>
#include <OpenGL/gl3.h>
#include <stdbool.h>
#include <stdint.h>

typedef struct TSCLRuntime TSCLRuntime;

typedef enum { TSCLLogError, TSCLLogDefault, TSCLLogInfo } TSCLLogLevel;

typedef struct {
    CGLShareGroupObj shareGroup;   // the core's GL context share group
    void (*log)(void *ctx, TSCLLogLevel level, const char *message);   // optional
    void *logContext;
    bool profiling;                // queue with CL_QUEUE_PROFILING_ENABLE: TSCLRuntimeDispatchTimed reports GPU time
} TSCLRuntimeConfig;

// A GL object as the core owns it. Textures: target GL_TEXTURE_2D, GL_TEXTURE_RECTANGLE (IOSurface),
// GL_TEXTURE_2D_ARRAY, GL_TEXTURE_3D, ...; buffers: target 0.
typedef struct {
    GLuint name;
    GLenum target;
    GLint level;
} TSCLGLObject;

typedef struct {
    uint64_t runs;            // = CL submissions
    uint64_t dispatches;
    uint64_t acquires;        // GL objects acquired (each once per run)
    uint64_t wraps;           // clCreateFromGL* calls (cache misses)
    uint64_t submitMicros;    // CPU time spent in the submissions (on the submitter thread when asynchronous)
    uint64_t blockedMicros;   // asynchronous: time the GPU queue waited in TSCLRuntimeWaitSubmitted
    uint64_t errors;
    uint64_t gpuNanos;        // GPU time of the timed dispatches that completed (profiling)
} TSCLStats;

TSCLRuntime *TSCLRuntimeCreate(const TSCLRuntimeConfig *config);
void TSCLRuntimeDestroy(TSCLRuntime *rt);   // ends the run and waits for CL to go idle
cl_context TSCLRuntimeContext(TSCLRuntime *rt);
cl_device_id TSCLRuntimeDevice(TSCLRuntime *rt);
cl_command_queue TSCLRuntimeQueue(TSCLRuntime *rt);

// cl_mem objects for GL objects a dispatch is about to use, in `out`: wrapped once (cached by name/target/level),
// acquired at most once per run. Opens the run if needed. Returns CL_SUCCESS or the first CL error.
cl_int TSCLRuntimeUse(TSCLRuntime *rt, const TSCLGLObject *objects, cl_uint count, cl_mem *out);

// Enqueues a kernel in the current run (opening one if needed); nothing is submitted yet.
cl_int TSCLRuntimeDispatch(TSCLRuntime *rt, cl_kernel kernel, cl_uint dims, const size_t *offset,
                           const size_t *global, const size_t *local);

// Same, and calls done(ctx, GPU nanoseconds) exactly once when the enqueue succeeded: on a CL thread once the
// kernel has run when the runtime profiles, at once with 0 otherwise.
cl_int TSCLRuntimeDispatchTimed(TSCLRuntime *rt, cl_kernel kernel, cl_uint dims, const size_t *offset, const size_t *global,
                                const size_t *local, void (*done)(void *ctx, uint64_t gpuNanos), void *ctx);
bool TSCLRuntimeProfiling(const TSCLRuntime *rt);

// Bumped whenever the runtime releases a cl_mem: a later cl_mem can reuse the handle value, so callers that
// remember kernel arguments by handle must set them again when it changes.
uint64_t TSCLRuntimeGeneration(const TSCLRuntime *rt);

// Ends the run: releases every acquired GL object, which submits the whole run. Cheap when no run is open:
// the core calls it before any GL command and before its completion fence.
void TSCLRuntimeEndRun(TSCLRuntime *rt);
bool TSCLRuntimeInRun(const TSCLRuntime *rt);

// Measured with profiling (tests/compute/dispatchbench.m): a GL fence issued after the release does NOT wait
// for the run's kernels unless GL work depends on what they wrote; the release is ordered, the GPU work is
// not. So each synchronous end of run keeps an event that completes after the run's last command: the caller
// takes it (ownership passes, NULL when there is none) and waits for it, e.g. before reporting completion.
cl_event TSCLRuntimeTakeRunEvent(TSCLRuntime *rt);
// Any thread, TSCL_FLUSH_MODE=2 only: the event may still be waiting to be submitted: flush its queue from a
// background thread (the flush can block for the duration of earlier CL work). Coalesced; no-op otherwise.
void TSCLRuntimeKickEvent(cl_event event);

// Same, but the submission (~0.2 ms of driver time) runs on a CL submitter thread while the GPU queue goes on
// encoding the following GL commands. GL commands only reach the GPU at a flush, so the GPU queue must call
// TSCLRuntimeWaitSubmitted before its next glFlush/glFinish/fence (opening a run, Forget and Destroy also join).
// Encoding GL commands that read what the run writes is fine before the join, flushing them is not.
// The run's event (TSCLRuntimeTakeRunEvent) is available from the join on.
void TSCLRuntimeEndRunAsync(TSCLRuntime *rt);
void TSCLRuntimeWaitSubmitted(TSCLRuntime *rt);

// The core is about to delete or re-specify a GL object (call before glDelete*/glTexImage*/glBufferData, since GL
// recycles names): drop its cl_mem, ending the run first if the run holds it.
void TSCLRuntimeForget(TSCLRuntime *rt, GLuint name, GLenum target);

TSCLStats TSCLRuntimeGetStats(const TSCLRuntime *rt);
