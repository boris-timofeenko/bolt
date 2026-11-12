#!/bin/bash
# Measures how long it takes, after a key press, until the next photo is sharp on screen, and where the time of
# that step goes. Drives a release build in the background through the debug channel (`taps`, `first`, `hold`,
# see Sources/Bolt/App/ScrollBench.swift); the app is never brought to the front and the screen is not recorded.
#
#   scripts/scroll-bench.sh [options] <photos-folder> <results-folder>
#
#   --baseline <git-ref>   also build that commit in a git worktree and alternate it with the working tree:
#                          base, new, new, base, ... (the order flips every round); each table cell then reads
#                          "base → new"
#   --rounds <n>           rounds over all scenarios (default 3); the tables pool the presses of all rounds
#   --only <a,b,...>       only these scenarios, e.g. taps-400,first-300 (any interval: taps-250, hold-45, ...)
#   --hold-delay <ms>      wait between the first press and the first repeat of a held key (default 400, which is
#                          what a keyboard does; 375-500 ms is the macOS range)
#   --first-launches <n>   launches per round for the first-press scenarios (default 5, one press per launch)
#   --no-build             use the existing build/Bolt.app instead of rebuilding it
#   --resume               keep the runs already in <results-folder> and only do the missing ones (after an
#                          interrupted run); use the same options as before
#   --report-only          run nothing: print the tables again from the runs already in <results-folder>
#                          (only the results folder is given)
#
# Scenarios, in the order of the tables:
#   taps-1000 taps-400 taps-150 taps-60   single presses, one per N ms (40, 60, 100, 100 presses)
#   first-300 first-2000                  one press N ms after the window showed the first frame, fresh launch
#   turn-400                              20 presses forward, then 20 back, one per 400 ms
#   jump-1000                             15 Page Down presses (10 photos each), one per second
#   hold-90 hold-33 hold-16               a held arrow key (120 repeats; 90 ms is the macOS default repeat)
#
# Every run starts a new Bolt process, so the decoded-frame cache is cold, and works on a clone of the photos in a
# temporary folder. The photos must not be in ~/Documents, ~/Desktop or ~/Downloads: an app started by `open` can't
# read those without a permission prompt on the screen, and the scan of the folder hangs behind it for every
# process that touches that folder. Builds and runs take the shared lock perf-lab/.measure.lock
# (BOLT_MEASURE_LOCK= overrides the path, empty disables it); a round of runs holds it for a minute or two.
set -uo pipefail

SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
cd "$(dirname "$0")/.."
ROOT="$PWD"
LOCK="${BOLT_MEASURE_LOCK-$ROOT/perf-lab/.measure.lock}"
CTL="$ROOT/.build/boltctl"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
ALL_SCENARIOS="taps-1000 taps-400 taps-150 taps-60 first-300 first-2000 turn-400 jump-1000 hold-90 hold-33 hold-16"
# The longest a round holds the lock, in seconds: scenarios are split into rounds of about this much.
LOCK_CHUNK=130

locked() {
    if [ -n "$LOCK" ]; then lockf -t 3600 "$LOCK" "$@"; else "$@"; fi
}

# MARK: - Scenarios

# Number of key presses in a scenario.
scenario_steps() {
    local mode="${1%%-*}" ms="${1##*-}"
    case "$mode" in
        hold) echo 120 ;;
        taps) if [ "$ms" -ge 1000 ]; then echo 40; elif [ "$ms" -ge 400 ]; then echo 60; else echo 100; fi ;;
        turn) echo 40 ;;
        jump) echo 15 ;;
        first) echo 1 ;;
        *) echo "unknown scenario $1" >&2; return 1 ;;
    esac
}

# The debug command for a scenario. Usage: scenario_command <scenario> <hold-delay> <out.json>
scenario_command() {
    local mode="${1%%-*}" ms="${1##*-}" steps
    steps=$(scenario_steps "$1") || return 1
    case "$mode" in
        hold) echo "hold $steps $ms $3 delay=$2" ;;
        taps) echo "taps $steps $ms $3" ;;
        turn) echo "taps $steps $ms $3 turn=$(( steps / 2 ))" ;;
        jump) echo "taps $steps $ms $3 pgdn" ;;
        first) echo "first $ms $3" ;;
    esac
}

