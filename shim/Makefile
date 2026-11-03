# TeraScale Metal Shim
CC      = clang
# The translator's revision (hash of its sources) keys the GLSL caches and the precompiled .mslbundle files:
# builds of the same translator share them.
TRANSLATOR_REV := $(shell cat src/TSAirTranslator.m src/TSLLVM.h | shasum | cut -c1-12)
CFLAGS  = -fobjc-arc -O1 -g -Wall -Wno-unused-function -mmacosx-version-min=26.0 -DTS_SOURCE_DIR=\"$(CURDIR)\" \
          -DTS_TRANSLATOR_REV=\"$(TRANSLATOR_REV)\"
FRAMEWORKS = -framework Foundation -framework Metal -framework OpenGL -framework IOSurface -framework IOKit -framework QuartzCore
BUILD   = build
SRC     = $(wildcard src/*.m)
HEADERS = $(wildcard src/*.h)

BUNDLE  = $(BUILD)/TeraScaleMTLDriver.bundle

# TeraScale Compute's CL runtime is part of the core; OpenCL itself is loaded with dlopen (TS_CL_DYNAMIC).
CORE_CL_SRC = src/compute/TSCLRuntime.c
CORE_CL     = $(CORE_CL_SRC) src/compute/TSCLRuntime.h src/compute/TSCLApi.h
# TeraScale Swift's accelerator (plain C, docs/OTTIMIZZAZIONE-SWIFT.md) is part of the core too; src/TSSwift.m starts it.
CORE_SWIFT_SRC = src/swift/TSSwiftAccel.c
CORE_SWIFT     = src/swift/TSSwiftAccel.h

TESTS   = phase1 phase2 phase3 translate cfg uploads

TOOLS   = tools/airtrans tools/airdump tools/mslbundle tools/glassgen tools/caglass tools/rbglass tools/cltrans tools/winid tools/sheet tools/imgdiff tools/mouse tools/keys tools/scroll

all: $(BUILD)/libTSMetal.dylib $(BUILD)/libTSMetalInject.dylib $(BUNDLE) $(BUILD)/libTSSwift.dylib $(BUILD)/libTSEntSpoof.dylib $(addprefix $(BUILD)/,$(TESTS)) $(BUILD)/window $(TOOLS)

# Developer tools (tools/*.m): airtrans/airdump link the shim from build/.
tools/airtrans tools/airdump tools/mslbundle tools/glassgen: tools/%: tools/%.m $(BUILD)/libTSMetal.dylib
	$(CC) $(CFLAGS) -Isrc $(FRAMEWORKS) -L$(BUILD) -lTSMetal -Wl,-rpath,$(CURDIR)/$(BUILD) $< -o $@
# CoreAnimation's Metal renderer (CARenderer) on the shim: AppKit glass materials rendered in-process.
tools/caglass: tools/caglass.m
	$(CC) $(CFLAGS) $(FRAMEWORKS) -framework Cocoa -framework UniformTypeIdentifiers $< -o $@
# SwiftUI glass drawn by RenderBox in-process (Spotlight's path).
tools/rbglass: tools/rbglass.swift
	swiftc -parse-as-library -O $< -o $@
# TeraScale Compute: AIR kernels -> OpenCL C, optionally built on the GPU.
tools/cltrans: tools/cltrans.m $(BUILD)/libTSMetal.dylib
	$(CC) $(CFLAGS) -Isrc $(FRAMEWORKS) -framework OpenCL -L$(BUILD) -lTSMetal -Wl,-rpath,$(CURDIR)/$(BUILD) $< -o $@
# Window ids and synthetic input for app tests (mouse/keys/scroll post real events: hover, panning).
tools/winid tools/mouse tools/keys tools/scroll: tools/%: tools/%.m
	$(CC) $(CFLAGS) -framework Foundation -framework CoreGraphics $< -o $@
tools/sheet tools/imgdiff: tools/%: tools/%.m
	$(CC) $(CFLAGS) -framework Foundation -framework CoreGraphics -framework ImageIO -framework CoreText -framework UniformTypeIdentifiers $< -o $@

# Phase 4: the driver bundle Metal.framework loads from /Library/GPUBundles (docs/FASE4-INTERFACCE.md).
$(BUNDLE): $(SRC) $(HEADERS) $(CORE_CL) system/TeraScaleMTLDriver-Info.plist
	@mkdir -p $@/Contents/MacOS
	$(CC) $(CFLAGS) -DTS_CL_DYNAMIC -bundle $(FRAMEWORKS) $(SRC) $(CORE_CL_SRC) -o $@/Contents/MacOS/TeraScaleMTLDriver
	rm -rf $(BUNDLE).dSYM && mv $@/Contents/MacOS/TeraScaleMTLDriver.dSYM $(BUNDLE).dSYM
	sed "s/BUILD_VERSION/$$(date +%Y%m%d.%H%M)/" system/TeraScaleMTLDriver-Info.plist > $@/Contents/Info.plist
	codesign -s - -f $@

$(BUILD)/libTSMetal.dylib: $(SRC) $(HEADERS) $(CORE_CL)
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -DTS_CL_DYNAMIC -dynamiclib -install_name @rpath/libTSMetal.dylib $(FRAMEWORKS) $(SRC) $(CORE_CL_SRC) -o $@

# Self-contained shim + MTLCreateSystemDefaultDevice/MTLCopyAllDevices interposer (DYLD_INSERT_LIBRARIES).
# Test-only: answers Apple-only entitlement checks inside an ad-hoc re-signed copy (tools/shim-run.sh --fake-entitlements).
$(BUILD)/libTSEntSpoof.dylib: tools/entspoof.m
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -dynamiclib -framework Foundation -framework Security tools/entspoof.m -o $@

$(BUILD)/libTSMetalInject.dylib: $(SRC) $(HEADERS) $(CORE_CL)
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) -DTS_CL_DYNAMIC -dynamiclib -install_name @rpath/libTSMetalInject.dylib $(FRAMEWORKS) -framework CoreGraphics $(SRC) $(CORE_CL_SRC) -o $@

$(BUILD)/phase3: tests/phase2.m $(BUILD)/libTSMetal.dylib
	$(CC) $(CFLAGS) -DTS_TRANSLATED -Isrc $(FRAMEWORKS) -L$(BUILD) -lTSMetal -Wl,-rpath,@executable_path $< -o $@

$(BUILD)/%: tests/%.m $(BUILD)/libTSMetal.dylib
	$(CC) $(CFLAGS) -Isrc $(FRAMEWORKS) -framework Cocoa -framework QuartzCore -L$(BUILD) -lTSMetal -Wl,-rpath,@executable_path $< -o $@

# TeraScale Glass lab: CGLCreateContext interposer for a lab copy of tools/caglass named WindowServer.
$(BUILD)/libTSGlassLab.dylib: tests/glass/lab.c
	$(CC) -O1 -g -Wall -DGL_SILENCE_DEPRECATION -Wno-deprecated-declarations -dynamiclib -framework OpenGL $< -o $@
# The app side in an AppKit process without its NSApplication and denied WindowServer (Chrome's GPU helper).
$(BUILD)/glasshelper: tests/glass/helper.m
	$(CC) $(CFLAGS) -framework Foundation -framework AppKit -framework CoreGraphics $< -o $@

# Phase 4: Metal.framework's own discovery of the bundle, simulated (tests/system/regsim.m).
$(BUILD)/libTSRegSim.dylib: tests/system/regsim.m
	$(CC) $(CFLAGS) -dynamiclib -framework Foundation -framework IOKit $< -o $@
$(BUILD)/systest: tests/system/systest.m
	$(CC) $(CFLAGS) -framework Foundation -framework Metal -framework CoreGraphics -framework IOKit $< -o $@

test: all $(BUILD)/libTSRegSim.dylib $(BUILD)/systest
	@for t in $(TESTS); do echo "== $$t"; $(BUILD)/$$t || exit 1; done
	@echo "== system"; tests/system/run.sh

# TeraScale Compute (docs/PIANO-COMPUTE.md): OpenCL probes (C0) and the extension's CL runtime (src/compute,
# not part of the core: the core's SRC wildcard does not descend into src/compute).
COMPUTE_SRC    = $(wildcard src/compute/*.c)
COMPUTE_PROBES = $(addprefix $(BUILD)/,clprobe clinterop roundtrip clcost bufcoherence clruntime glkernels ctest libTSCLProbe.dylib clprobe-hardened \
                 vramplace dispatchbench)
CL_FRAMEWORKS  = -framework Foundation -framework OpenGL -framework OpenCL -framework IOSurface -framework QuartzCore
compute: $(COMPUTE_PROBES)
$(BUILD)/clprobe: tests/compute/clprobe.c
	@mkdir -p $(BUILD)
	$(CC) -O1 -g -Wall -framework OpenCL $< -o $@
# G3: placement of CL-only buffers under VRAM pressure (default / ALLOC_HOST_PTR / USE_HOST_PTR).
$(BUILD)/vramplace: tests/compute/vramplace.c
	@mkdir -p $(BUILD)
	$(CC) -O1 -g -Wall -framework OpenCL -framework IOKit -framework CoreFoundation $< -o $@
$(BUILD)/clinterop: tests/compute/interop.m
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(CL_FRAMEWORKS) $< -o $@
$(BUILD)/roundtrip $(BUILD)/clcost $(BUILD)/bufcoherence: $(BUILD)/%: tests/compute/%.m
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(CL_FRAMEWORKS) $< -o $@
$(BUILD)/clruntime: tests/compute/runtime.m $(COMPUTE_SRC) src/compute/TSCLRuntime.h
	@mkdir -p $(BUILD)
	$(CC) $(CFLAGS) $(CL_FRAMEWORKS) tests/compute/runtime.m $(COMPUTE_SRC) -o $@
# C0.2: the runtime inside an app (shim-run.sh --cl-probe) and as a hardened, sandboxed executable.
$(BUILD)/libTSCLProbe.dylib: tests/compute/clprobe-inject.m $(COMPUTE_SRC) src/compute/TSCLRuntime.h
	$(CC) $(CFLAGS) -dynamiclib $(CL_FRAMEWORKS) tests/compute/clprobe-inject.m $(COMPUTE_SRC) -o $@
$(BUILD)/clprobe-hardened: tests/compute/clprobe-inject.m $(COMPUTE_SRC) src/compute/TSCLRuntime.h tests/compute/sandbox-app.entitlements \
                           tests/compute/clprobe-Info.plist
	$(CC) $(CFLAGS) -DTS_PROBE_EXECUTABLE $(CL_FRAMEWORKS) -Wl,-sectcreate,__TEXT,__info_plist,tests/compute/clprobe-Info.plist \
	    tests/compute/clprobe-inject.m $(COMPUTE_SRC) -o $@
	codesign -s - -f -o runtime -i com.terascale.clprobe --entitlements tests/compute/sandbox-app.entitlements $@
# GL path of the core: kernels that work as fragment shaders, through the real device (libTSMetal).
# dispatchbench: per-dispatch cost of the OpenCL path (A/B between builds: it loads the libTSMetal next to it).
$(BUILD)/glkernels $(BUILD)/ctest $(BUILD)/dispatchbench: $(BUILD)/%: tests/compute/%.m $(BUILD)/libTSMetal.dylib
	$(CC) $(CFLAGS) -Isrc $(FRAMEWORKS) -L$(BUILD) -lTSMetal -Wl,-rpath,@executable_path $< -o $@
# Handoff correctness (runtime, buffers, textures, 10.000-dispatch stress) on the real GPU; C1 adds the policy cases.
test-compute: $(BUILD)/clruntime $(BUILD)/bufcoherence $(BUILD)/glkernels $(BUILD)/ctest $(BUILD)/dispatchbench tools/cltrans
	@echo "== GL path, compute off"; $(BUILD)/glkernels --off | tail -1
	@echo "== GL path"; $(BUILD)/glkernels | grep -v "^  ok"
	@echo "== OpenCL path, compute off"; $(BUILD)/ctest --off | tail -1
	@echo "== OpenCL path"; $(BUILD)/ctest | grep -v "^  ok"
	@echo "== OpenCL translation of the corpus"; tools/cltrans tests/compute/kernels.metal --build --quiet | tail -1
	@echo "== compute runtime"; $(BUILD)/clruntime 200 > /dev/null && echo ok || { $(BUILD)/clruntime 200; exit 1; }
	@echo "== buffer coherence"; $(BUILD)/bufcoherence 20
	@echo "== OpenCL dispatch cost and completion"; TSMTL_STATS=1 $(BUILD)/dispatchbench 5 | grep -v "^gpu:"
	@echo "== idle release of the CL context"; TSMTL_CL_IDLE=2 $(BUILD)/ctest --idle | tail -1

# TeraScale Glass (docs/PIANO-GLASS.md): Apple's glass shaders for Moraea, composed with Moraea's shaders and compared
# with the Metal renderer in the lab (a caglass copy named WindowServer).
test-glass: all $(BUILD)/libTSGlassLab.dylib $(BUILD)/glasshelper
	@tests/glass/lab.sh
	@tests/glass/helper.sh

# TeraScale Swift (docs/OTTIMIZZAZIONE-SWIFT.md): the accelerator alone, injectable (DYLD_INSERT_LIBRARIES), and the
# validation corpus: runtime alone, accelerator in validation mode and accelerator alone must answer the same.
$(BUILD)/libTSSwift.dylib: tests/swift/inject.c
	@mkdir -p $(BUILD)
	$(CC) -O2 -g -Wall -dynamiclib -lobjc tests/swift/inject.c -o $@
test-swift: $(BUILD)/libTSSwift.dylib $(BUNDLE)
	@echo "== validation corpus"; tests/swift/run.sh
	@echo "== driver bundle: policy and log"; tests/swift/bundle.sh

# Phase 4 kext (Lilu plugin), built with the vendored Lilu 1.7.1 SDK and MacKernelSDK.
kext:
	kext/build.sh

clean:
	rm -rf $(BUILD)

.PHONY: all test clean kext compute test-compute test-glass test-swift
