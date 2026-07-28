.PHONY: build test test-tools install wind

PREFIX ?= $(HOME)/.local

wind: tools/wind.d tools/filelist.d
	tools/capped ldc2 -of=tools/wind -I=tools tools/wind.d tools/filelist.d

# tools/capped holds a memory ceiling and reports the peak; see the header there
# for why an unbounded build is not an option on this machine.
#
# build uses the "production" configuration, which excludes source/*_test.d.
# Those files are static assert, not unittest, so they evaluate at CTFE in every
# build including release. Measured 2026-07-28 with ldc2 -ftime-trace: semantic
# analysis was 221s of a 311s release build, and __equals over by-value
# ParseResult copies inside the test modules was 107s of that on its own.
# Excluding them took the release build from 311s to 44s.
#
# The assertions still run. They run under make test, which uses the default
# "application" configuration with every source file included. Defining the
# exclusion as a separate config rather than as the default is deliberate:
# dub test derives its build from the default configuration, so excluding the
# tests there would have silently stopped testing them.
build: wind
	tools/capped dub build --build=release --config=production

test: test-tools
	tools/capped dub test

# CTFE assertions in tools/*_test.d — failure shows as compile error.
test-tools:
	tools/capped ldc2 -c -od=/tmp -I=tools tools/filelist.d tools/filelist_test.d

install: build
	mkdir -p $(PREFIX)/bin
	cp ground $(PREFIX)/bin/ground
	./ground attest
	./ground decay
