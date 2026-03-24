.PHONY: build test install

PREFIX ?= $(HOME)/.local
build:
	time dub build --build=release

test:
	dub test

install: build
	mkdir -p $(PREFIX)/bin
	cp graunde $(PREFIX)/bin/graunde
