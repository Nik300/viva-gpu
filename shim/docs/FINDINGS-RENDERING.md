# Findings: rendering errors in Chrome (odontoiatriasempioneroma.it)

Date: 2026-10-31. Status: **investigation open**. Three shim bugs found (one fixed and verified, one confirmed with partial mitigation, one latent), plus a residual cause still unidentified. **Nothing has been installed**: the installed driver is still 0.4.0 (20261031.1339); all changes live only in `src/` and `build/`.

> **Session 2 (evening of 2026-10-31) is at the end of this file (§11–§17) and supersedes §4, §9 and §10.** Short version: B2 now has its proper fix (GL fence), IOSurface use counts are held like Metal does, and the residual bug has a **deterministic minimal repro** (`tests/web/bf4.html`). Seven more hypotheses are ruled out with measurements. The bug disappears only under the heavy trace (GPU sync after every draw). Next step: `TSMTL_SYNC_DRAW` (§16).
Snapshot taken before the changes: `snapshots/pre-render-fix-20261031-1620.tgz`.
Screenshots referenced below: `docs/findings-2026-10-31/`.

---

## 1. Symptoms

Page `https://www.odontoiatriasempioneroma.it/` in Chrome 156 (copy `apps/Google Chrome.app`, policy `list`):

- cookie banner "La tua privacy, prima di tutto": only the blurred background shows, no text, white background or buttons; sometimes drawn half-way (right side only);
- "glass" card in the header (carousel "Igiene orale…"): same symptom, blurred background without content;
- below the fold: rectangles ~256 px (tiles) placed in the wrong spot, flat-colour blocks, layers cut off, text "barcode-like" (glyphs stretched vertically), footer missing;
- **intermittent**: same page, same scroll position, different result run to run; once wrong, it stays wrong until Chrome redraws that region.

Reference: same browser copy with `--disable-gpu --disable-gpu-compositing` (profile `apps/home-Chrome-ref`) renders correctly.
Example: `findings-2026-10-31/sheetA.png` (left = shim, right = reference).

## 2. What Chrome does on this machine (measured)

`SystemInfo.getInfo` on the test instance:

- `rasterization: unavailable_off` → **no GPU raster**: tiles are drawn by the **renderer process's CPU** directly into IOSurfaces (zero-copy). Measured: no IOSurface write goes through the shim (0 `replaceRegion`, 0 blit buffer→IOSurface texture).
- `skiaBackendType = GraphiteDawnMetal` → compositing = Skia Graphite on Dawn on Metal (= shim). WebGL instead goes through ANGLE-Metal.
- Each tile = one `MTLTexture` over an IOSurface (256×256, 512×64, 512×512…; descriptor size == IOSurface size, measured).
- Graphite draws each tile with its own `baseInstance` (vertex pulling from Private buffers `v1` 2048 B and `v3` 16388 B that alternate per frame); depth `Depth16Unorm` LESS, clear 1.
- `backdrop-filter` elements: own render pass (texture 1024×320, 448×512…), backdrop copy via blit from the root, blur in 3–4 small passes, final composite. **Chrome caches the element's render pass**: if its content gets corrupted once, the corruption stays on screen.
- Frames are mostly **partial** (only the damage: e.g. the logo marquee, scissor 1344×48) with `loadAction=Load` on the root: a wrong full frame persists.
- Minimal repro: `tests/web/bf2.html` (static), `bf4.html` (big card + marquee in continuous animation). Trigger: **layer with backdrop-filter larger than a tile** (box-shadow is irrelevant; it only enlarges the layer).

## 3. Bugs found in the shim

### B1 — scissor lost after `refreshFromRectangle` (FIXED, verified)
`TSMtlTexture refreshFromRectangle` (refresh of the 2D copy of an IOSurface) runs **mid-pass** during resource binding, does `glDisable(GL_SCISSOR_TEST)` and never restores it, behind the encoder's GL shadow: every later draw in the pass loses its clip.
Fix in `src/TSMtlResources.m`: save `glIsEnabled(GL_SCISSOR_TEST)` and restore it after the blit.
Verification: `bf2.html` static, broken before (`bf2-sheet.png`) → identical to the reference after (`bf2-sheet2.png`). **Not enough** for the real site.

### B2 — "completed" before the GPU has executed (CONFIRMED, mitigation only as a knob)
`submitCommandBuffers` (`src/TSMtlCommands.m`) executes, does `glFlush()`, then calls scheduled/completed handlers; `encodeSignalEvent` sets `signaledValue` at CPU execution time. But the AMD GL driver runs the commands **later**. Chrome/Dawn use those signals to release resources (tiles back to the renderer, staging buffers reused).
Test: knob `TSMTL_SYNC_COMPLETION=1` (`glFinish()` before signal and completion) → **marked improvement** (`D-sheet.png`: banner visible in 2 of 3 positions, news and footer correct) but **not resolved** (glass card and banner still empty in some captures).
Proper fix to implement: GL fence (`glFenceSync`) after each CB, completion + event signal deferred until `glClientWaitSync` succeeds (non-blocking polling on the GPU queue / at the next execution / `dispatch_after`), instead of a per-CB `glFinish`.

