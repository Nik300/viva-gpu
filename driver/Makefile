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

all: $(OUT)/libvmg.a $(OUT)/test_vmg

$(OUT)/%.o: %.c $(HDR)
	@mkdir -p $(OUT)
	$(CC) -std=gnu11 $(CFLAGS) -c $< -o $@

$(OUT)/%.o: %.m $(HDR)
	@mkdir -p $(OUT)
	$(CC) -fobjc-arc $(CFLAGS) -c $< -o $@

$(OUT)/libvmg.a: $(OBJ)
	rm -f $@
	libtool -static -o $@ $(OBJ) 2>/dev/null

$(OUT)/test_vmg: tests/test_vmg.c $(OUT)/libvmg.a
	$(CC) -std=gnu11 $(CFLAGS) $< $(OUT)/libvmg.a $(MESA_LD) -framework Foundation -framework Metal -o $@

test: $(OUT)/test_vmg
	$(OUT)/test_vmg llvmpipe
	VGPU_BACKEND=mock $(OUT)/test_vmg panfrost

clean:
	rm -rf out
.PHONY: all test clean
