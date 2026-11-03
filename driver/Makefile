# Viva Metal driver (macOS build for tests: llvmpipe, and Panfrost on the vgpu mock).
# Needs ../mesa/out/macos (mesa/build.sh macos).
CC        = clang
MESA      = ../mesa/out/macos
MESA_CF   = $(filter-out -std=%,$(shell cat $(MESA)/cflags.txt))
MESA_LD   = $(shell cat $(MESA)/ldflags.txt)
CFLAGS    = -O1 -g -Wall -Wno-unused-function -Wno-four-char-constants -DVMG_HAVE_LLVMPIPE=1 $(MESA_CF) -I.
OUT       = out/macos
C_SRC     = vmg_air.c vmg_screen.c vmg_exec.c
M_SRC     = vmg_formats.m
OBJ       = $(addprefix $(OUT)/,$(C_SRC:.c=.o) $(M_SRC:.m=.o))
HDR       = vmg.h vmg_internal.h vmg_llvm.h

all: $(OUT)/libvmg.a $(OUT)/test_vmg $(OUT)/airnir

$(OUT)/%.o: %.c $(HDR)
	@mkdir -p $(OUT)
	@$(CC) -std=gnu11 $(CFLAGS) -c $< -o $@

$(OUT)/%.o: %.m $(HDR)
	@mkdir -p $(OUT)
	@$(CC) -fobjc-arc $(CFLAGS) -c $< -o $@

$(OUT)/libvmg.a: $(OBJ)
	rm -f $@
	@libtool -static -o $@ $(OBJ) 2>/dev/null

$(OUT)/test_vmg: tests/test_vmg.c $(OUT)/libvmg.a
	@$(CC) -std=gnu11 $(CFLAGS) $< $(OUT)/libvmg.a $(MESA_LD) -framework Foundation -framework Metal -o $@

test: $(OUT)/test_vmg
	$(OUT)/test_vmg llvmpipe
	VGPU_BACKEND=mock $(OUT)/test_vmg panfrost

clean:
	rm -rf out
.PHONY: all test clean

$(OUT)/airnir: tools/airnir.m $(OUT)/libvmg.a
	@$(CC) -fobjc-arc $(CFLAGS) $< $(OUT)/libvmg.a $(MESA_LD) -framework Foundation -framework Metal -o $@

# The Metal driver (Objective-C on vmg) as a dylib for tests, exporting TSMtlCreateDevice so metal-shim's tests
# run unchanged.
SHIM      = ../shim
M_DRV     = $(wildcard metal/*.m)
M_HDR     = metal/VMPrivate.h metal/TSLog.h vmg.h
OBJC      = -fobjc-arc -O1 -g -Wall -Wno-unused-function -Wno-deprecated-declarations -Imetal -DTS_SOURCE_DIR=\"$(abspath $(SHIM))\"
FRAMEWORKS = -framework Foundation -framework Metal -framework IOSurface -framework IOKit -framework QuartzCore -framework CoreGraphics

$(OUT)/libVivaMetal.dylib: $(M_DRV) $(M_HDR) $(OUT)/libvmg.a
	@$(CC) $(OBJC) -dynamiclib -install_name @rpath/libVivaMetal.dylib $(M_DRV) $(OUT)/libvmg.a $(MESA_LD) $(FRAMEWORKS) -o $@

SHIM_TESTS = phase1 phase3 translate uploads
$(OUT)/phase3: $(SHIM)/tests/phase2.m $(OUT)/libVivaMetal.dylib
	@$(CC) $(OBJC) -DTS_TRANSLATED -I$(SHIM)/src $< -L$(OUT) -lVivaMetal -Wl,-rpath,@executable_path $(FRAMEWORKS) -framework Cocoa -o $@
$(OUT)/phase1 $(OUT)/translate $(OUT)/uploads: $(OUT)/%: $(SHIM)/tests/%.m $(OUT)/libVivaMetal.dylib
	@$(CC) $(OBJC) -I$(SHIM)/src $< -L$(OUT) -lVivaMetal -Wl,-rpath,@executable_path $(FRAMEWORKS) -framework Cocoa -o $@

metal: $(OUT)/libVivaMetal.dylib $(addprefix $(OUT)/,$(SHIM_TESTS)) $(OUT)/compute
test-metal: metal
	@for t in $(SHIM_TESTS); do echo "== $$t (llvmpipe)"; $(OUT)/$$t | tail -2 || exit 1; done
$(OUT)/compute: tests/compute.m $(OUT)/libVivaMetal.dylib
	@$(CC) $(OBJC) $< -L$(OUT) -lVivaMetal -Wl,-rpath,@executable_path $(FRAMEWORKS) -o $@
