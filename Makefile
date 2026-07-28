.PHONY: build test test-tools install wind

PREFIX ?= $(HOME)/.local

wind: tools/wind.d tools/filelist.d
	ldc2 -of=tools/wind -I=tools tools/wind.d tools/filelist.d

# build uses the "production" configuration, which excludes source/*_test.d.
# Those files are static assert, not unittest, so they evaluate at CTFE in every
# build including release. Measured 2026-07-28 with ldc2 -ftime-trace: semantic
# analysis was 221s of a 311s release build, and __equals over by-value
# ParseResult copies inside the test modules was 107s of that on its own.
# Excluding them took the release build from 311s to 12s.
#
# The assertions still run. They run under make test, which uses the default
# "application" configuration with every source file included. Defining the
# exclusion as a separate config rather than as the default is deliberate:
# dub test derives its build from the default configuration, so excluding the
# tests there would have silently stopped testing them.
#
# To measure a build: /usr/bin/time -l make build (-v on Linux).
#
# Measured 2026-07-28, production config, same machine:
#   plain      11.66s   532 MiB peak
#   --lowmem   13.67s   335 MiB peak
#
# --lowmem is on, in dub.json. It puts the LDC frontend under a GC so CTFE
# arenas get collected rather than growing monotonically. 2s against a 60s
# bar is cheap; 37% off peak is not, on an 8GB machine, on the axis that
# took the machine down on 2026-07-27. CTFE memory also scales with the
# control set, and that set grows every time a repo comes under ground:
# 891 files from 8 projects as of this measurement.
#
# Revisit if build time ever approaches the bar. Memory is the cheaper
# thing to spend right now; time is not.
build: wind
	dub build --build=release --config=production

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
