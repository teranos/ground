.PHONY: build test test-tools test-ug install install-ug wind ug book annot press binder editor

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

# ug is its own binary: no sqlite, no controls, no druntime. It is built by
# ldc2 directly because dub builds one target and that target is ground.
UG_SOURCES = ug/main.d ug/input.d ug/head.d ug/report.d \
             ug/clock.d ug/row.d ug/json.d ug/git.d ug/status.d \
             ug/sql.d ug/perf.d ug/qntx.d ug/probe.d ug/path.d ug/statusline.d \
             ug/tmux.d

# sqlite3 is the one library ug links. ground owns every row it reads; ug only
# ever issues SELECT.
ug: $(UG_SOURCES)
	ldc2 -betterC -of=ug/ug -I=ug $(UG_SOURCES) -L-lsqlite3 -L-L/usr/local/opt/sqlite/lib

test: test-tools test-ug
	dub test

# CTFE assertions in tools/*_test.d — failure shows as compile error.
test-tools:
	ldc2 -c -od=/tmp -I=tools tools/filelist.d tools/filelist_test.d
	ldc2 -c -od=/tmp -I=tools tools/cases.d tools/cases_test.d
	ldc2 -c -od=/tmp -I=tools tools/concept.d tools/concept_test.d
	ldc2 -c -od=/tmp -I=tools tools/bind.d tools/bind_test.d
	ldc2 -c -od=/tmp -I=tools tools/cases.d tools/edit.d tools/edit_test.d

# Same shape for ug/*_test.d.
test-ug:
	ldc2 -c -betterC -od=/tmp -I=ug ug/clock.d ug/clock_test.d
# -J=. lets row_test read captures/grove/out.bytes at CTFE, so parity is
# asserted against collet's own output rather than a transcription of it.
	ldc2 -c -betterC -J=. -od=/tmp -I=ug ug/json.d ug/json_test.d
	ldc2 -c -betterC -od=/tmp -I=ug ug/git.d ug/git_test.d
	ldc2 -c -betterC -od=/tmp -I=ug ug/status.d ug/status_test.d
	ldc2 -c -betterC -od=/tmp -I=ug ug/perf.d ug/perf_test.d
	ldc2 -c -betterC -od=/tmp -I=ug ug/perf.d ug/scan_test.d
	ldc2 -c -betterC -od=/tmp -I=ug ug/sql.d ug/sql_test.d
	ldc2 -c -betterC -od=/tmp -I=ug ug/qntx.d ug/json.d ug/qntx_test.d
	ldc2 -c -betterC -od=/tmp -I=ug ug/probe.d ug/qntx.d ug/json.d ug/probe_test.d
	ldc2 -c -betterC -od=/tmp -I=ug ug/path.d ug/path_test.d
	ldc2 -c -betterC -od=/tmp -I=ug ug/tmux.d ug/statusline.d ug/json.d ug/tmux_test.d
	ldc2 -c -betterC -J=. -od=/tmp -I=ug ug/row.d ug/clock.d ug/json.d ug/status.d ug/row_test.d

# The row runs from PREFIX, not from the checkout: a status line pointed at a
# build directory goes blank the moment that directory moves.
install-ug: ug
	mkdir -p $(PREFIX)/bin
	cp ug/ug $(PREFIX)/bin/ug

install: build install-ug
	mkdir -p $(PREFIX)/bin
	cp ground $(PREFIX)/bin/ground
	./ground attest
	./ground decay

# The book is generated from the source it documents, so it cannot describe a
# ground that does not exist. Every module is a chapter, and both comment kinds
# are prose: a ddoc pass writing the same paths overwrote what press extracted.
press: tools/press.d tools/cases.d tools/concept.d
	ldc2 -of=tools/press -I=tools tools/press.d tools/cases.d tools/concept.d

binder: tools/binder.d tools/bind.d
	ldc2 -of=tools/binder -I=tools tools/binder.d tools/bind.d

# The notes, editable in a browser and written back into the comment they came
# from. A note is found again by what it says, at the moment you save it, so
# nothing here stores a position that the next edit would make wrong.
editor: tools/editor.d tools/edit.d tools/cases.d tools/concept.d
	ldc2 -of=tools/editor -I=tools tools/editor.d tools/edit.d tools/cases.d tools/concept.d

# One typesetter, and the web copy is bound from what it set. Page 12 on the
# screen is the sheet carrying 12 on paper, because it is that sheet and not a
# second rendering of the same source.
book: press binder
	mkdir -p doc/tex
# press clears doc/tex itself, once it has proved every example fits a page.
# Clearing here meant a halt deleted the last good book on its way out.
	./tools/press
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
