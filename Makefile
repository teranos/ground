.PHONY: build test test-tools test-ug test-mcp install install-ug prune-dub-cache wind ug book annot press binder editor

PREFIX ?= $(HOME)/.local

# Every recipe runs with the compiler, dub and sqlite flake.lock pins, the ones
# CI and the releases build with. Homebrew's were x86_64 on an arm64 machine:
# the build ran under Rosetta, 35s against 14s native, and so did every hook.
# Outside the pinned shell make enters it and runs the same goals there.
# --profile roots that toolchain, since the installed ground loads its sqlite
# from the store and a garbage collection would otherwise take it away.
PINNED := $(findstring /nix/store/,$(shell command -v ldc2))
DEVSHELL := $(PREFIX)/lib/ground/devshell

ifeq ($(PINNED),)
GOALS := $(or $(MAKECMDGOALS),build)
.PHONY: $(GOALS)
$(firstword $(GOALS)):
	mkdir -p $(dir $(DEVSHELL))
	nix develop .#default --profile $(DEVSHELL) --command make $(GOALS)
ifneq ($(words $(GOALS)),1)
$(wordlist 2,$(words $(GOALS)),$(GOALS)):
	@:
endif
else

wind: tools/wind.d tools/filelist.d tools/openapi.d source/libgit2.d
	ldc2 -of=tools/wind -I=tools -I=source tools/wind.d tools/filelist.d tools/openapi.d source/libgit2.d -L-lgit2

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

# ug is its own binary: no sqlite, no controls, no druntime. It is built by
# ldc2 directly because dub builds one target and that target is ground.
UG_SOURCES = ug/main.d ug/input.d ug/head.d ug/report.d \
             ug/clock.d ug/row.d ug/json.d ug/git.d ug/status.d \
             ug/sql.d ug/perf.d ug/qntx.d ug/probe.d ug/path.d ug/statusline.d \
             ug/tmux.d ug/usage.d ug/fable.d source/sessionmodel.d source/libgit2.d source/costgate.d

# ground owns the schema and every row ug reads. ug writes one thing: the usage
# reading from its input, which no hook is handed, every four hours and once
# per new session. libgit2 reads the tree's status in its own process.
ug: $(UG_SOURCES)
	ldc2 -betterC -of=ug/ug -I=ug -I=source $(UG_SOURCES) -L-lsqlite3 -L-lgit2

test: test-tools test-ug test-mcp
	dub test

# ground's side of libmcp: the D binding's layout against the C, ground mcp
# against the library's test server, the harness dispatch, and ground code
# owning a session's servers. LIBMCP_SRC is the input's source; the devShell sets it.
MCP_LIBS = $(foreach f,$(shell pkg-config --libs libmcp json-c libcurl),-L$(f))
MCP_SERVER = LIBMCP_SERVER=$(LIBMCP_SRC)/tests/server.py
test-mcp: build
	test -n "$(LIBMCP_SRC)" || { echo "test-mcp: LIBMCP_SRC names no libmcp source; run under nix develop" >&2; exit 1; }
	mkdir -p build
	cc -c $(LIBMCP_SRC)/tests/abi.c $(shell pkg-config --cflags libmcp) -o build/abi.o
	ldc2 -betterC -I=source -of=build/abi-test mcp/abi.d build/abi.o $(MCP_LIBS)
	build/abi-test
	ldc2 -betterC -I=source -of=build/mcp-client mcp/client.d source/mcpcmd.d $(MCP_LIBS)
	$(MCP_SERVER) python3 mcp/test_d.py build/mcp-client
	ldc2 -betterC -I=source -of=build/mcp-harness mcp/harness.d source/code/mcp.d source/code/reply.d source/libjsonc.d $(MCP_LIBS)
	$(MCP_SERVER) python3 mcp/test_harness.py build/mcp-harness
	$(MCP_SERVER) python3 mcp/test_ground.py ./ground

# CTFE assertions in tools/*_test.d — failure shows as compile error.
test-tools:
	ldc2 -c -od=/tmp -I=tools tools/filelist.d tools/filelist_test.d
	ldc2 -c -od=/tmp -I=tools tools/cases.d tools/cases_test.d
	ldc2 -c -od=/tmp -I=tools tools/concept.d tools/concept_test.d
	ldc2 -c -od=/tmp -I=tools -J=doc tools/bind.d tools/bind_test.d
