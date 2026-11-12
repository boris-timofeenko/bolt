#!/bin/bash
# Times photo viewers on the same photos, from a screen recording.
# Needs build/BoltBench.app allowed in Screen Recording and Accessibility (System Settings → Privacy & Security).
# Takes over the screen while it runs: don't touch the mouse or keyboard.
#
#   Benchmarks/run-viewer-bench.sh <photos-folder> <results-folder> [rounds] [--generic]
#
# Default: synthetic photos from make-bench-photos.swift, recognised by colour; Bolt, XnView MP and
# Preview, about a minute each.
# --generic: any photos (real ones too), recognised by comparing frames of the recording with each other,
# with a held arrow key at the end. Bolt, XnView MP, Quick Look, ApolloOne and Preview take turns, round
# by round, about four minutes each. A viewer that isn't installed is skipped with a line saying so (and in
# skipped.txt). Add --hue-check after --generic on synthetic photos to time every step the colour way as
# well, for comparison.
#   VIEWERS                  which, in this order (default "bolt xnview quicklook apollo preview");
#                            quicklook is a Finder window, the space bar and arrows, the way people use it,
#                            qlmanage is `qlmanage -p`, the fallback
#   XNVIEW_APP, APOLLO_APP   where the apps are (default /Applications/XnViewMP.app, /Applications/ApolloOne.app)
#   APOLLO_FLAGS             extra viewerbench flags for ApolloOne, e.g. "--open-all" if it only pages
#                            through files opened together
# Add --hold-seconds 0 to leave out the held key.
# MEASURE_LOCK=<file>: each run waits for this lock (lockf), so other measurements stay out of it.
set -uo pipefail
cd "$(dirname "$0")/.."
PHOTOS="$1"
RESULTS="$2"
ROUNDS="${3:-2}"
shift $(( $# < 3 ? $# : 3 ))
EXTRA=("$@")
GENERIC=0
for flag in "${EXTRA[@]+"${EXTRA[@]}"}"; do [ "$flag" = --generic ] && GENERIC=1; done
mkdir -p "$RESULTS"
# open hands the app a fresh working directory: absolute paths only.
PHOTOS="$(cd "$PHOTOS" && pwd)"
# Bolt is signed ad hoc, so every rebuild has to ask again for Documents, Desktop or Downloads, and the
# unanswered request stalls everything else that touches those folders. Keep the photos elsewhere.
case "$PHOTOS/" in
    "$HOME"/Documents/*|"$HOME"/Desktop/*|"$HOME"/Downloads/*)
        echo "photos in $PHOTOS: put them outside ~/Documents, ~/Desktop and ~/Downloads" >&2; exit 1 ;;
esac
RESULTS="$(cd "$RESULTS" && pwd)"
LOCK=()
[ -n "${MEASURE_LOCK:-}" ] && LOCK=(lockf -t 3600 "$MEASURE_LOCK")
"${LOCK[@]+"${LOCK[@]}"}" Benchmarks/build-viewer-bench.sh > /dev/null

bench() {
    local name="$1"; shift
    "${LOCK[@]+"${LOCK[@]}"}" caffeinate -d open -W "$PWD/build/BoltBench.app" --args --folder "$PHOTOS" \
        --runs 3 --out "$RESULTS/$name.json" --snapshots "$RESULTS" "$@"
    grep -h '"error"' "$RESULTS/$name.json" 2>/dev/null | sed "s/^ */$name: /"
}

# An app that isn't there is skipped, not failed.
present() {
    [ -d "$2" ] && return 0
    echo "$1: no $2, skipped" | tee -a "$RESULTS/skipped.txt"
    return 1
}

if [ "$GENERIC" = 1 ]; then
    XNVIEW_APP="${XNVIEW_APP:-/Applications/XnViewMP.app}"
    APOLLO_APP="${APOLLO_APP:-/Applications/ApolloOne.app}"
    read -r -a APOLLO_EXTRA <<< "${APOLLO_FLAGS:-}"
    # The trial version shows a notice on the photo for a few seconds after launch: left out of the
    # opening's comparison (x, y, width, height as fractions of the window).
    APOLLO_TRIAL_NOTICE=0.30,0.34,0.40,0.15
    for round in $(seq 1 "$ROUNDS"); do
        for viewer in ${VIEWERS:-bolt xnview quicklook apollo preview}; do
            case "$viewer" in
                bolt) bench "bolt-$round" --app "$PWD/build/Bolt.app" "${EXTRA[@]}" ;;
                xnview) present "XnView MP" "$XNVIEW_APP" && bench "xnview-$round" --app "$XNVIEW_APP" "${EXTRA[@]}" ;;
                # Finder in list view: down and up go through the files.
                quicklook) bench "quicklook-$round" --quicklook finder --next-key 125 --prev-key 126 "${EXTRA[@]}" ;;
                qlmanage) bench "qlmanage-$round" --quicklook qlmanage --next-key 124 --prev-key 123 "${EXTRA[@]}" ;;
                apollo) present ApolloOne "$APOLLO_APP" &&
                    bench "apollo-$round" --app "$APOLLO_APP" --open-mask "$APOLLO_TRIAL_NOTICE" \
                        "${APOLLO_EXTRA[@]+"${APOLLO_EXTRA[@]}"}" "${EXTRA[@]}" ;;
                preview) bench "preview-$round" --app /System/Applications/Preview.app --open-all --next-key 125 "${EXTRA[@]}" ;;
                *) echo "unknown viewer $viewer: bolt, xnview, quicklook, qlmanage, apollo, preview" >&2 ;;
            esac
        done
    done
    python3 Benchmarks/ViewerBench/summarize.py "$RESULTS"
    exit 0
fi

for round in $(seq 1 "$ROUNDS"); do
    bench "bolt-$round" --app "$PWD/build/Bolt.app" --steps 25
    bench "xnview-$round" --app /Applications/XnViewMP.app --steps 25
    bench "preview-$round" --app /System/Applications/Preview.app --open-all --next-key 125 --steps 25
done

python3 - "$RESULTS" <<'PY'
import glob, json, statistics, sys
rows = {}
for path in sorted(glob.glob(sys.argv[1] + "/*.json")):
    data = json.load(open(path))
    if data.get("mode") == "generic":
        continue
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
