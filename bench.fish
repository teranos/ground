#!/usr/bin/env fish
# Benchmark CTFE compile time with varying control counts.
# Generates a temporary pbt file, builds, measures time, removes it.
#
# Scaling limits (pool-based ParseResult, 2026-04-04, Apple M-series):
#
#   Controls  Build time  Status
#   300       9s          OK
#   1,400     9s          OK
#   3,800     14s         OK (was OOM before pool refactor)
#   10,000    26s         OK
#   30,000    87s         OK
#   50,000    138s        OOM
#   100,000   379s        OOM
#
# Wall is between 30k–50k. LDC's CTFE interpreter exhausts memory.
# Runtime performance is unaffected by control count.

set PBT controls/bench.pbt

function cleanup --on-event fish_exit
    rm -f $PBT
end

set COUNTS $argv
if test (count $COUNTS) -eq 0
    set COUNTS 300 1400 3800 10000 30000 100000
end

for N in $COUNTS
    echo "=== $N controls ==="

    # Generate pbt
    begin
        echo "scope {"
        echo '  event: "PreToolUse"'
        for i in (seq 1 $N)
            echo "  control {"
            echo "    name: \"bench-$i\""
            echo "    cmd: \"bench-cmd-$i\""
            echo "    msg: \"Benchmark control $i\""
            echo "  }"
        end
        echo "}"
    end >$PBT

    set SIZE (wc -c <$PBT | string trim)
    echo "  pbt size: $SIZE bytes"

    # --config=production so this measures what ground ships. The default
    # configuration compiles source/*_test.d, whose static asserts are CTFE
    # work the release binary does not do, and including them made every number
    # in the table above larger than the thing it claimed to measure.
    #
    # time -l reports peak resident size, which is the axis this benchmark never
    # had and the one that decides where the wall actually is. -v on Linux.
    set START (date +%s)
    if /usr/bin/time -l dub build --build=release --config=production 2>&1 | grep -E "maximum resident|Error"
        set END (date +%s)
        echo "  build time: "(math $END - $START)"s"
    else
        echo "  FAILED"
    end

    rm -f $PBT
    echo
end
