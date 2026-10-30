#!/bin/bash
# Battery check: runs Toolbelt idle with every module on and measures how much CPU it uses
# and how often it wakes the processor. Fails if either is more than an idle menu-bar app should use.
# Run after build.sh.

set -uo pipefail
cd "$(dirname "$0")/../.."

APP_BIN="build/Toolbelt.app/Contents/MacOS/Toolbelt"
DATA_DIR="$(mktemp -d -t toolbelt-energy)"
export TOOLBELT_DATA_DIR="$DATA_DIR"

# Limits for an app that's just sitting there: under 1% of one CPU core, under 15 wake-ups a second.
MAX_CPU_PERCENT=1.0
MAX_WAKEUPS_PER_SEC=15
SECONDS_TO_MEASURE=30

# A snippet (so the typing listener runs) and a shelf (so a shelf window is open).
cat > "$DATA_DIR/snippets.json" <<'JSON'
[{"id": "7E3C1E2A-0000-4000-8000-000000000001", "keyword": ";e", "name": "Energy", "text": "x"}]
JSON
cat > "$DATA_DIR/shelves.json" <<'JSON'
[{"id": "7E3C1E2A-0000-4000-8000-000000000002", "name": "Shelf", "color": "blue", "items": []}]
JSON

measure() {
    local label="$1" pid="$2"
    local before after cpu_seconds percent wakeups
    before=$(ps -o cputime= -p "$pid" | awk -F'[:.]' '{ print ($1*60 + $2) + ("0." $3) }')
    # top's second sample covers the measuring period; IDLEW = wake-ups from idle.
    local sample
    sample=$(top -l 2 -s "$SECONDS_TO_MEASURE" -pid "$pid" -stats pid,cpu,idlew 2>/dev/null | awk -v p="$pid" '$1==p' | tail -1)
    after=$(ps -o cputime= -p "$pid" | awk -F'[:.]' '{ print ($1*60 + $2) + ("0." $3) }')
    cpu_seconds=$(echo "$after - $before" | bc -l)
    percent=$(echo "100 * $cpu_seconds / $SECONDS_TO_MEASURE" | bc -l)
    wakeups=$(echo "$sample" | awk '{ print $3 }')
    wakeups_per_sec=$(echo "${wakeups:-0} / $SECONDS_TO_MEASURE" | bc -l)
    printf "%s: %.2f%% CPU (%.2f s over %d s), %.1f wake-ups a second\n" "$label" "$percent" "$cpu_seconds" "$SECONDS_TO_MEASURE" "$wakeups_per_sec"
    if (( $(echo "$percent > $MAX_CPU_PERCENT" | bc -l) )); then
        echo "✗ $label uses too much CPU while idle (limit $MAX_CPU_PERCENT%)"
        failed=1
    fi
    if (( $(echo "$wakeups_per_sec > $MAX_WAKEUPS_PER_SEC" | bc -l) )); then
        echo "✗ $label wakes the processor too often while idle (limit $MAX_WAKEUPS_PER_SEC a second)"
        failed=1
    fi
}

failed=0

# 1. Idle right after starting
"$APP_BIN" &
pid=$!
sleep 10
measure "Idle" "$pid"
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

# 2. Idle after opening and closing every Settings tab (catches timers left running)
TOOLBELT_SHOW="energy-settings" "$APP_BIN" &
pid=$!
sleep 15
measure "Idle after using Settings" "$pid"
kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null

rm -rf "$DATA_DIR"
if [ "$failed" -eq 0 ]; then echo "✓ battery use is within limits"; fi
exit "$failed"