# Roughly how long one run takes, for splitting rounds into chunks the lock is held for.
scenario_seconds() {
    local mode="${1%%-*}" ms="${1##*-}" steps
    steps=$(scenario_steps "$1") || return 1
    case "$mode" in
        hold) echo $(( steps * ms / 1000 + HOLD_DELAY / 1000 + 9 )) ;;
        first) echo $(( FIRST_LAUNCHES * 6 )) ;;
        *) echo $(( steps * ms / 1000 + 9 )) ;;
    esac
}

# MARK: - One run, inside the lock

# Starts a new instance on a photo and sets $pid to it.
launch_app() {
    local app="$1" before
    before=$(pgrep -f "$app/Contents/MacOS/Bolt" | sort)
    open -g -n -a "$app" "$2" --args --debug-control || return 1
    pid=""
    for _ in $(seq 1 60); do
        pid=$(comm -13 <(echo "$before") <(pgrep -f "$app/Contents/MacOS/Bolt" | sort) | head -1)
        [ -n "$pid" ] && return 0
        sleep 0.1
    done
    echo "the app did not start" >&2
    return 1
}

# Prints one field of the app's state, or nothing.
state_field() {
    rm -f "$STATE"
    "$CTL" state "$STATE"
    for _ in $(seq 1 20); do [ -s "$STATE" ] && break; sleep 0.05; done
    plutil -extract "$1" raw -o - "$STATE" 2>/dev/null
}

quit_app() {
    kill "$pid" 2>/dev/null
    for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
}

# Runs one scenario on a fresh instance and quits it. A run on a folder the app has not listed completely would
# measure nothing, so that is a failure. Usage: run_one <app> <photos> <scenario> <hold-delay> <out.json>
run_one() {
    local app="$1" photos="$2" scenario="$3" delay="$4" out="$5"
    local mode="${scenario%%-*}" interval="${scenario##*-}" steps command count first limit
    steps=$(scenario_steps "$scenario") || return 1
    command=$(scenario_command "$scenario" "$delay" "$out") || return 1
    count=$(find "$photos" -maxdepth 1 -type f ! -name '.*' | wc -l | tr -d ' ')
    first=$(find "$photos" -maxdepth 1 -type f ! -name '.*' | sort | head -1)
    STATE="$out.state"
    rm -f "$out" "$STATE"

    launch_app "$app" "$first" || return 1
    # Only this instance is ever stopped: another Bolt may be in use on this Mac.
    trap 'kill "$pid" 2>/dev/null' EXIT INT TERM

    if [ "$mode" = first ]; then
        # The press is timed from the first frame, so it goes out as soon as the app answers. A command sent before
        # the app listens is lost, hence asking again every 0.1 s.
        for _ in $(seq 1 300); do
            rm -f "$STATE"
            "$CTL" state "$STATE"
            for _ in 1 2 3 4; do [ -s "$STATE" ] && break 2; sleep 0.025; done
        done
        # shellcheck disable=SC2086
        "$CTL" $command
        limit=15
    else
        local ready=0
        for _ in $(seq 1 100); do
            if [ "$(state_field count)" = "$count" ] && [ "$(state_field frameKind)" != preview ]; then ready=1; break; fi
            sleep 0.2
        done
        [ "$ready" = 1 ] || { echo "the folder did not load: $(state_field count) of $count photos" >&2; return 1; }
        [ "$(state_field index)" = 0 ] || echo "warning: did not start at the first photo" >&2
        # Let the prefetch for the first photo finish, so every run starts from the same place.
        sleep 1.5
        # shellcheck disable=SC2086
        "$CTL" $command
        limit=$(( steps * interval / 1000 + delay / 1000 + 20 ))
    fi
    local waited=0
    while [ ! -s "$out" ] && [ "$waited" -lt $(( limit * 10 )) ]; do sleep 0.1; waited=$(( waited + 1 )); done
    [ -s "$out" ] || { echo "no result after ${limit}s" >&2; return 1; }
    if [ "$mode" = first ] && [ "$(state_field count)" != "$count" ]; then
        echo "the folder never loaded ($(state_field count) of $count photos), run dropped" >&2
        rm -f "$out"
        return 1
    fi
    quit_app
    trap - EXIT INT TERM
    rm -f "$STATE"
}