### B3 — `encodeWaitForEvent:value:` was a no-op (LATENT)
Comment in the code: "Everything runs in submission order on one serial queue, so waits are already satisfied". False if the waiting CB is committed before the one that signals (cross-queue). On this page it does **not** happen: check added (warning `wait unsatisfied`) → **0 occurrences**. It remains a latent bug: a real fix needs a scheduler that suspends CBs at the wait and runs other queues.

### B4 — `tsmtl log` is blind on Chrome's GPU process (DIAGNOSTICS)
Chrome's GPU sandbox blocks os_log: process `Google Chrome Helper (Aperitif)` emits **0 messages** (only Activity), not even from Apple frameworks. The installed driver's errors/warnings in that process are not visible to `tsmtl log`. To see them you need a separate instance with `TSMTL_LOG=1` (stderr). Possible improvement: a file fallback in the cache directory that the GPU sandbox allows (`<DARWIN_USER_CACHE_DIR>/…/com.apple.metal/`).

### B5 — IOSurfaces rewritten after binding (MEASURED, effect not visible)
`IOSurfaceGetSeed` changes 11–285 times every 5 s on the bound tiles. Added rebinding (`CGLTexImageIOSurface2D` again) when the seed changes (`rebindIfSurfaceChanged`, disable with `TSMTL_NO_SEED_REBIND=1`). A/B (`B-sheet.png` vs. without rebind): **no visible difference**. Kept because it costs little and is correct in principle.

## 4. Residual cause (open)

With B1 fixed and B2 mitigated there are still emptied render pass textures. Timeline measured with the trace (`trace` §6):
- banner texture 1024×320: 71 % opaque for ~30 CBs, then a `loadAction=Load` pass with **the same draws** (same tiles, same `baseInstance`, same depth/blend/scissor, GL state consistent with the shadow) produces **0 %**; from then on the composite samples an empty texture;
- glass card 448×512: same pattern, alternating per frame between 83 % and 0 %; the bad draw samples a tile just rewritten (seed changed right before).

Leading hypothesis: when the GPU actually reads it, the tile is **transparent or half-written** because the renderer is writing it (a write in progress does not change the seed until unlock, so the encode/execute seed comparison cannot see it). Supporting evidence: reading tiles **from CPU memory** at execution time (`TSMTL_SURFACE_UPLOAD`) yields blank / half-drawn tiles (E, F worse). Open questions: why the renderer writes tiles that are still in use (early signal from the shim through another path? Chrome IOSurface "in use" check? cross-process fences that do not exist with `_MTLSharedEvent`, which is CPU-only and has no kernel object?).

## 5. Hypotheses ruled out (with evidence)

| Hypothesis | Test | Result |
|---|---|---|
| Rectangle variant scales coordinates by the IOSurface size ≠ MTLTexture | trace of sizes at creation | descriptor == surface in every case |
| The box-shadow causes the bug | `bf2.html`: big card without shadow | breaks anyway: size/multiple tiles matter |
| Unsatisfied `MTLSharedEvent` waits | check at execution time | 0 occurrences |
| Two shim devices in the process (parallel GL queues) | `device ready` per process | 1 in browser, 1 in GPU process |
| GL state desync vs encoder shadow (program, FBO, VAO, viewport, scissor, `ts_base_instance`) | `!!` checks per draw | 0 mismatches |
| `baseInstance` uniform cache shared between variants | code: each variant is its own `TSGLProgram` | separate caches |
| CPU vs GL copy differs in bound buffers | full comparison (≤64 KB) per draw | 0 differences |
| Stale IOSurfaces in the GL driver | CPU vs GL comparison (FBO + glReadPixels) | 170/170 coherent — **but only under the heavy trace, which synchronizes** |
| Tile rewritten between encode and execution | seed at encode vs execution | 0 differences — **doesn't see in-progress writes** |

## 6. Tools built (keep, reuse)

- `TSMTL_DRAW_TRACE=<file>`: when the file appears, traces N command buffers (N = number written in the file, else `TSMTL_DRAW_TRACE_CBS`, else 3): passes, draws, blits, mid-pass links, waits, GL-vs-shadow consistency (`!!`), buffer bindings, encode/exec seed of IOSurfaces. Example: `echo 200 > /tmp/trig` with the instance running.
- `TSMTL_DRAW_TRACE_HEAVY=1`: adds GL readbacks (content % of sampled textures, IOSurface coherence, target result after each draw, CPU/GL buffer comparison). **Synchronizes the GPU and hides races**: use only for deterministic bugs.
- Trace in progress (in the source, **not built**): CPU-only % opaque + `IOSurfaceIsInUse` per sampled IOSurface, without GL readbacks.
- Knobs: `TSMTL_SYNC_COMPLETION`, `TSMTL_SURFACE_UPLOAD` (experiment, worsens), `TSMTL_NO_SEED_REBIND`. Stats: `iosurface rebinds (seed changed)`.
- `tools/chrome-ab.sh <tag> [VAR=val…]`: fresh test instance (`--system`, build bundle, GPU sandbox off, no throttling), 6 captures at y=0…4000, contact sheet `$TS_SHOTS/<tag>-sheet.png`. `tools/cdp-probe.sh`: `cdp.py` with a 15 s limit.
- Test pages: `tests/web/bf.html` (variants blur/saturate/shadow/animation), `bf2.html` (separates size/shadow/outline), `bf3.html` (+ marquee), `bf4.html` (big card + marquee only).
- Reference: `apps/Google Chrome.app/Contents/MacOS/Google Chrome --user-data-dir=$PWD/apps/home-Chrome-ref/profile --remote-debugging-port=9223 --disable-gpu --disable-gpu-compositing …`.

