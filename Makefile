.PHONY: build test test-tools install wind

PREFIX ?= $(HOME)/.local

wind: tools/wind.d tools/filelist.d
	ldc2 -of=tools/wind -I=tools tools/wind.d tools/filelist.d

build: wind
	time dub build --build=release

test: test-tools
	dub test

# CTFE assertions in tools/*_test.d — failure shows as compile error.
test-tools:
	ldc2 -c -od=/tmp -I=tools tools/filelist.d tools/filelist_test.d

install: build
	mkdir -p $(PREFIX)/bin
	cp ground $(PREFIX)/bin/ground
	./ground attest
	./ground decay
