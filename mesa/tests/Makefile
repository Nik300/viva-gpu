# Builds the smoke test against out/macos (run ../build.sh macos first).
HERE := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
OUT ?= $(abspath $(HERE)/../out/macos)
CC ?= cc
CFLAGS := -O1 -g $(shell cat $(OUT)/cflags.txt)
LDFLAGS := $(shell cat $(OUT)/ldflags.txt)

all: smoke

smoke: smoke.c $(OUT)/lib/libmesa_viva.a
	$(CC) $(CFLAGS) -o $@ smoke.c $(LDFLAGS)

clean:
	rm -f smoke

.PHONY: all clean
