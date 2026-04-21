.PHONY: build test install wind

PREFIX ?= $(HOME)/.local

wind: tools/wind.d
	ldc2 -of=tools/wind tools/wind.d

build: wind
	time dub build --build=release

test:
	dub test

install: build
	mkdir -p $(PREFIX)/bin
	cp ground $(PREFIX)/bin/ground
	./ground attest
	./ground decay
