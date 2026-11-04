# Direct scanout: how CoreAnimation knows a framebuffer can be reused (RE, iOS 16.7.16 20H392, iPhone10,3)

Date: 2026-11-04. Sources: dyld shared cache 20H392 (`QuartzCore`, `IOMobileFramebuffer.framework`,
`IOSurface.framework`), and the Apple kernelcache `kernelcache.release.iPhone10,3_6` (the
`IOMobileFramebufferLegacy.cpp` code in `com.apple.iokit.IOMobileGraphicsFamily` / `AppleMobileDispH10P`). Compared
against our `SweetFramebuffer.cpp` / `SweetSurface.cpp` (not modified).

Labels: **[V]** = verified in disassembly (address given). **[I]** = strong inference from the code. **[G]** = guess,
not checked.

---

## TL;DR

* **CA's display path does not use IOSurface use counts and does not use any notification to reuse a framebuffer.
  It uses `IOMobileFramebufferSwapWait` = AppleCLCD user client selector 6, with the swap id of the old frame and
  options `0x80000000` (poll for "retired").** Our kernel returns success at once, so CA thinks the frame on screen is
  free and renders the next frame into it. That causes the tearing. **[V]**
* The fix is in the kernel only: selector 6 must return `kIOReturnBusy` (0xe00002d5) for a poll, or block when the
  no-block bit is clear, while the swap is still queued, still waiting for the frame end, or still the one being
  scanned out. **[V]** (Apple's `swap_wait_gated`, below.)
* There is no swap-complete notification. IOMobileFramebuffer.framework only has callbacks for notification types 0
  (hot plug), 1 (power), 3 (frame info), 4 (CRC) and 5 (vsync). **[V]**
* IOSurface use counts still matter, but for a different reason. Apps' `CABackingStore` checks
  `IOSurfaceIsInUse` to see whether backboardd still holds a layer buffer. That value is read from the surface's
  **shared state page at +0x18 (u32, category 0) and +0x1c (u32, category 1)**, which the kernel must keep up to date.
  Our traps 0/1 do nothing today, so this is a second, separate correctness bug, for app content and not the display.
  **[V]**
* The userland Metal driver has no part in the display reuse protocol. **[V/I]**

---

## 1. How CA (backboardd) decides a framebuffer page can be drawn into again

### 1.1 The IOMFBDisplay page ring [V/I]

`CA::WindowServer::IOMFBDisplay` keeps a small ring of "Pages" inside the object, at `this+0x3a8`, 0x30 bytes each.
Indexes: head `+0x358`, tail (current) `+0x35c`, count `+0x360`. Each page has these fields:

| page off | meaning (inferred) |
|---|---|
| +0x00 (`this+0x3a8+i*0x30`) | frame sequence (u32), 0 = page empty |
| +0x08 | `Buffer*` (refcount at Buffer+0x8, flag Buffer+0x84) |
| +0x10 | `CA::WindowServer::Surface*` (unref'd on release) |
| +0x18 (`+0x3c0`) | **IOMFB swap id** returned by `IOMobileFramebufferSwapBegin` |
| +0x20 | optional detached-layer handle |
| +0x28 (`+0x3d0`) | flags byte (bit2 = swapped, bit3 = seen displayed, ...) |

### 1.2 `IOMFBDisplay::can_update_(unsigned)` @ 0x1882be944 [V]

For every page from head up to (not including) the current one:

```
0x1882beb2c  ldr w1, [page+0x3c0]          ; swap id of the old page
0x1882beb30  ldr x0, [this+0x318]          ; IOMobileFramebufferRef
0x1882beb34  mov x2, x25                   ; 0x80000000 (no-block), or 0 if page_flipping_disabled / caller bit1
0x1882beb38  bl  _IOMobileFramebufferSwapWait
0x1882beb3c  cbnz w0, -> cannot update     ; still busy: do not touch this page
             ; == 0: page+0x3c0 = 0, Buffer refcount--, Surface::unref() -> page free
```

When the process does not run with VBL (`CADeviceUseVBL::use_vbl == 0`), the same check goes through
`CA::WindowServer::swap_wait_timeout(IOMobileFramebuffer&, swapid, opts, double*)` @ 0x18853c088. That function
loops `SwapWait(fb, id, opts)` with `usleep(100)` until the result is 0 or a deadline passes. It only makes sense if
the kernel returns an error immediately when the swap is not done yet. **[V]**

The current page is checked with `SwapWait(id, 0x80000001)` (0x1882becc4, 0x1882bed10). If the result is not
`kIOReturnBusy` (0xe00002d5), page flag bit3 ("displayed") is set. This only feeds timing and statistics. **[V]**

### 1.3 Other SwapWait uses in QuartzCore [V]

| site | args (swap id, options) | purpose |
|---|---|---|
| `finish_update` 0x1882d1138 | (page id, 0x80000000) for every page | counts the free (retired) pages |
| `finish_update` 0x1882d3024 | (0, 2) after `SwapEnd`, when a flag is set | waits until no swap is pending |
| `finish_update` 0x1882d39cc, `finish_skylight_update` 0x18852d2fc | (id, 1) | blocks until the swap is displayed (default framebuffer / skylight) |
| `is_ready` 0x1882f9344 | (0, 0x80000003) | "display ready" poll |
| `idle` 0x188394570, `set_all_layers_to_null`, flipbook | (0, 2) | drains all swaps |
| `IOMFBFlipBook::swapped_frame_displayed_p` 0x18843eb48 | (id, 0x80000001) | displayed poll |
| `set_flipbook_*` | (0, 3) | mode query |

### 1.4 What CA does **not** use [V]

* No `IOSurfaceIsInUse` / `IncrementUseCount` call anywhere in the `IOMFBDisplay` / `IOMFBServer` swap path. The only
  QuartzCore callers are `buffer_is_unused(CABackingStoreBuffer*)` @ 0x188335e40, `ImageQueue::did_display`
  @ 0x18830c750, the HDR/PSE processors, `CAImageQueueInsertImage_`, and `CA::Render::Surface` ctor/dtor
  (0x18834c7bc, 0x188343eec, 0x188315138).
* No swap-complete callback. `IOMobileFramebuffer.framework` dispatches async notifications through
  `_NotifyCallbackFuncs` @ 0x1e20ee960, indexed by the selector-72 `type`:

| type | handler | CA consumer |
|---|---|---|
| 0 | `IOMobileFramebufferHotPlugNotifyFunc` 0x1af22b720 | `IOMFBServer::hotplug_callback` |
| 1 | `IOMobileFramebufferPowerNotifyFunc` 0x1af22b784 | power |
| 2 | — (NULL) | |
| 3 | `FrameInfoNotifyFunc` 0x1af223114 (args[0]=mask\|bit31 64-bit flag, args[1]=frame id, then values) | `IOMFBServer::frame_info_callback` (statistics) |
| 4 | `IOMobileFramebufferCRCNotifyFunc` 0x1af22b7f0 | CRC |
| 5 | `IOMobileFramebufferVsyncNotifyFunc` 0x1af22b850 | `IOMFBServer::vsync_callback` |

`kern_EnableNotifications` @ 0x1af227afc: `IOConnectCallScalarMethod(conn, 72, [NotifyCallbackFuncs[type], fb,
type, 0])`. The port's refcon comes back as `fb`. **[V]**

**Vsync payload (type 5)** @ 0x1af22b850 **[V]**: six 32-bit args, combined as
`a = args0|args1<<32`, `t = args2|args3<<32` (passed through `fb->[0x930]`, a time conversion), and
`p = args4|args5<<32`. The callback is called as `cb(fb, a, t, p, refcon)`. In `IOMFBServer::vsync_callback`
@ 0x1882ba1ec, `a` is only kdebug-traced, `t` is the vblank host time, and **`t + p` is used as the next vblank
time** (0x1ba354), with `CATimeWithHostTime(p)` turned into an interval (0x1ba3c4). **So `p` is the refresh period in
mach ticks [I].** Our kernel sends 0 there. This is not the tearing bug, but it should be `16.667 ms` in ticks (or the
measured OVL frame period).

### Answer to Q1

The answer is **(c), SwapWait**. CA reuses a page only after `SwapWait(page_swap_id, 0x80000000)` returns 0 (or the
blocking/timeout variant returns 0). (a) does not exist. (b) is not used for framebuffers. (d) is limited to
statistics (frame info) and timing (vsync).

---

## 2. Apple's kernel semantics of selector 6 (`swap_wait_gated`) [V]

User side: `kern_SwapWait` @ 0x1af223648 calls `IOConnectCallScalarMethod(conn, 6, [swapId, options, 0], 3, NULL,
NULL)`. `kern_SwapWaitWithTimeout` @ 0x1af227990 does the same with `[swapId, options, (u64)(timeout * k)]`.
`IOMobileFramebufferWaitSurface` = `SwapWait(fb, fb->lastSwapId (+0x68, written by SwapBegin), 1)`. **[V]**

Kernel: `swap_wait_gated(this, ?, swapId, options, timeout)` in `IOMobileFramebufferLegacy.cpp` (kernelcache, function
before 0xfffffff005c11c04, located through the string `"swap_wait_gated"` @ 0xfffffff004f66214, xref
0xfffffff005c1191c). It is unoptimised code and reads directly:

```
noBlock  = options & 0x80000000;  options &= 0x7fffffff
hasTimeout = timeout != 0;  deadline = clock_interval_to_deadline(timeout, 1000000)   // timeout in ms
if (swaps aborted)                         return 0xe00002eb (kIOReturnAborted)
if (options == 3 || options == 4)          return fFlag@0x1478 ? 0 : kIOReturnBadArgument   // state query
if (display not usable: power/flags)       return 0xe00002e3
loop:
  if (helper@0x...13050(this))             return 0                // nothing to wait for (e.g. display off)
  displayed = (swapId == fDisplaySwapID@0x1464)
  pending   = fPendingSwap@0x1308 && fPendingSwap->swapID@+0x314 == swapId
  if (!pending) for (s = fSwapQueue@0x1310; s; s = s->next@+0x968)
                    if (s->swapID == swapId) pending = true
  log "swapID = %d fDisplaySwapID = %d fPendingSwap = %p fPending->swapID = %d"
  option 0:  if (!displayed && !pending) return 0     // RETIRED: not on screen, not queued, not latching
  option 1:  if (!pending)               return 0     // DISPLAYED (or already retired / dropped)
  option 2:  if (!fPendingSwap && !fSwapQueue) return 0   // ALL DONE (swapId ignored, CA passes 0)
  if (noBlock)                           return 0xe00002d5 (kIOReturnBusy)
  commandSleep(until deadline, cap 5 s); after repeated timeouts it cancels all swaps and returns an error
```

A swap object with flag `+0x54a` set (cancelled) also ends the wait with an error. The waiters are woken
(`commandWakeup`) when the displayed swap changes or swaps are cancelled. **[I]** (The panic text "CommandWake didn't
happen even after 5 seconds" confirms that a wakeup is expected.)

Related selectors [V]: `SwapCancel` = sel 52 `[swapId]`, `SwapCancelAll` = sel 81 (2 scalars), `SwapSignal` = sel 20
(2 scalars), `SwapBegin` = sel 4 (out: swap id, saved in fb+0x68), `SwapEnd` = sel 5 struct 0x46c (the userland
`kern_SwapEnd` does nothing with surfaces or use counts).

---

## 3. IOSurface use counts (Q2) [V]

`IOSurfaceClient` is `malloc`'d in `__ioSurfaceClientCreateWithLockResult` @ 0x1a3980bc8. **The kernel's lock result
(sel 0/4/34 struct out) is copied to client+0x68.** So client+0x70 = lock result +0x08 = the **shared state page**
user address, and client+0x80 = lock result +0x18 = surface id. client+0xb5 = lock result +0x4d is the
`kIOSurfaceProhibitUseCount` flag (when set, every use-count call aborts the process).

| API | implementation |
|---|---|
| `IOSurfaceIncrementUseCount(s)` → `IOSurfaceClientIncrementUseCountForCategory(c, 0)` @ 0x1a3986ad4 | atomic ++ of a **per-process** count at client+0x8 (u32 cat0 low, u32 cat1 high). **Only on a 0→1 transition**: `IOConnectTrap2(conn, 0, id, category)`. |
| `IOSurfaceDecrementUseCount` → `...DecrementUseCountForCategory(c, 0)` @ 0x1a3986c30 | atomic -- of client+0x8. **Only on a 1→0 transition**: `IOConnectTrap2(conn, 1, id, category)`. |
| `IOSurfaceGetUseCount` → `IOSurfaceClientGetUseCount` @ 0x1a3986d84 | **local only**: (client+0x8).lo + .hi. No kernel involved. |
| `IOSurfaceIsInUse` → `IOSurfaceClientIsInUse` @ 0x1a39832d0 | **`*(u64 *)(statePage + 0x18) != 0`**. Read from the shared page, no syscall. |
| `IOSurfaceIsInUseForCategory(c)` @ 0x1a3986dfc | `u32 at statePage+0x18` (cat 0) or `+0x1c` (cat 1) `!= 0` |
| `IsInUseForAnyOtherCategory(c)` @ 0x1a3986eb4 | the other category's u32 `!= 0` |

The trap return value is only printed on failure ("kIOSurfaceMethodIncrementUseCountForCategory failed").

**Where the kernel must store the count:** the surface's state page (the one already mapped read-only into every task
at lock result +0x08). Use **u32 at +0x18 for category 0 and u32 at +0x1c for category 1**. These offsets are free in
our layout (+0 registry id, +0xc seed, +0x20 value generation, +0x28 value size, +0x30 bulk). The value only needs to
be non-zero while anyone holds the surface. A good choice is the number of (client, category) holders: each process
calls the trap at most once per category (on its 0→1 edge), so the kernel counts per user client. On `clientClose`,
the kernel drops that client's holds.

Cross-process consumers:
* backboardd's `CA::Render::Surface::Surface(__IOSurface*, ...)` increments the use count of the app surfaces it
  imports (0x18834c7bc, 0x188343eec) and decrements it in the dtor (0x188315138).
* The app's `CABackingStore` reuses a buffer only when `buffer_is_unused` → `!IOSurfaceIsInUse` (0x188335e74).

With traps 0/1 as no-ops, `+0x18` is always 0, so apps reuse backing stores that backboardd may still be compositing.
This can tear or flicker **inside app layers**. It is independent of the display bug, but worth fixing at the same time.

---

## 4. Minimal kernel protocol for AppleCLCD (Q3)

Keep three kinds of state per framebuffer, under `fFB->fLock`. Our K0c queue and K0d pending switch already map onto
them:

* **Q** = swaps that went through SwapEnd and are not chosen yet (the `SWEET_FB_QUEUE` entries).
* **P** = the swap whose surface was programmed or is about to be programmed into the OVL, before the frame end where
  it takes effect (K0d "switch pending").
* **D** = the swap id whose surface the OVL is scanning out now. For the copy path, this is the swap whose pixels are
  being copied.

**Retired(S)** ⇔ S ∉ Q, S ≠ P, S ≠ D. **Displayed(S)** ⇔ S ∉ Q and S ≠ P.

Events:

1. **SwapBegin (sel 4)**: allocate the id (as now). An id with no SwapEnd yet is in no set, so it counts as retired.
   That matches Apple, where a never-ended id is not found.
2. **SwapEnd (sel 5)**: push S onto Q. Nothing else.
3. **A tick or early present picks S_k from Q** (the newest GPU-idle swap): older queued swaps that are dropped
   leave Q → they are retired now (they were never scanned out, so their surfaces are free). S_k becomes P. Wake the
   waiters.
4. **Frame end where the OVL address switch to S_k's surface is made** (the INTSTA bit-1 poll in the vsync timer): let
   old = D; D = S_k; P = none. **old is retired from this moment.** Wake the waiters. If you are not sure that the
   write landed inside vblank, retire `old` one frame end later. That is safer, and you lose only one frame of
   pipelining.
5. **Copy path** (non-contiguous surface, partial frame, console): S stays P until its copy into the panel buffer is
   finished. After that, S's surface is no longer read, so treat it as D→retired at once, or simply make D = S and
   retire the previous D. Either way is correct, because the panel buffer and not S's surface is on screen.
6. **Swaps that do not change the scanout surface** (layer mask 0, default surface, parameter-only swaps): remove them
   from Q/P when they are processed. They must **not** replace D. Otherwise the swap whose surface is really on screen
   would be reported as retired. **[I]** (On Apple every swap describes all layers. Here it is safer to advance D only
   when the OVL source address really changes.)
7. **SwapCancel (sel 52, [id]) / SwapCancelAll (sel 81)**: remove from Q (and P if it is not latched yet) and wake the
   waiters.
8. **Power off (sel 12, state 0)**: keep the sets consistent. The OVL keeps scanning during the fade, so do not retire
   D early. Apple returns 0xe00002e3 when the display cannot be used. We can keep returning normal results.

**SwapWait (sel 6, scalars [swapId, options, timeout]):**

```
noBlock = opt & 0x80000000; op = opt & 0x7fffffff
op 3 or 4          -> return kIOReturnSuccess        (display ready / enabled query)
loop:
  op 0: done if Retired(swapId)
  op 1: done if Displayed(swapId)
  op 2: done if Q empty && P none                    (swapId is 0)
  done        -> return kIOReturnSuccess
  noBlock     -> return kIOReturnBusy (0xe00002d5)
  sleep on the framebuffer (IOLockSleepDeadline / commandSleep), deadline = timeout ms if given, else cap ~5 s
  on timeout  -> return kIOReturnTimeout (0xe00002d6)  (Apple cancels all swaps after retries; optional)
```

Waking must happen on events 3, 4, 5, 6 and 7. **Do not block inside the vsync timer or the work loop.** Only the
user-client thread that called sel 6 sleeps.

**Notifications:** nothing new is needed for reuse. Keep type 5 vsync, but put the refresh period (mach ticks) in
args 4/5. CA uses it as `next_vbl = t + p`.

**IOSurface (separate fix):** trap 0/1 `(id, category<2)` → per-client per-surface per-category hold
(0↔1). Keep the global count in the state page at +0x18/+0x1c (u32 each), and drop it on client close / surface
release. Optionally, AppleCLCD can also increment +0x18 for the surface in D (and in P) and decrement it on
retirement. CA's IOMFB path does not need this, but `ImageQueue::did_display` and other `IsInUse` readers see it, and
it matches what a real display kext probably does **[G]** (not verified in AppleMobileDispH10P).

Expected behaviour after the fix: CA's ring has 2 (maybe 3 **[G]**) pages. For frame N+1 it polls the swap of the
page it wants (N-1). That swap retires only when frame N reaches the frame end and the OVL has switched. So CA never
draws into the surface being scanned out. With the K0c queue it may stall up to one frame, which is the correct
double-buffer behaviour.

---

## 5. Metal driver responsibility (Q4)

* **The display reuse gating is kernel-only** (selector 6 semantics + wakeups). CA's IOMFB path never consults use
  counts. **[V]**
* The "GPU has finished rendering frame N before it is scanned out" ordering is also kernel-side and already done
  (K0c `viva_gpu_surface_idle` before choosing a swap). The driver does not need to wait before backboardd calls
  SwapEnd. **[V from our source]**
* The driver's `IOSurfaceIncrementUseCount`/`DecrementUseCount` around command buffers are harmless. They only reach
  the kernel on 0↔1 transitions per process, and only become visible to other processes once the kernel implements
  traps 0/1 + state page +0x18. This is fine for app↔backboardd buffer reuse (`CABackingStore`), but it **must not be
  relied upon for GPU synchronisation**. Keep using the kernel fences. **[I]**
* If the driver ever passes surfaces created with `kIOSurfaceProhibitUseCount`, those calls abort the process
  (`IOSurfaceIncrementUseCountForCategory: error: ... kIOSurfaceProhibitUseCount`). Check the flag (lock result
  +0x4d) or avoid such surfaces. **[V]**

---

## Evidence index

| item | address |
|---|---|
| `IOMobileFramebufferSwapWait` → fb vtable +0x750 → `kern_SwapWait` (sel 6, [id, opts, 0]) | 0x1af2230f8 / 0x1af223648 |
| `kern_SwapWaitWithTimeout` (sel 6, [id, opts, timeout]) | 0x1af227990 |
| `IOMobileFramebufferWaitSurface` (id = fb+0x68, opts 1) | 0x1af2252a0 |
| `kern_SwapBegin` (sel 4, stores id at fb+0x68) / `kern_SwapEnd` (sel 5, 0x46c) | 0x1af223708 / 0x1af223530 |
| `kern_SwapCancel` sel 52, `kern_SwapCancelAll` sel 81, `kern_SwapSignal` sel 20 | 0x1af227a14 / 0x1af227a7c / 0x1af227924 |
| `kern_EnableNotifications` sel 72 [func, fb, type, 0]; table `_NotifyCallbackFuncs` | 0x1af227afc / 0x1e20ee960 |
| `IOMobileFramebufferVsyncNotifyFunc` | 0x1af22b850 |
| `CA::WindowServer::IOMFBDisplay::can_update_` | 0x1882be944 (SwapWait at 0x1882beb38) |
| `CA::WindowServer::swap_wait_timeout` (poll + usleep(100)) | 0x18853c088 |
| `IOMFBDisplay::finish_update` free-page count | 0x1882d1118..0x1882d1154 |
| `IOMFBDisplay::collect_buffers` (Buffer refcount +0x8, release_buffer) | 0x188305288 |
| `IOMFBServer::vsync_callback` (next vbl = t + p) | 0x1882ba1ec, 0x1882ba354 |
| kernel `swap_wait_gated` (IOMobileFramebufferLegacy.cpp) | body 0xfffffff005c1115c+..0xfffffff005c11c00 |
| `__ioSurfaceClientCreateWithLockResult` (lock result → client+0x68) | 0x1a3980bc8 |
| `IOSurfaceClientIsInUse` (statePage+0x18) | 0x1a39832d0 |
| `IOSurfaceClientIncrement/DecrementUseCountForCategory` (traps 0/1 on 0↔1) | 0x1a3986ad4 / 0x1a3986c30 |
| `IOSurfaceClientGetUseCount` (local only) | 0x1a3986d84 |
| `buffer_is_unused(CABackingStoreBuffer*)` → IOSurfaceIsInUse | 0x188335e40 |
