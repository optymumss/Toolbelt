#!/bin/bash
# Battery check: runs Toolbelt idle with every module on and measures how much CPU it uses
# and how often it wakes the processor. Fails if either is more than an idle menu-bar app should use.
# Run after build.sh.

set -uo pipefail
cd "$(dirname "$0")/../.."

APP_BIN="build/Toolbelt.app/Contents/MacOS/Toolbelt"
DATA_DIR="$(mktemp -d -t toolbelt-energy)"
export TOOLBELT_DATA_DIR="$DATA_DIR"

# Limits for an app that's just sitting there: under 1% of one CPU core, under 15 wake-ups a
# second, and an energy impact under 2 (Activity Monitor's scale; busy apps show 10–100+).
MAX_CPU_PERCENT=1.0
MAX_WAKEUPS_PER_SEC=15
MAX_ENERGY_IMPACT=2
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
    local before after cpu_seconds percent report line wakeups energy
    before=$(ps -o cputime= -p "$pid" | awk -F'[:.]' '{ print ($1*60 + $2) + ("0." $3) }')
    # powermetrics (built into macOS) reports, per process, wake-ups from idle and the same
    # "Energy Impact" figure Activity Monitor shows. Needs sudo, which GitHub's Macs allow.
    report=$(sudo powermetrics --samplers tasks --show-process-energy -i $((SECONDS_TO_MEASURE * 1000)) -n 1 2>/dev/null)
    after=$(ps -o cputime= -p "$pid" | awk -F'[:.]' '{ print ($1*60 + $2) + ("0." $3) }')
    cpu_seconds=$(echo "$after - $before" | bc -l)
    percent=$(echo "100 * $cpu_seconds / $SECONDS_TO_MEASURE" | bc -l)
    # Columns end with: … Wakeups (Intr, Pkg idle)  Energy Impact
    line=$(echo "$report" | awk -v p="$pid" '$2 == p' | head -1)
    wakeups=$(echo "$line" | awk '{ print $(NF-1) }')
    energy=$(echo "$line" | awk '{ print $NF }')
    if ! [[ "$wakeups" =~ ^[0-9.]+$ && "$energy" =~ ^[0-9.]+$ ]]; then
        echo "✗ $label: couldn't read wake-ups and energy for Toolbelt (pid $pid) from powermetrics"
        echo "$report" | head -40
        failed=1
        return
    fi
    printf "%s: %.2f%% CPU, %s wake-ups a second, energy impact %s\n" "$label" "$percent" "$wakeups" "$energy"
    if (( $(echo "$percent > $MAX_CPU_PERCENT" | bc -l) )); then
        echo "✗ $label uses too much CPU while idle (limit $MAX_CPU_PERCENT%)"
        failed=1
    fi
    if (( $(echo "$wakeups > $MAX_WAKEUPS_PER_SEC" | bc -l) )); then
        echo "✗ $label wakes the processor too often while idle (limit $MAX_WAKEUPS_PER_SEC a second)"
        failed=1
    fi
    if (( $(echo "$energy > $MAX_ENERGY_IMPACT" | bc -l) )); then
        echo "✗ $label has too high an energy impact while idle (limit $MAX_ENERGY_IMPACT)"
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
