#!/usr/bin/env python3
"""Tables from generic viewerbench runs: steps of all rounds pooled per app and scenario.

    python3 Benchmarks/ViewerBench/summarize.py <results-folder> [...]

Each folder holds <app>-<round>.json files written by `viewerbench --generic`.
"""
import glob
import json
import os
import statistics
import sys

SCENARIOS = [
    ("open", "открыть из Finder"),
    ("1000ms", "1 нажатие в 1000 мс"),
    ("400ms", "1 нажатие в 400 мс"),
    ("150ms", "1 нажатие в 150 мс"),
    ("back", "разворот, назад раз в 600 мс"),
]


def percentile(values, share):
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(len(ordered) * share))]


def stats(values):
    if not values:
        return "—"
    return f"{statistics.median(values):.0f} / {percentile(values, 0.95):.0f} / {max(values):.0f}"


ORDER = ["Bolt", "XnViewMP", "QuickLook", "qlmanage", "ApolloOne", "Preview"]


def load(folder):
    runs = {}
    for path in sorted(glob.glob(os.path.join(folder, "*.json"))):
        data = json.load(open(path))
        if data.get("mode") != "generic":
            continue
        runs.setdefault(data["app"], []).append(data)
    rank = lambda app: ORDER.index(app) if app in ORDER else len(ORDER)
    return dict(sorted(runs.items(), key=lambda item: rank(item[0])))


def pooled(runs, scenario):
    appeared, sharp, blurred = [], [], []
    steps = not_changed = not_sharp = indistinct = no_reference = 0
    firsts = []
    for run in runs:
        if scenario == "open":
            for row in run["open"]:
                steps += 1
                if row.get("unsettled"):
                    no_reference += 1
                    continue
                if row.get("appearedMs") is None:
                    not_changed += 1
                    continue
                appeared.append(row["appearedMs"])
                if row.get("sharpMs") is None:
                    not_sharp += 1
                else:
                    sharp.append(row["sharpMs"])
                if row.get("blurredMs") is not None:
                    blurred.append(row["blurredMs"])
            continue
        data = run["scenarios"].get(scenario)
        if not data:
            continue
        for number, row in enumerate(data["rows"]):
            steps += 1
            if row.get("noReference"):
                no_reference += 1
            elif row.get("indistinct"):
                indistinct += 1
            elif row.get("notChanged"):
                not_changed += 1
            else:
                appeared.append(row["appearedMs"])
                if row.get("sharpMs") is None:
                    not_sharp += 1
                else:
                    sharp.append(row["sharpMs"])
                if row.get("blurredMs") is not None:
                    blurred.append(row["blurredMs"])
                if number == 0:
                    firsts.append(row)
    return dict(appeared=appeared, sharp=sharp, blurred=blurred, steps=steps, not_changed=not_changed,
                not_sharp=not_sharp, indistinct=indistinct, no_reference=no_reference, firsts=firsts)


def table(folder):
    runs = load(folder)
    print(f"\n## {folder}: " + ", ".join(f"{app} × {len(r)}" for app, r in runs.items()))
    print("\nмедиана / p95 / максимум, мс; задержка записи входит во все цифры\n")
    print("| сценарий | программа | шагов | появилось | чёткое | не сменилось | не стало чётким | размытое: шагов, медиана / макс мс |")
    print("|---|---|---:|---:|---:|---:|---:|---:|")
    for scenario, title in SCENARIOS:
        for app, app_runs in runs.items():
            p = pooled(app_runs, scenario)
            if not p["steps"]:
                continue
            blur = "0"
            if p["blurred"]:
                blur = f"{len(p['blurred'])}: {statistics.median(p['blurred']):.0f} / {max(p['blurred']):.0f}"
            extra = []
            if p["indistinct"]:
                extra.append(f"похожих {p['indistinct']}")
            if p["no_reference"]:
                label = "не устоялось" if scenario == "open" else "без эталона"
                extra.append(f"{label} {p['no_reference']}")
            steps = f"{p['steps']}" + (f" ({', '.join(extra)})" if extra else "")
            print(f"| {title} | {app} | {steps} | {stats(p['appeared'])} | {stats(p['sharp'])} | "
                  f"{p['not_changed']} | {p['not_sharp']} | {blur} |")
    print("\nПервое нажатие после открытия (сценарий 1000 мс), появилось → чёткое, мс, по кругам:")
    for app, app_runs in runs.items():
        firsts = pooled(app_runs, "1000ms")["firsts"]
        cells = [f"{r['appearedMs']:.0f} → {r.get('sharpMs', float('nan')):.0f}" for r in firsts]
        print(f"- {app}: " + "; ".join(cells))
    print("\nМедиана «чёткого» по кругам (разброс между сеансами):")
    for app, app_runs in runs.items():
        parts = []
        for run in app_runs:
            row = []
            for scenario, _ in SCENARIOS[1:]:
                values = pooled([run], scenario)["sharp"]
                row.append(f"{statistics.median(values):.0f}" if values else "—")
            parts.append("/".join(row))
        print(f"- {app} (1000/400/150/назад): " + "; ".join(parts))
    holds = {app: [r["hold"] for r in app_runs if r.get("hold")] for app, app_runs in runs.items()}
    if any(holds.values()):
        print("\nЗажатая стрелка (системный автоповтор), медиана по кругам, в скобках каждый круг:\n")
        print("| программа | фото/с за всё зажатие | фото/с на автоповторе | чётких среди показанных | "
              "времени с чётким фото | чёткое после отпускания, мс | ещё менялось после отпускания, мс |")
        print("|---|---:|---:|---:|---:|---:|---:|")

        def cell(values, fmt):
            values = [v for v in values if v is not None]
            if not values:
                return "—"
            return fmt(statistics.median(values)) + " (" + ", ".join(fmt(v) for v in values) + ")"

        number = lambda v: f"{v:.1f}"
        share = lambda v: f"{v * 100:.0f}%"
        ms = lambda v: f"{v:.0f}"
        for app, items in holds.items():
            if not items:
                continue
            print(f"| {app} | {cell([h.get('photosPerSecond') for h in items], number)} | "
                  f"{cell([h.get('photosPerSecondRepeating') for h in items], number)} | "
                  f"{cell([h.get('sharpPhotoShare') for h in items], share)} | "
                  f"{cell([h.get('sharpTimeShare') for h in items], share)} | "
                  f"{cell([h.get('sharpAfterReleaseMs') for h in items], ms)} | "
                  f"{cell([h.get('lastChangeAfterReleaseMs') for h in items], ms)} |")
        first = next(h for items in holds.values() for h in items)
        print(f"\nАвтоповтор: задержка {first['repeatDelayMs']:.0f} мс, затем каждые {first['repeatIntervalMs']:.0f} мс; "
              f"зажата {first['heldMs'] / 1000:.1f} с.")
        broken = [f"{app} круг {n + 1}" for app, items in holds.items() for n, h in enumerate(items)
                  if not h.get("anchorReached")]
        if broken:
            print("Обход назад не дошёл до начала зажатия (эталоны неполные): " + ", ".join(broken))

    print("\nЗадержка записи, медиана, мс (по цвету / сравнением кадров):")
    for app, app_runs in runs.items():
        hue = [r["captureDelayMs"].get("median") for r in app_runs if r["captureDelayMs"]]
        generic = [r["captureDelayGenericMs"].get("median") for r in app_runs if r["captureDelayGenericMs"]]
        print(f"- {app}: " + ", ".join(f"{h:.0f}/{g:.0f}" for h, g in zip(hue, generic)))


for folder in sys.argv[1:]:
    table(folder)