# Runs a list of scenarios one after another while holding the lock: a round, a couple of minutes at most.
# Usage: scroll-bench.sh --run-batch <hold-delay> <photos> <label> <variant|app|scenario|out>...
run_batch() {
    local delay="$1" photos="$2" label="$3" failed=0 spec variant app scenario out
    shift 3
    for spec in "$@"; do
        IFS='|' read -r variant app scenario out <<< "$spec"
        printf '%s  %-10s %-5s ' "$label" "$scenario" "$variant"
        # A subshell, so the instance is stopped even if the run fails half way.
        if ( run_one "$app" "$photos" "$scenario" "$delay" "$out" ); then
            echo ok
        else
            echo FAILED; failed=$(( failed + 1 )); rm -f "$out"
        fi
    done
    return "$failed"
}

if [ "${1:-}" = "--run-batch" ]; then
    shift
    run_batch "$@"
    exit $?
fi

# MARK: - Options

BASELINE=""
ROUNDS=3
ONLY=""
HOLD_DELAY=400
FIRST_LAUNCHES=5
BUILD=1
RESUME=0
REPORT_ONLY=0
POSITIONAL=()
while [ $# -gt 0 ]; do
    case "$1" in
        --baseline) BASELINE="$2"; shift 2 ;;
        --rounds) ROUNDS="$2"; shift 2 ;;
        --only) ONLY="$2"; shift 2 ;;
        --hold-delay) HOLD_DELAY="$2"; shift 2 ;;
        --first-launches) FIRST_LAUNCHES="$2"; shift 2 ;;
        --no-build) BUILD=0; shift ;;
        --resume) RESUME=1; shift ;;
        --report-only) REPORT_ONLY=1; shift ;;
        -h|--help) sed -n '2,34p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "unknown option $1" >&2; exit 2 ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done
if [ "$REPORT_ONLY" = 1 ]; then
    [ "${#POSITIONAL[@]}" = 1 ] || { echo "usage: scripts/scroll-bench.sh --report-only [--rounds n] [--only ...] <results-folder>" >&2; exit 2; }
    POSITIONAL=("${POSITIONAL[0]}" "${POSITIONAL[0]}")
fi
[ "${#POSITIONAL[@]}" = 2 ] || { echo "usage: scripts/scroll-bench.sh [options] <photos-folder> <results-folder>" >&2; exit 2; }
PHOTOS_SRC="$(cd "${POSITIONAL[0]}" && pwd -P)" || exit 2
mkdir -p "${POSITIONAL[1]}"
RESULTS="$(cd "${POSITIONAL[1]}" && pwd)"
case "$RESULTS" in *" "*) echo "the results folder path can't contain spaces (the debug channel splits on them)" >&2; exit 2 ;; esac
if [ "$REPORT_ONLY" = 0 ]; then
    for protected in Documents Desktop Downloads "Library/Mobile Documents"; do
        case "$PHOTOS_SRC/" in
            "$HOME/$protected/"*)
                echo "refusing to run: $PHOTOS_SRC is inside ~/$protected." >&2
                echo "macOS asks permission before an app started by \`open\` may read there, and the prompt freezes every" >&2
                echo "process that touches the folder until someone answers it. Use a copy elsewhere, e.g." >&2
                echo "  cp -cR \"$PHOTOS_SRC\" ~/bolt-perf-photos/$(basename "$PHOTOS_SRC")" >&2
                exit 2 ;;
        esac
    done
fi
SCENARIOS="${ONLY:+${ONLY//,/ }}"
SCENARIOS="${SCENARIOS:-$ALL_SCENARIOS}"

# MARK: - Table

