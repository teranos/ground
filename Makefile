.PHONY: build test install ui ui-dev

PREFIX ?= $(HOME)/.local
build:
	dub build --build=release

test:
	dub test

install: build
	mkdir -p $(PREFIX)/bin
	cp graunde $(PREFIX)/bin/graunde

ui:
	cd ui && bun install --frozen-lockfile && cargo tauri build

ui-dev:
	cd ui && bun install && cargo tauri dev

ui-mock:
	cd ui && bun run build && cd dist && python3 -m http.server 3100
