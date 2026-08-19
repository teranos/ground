#!/bin/sh
# Captures one collet render as a reference for ug to be measured against.

# Two of collet's nine clock reads have nothing behind them to pin: the marquee
# offset advances every 1200ms and the blink parity every 1000ms.

# Neither can be frozen without editing collet, so the spawn is sandwiched
# instead. A capture that straddles a tick boundary is thrown away and retaken.

# Usage: capture.sh <name> <payload.json> [tries]

set -eu

NAME=${1:?name required}
PAYLOAD=${2:?payload json required}
TRIES=${3:-20}

COLLET=/home/golem/SBVH/sbvh-nl/collet/bin/collet
ROOT=$(cd "$(dirname "$0")" && pwd)
DIR="$ROOT/captures/$NAME"

now_ms() {
  perl -MTime::HiRes=time -e 'printf "%.0f", time()*1000'
}

rm -rf "$DIR"
mkdir -p "$DIR"
cp "$PAYLOAD" "$DIR/in.json"

i=1
while [ "$i" -le "$TRIES" ]; do
  before=$(now_ms)
  COLLET_DEPLOY_FILE="$DIR/deploy.json" COLLET_FAULT_FILE="$DIR/faults.log" \
    "$COLLET" < "$DIR/in.json" > "$DIR/out.bytes" 2> "$DIR/err.txt"
  after=$(now_ms)

  marquee_before=$((before / 1200))
  marquee_after=$((after / 1200))
  blink_before=$((before / 1000))
  blink_after=$((after / 1000))

  if [ "$marquee_before" = "$marquee_after" ] && [ "$blink_before" = "$blink_after" ]; then
    {
      echo "marquee_tick $marquee_before"
      echo "blink_tick $blink_before"
      echo "unix_ms_before $before"
      echo "unix_ms_after $after"
      echo "attempt $i"
    } > "$DIR/ticks"
    echo "captured $NAME in $((after - before))ms on attempt $i"
    echo "  marquee_tick $marquee_before  blink_tick $blink_before"
    echo "  bytes $(wc -c < "$DIR/out.bytes" | tr -d ' ')"
    exit 0
  fi

  i=$((i + 1))
done

echo "no capture: $TRIES attempts all straddled a tick boundary" >&2
exit 1