## 7. Tested and NOT working (don't retry as is)

- Seed rebind alone (B): no visible improvement.
- `TSMTL_SURFACE_UPLOAD` (tiles read from CPU memory and loaded with `glTexSubImage2D`), with or without sync (E, F): **worse**, blank / half-drawn tiles and "barcode" text.
- `TSMTL_SYNC_COMPLETION` alone (D): improves, doesn't resolve. And `glFinish` per CB is not an acceptable final solution (serializes CPU and GPU).
- `glGetTexImage` on a `GL_TEXTURE_RECTANGLE` bound to an IOSurface: **returns all zeros** on this driver (it isn't a reliable reading method). Use FBO + `glReadPixels`.

## 8. Mistakes I made (to avoid)

1. **Scroll loop with an empty height**: I parsed the output of `cdp.py eval` with a wrong grep (it prints only the value, not JSON) → `seq 0 800 ""` = 1 px steps; 5 minutes lost and a background task to kill. Check the variable before the loop.
2. **Edit without a prior Read** (twice): the Edit failed but `make` ran in the same command on the unchanged source. Don't chain `make` after an Edit that might fail; check that the binary contains the change (`strings`).
3. **Python insertion inside a `for` without braces**: the build failed, and since `make | grep error` was followed by the test in the same command, **I ran the previous build** believing it was the new one. Rule: stop the chain if the build fails (`make || exit`), and check the bundle timestamp.
4. **Choosing the tab by URL** after navigating elsewhere (`--target sempione` on a page that had become `bf.html`) → `StopIteration`. Address it by the current URL or use `/json/list`.
5. **Occluded windows**: when the user's windows cover the test instances, Chrome marks them `hidden` and stops producing frames → captures/eval hang (socket timeout). Always launch with `--disable-backgrounding-occluded-windows --disable-renderer-backgrounding --disable-background-timer-throttling`.
6. **`--system` without `--disable-gpu-sandbox`**: the GPU process can't read the bundle in `~/metal-shim/build` → "Exiting GPU process due to errors during initialization". Only for tests.
7. **Conclusions drawn under the heavy trace**: GL readbacks synchronize the queue and **make the bug disappear** (heisenbug). Two "everything correct" runs and the "IOSurfaces coherent" verdict came from heavy mode: not valid as proof of absence of races.
8. **Partial frames traced as if complete**: Chrome redraws only the damage; the broken card was drawn in an earlier frame. To trace a full frame: a CDP capture (forces a full frame) or scrolling, with enough CBs (≥100).
9. **Hypotheses before measurements**: rectangle scaling, shared uniform cache, two devices, events: each formulated and only then verified. Better to set up the per-draw consistency trace right away (it took 1 build and ruled out 4 hypotheses at once).
10. **Single runs for an intermittent bug**: A/B with one run per configuration isn't conclusive (D vs B could vary by chance). For each configuration use ≥3 runs and count broken captures.
11. **Interpreting the seed**: the seed changes only on unlock; an in-progress write is invisible to the encode/exec comparison. Don't use it to rule out concurrent writes.
12. The scratchpad is per session: scripts and test pages must go straight into `~/metal-shim/tools` / `tests/web` (done now).

## 9. Possible paths to resolution (in order)

1. **Proper fix for B2**: GL fence per CB, completion and `encodeSignalEvent` deferred until the fence passes (signals in CB order). Measure fps on Maps/Chrome (prior reference: Maps ~30 fps). Keep B1.
2. **Bisect the residual cause with Chrome flags** on the test instance (≥3 runs each, `tools/chrome-ab.sh`):
   - `--enable-gpu-rasterization` (tiles drawn by Graphite in the GPU process: no CPU writes from the renderer);
   - `--disable-zero-copy` / one-copy (if the flag exists in 156: the renderer writes to shared memory, the GPU process copies);
   - `--disable-features=…` Graphite → Ganesh/ANGLE for comparison.
   If one of these resolves it, it is both a diagnosis (cross-process synchronization of the tiles) and an immediate **workaround** (flag on the user's Chrome).
3. **Build the light trace** already in the source (CPU % opaque + `IOSurfaceIsInUse`) and check whether the bad draw samples a transparent tile and whether `IsInUse` is 0 (= nobody, including us, declares the surface in use). If so: emulate what Metal/IOGPU does, i.e. `IOSurfaceIncrementUseCount` on IOSurfaces referenced by a CB at commit and `Decrement` on real completion (fence), so whoever checks `IOSurfaceIsInUse` doesn't rewrite them. To verify in the Chromium source which check the resource pool uses.
4. **B3**: CB scheduler with real waits (per-queue FIFO, a CB suspended at an unsatisfied wait, retry on signal).
5. **B4**: file log fallback for sandboxed processes, so the installed driver's errors in Chrome's GPU process become visible.
6. Clean-up before install: trace and knobs are gated by globals (no cost when off); remove `TSMTL_SURFACE_UPLOAD` if it stays useless; `make test` (phase1…system) must pass; new snapshot; installation with `system/install.sh` **run by the user** (rules: no writes to `/Library` without OK).

## 10. State left behind

- Changed: `src/TSMtlResources.m` (B1, B5, upload experiment, trace reports), `src/TSMtlCommands.m` (B2 knob, B3 check, blit trace), `src/TSMtlRender.m` (draw trace), `src/TSMtlCommon.m` / `TSPrivate.h` (trace globals, `iosurface rebinds` stat), `src/TSMtlDevice.m` (trace tick, IOSurface size trace).
- `make test` **not run** after the changes.
- Test Chrome instances (profiles `home-Chrome-test`, `home-Chrome-ref`) may still be running: `pkill -f home-Chrome-test/profile; pkill -f home-Chrome-ref/profile`. They don't touch the user's Chrome (default profile).

---

# Session 2 — 2026-10-31 evening

Everything is still **only in `src/` and `build/`**: nothing installed, the system-wide driver is still 0.4.0. Backups of the files touched first: `backups/b2-fence/` (`TSMtlCommands.m`, `TSMtlDevice.m`, `TSPrivate.h`, `TSMtlRender.m.pre-knobs`). Screenshots and contact sheets of this session: `docs/findings-2026-10-31/b2/`. Snapshot at the end of the session: `snapshots/render-session2-20261031-2039.tgz`.

## 11. Changes made (kept)

### 11.1 B2 — proper fix: completion deferred to a GL fence (DONE, tested)
- `TSMtlDevice afterGPUCompletes:` (`src/TSMtlDevice.m`): `glFenceSync` + `glFlush`, FIFO of pending completions, polled without blocking (`glClientWaitSync(fence, 0, 0)`) right away and then every 250 µs via `dispatch_after` on the GPU queue while some are left. A failed wait completes anyway (never leaves a command buffer hanging).
- `submitCommandBuffers` (`src/TSMtlCommands.m`): "scheduled" stays immediate (present needs it). Shared event signals, post-flush work (visibility queries: `GL_QUERY_RESULT` no longer stalls) and `commandBufferDidComplete` run in order once the fence has passed.
- `encodeSignalEvent`: the signal is queued on the command buffer (`takeSignals`), no longer set at CPU execution. The B3 check (`wait unsatisfied`) also counts values already issued to the GPU (`TSIssuedSignals`, weak map), so there are no false alarms.
- Knob `TSMTL_EARLY_COMPLETION=1` = old behaviour (A/B). `TSMTL_SYNC_COMPLETION` is still there.
- `make test`: 44/33/33/15/57/18/8, all passing (see §15.1 for a caveat on the test suite).
- Effect on the site: **none visible by itself** (G vs H runs, 3+3). It is correct and stays.

### 11.2 IOSurface use count held like Metal (DONE, tested)
- Measured: with the old code the IOSurfaces sampled by the GPU were `IOSurfaceIsInUse == 0` in 2669 of 2698 samples. Chrome's renderer (cc `ResourcePool`, `IsInUseByMacOSWindowServer`) relies on that flag before reusing a tile.
- Measured (`exp/usecount/usecount.m`): `IOSurfaceIncrementUseCount` in one process **is seen** by `IOSurfaceIsInUse` in another (kernel-level count).
- `-[TSMtlCommandBuffer useSurface:]` at encode time (render `setTexture`, pass attachments via `TSMtlUsePassSurfaces`, blit src/dst, mipmaps). Count incremented at commit (`beginSurfaceUse`) and decremented at real completion (`endSurfaceUse`, after the fence). Knob `TSMTL_NO_SURFACE_USE=1`.
- Verified: the tiles are now `inuse1` in the trace. Effect on the site: **none visible** (U vs N runs, 3+3). Correct, stays.

### 11.3 Bisection knobs (zero cost when off)
- `TSMTL_NO_SHADOW=1`: before every draw, forgets the GL state shadow and the program's uniform cache (every GL state is re-issued).
- `TSMTL_NO_DEDUP=1`: after every draw, resets the encode-time dedup (`_sh`), so every `set*` call is kept.
- `TSMTL_NO_RECT=1`: IOSurfaces are sampled through the 2D copy (GPU blit), not in place as `GL_TEXTURE_RECTANGLE`.
- `TSMTL_REBIND_ALWAYS=1`: `CGLTexImageIOSurface2D` again on the first use in every command buffer, whatever the seed.
- Heavy trace: `-> target N% opaque changed x a..b y c..d` (bounding box of the pixels each draw changed). `TSMTL_DRAW_TRACE_DIR=<dir>` saves the IOSurface rendered by each pass as `pass-NNNN.bmp` (after `glFinish`).
- **Not applied** (the user stopped the tool call): `TSMTL_SYNC_DRAW` (`glFinish` after every draw). It is NOT in the source.

### 11.4 Tools
- `tools/imgdiff a.png b.png [mask.png]` (ImageIO, in the Makefile): % of pixels that differ by more than `IMGDIFF_THRESHOLD` (48) + red mask.
- `tools/chrome-ref.sh <tag>`: reference captures (`--disable-gpu --disable-gpu-compositing`, port 9223), **with `--disable-gpu-sandbox` too**: the warning bar makes the viewport 817 px tall in both instances (otherwise 873 vs 817 and the comparison is invalid).
- `tools/chrome-score.sh <ref> <tags…>`: `imgdiff` per position + `<tag>-mask-N.png`.
- `tools/chrome-ab.sh`: `CHROME_EXTRA="--flag…"`, `URL=…`, `TARGET=<substring of the tab URL>`.
- `tests/web/grid.html`: 14×60 grid of numbered, coloured cells (tiles/scroll/composition).
- Reference noise: ref vs ref = 0 / 1.7 / 3.6 / 0 / 0 / 0 % (carousel/marquee); `bf3`/`bf4` have a marquee, so their % is always ~12–13 and **does not tell broken from correct**: look at the images.

## 12. Results on the site (6 positions y=0…4000, % differing from `refb`)

| run | configuration | result |
|---|---|---|
| U1–3 | fence + use count | 5.7–7.8 / 12 / 10–23 / **37.93** / 5.5–10.5 / 12.8–18.4 |
| N1–3 | fence, `NO_SURFACE_USE` | same; position 4 = **37.93** in 5 of 6 runs |
| S1 | `NO_SHADOW` | position 4 = 37.93 |
| D1 | `NO_DEDUP` | position 4 = 37.93 |
| NR1 | `NO_RECT` (2D copy, 240 MB copied) | position 4 = 42.59, still broken |
| X1 | translator passes/struct/cache/warm-up off | 80–95 %: 15 fallback pipelines ("no zero for type kind 12"), a different bug, expected |
| R1 | `--enable-gpu-rasterization --ignore-gpu-blocklist` | broken differently (black rectangles, banner scaled down): **CPU-written tiles are not the (only) cause** |
| K1/K2 | `--disable-features=SkiaGraphite` (+`--use-angle=metal`) | correct, **but chrome://gpu = "Compositing: Software only"**: the shim is not used, so it proves nothing. Chrome 156 on Mac has no Ganesh/ANGLE-Metal compositor. Software compositing = possible workaround for the user, at the cost of acceleration |
| GR1 | `grid.html` | **0.00 everywhere**: plain tiles, scrolling and composition are correct |

Position 4 identical to the pixel in almost every run ⇒ the defect is **deterministic**, not a race between runs.

## 13. Minimal deterministic repro: `tests/web/bf4.html`

`bf.html` (card 5 "+animation" with no content, plus a stray tile), `bf2.html` (card 5 empty) and `bf4.html` are all broken. `bf4` (840×330 card with backdrop-filter + continuous marquee) is the most readable one. Real screen (`screencapture -l <winid>`) and CDP screenshot are **broken in the same way** (`b2/W1-cmp.png`), so it is not an artefact of the capture path.

Pipeline measured with the trace (`exp/trace-bf4b.txt`, `bf4c`, `bf4d`):
1. Card content pass `896x384` (once at startup, then **cached**): 9 tile draws with their own `baseInstance` (5 `drawIdx n29`, 3 `draw v0+4`), two mid-pass links of variant `0x1`. Under the heavy trace each tile lands in its own cell (4 columns 0..254/255..508/509..762/763..879 × rows 0..254/255..369), target 94% opaque: **geometry and tile contents correct**.
2. Backdrop blit from the root (30,233) 880×370 → 1024×512, 3–4 blur passes, then into `1024x512` B: blurred backdrop + card (bi=68, changes exactly x 0..879 y 0..369), then B onto the root (bi=69).
3. Root saved pass by pass (`exp/passes-bf4/`, `TSMTL_DRAW_TRACE_DIR`): **card correct in every frame under the heavy trace**. The CDP capture taken during the trace is correct (`TB4d-1`), the one after the trace ends is broken (`TB4d-6`).

What is wrong on screen (normal run): **not a shift**. Tile column 0 of the card is missing in both rows (only the blurred backdrop shows), row 1 col 1 is grey, row 1 col 2 is missing, col 3 is plain opaque white; the right edge is in the right place. So some tiles, **when the card pass runs**, are sampled with wrong or empty content, and the cached result stays on screen.

Measurements that pin it down:
- Light trace (no GL readback, only CPU lock+scan): CPU memory of the tiles **correct** at execution (20/45/45/45/45/100/100/99 %, the same values as the correct heavy run), seeds stable (`enc 2 exec 2`), no `!!RACE`. **Result broken** (`TB4b`).
- `TSMTL_SURFACE_UPLOAD=1` (upload from CPU memory): broken in the same way (uncertainty: last 5 s stat `texture upload KB=0`, so I could not prove the path was used in the card pass).
- `TSMTL_REBIND_ALWAYS=1`: still broken, and the two captures differ from each other (the card pass was redrawn, again wrong).
- Heavy trace (readback after every draw = CPU waits for the GPU): **correct**.

⇒ The remaining candidate is a dependency between draws/passes that the GL driver does not honour without synchronization (or something the heavy readbacks change as a side effect). To verify with `TSMTL_SYNC_DRAW` (§16).

Useful facts about Dawn/Graphite shaders (`exp/msl-bf4/*.metal`, `exp/glsl-bf4.txt`): vertex pulling, 15 `uint` per instance from `buffer(2)` at `instance_id*15`; at +5 an `ssboIndex` that the fragment uses (`flat` varying) to read per-draw data from `buffer(1)`. Translation checked: `(gl_InstanceID + ts_base_instance) * 15`, `flat` qualifiers present, `ts_base_vertex` set, `bi` in the trace = requested baseInstance.

## 14. Hypotheses ruled out in session 2 (with evidence)

| Hypothesis | Test | Result |
|---|---|---|
| Completion/signals too early (B2) as the main cause | fence fix, G vs H 3+3 | no visible difference |
| Renderer reuses tiles still in use (IsInUse) | use count held, U vs N 3+3 | no difference (and with GPU raster it breaks anyway) |
| The GPU writes the tiles (CPU/GL conflict) | trace: render targets | the only IOSurface target is the root 1400×960 |
| Driver: texture buffer does not follow an orphaned buffer | `exp/tboorphan/tbo.m`: orphan/SubData/rebind/size 2048↔16388, 64 draws without `glFinish`, ×3 | 0/64 wrong in every case |
| Pass clear bound by scissor/masks | code `begin` | scissor disabled, masks restored, `glClearBuffer*` |
| Texture views / readback between mirrors | trace | 0 passes on views, 0 sampled views |
| GL state shadow / per-program uniform cache | `NO_SHADOW`, code `_uniforms` per program | unchanged |
| Encode-time dedup | `NO_DEDUP` | unchanged |
| `_vertexShift`, UBO copy ring (`copyGen`, reservation) | code | correct (offset resets `copyGen`, upfront reservation per draw) |
| In-place rectangle variant / coordinate scaling | `NO_RECT` (2D copy) | unchanged |
| Stale disk translations | cache key | includes `TSAirTranslatorTag()` |
| Compute no-op / unimplemented APIs | `TSMTL_LOG=1` (catch-all writes to stderr), `TSMTL_TRACE=1` | 0 `unimplemented`, no compute encoder |
| Stale IOSurface copy in the driver (seed) | `REBIND_ALWAYS` | still broken |
| Installed driver 0.4.0 mixed with the build | `lsof` on the GPU process (`--type=gpu-process`) and the browser | only `build/TeraScaleMTLDriver.bundle` + `build/libTSRegSim.dylib`; no `/Library/GPUBundles`, no `libTSMetalInject` |

## 15. Other problems found

### 15.1 `make test` loads the installed driver too
Messages `Class TSMtlTexture is implemented in both build/libTSMetal.dylib and /Library/GPUBundles/TeraScaleMTLDriver.bundle`: a test linked to the build calls system Metal, which (kext installed) also loads the 0.4.0 bundle. ObjC keeps one copy per class, C globals are duplicated ⇒ **the passing results of that test are not fully reliable**. To fix: run the tests with the system driver off for the process (policy/env), then check that the message is gone. Not related to Chrome (verified, §14).

### 15.2 `vmmap` crashes on Chrome's GPU process
`-[_IOSurfaceDebugDescription pixelFormatString]: unrecognized selector` (crash of vmmap, not of Chrome). To list the loaded images use `lsof -p <pid> | grep -E "TeraScale|libTS"`. The GPU process command line does not contain `--user-data-dir`: find it by `--type=gpu-process`.

## 16. Next steps (in order)

1. **`TSMTL_SYNC_DRAW=1`** (`glFinish` after every draw, without other readbacks) on `bf4`: if it fixes it, the cause is a dependency between draws. Then narrow down: `glFlush` per draw → sync only at pass boundaries (`end`) → sync only before passes that sample textures rendered in the same CB (backdrop blit → blur → composite: texture rendered then sampled, `didRenderGL`/owner, `gpuCopy…` blit between FBOs). If it does NOT fix it: bisect the heavy trace by component (target readback / `surfaceCoherencyReport` / `glContentReport` / `glGetBufferSubData`).
2. Check that `TSMTL_SURFACE_UPLOAD` is really used in the card pass (stat per pass) before discarding it.
3. Fix `make test` (§15.1).
4. Clean-up before install: decide on knobs (keep them, they cost nothing); `make test`; snapshot; install via `system/install.sh` **run by the user**.
5. Workaround to offer the user until it is fixed: Chrome with `--disable-gpu-compositing` (correct pages, no acceleration).

## 17. My mistakes in session 2 (to avoid)

1. **Edit without Read again** (4 Edits failed at the start). No build was chained, so no damage. Rule: Read before Edit; never chain make.
2. `grep -E` with `(?!…)` under ugrep → regex error that hid the build output. Check build errors separately (`make || exit`).
3. `tail -n +$(wc -l)`: wc's leading spaces → `illegal offset`, empty trace file. Use `wc -l < f | tr -d ' '`.
4. Numeric comparison against a reference with a **different viewport** (warning bar only in the test instance): 10–46 % meaningless. Check sizes (`sips -g pixelHeight`) before comparing.
5. **False positive K1**: "correct" page that was software compositing. After every Chrome flag, check chrome://gpu (`Compositing:`) and that `stats/5s` lines exist.
6. `sed 's/0x[0-9a-f]+//'` also ate dimensions (`1400x960` → `140`). Remove only `=0x…:` pointers.
7. Trace log overwritten by the following runs: copy `apps/Google Chrome.log` into `exp/` right after every trace.
8. Too long reading code by hypothesis (TBO, ring, shift, variants) before having a deterministic repro. The decisive step was the minimal page + where each draw lands + root pass by pass: do that first.

# Session 3 — 2026-10-31 night: cause found and fixed

Supersedes §13's conclusion and §16. Everything is still **only in `src/` and `build/`** (system-wide driver is 0.4.0). Captures: `docs/findings-2026-10-31/b3/`. Backups of the files touched first: `backups/heavy-mask/`.

## 18. Cause: texture-buffer views keep reading re-specified storage (FIXED, verified)

- **Mechanism.** `-[TSMtlBuffer glBuffer]` re-specifies the GL buffer (`glBufferData`, "orphaning", so in-flight draws keep the old storage and nothing waits) when the whole buffer or more than half of it is dirty. On this AMD driver a **texture buffer (TBO) attached to that buffer can keep reading the old storage**. Dawn/Graphite does vertex pulling: per-instance data (rect, depth, `ssboIndex`) is read with `texelFetch` from the `<buf>_4` RGBA32UI TBO. Stale instance data ⇒ empty quads. The bf4 card content pass (tiles of the card) lost exactly 3 of its 8 tile draws (bi 2, 5, 10: `changed none`), and the cached card stayed wrong until the next re-raster.
- **Fix** (`src/TSMtlResources.m`): `_storageGen` is bumped on every `glBufferData`; `glTextureBuffer`/`glTextureBuffer4` call `glTexBuffer` again when the view has seen an older generation (cost: one `glTexBuffer` per re-specification, not per draw). Same for `MTLTextureTypeTextureBuffer` textures (`uploadGL`), which in addition **never refreshed** their buffer's GL copy before (latent bug: `canTransferPixels` = NO skipped them).
- **Knobs:** `TSMTL_NO_TBO_REATTACH=1` = old behaviour (A/B), `TSMTL_NO_ORPHAN=1` = `glBufferSubData` instead of re-specifying (also fixes it, but can stall on in-flight buffers).
- **Verified**
  - bf4, every card pass traced (`TSMTL_DRAW_TRACE_HEAVY=16`): 3 empty draws per pass from the 2nd/3rd pass on in every run (HV1–4, SB1, ND1, NR2) → **0 in all 10 passes** with `NO_ORPHAN` (NO1). Without trace, 8/8 captures correct with `NO_ORPHAN` (NO2), `TBO_REATTACH` (TR1) and the final default (FX1).
  - Site, 6 positions vs `refb` (noise ref/ref 0 / 1.7 / 3.6 / 0 / 0 / 0): before **7.76 / 11.18 / 10.22 / 30.33 / 10.55 / 12.78** (SB0); after **0.02 / 8.76 / 3.54–4.27 / 0.00 / 0.00 / 0.00** (FS1, FS2, SR1, SR2). Position 2 = whole page scrolled ~8 px (mask shows doubled outlines), not a rendering error. A/B `NO_TBO_REATTACH=1` (FS0): position 4 back to **37.93**, the historical broken value.
  - `make test`: 44/33/33/15/57/18/8 (§15.1 caveat still applies).
- Why §14's isolated test (`exp/tboorphan`) passed: it did not reproduce Chrome's pattern; the real trigger is not understood at driver level (texture-cache lines or the view caching the old storage). The fix does not depend on it.

## 19. How it was found (what actually worked)

1. `TSMTL_SYNC_DRAW=1` (glFinish per draw): still broken ⇒ not a missing wait. `TSMTL_PASS_END_SYNC=1|2|3` (glFinish / IOSurface lock at pass end): still broken.
2. The "heavy trace is correct" observation of §13 was **wrong in its interpretation**: the card pass is re-run on **every CDP capture** (`TSMTL_PASS_LOG=1`, timestamps vs `exp/shots-*.txt`), first `load2` then `load1`. Earlier traces covered only the first command buffers, so captures taken during the trace came from traced passes and later ones from untraced passes. Tracing the **whole run** (`TSMTL_DRAW_TRACE` file with 100000) showed the bug under the heavy trace too.
3. Per-draw `changed none` pointed at 3 draws. Then, one input class at a time, all identical between the good and the broken pass: encoded commands, GL state read back from GL (units, names, sizes, samplers), depth (`TSMTL_NO_DEPTH=1` still broken), IOSurface path (`TSMTL_NO_RECT=1` still broken, same 3 draws), buffer CPU contents in the card region (`buf-<hash>.bin` dumps), `setBytes` slot 30 (Dawn buffer lengths). What was left was how the shader reads the buffers: the TBO → `NO_ORPHAN` → fixed.

Lesson: **when every input is identical and the output differs, look at the path between input and shader (views, caches), not at the inputs again.** And: before trusting "under trace it works", check that the trace actually covers the pass that produced the captured picture.

## 20. Tools and knobs added in session 3 (zero cost when off)

- `TSMTL_DRAW_TRACE_HEAVY=<bits>` (1 = all, as before): 2 sampled-texture readback, 4 IOSurface coherence, 8 buffer CPU/GL compare, 16 target after each draw (`changed …`), 32 per-pass save with `TSMTL_DRAW_TRACE_DIR`.
- `TSMTL_DRAW_TRACE_DIR`: per-pass save now also covers private targets (`pass-NNNN-WxH[-ios].bmp`, `TSMtlDrawTraceSaveBMP`); every distinct bound-buffer content saved once as `buf-<fnv>.bin`.
- Trace lines now carry: IOSurface ID (`:ios#N`), FNV hash of each bound buffer (`#xxxxxxxx`), `setBytes` contents (`bytes(n)[w0,w1,…]`), real GL unit state (`uN=[R]name WxH sSampler/minFilter/wrapS`).
- `TSMTL_PASS_LOG=1`: one line per pass (wall clock, target size, load action). `TSMTL_SYNC_DRAW=1`, `TSMTL_PASS_END_SYNC=<1|2|4>`, `TSMTL_NO_DEPTH=1`: bisection only.
- `tools/chrome-passlog.sh <tag> [env…]` (bf4, timestamped captures), `tools/heavy-bisect.sh` (before/during/after a trace; `PRE=1` arms it at launch).

## 21. Next steps

1. Re-test the user's real browsing (site + others) with the build bundle; then **install via `system/install.sh`, run by the user** (bump the bundle version so `tsmtl status` shows it).
2. §15.1 (`make test` loads the installed driver) is still open.
3. ~~Optional clean-up~~: `exp/passes-*` deleted (2026-11-01); `exp/bufs-hv3` (59 MB) is still there.

**Update 2026-11-01:** §15.1 fixed — `phase1` no longer calls the system `MTLCreateSystemDefaultDevice()` (it loaded the installed bundle next to the build: duplicate classes); it checks with `dladdr` that the symbol still resolves to Metal.framework. `make test` 44/33/33/15/57/18/8 with no `implemented in both`. Bundle version 0.5.0; update with `system/update.sh` (preflight, then `install.sh --bundle`; `--revert` puts back the previous bundle only).

# Session 4 — 2026-11-01: pipeline creation cost (user: Chrome slow to load YouTube / the site)

## 22. Measurements and what was tried

Tool: `tools/chrome-loadbench.sh <tag> [env…]` (fresh test Chrome, YouTube 30 s, then the site 30 s) + `tools/loadsum.pl exp/log-<tag>.txt`. New stats (TSMTL_STATS): `pipeline create ms` (as the caller sees it), `link ms`, `warm-up ms`, `translate ms`, `variant links`, `programs drawn`, `pipeline sync ms` (GPU-queue time spent creating pipelines). `TSMTL_PIPE_LOG=1`: one line per pipeline (wall time, thread, rect slots).

Facts (warm translation cache; ~21 pipelines per load):
- Chrome creates **all** pipelines on worker threads (`ThreadPoolForegroundWorker`, Dawn async creation), each waits **0.6–0.85 s** on average (serial GPU queue: behind frames and the other pipelines). Real work per program: link ~50 ms + warm-up ~170 ms (driver hardware compile). GPU queue occupied by a load: 5.9–8.8 s, run-to-run noise ±25 % (YouTube content changes).
- Translation is negligible with a warm cache; a rebuild changes `TSAirTranslatorTag()`, so the first load after an update re-translates (~2 s).
- `TSMTL_NO_WARMUP=1`: total unchanged (4.05 vs 4.1 s): the compile just moves into the first frames. The warm-up is not duplicated work.
- ~27 % of linked programs were never drawn (base programs of pipelines that end up drawn with the rectangle variant, and vice versa).

Tried, measured, **not kept** (code of the last two in `backups/bg-compile-experiment/`):
| idea | result |
|---|---|
| base program linked on first need (lazy) | fewer links, but links/warm-ups mid-pass cost ~1.4× (flush of queued work): GPU queue 7.5 s vs 6.2 s |
| link on a shared GL context (compile queue) | pipelines ready **3× sooner** (avg 210 vs 650 ms), but the driver redoes per-context work at first use on the GPU context (+115 ms/program): GPU queue **~11 s vs ~6 s** |
| link the all-rectangles variant first (predict IOSurface use) | Chrome draws only ~half of rect pipelines with IOSurfaces: wasted variants + base programs linked mid-pass; 8.0 s vs 5.9–8.8 s, not better than noise |

Kept: original creation flow (link + warm-up at creation on the GPU queue) plus the instrumentation. Remaining levers (not done): smaller GLSL per program (compile time grows with shader size; A5 "compact GLSL"), fewer distinct programs (dedupe Dawn variants that differ only in constants). Driver program binaries do not exist (Phase 3b), so the ~200 ms/program per Chrome launch cannot be cached across launches.

