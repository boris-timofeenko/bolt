#!/bin/bash
# Times Bolt, XnView MP and Preview on the same photos, from a screen recording.
# Needs build/BoltBench.app allowed in Screen Recording and Accessibility (System Settings → Privacy & Security).
# Takes over the screen for about a minute per app: don't touch the mouse or keyboard.
#
#   Benchmarks/run-viewer-bench.sh <photos-folder> <results-folder> [rounds]
set -uo pipefail
cd "$(dirname "$0")/.."
PHOTOS="$1"
RESULTS="$2"
ROUNDS="${3:-2}"
mkdir -p "$RESULTS"
Benchmarks/build-viewer-bench.sh > /dev/null

bench() {
    local name="$1"; shift
    open -W "$PWD/build/BoltBench.app" --args --folder "$PHOTOS" --steps 25 --runs 3 \
        --out "$RESULTS/$name.json" --snapshots "$RESULTS" "$@"
}

for round in $(seq 1 "$ROUNDS"); do
    bench "bolt-$round" --app "$PWD/build/Bolt.app"
    bench "xnview-$round" --app /Applications/XnViewMP.app
    bench "preview-$round" --app /System/Applications/Preview.app --open-all --next-key 125
done

python3 - "$RESULTS" <<'PY'
import glob, json, statistics, sys
rows = {}
for path in sorted(glob.glob(sys.argv[1] + "/*.json")):
    data = json.load(open(path))
    rows.setdefault(data["app"], []).append(data)

def med(values):
    values = [v for v in values if v is not None]
    return f"{statistics.median(values):.0f}" if values else "—"

print(f"{'':34}" + "".join(f"{app:>12}" for app in rows))
lines = [
    ("open from Finder, visible ms", lambda d: d["openVisibleMs"]),
    ("open from Finder, sharp ms", lambda d: d["openSharpMs"]),
    ("next photo, visible ms (median)", lambda d: [d["slowVisible"].get("median")]),
    ("next photo, sharp ms (median)", lambda d: [d["slowSharp"].get("median")]),
    ("next photo, sharp ms (p95)", lambda d: [d["slowSharp"].get("p95")]),
    ("skimming 6.7/s, visible ms (median)", lambda d: [d["fastVisible"].get("median")]),
    ("skimming 6.7/s, skipped of 25", lambda d: [d["fastMissed"]]),
    ("key held 3 s, photos/s", lambda d: [d["holdPhotosShownPerSecond"]]),
    ("after release, still changing ms", lambda d: [d["holdSettleAfterReleaseMs"]]),
    ("after release, sharp ms", lambda d: [d["holdSharpAfterReleaseMs"]]),
    ("recording delay ms (in all above)", lambda d: [d["captureDelayMs"].get("median")]),
]
for label, pick in lines:
    print(f"{label:34}" + "".join(f"{med([v for d in rows[app] for v in pick(d)]):>12}" for app in rows))
PY