# Prints the tables for the runs in $RESULTS and saves them. Usage: print_table "<variants>" "<scenarios>"
print_table() {
python3 - "$RESULTS" "$ROUNDS" "$1" "$2" <<'PY'
import glob, json, math, re, statistics, sys

results, rounds, variants, scenarios = sys.argv[1], int(sys.argv[2]), sys.argv[3].split(), sys.argv[4].split()
SHARP = ("screen", "full")
LATE_MS = 100  # a first press later than this after its time says little about the first press

def load(variant, scenario):
    runs = []
    for path in sorted(glob.glob(f"{results}/{variant}/{scenario}-r*.json")):
        data = json.load(open(path))
        if "summary" not in data:
            continue
        data["round"] = int(re.search(r"-r(\d+)", path.split("/")[-1]).group(1))
        runs.append(data)
    return runs

def median(values):
    return statistics.median(values) if values else None

def percentile(values, fraction):
    """Nearest rank."""
    if not values:
        return None
    ordered = sorted(values)
    rank = math.ceil(round(fraction * len(ordered), 9))
    return ordered[min(len(ordered) - 1, max(rank - 1, 0))]

def share(part, whole):
    return 100 * part / whole if whole else None

def ms(value):
    if value is None:
        return "—"
    if value == math.inf:
        return "∞"
    return f"{value:.0f}" if value >= 10 or value == 0 else f"{value:.1f}"

def pct(value):
    return "—" if value is None else f"{value:.0f}"

def rate(value):
    return "—" if value is None else f"{value:.1f}"

def whole(value):
    return "—" if value is None else f"{value:.0f}"

def stats(samples, runs):
    """Everything the tables show for one scenario of one build, from the pooled presses of all rounds."""
    n = len(samples)
    press = [s["pressToSharpMs"] for s in samples if s["pressToSharpMs"] is not None]
    # A photo that never got sharp while it was on screen counts as infinitely late: leaving it out would make
    # a scenario where most photos stay blurry look fast.
    everyone = press + [math.inf] * (n - len(press))
    cached = [s for s in samples if s["shown"] in SHARP]
    sharp = [s for s in samples if s["sharpBytes"]]

    def column(key, rows=cached):
        return [s[key] for s in rows if s[key] is not None]

    def per_run(key):
        return median([r["summary"][key] for r in runs if r["summary"].get(key) is not None])

    return {
        "presses": n,
        "pressMedian": median(everyone), "pressP95": percentile(everyone, 0.95), "pressMax": max(everyone) if everyone else None,
        "pressMedianSharp": median(press),
        "anyMedian": median([s["lagMs"] for s in samples]), "anyP95": percentile([s["lagMs"] for s in samples], 0.95),
        "ready": share(len(cached), n), "never": share(n - len(press), n),
        "before": median(column("beforeMs")), "show": median(column("showMs")),
        "after": median(column("afterMs")), "commit": median(column("commitMs")),
        "main": median(column("mainMs")), "mainP95": percentile(column("mainMs"), 0.95),
        "showHDR": median(column("showMs", [s for s in cached if s["hdr"]])),
        "showSDR": median(column("showMs", [s for s in cached if not s["hdr"]])),
        "hdr": share(sum(1 for s in sharp if s["sharpHdr"]), len(sharp)),
        "megabytes": median([s["sharpBytes"] / 1048576 for s in sharp]),
        "perSecond": per_run("shownPerSecond"), "release": per_run("releaseToSharpMs"), "memory": per_run("memoryMB"),
        "timedOut": sum(1 for r in runs if r["summary"].get("releaseTimedOut")) * 2 > len(runs),
        "lost": share(sum(1 for r in runs if r["summary"].get("ignored")), len(runs)),
    }

def subsets(scenario, runs):
    """The rows of the tables for a scenario. A turn-around is told apart by direction."""
    if scenario.startswith("turn-") and runs:
        turn = runs[0]["summary"].get("turnAfter") or 20
        return [(f"{scenario} вперёд", lambda s, r: s["i"] < turn), (f"{scenario} назад", lambda s, r: s["i"] >= turn)]
    if scenario.startswith("first-"):
        return [(scenario, lambda s, r: r["summary"].get("lateMs", 0) <= LATE_MS)]
    return [(scenario, lambda s, r: True)]

rows = []  # (label, {variant: stats}, {variant: per-round values})
late_runs = {}
for scenario in scenarios:
    runs = {v: load(v, scenario) for v in variants}
    for label, keep in subsets(scenario, [r for v in variants for r in runs[v]]):
        cells, spreads = {}, {}
        for v in variants:
            if not runs[v]:
                continue
            cells[v] = stats([s for r in runs[v] for s in r.get("samples", []) if keep(s, r)], runs[v])
            by_round = {}
            for r in runs[v]:
                by_round.setdefault(r["round"], []).extend(s for s in r.get("samples", []) if keep(s, r))
            per_round = [stats(found, []) for found in by_round.values() if found]
            spreads[v] = {"median": [c["pressMedian"] for c in per_round if c["pressMedian"] is not None],
                          "ready": [c["ready"] for c in per_round if c["ready"] is not None]}
            if scenario.startswith("first-"):
                late = sum(1 for r in runs[v] if r["summary"].get("lateMs", 0) > LATE_MS)
                if late:
                    late_runs[f"{scenario}/{v}"] = late
        if cells:
            rows.append((label, cells, spreads))

def cell(cells, key, fmt):
    return " → ".join(fmt(cells[v][key]) if v in cells else "нет данных" for v in variants)

def spread(spreads, key, fmt):
    parts = []
    for v in variants:
        found = spreads.get(v, {}).get(key, [])
        if not found:
            parts.append("—")
            continue
        low, high = fmt(min(found)), fmt(max(found))
        parts.append(low if low == high else f"{low}–{high}")
    return " → ".join(parts)

def table(title, columns):
    label_width = max([len(title)] + [len(label) for label, _, _ in rows])
    body = [[fn(cells, spreads) for _, fn in columns] for _, cells, spreads in rows]
    widths = [max([len(header)] + [len(line[i]) for line in body]) for i, (header, _) in enumerate(columns)]
    out = ["| " + " | ".join([f"{title:<{label_width}}"] + [f"{h:>{w}}" for (h, _), w in zip(columns, widths)]) + " |",
           "|" + "|".join(["-" * (label_width + 2)] + ["-" * (w + 1) + ":" for w in widths]) + "|"]
    for (label, _, _), line in zip(rows, body):
        out.append("| " + " | ".join([f"{label:<{label_width}}"] + [f"{c:>{w}}" for c, w in zip(line, widths)]) + " |")
    return "\n".join(out)

def column(key, fmt):
    return lambda cells, spreads: cell(cells, key, fmt)

def release(cells, spreads):
    return " → ".join("нет данных" if v not in cells else (">3000" if cells[v]["timedOut"] else ms(cells[v]["release"]))
                      for v in variants)

tables = [
    table("нажатие → чёткий кадр в слое", [
        ("нажатий", column("presses", str)),
        ("медиана, мс", column("pressMedian", ms)), ("p95, мс", column("pressP95", ms)),
        ("макс., мс", column("pressMax", ms)),
        ("чёткий сразу, %", column("ready", pct)), ("не стал чётким, %", column("never", pct)),
        ("любой кадр: медиана, мс", column("anyMedian", ms)), ("p95, мс", column("anyP95", ms)),
    ]),
    table("шаг, чёткий кадр был в кэше (медианы)", [
        ("до показа, мс", column("before", ms)), ("показ с коммитом, мс", column("show", ms)),
        ("после показа, мс", column("after", ms)), ("коммит в конце хода, мс", column("commit", ms)),
        ("гл. поток на шаг, мс", column("main", ms)), ("p95, мс", column("mainP95", ms)),
    ]),
    table("остальное", [
        ("HDR-кадров, %", column("hdr", pct)), ("кадр, МБ", column("megabytes", whole)),
        ("показ HDR, мс", column("showHDR", ms)), ("показ не HDR, мс", column("showSDR", ms)),
        ("фото в секунду", column("perSecond", rate)), ("после отпускания чёткий, мс", release),
        ("нажатие потеряно, % запусков", column("lost", pct)), ("память, МБ", column("memory", whole)),
    ]),
    table("разброс по кругам (мин–макс)", [
        ("медиана нажатие → чёткий, мс", lambda cells, spreads: spread(spreads, "median", ms)),
        ("чёткий сразу, %", lambda cells, spreads: spread(spreads, "ready", pct)),
    ]),
]
text = "\n\n".join(tables)
print(text)

notes = []
for scenario in scenarios:
    if scenario.startswith("first-"):
        continue
    short = {v: len(load(v, scenario)) for v in variants if 0 < len(load(v, scenario)) < rounds}
    if short:
        notes.append(f"{scenario}: кругов меньше, чем заказано: {short}")
if late_runs:
    notes.append(f"нажатие позже заказанного больше чем на {LATE_MS} мс, запуски не учтены: {late_runs}")
notes.append("∞: чёткий кадр так и не появился, пока фото было на экране; такие нажатия входят в медиану, p95 и максимум.")
if len(variants) > 1:
    notes.append("В ячейках «база → новая».")
if notes:
    print("\n" + "\n".join(notes))
open(f"{results}/table.md", "w").write(text + "\n" + ("\n" + "\n".join(notes) + "\n" if notes else ""))
json.dump({f"{v}/{label}": cells[v] for label, cells, _ in rows for v in cells},
          open(f"{results}/medians.json", "w"), indent=1, ensure_ascii=False)
PY
}