# -J=doc lets the book's own preamble be read at CTFE, so a face the machine
# resolves rather than the closure fails the build instead of the tag.
	ldc2 -c -od=/tmp -I=tools -J=doc tools/typeset.d tools/typeset_test.d
	ldc2 -c -od=/tmp -I=tools tools/cases.d tools/edit.d tools/edit_test.d
	ldc2 -c -od=/tmp -I=tools -I=source -J=doc tools/editor.d tools/edit.d tools/cases.d tools/concept.d source/fmt.d tools/editor_test.d
	ldc2 -c -od=/tmp -I=tools tools/openapi.d tools/openapi_test.d
	ldc2 -c -od=/tmp -I=tools -I=source tools/press.d tools/cases.d tools/concept.d source/fmt.d tools/press_test.d

# Same shape for ug/*_test.d.
test-ug:
	ldc2 -c -betterC -od=/tmp -I=ug ug/clock.d ug/clock_test.d
	ldc2 -c -betterC -od=/tmp -I=ug ug/json.d ug/json_test.d
	ldc2 -c -betterC -od=/tmp -I=ug -I=source ug/git.d ug/git_test.d
	ldc2 -c -betterC -od=/tmp -I=ug ug/status.d ug/status_test.d
	ldc2 -c -betterC -od=/tmp -I=ug ug/perf.d ug/perf_test.d
	ldc2 -c -betterC -od=/tmp -I=ug ug/perf.d ug/scan_test.d
	ldc2 -c -betterC -od=/tmp -I=ug ug/sql.d ug/sql_test.d
	ldc2 -c -betterC -od=/tmp -I=ug ug/qntx.d ug/json.d ug/qntx_test.d
	ldc2 -c -betterC -od=/tmp -I=ug ug/probe.d ug/qntx.d ug/json.d ug/probe_test.d
	ldc2 -c -betterC -od=/tmp -I=ug ug/path.d ug/path_test.d
	ldc2 -c -betterC -od=/tmp -I=ug ug/tmux.d ug/statusline.d ug/json.d ug/tmux_test.d
	ldc2 -c -betterC -od=/tmp -I=ug -I=source ug/usage.d source/sessionmodel.d ug/usage_test.d
	ldc2 -c -betterC -od=/tmp -I=ug ug/fable.d ug/json.d ug/statusline.d ug/probe.d ug/qntx.d ug/fable_test.d

# ug the way Claude Code runs it: frames cancelled mid-run, against a QNTX that
# never answers. Not part of make test, because it waits on curl's timeout.
test-ug-live: build ug
	ldc2 -betterC -of=/tmp/ug-live-test ug/live_test.d -L-lsqlite3
	/tmp/ug-live-test ug/ug ./ground

# The row runs from PREFIX, not from the checkout: a status line pointed at a
# build directory goes blank the moment that directory moves.
#
# A binary is renamed into place, never copied over the one already there. cp
# onto an existing file keeps its inode. On 2026-09-14, arm64 macOS: the ground
# cp wrote over the running one was SIGKILLed on every launch, codesign said
# valid, and the same bytes copied to a new inode ran.
install-ug: ug
	mkdir -p $(PREFIX)/bin
	cp ug/ug $(PREFIX)/bin/ug.new
	mv -f $(PREFIX)/bin/ug.new $(PREFIX)/bin/ug

install: build install-ug
	mkdir -p $(PREFIX)/bin
	cp ground $(PREFIX)/bin/ground.new
	mv -f $(PREFIX)/bin/ground.new $(PREFIX)/bin/ground
# The ACP schemas flake.nix pins, linked from the store; the link roots them
# against a garbage collection. ground parity reads them under ~/.local, so a
# PREFIX elsewhere shows the schema as absent rather than measuring another.
	mkdir -p $(PREFIX)/lib/ground
	nix build .#acp-schemas --out-link $(PREFIX)/lib/ground/acp
	$(MAKE) prune-dub-cache
	./ground attest
