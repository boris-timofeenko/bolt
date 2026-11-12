#!/bin/bash
# Times an arrow key press to the next photo on screen when its frame is already decoded. Release builds of
# Bolt are driven in the background through the present probe (Sources/Bolt/App/PresentProbe.swift); the app
# is never brought to the front. The apps given are alternated, and the order flips every round.
#
#   scripts/present-bench.sh [--rounds 3] [--count 40] [--interval 300] <photos> <results> <name>=<Bolt.app>...
#   scripts/present-summary.py <results>
#
# <photos> must be outside ~/Documents, ~/Desktop and ~/Downloads: an app started by `open` can't list them
# without a permission prompt, and would see only the photo it was opened with. A run in which Bolt didn't
# list the whole folder is left out of the summary. Each run takes perf-lab/.measure.lock (BOLT_MEASURE_LOCK=
# overrides the path, empty disables it) for about 20 seconds.
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.."
LOCK="${BOLT_MEASURE_LOCK-$PWD/perf-lab/.measure.lock}"
CTL=.build/present-ctl

# One run: start the app on the first photo, give it time to list the folder and decode around it, flip.
run_one() {
    local app="$1" out="$2" channel="present$$x$RANDOM" pid=""
    local first
    first=$(find "$PHOTOS" -maxdepth 1 -type f ! -name '.*' | sort | head -1)
    rm -f "$out"
    open -g -n -a "$app" "$first" --args --present-probe "$channel" || return 1
    for _ in $(seq 1 50); do
        pid=$(pgrep -f -- "--present-probe $channel" | head -1)
        [ -n "$pid" ] && break
        sleep 0.1
    done
    [ -n "$pid" ] || { echo "the app did not start" >&2; return 1; }
    trap 'kill "$pid" 2>/dev/null' EXIT INT TERM
    sleep 3
    "$CTL" "$channel" flip "$COUNT" "$INTERVAL" "$out"
    for _ in $(seq 1 $(( (COUNT * INTERVAL / 1000 + 10) * 10 ))); do [ -s "$out" ] && break; sleep 0.1; done
    "$CTL" "$channel" quit
    for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    kill "$pid" 2>/dev/null
    trap - EXIT INT TERM
    [ -s "$out" ]
}

locked() {
    if [ -n "$LOCK" ]; then lockf -t 3600 "$LOCK" "$@"; else "$@"; fi
}

# Inside the lock, from the loop below.
if [ "${PRESENT_RUN_ONE:-}" = 1 ]; then
    run_one "$1" "$2"
    exit $?
fi

ROUNDS=3 COUNT=40 INTERVAL=300
while [[ "${1:-}" == --* ]]; do
    case "$1" in
        --rounds) ROUNDS="$2" ;;
        --count) COUNT="$2" ;;
        --interval) INTERVAL="$2" ;;
        *) echo "unknown option $1" >&2; exit 2 ;;
    esac
    shift 2
done
[ $# -ge 3 ] || { sed -n '2,13p' "$0" >&2; exit 2; }
PHOTOS="$1" RESULTS="$2"
shift 2
export PHOTOS COUNT INTERVAL
mkdir -p "$RESULTS" .build

# The probe listens on a channel of its own, so other copies of Bolt with --debug-control don't react.
if [ ! -x "$CTL" ]; then
    printf '%s\n' 'import Foundation' \
        'let name = Notification.Name("org.boltviewer.Bolt.present." + CommandLine.arguments[1])' \
        'let line = CommandLine.arguments.dropFirst(2).joined(separator: " ")' \
        'DistributedNotificationCenter.default().postNotificationName(name, object: line, userInfo: nil, deliverImmediately: true)' \
        > .build/present-ctl.swift
    swiftc -O .build/present-ctl.swift -o "$CTL" || exit 1
fi

SPECS=("$@")
for round in $(seq 1 "$ROUNDS"); do
    ORDER=("${SPECS[@]}")
    if (( round % 2 == 0 )); then
        ORDER=()
        for (( i = ${#SPECS[@]} - 1; i >= 0; i-- )); do ORDER+=("${SPECS[$i]}"); done
    fi
    for spec in "${ORDER[@]}"; do
        name="${spec%%=*}" app="${spec#*=}"
        out="$RESULTS/$name-$round.json"
        printf 'round %s  %-12s ' "$round" "$name"
        if PRESENT_RUN_ONE=1 locked "$SELF" "$app" "$out"; then echo ok; else echo FAILED; fi
    done
done
echo "scripts/present-summary.py $RESULTS"