if [ "$REPORT_ONLY" = 1 ]; then
    variants=""
    for variant in base new; do [ -d "$RESULTS/$variant" ] && variants="$variants $variant"; done
    print_table "${variants# }" "$SCENARIOS"
    exit 0
fi

# MARK: - Baseline build

# Adds the benchmark to a checkout that doesn't have it: ScrollBench*.swift, the hook in ImageCanvasView and the
# three commands in DebugControl. Nothing else of the working tree is applied, so the base stays the base.
overlay_bench() {
    local tree="$1"
    [ -f "$tree/Sources/Bolt/App/ScrollBench.swift" ] && return 0
    cp "$ROOT"/Sources/Bolt/App/ScrollBench*.swift "$tree/Sources/Bolt/App/"
    python3 - "$tree/Sources/Bolt" <<'PY'
import pathlib, sys

root = pathlib.Path(sys.argv[1])

def insert_after(relative, anchor, addition):
    path = root / relative
    text = path.read_text()
    if text.count(anchor) != 1:
        sys.exit(f"{relative}: expected the anchor once, found {text.count(anchor)}: {anchor.strip()!r}")
    path.write_text(text.replace(anchor, anchor + addition))

canvas = "Viewer/ImageCanvasView.swift"
insert_after(canvas, "    private(set) var currentFrame: DecodedFrame?\n",
             "    enum ShownPhase { case willShow, didShow }\n"
             "    var onShown: ((ShownPhase, URL?, DecodedFrame?) -> Void)?\n")
insert_after(canvas, "    func show(_ newFrame: DecodedFrame, for newURL: URL) {\n",
             "        onShown?(.willShow, newURL, newFrame)\n")
insert_after(canvas, "        layoutImage()\n        CATransaction.commit()\n",
             "        onShown?(.didShow, newURL, newFrame)\n")
insert_after(canvas, "    func showMessage(_ text: String, for newURL: URL?) {\n",
             "        onShown?(.willShow, newURL, nil)\n")
insert_after(canvas, "        messageLabel.isHidden = text.isEmpty\n        layoutMessage()\n",
             "        onShown?(.didShow, newURL, nil)\n")
insert_after("App/DebugControl.swift", '        case "bench": bench(argument)\n',
             '        case "hold": ScrollBench.start(.hold, argument, in: controller)\n'
             '        case "taps": ScrollBench.start(.taps, argument, in: controller)\n'
             '        case "first": ScrollBench.startFirstPress(argument, in: controller)\n')
PY
}