# Every install is a run of parity, so the series has a point per ground built.
	./ground parity
	./ground decay

# dub keys its cache by version and every commit is a version: 129 builds, 18G.
DUB_CACHE := $(HOME)/.dub/cache/ground
prune-dub-cache:
	ls -td $(DUB_CACHE)/*/ | tail -n +4 | xargs rm -rf

# The book is generated from the source it documents, so it cannot describe a
# ground that does not exist. Both comment kinds are prose: a // line and a
# /// line reach the page alike.
press: tools/press.d tools/cases.d tools/concept.d source/fmt.d
	ldc2 -of=tools/press -I=tools -I=source tools/press.d tools/cases.d tools/concept.d source/fmt.d

# -J=doc lets bind.d carry doc/book.css, so the stylesheet is a file to read
# and the pages still stand on their own.
binder: tools/binder.d tools/bind.d doc/tokens.css doc/book.css
	ldc2 -of=tools/binder -I=tools -J=doc tools/binder.d tools/bind.d

# The notes, editable in a browser and written back into the comment they came
# from. A note is found again by what it says, at the moment you save it, so
# nothing here stores a position that the next edit would make wrong.
editor: tools/editor.d tools/edit.d tools/cases.d tools/concept.d source/fmt.d doc/tokens.css doc/author.css
	ldc2 -of=tools/editor -I=tools -I=source -J=doc tools/editor.d tools/edit.d tools/cases.d tools/concept.d source/fmt.d

# One typesetter, and the web copy is bound from what it set. Page 12 on the
# screen is the sheet carrying 12 on paper, because it is that sheet and not a
# second rendering of the same source.
book: press binder build
	mkdir -p doc/tex doc/measured
# press clears doc/tex itself, once it has proved every example fits a page.
# Clearing here meant a halt deleted the last good book on its way out.
	./tools/press
# What this ground measured, read out of the store: the parity table as it
# stands and the series of every run before it.
	./ground parity tex > doc/measured/parity.tex
	rm -f doc/html/*.html
# B5, and the margin is only what keeps the ink off the edge.
	@printf '%s\n' \
	  "\\usepackage[paperwidth=176mm,paperheight=250mm," \
	  "            inner=20mm,outer=16mm,top=18mm,bottom=20mm]{geometry}" \
	  > doc/edition.tex
	@printf '%s\n' \
	  "\\newcommand{\\groundcommit}{`git rev-parse --short HEAD`}" \
	  "\\newcommand{\\groundbuilt}{`date -u +%Y-%m-%dT%H:%M:%SZ`}" \
	  "\\newcommand{\\groundapi}{Claude Code hooks}" \
	  > doc/provenance.tex
	cd doc && latexmk -xelatex -silent -interaction=nonstopmode -jobname=book book.tex
	GROUND_COMMIT=`git rev-parse --short HEAD` \
	GROUND_BUILT=`date -u +%Y-%m-%dT%H:%M:%SZ` \
	./tools/binder

# The annotation copy. A4, and the 70mm outer margin is the whole point of it:
# a column to write in beside every row, down every page. No web copy — this
# edition is read on paper or not at all.
annot: press
	mkdir -p doc/tex
	./tools/press
	@printf '%s\n' \
	  "\\usepackage[paperwidth=210mm,paperheight=297mm," \
	  "            inner=20mm,outer=70mm,top=18mm,bottom=20mm]{geometry}" \
	  > doc/edition.tex
	@printf '%s\n' \
	  "\\newcommand{\\groundcommit}{`git rev-parse --short HEAD`}" \
	  "\\newcommand{\\groundbuilt}{`date -u +%Y-%m-%dT%H:%M:%SZ`}" \
	  "\\newcommand{\\groundapi}{Claude Code hooks}" \
	  > doc/provenance.tex
# Its own jobname, so the two editions cannot overwrite each other. The folio
# map is named after the job already, so it follows without being told.
	cd doc && latexmk -xelatex -silent -interaction=nonstopmode -jobname=annot book.tex
	@echo "annot: doc/annot.pdf is the A4 annotation copy"

endif
