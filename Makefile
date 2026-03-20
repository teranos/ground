.PHONY: build test install tower tower-dev

PREFIX ?= $(HOME)/.local
build:
	dub build --build=release

test:
	dub test

install: build
	mkdir -p $(PREFIX)/bin
	cp graunde $(PREFIX)/bin/graunde

tower:
	cd tower && bun install --frozen-lockfile && cargo tauri build

tower-dev:
	cd tower && bun install && cargo tauri dev