WORK="$(mktemp -d)"
WORKTREE=""
BASE_APP=""
cleanup() {
    if [ -n "$BASE_APP" ]; then "$LSREGISTER" -u "$BASE_APP" 2>/dev/null; fi
    if [ -n "$WORKTREE" ]; then git -C "$ROOT" worktree remove --force "$WORKTREE" 2>/dev/null; rm -rf "$WORKTREE"; fi
    rm -rf "$WORK"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

[ -x "$CTL" ] || swiftc -O scripts/boltctl.swift -o "$CTL" || exit 1

if [ "$BUILD" = 1 ]; then
    echo "building the working tree…"
    locked scripts/build-app.sh release > "$WORK/build.log" 2>&1 || { tail -20 "$WORK/build.log"; exit 1; }
fi
NEW_APP="$ROOT/build/Bolt.app"
[ -d "$NEW_APP" ] || { echo "no $NEW_APP" >&2; exit 1; }

VARIANTS="new"
if [ -n "$BASELINE" ]; then
    git rev-parse --verify --quiet "$BASELINE^{commit}" > /dev/null || { echo "unknown git ref $BASELINE" >&2; exit 2; }
    WORKTREE="$ROOT/build/scroll-bench-base"
    git worktree remove --force "$WORKTREE" 2>/dev/null; rm -rf "$WORKTREE"
    echo "building $BASELINE ($(git rev-parse --short "$BASELINE^{commit}")) in a worktree…"
    git worktree add --detach "$WORKTREE" "$BASELINE" > /dev/null 2>&1 || { echo "git worktree add failed" >&2; exit 1; }
    overlay_bench "$WORKTREE" || { echo "could not add the benchmark to $BASELINE" >&2; exit 1; }
    BASE_APP="$WORKTREE/build/Bolt.app"
    (cd "$WORKTREE" && locked scripts/build-app.sh release > "$WORK/build-base.log" 2>&1) ||
        { tail -20 "$WORK/build-base.log"; exit 1; }
    VARIANTS="base new"
fi
app_of() { if [ "$1" = base ]; then echo "$BASE_APP"; else echo "$NEW_APP"; fi; }

# MARK: - Photos

# A clone on the same volume: no copying, and nothing under ~/Documents (see the header).
MIRROR="$WORK/photos"
cp -cR "$PHOTOS_SRC" "$MIRROR" 2>/dev/null || cp -R "$PHOTOS_SRC" "$MIRROR"
# Same file cache for every run.
cat "$MIRROR"/* > /dev/null 2>&1

# MARK: - Runs

echo "photos: $PHOTOS_SRC ($(find "$MIRROR" -maxdepth 1 -type f | wc -l | tr -d ' ') files), rounds: $ROUNDS, key delay: $HOLD_DELAY ms"
echo "binaries: $(for variant in $VARIANTS; do printf '%s %s  ' "$variant" "$(shasum "$(app_of "$variant")/Contents/MacOS/Bolt" | cut -c1-10)"; done)"
# Only this run's scenarios are replaced: results of the others are kept (and all of them with --resume).
for variant in $VARIANTS; do
    mkdir -p "$RESULTS/$variant"
    if [ "$RESUME" = 0 ]; then
        for scenario in $SCENARIOS; do rm -f "$RESULTS/$variant/$scenario"-r*.json; done
    fi
done

# The scenarios in chunks that hold the lock for about LOCK_CHUNK seconds (counting every build once).
variant_count=$(echo "$VARIANTS" | wc -w | tr -d ' ')
chunks=()
chunk=""
chunk_seconds=0
for scenario in $SCENARIOS; do
    seconds=$(( $(scenario_seconds "$scenario") * variant_count ))
    if [ -n "$chunk" ] && [ $(( chunk_seconds + seconds )) -gt "$LOCK_CHUNK" ]; then
        chunks+=("$chunk"); chunk=""; chunk_seconds=0
    fi
    chunk="$chunk $scenario"
    chunk_seconds=$(( chunk_seconds + seconds ))
done
[ -z "$chunk" ] || chunks+=("$chunk")

# Adds a run to the round, unless --resume finds its result already there.
add_spec() {
    if [ "$RESUME" = 1 ] && [ -s "$3" ]; then return 0; fi
    specs+=("$1|$(app_of "$1")|$2|$3")
}

failures=0
for round in $(seq 1 "$ROUNDS"); do
    order="$VARIANTS"
    # Alternate the order so neither build always goes second.
    if [ "$VARIANTS" = "base new" ] && [ $(( round % 2 )) = 0 ]; then order="new base"; fi
    part=0
    for chunk in "${chunks[@]}"; do
        part=$(( part + 1 ))
        specs=()
        for scenario in $chunk; do
            if [ "${scenario%%-*}" = first ]; then
                # One press per launch: several launches make a sample.
                for launch in $(seq 1 "$FIRST_LAUNCHES"); do
                    for variant in $order; do
                        add_spec "$variant" "$scenario" "$RESULTS/$variant/$scenario-r${round}k$launch.json"
                    done
                done
            else
                for variant in $order; do
                    add_spec "$variant" "$scenario" "$RESULTS/$variant/$scenario-r$round.json"
                done
            fi
        done
        [ "${#specs[@]}" -gt 0 ] || continue
        # One lock for the whole chunk, so the shared lock changes hands every couple of minutes at most.
        locked "$SELF" --run-batch "$HOLD_DELAY" "$MIRROR" "round $round/$ROUNDS.$part" "${specs[@]}"
        status=$?
        # 75 is lockf giving up on the lock; any other status is the number of failed runs.
        [ "$status" != 75 ] || { echo "no lock after an hour: the round did not run" >&2; status=10; }
        failures=$(( failures + status ))
    done
done

echo
print_table "$VARIANTS" "$SCENARIOS"
echo
echo "raw runs: $RESULTS/<variant>/<scenario>-r<round>.json, tables: $RESULTS/table.md"
[ "$failures" = 0 ] || { echo "$failures run(s) failed" >&2; exit 1; }
