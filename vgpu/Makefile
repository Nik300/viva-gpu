# Viva GPU userspace client. `make` builds the static library and the self-test for the Mac (mock back-end).
CC      = clang
CFLAGS  = -O2 -g -Wall -Wextra -Wno-unused-parameter -Wno-four-char-constants -std=gnu11
OUT     = out/macos
SRC     = vgpu.c vgpu_mock.c vgpu_iokit.c

all: $(OUT)/libvgpu.a $(OUT)/test_vgpu

$(OUT)/libvgpu.a: $(SRC) vgpu.h ../uapi/viva_gpu_uapi.h
	@mkdir -p $(OUT)/obj
	for f in $(SRC); do $(CC) $(CFLAGS) -c $$f -o $(OUT)/obj/$${f%.c}.o || exit 1; done
	libtool -static -o $@ $(OUT)/obj/*.o

$(OUT)/test_vgpu: test_vgpu.c $(OUT)/libvgpu.a
	$(CC) $(CFLAGS) $< $(OUT)/libvgpu.a -framework IOKit -framework IOSurface -framework CoreFoundation -o $@

test: $(OUT)/test_vgpu
	$(OUT)/test_vgpu

clean:
	rm -rf out
.PHONY: all test clean
