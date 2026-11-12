#!/usr/bin/env python3
"""Summarises scripts/present-bench.sh results: median and p95 per app, in milliseconds after the key monitor
got the key. Only presses that showed an already decoded frame count; the first three of a run are left out
(the prefetch is still filling), and so is any run in which Bolt didn't list the whole folder.

    scripts/present-summary.py <results-folder>
"""
import glob
import json
import os
import re
import statistics
import sys

ROWS = [
    ('photo committed', 'shown'),
    ('handler done', 'handlerEnd'),
    ('end-of-turn commit', 'committed'),
    ('on screen', 'presented'),
]


def percentile(values, p):
    values = sorted(values)
    k = (len(values) - 1) * p / 100
    low = int(k)
    high = min(low + 1, len(values) - 1)
    return values[low] + (values[high] - values[low]) * (k - low)


def presses(path, expected_count):
    data = json.load(open(path))
    samples = data['samples']
    if any(s.get('count') != expected_count for s in samples):
        print(f'left out, the folder was not fully listed: {path}', file=sys.stderr)
        return []
    result = []
    for s in samples[3:]:
        if s.get('kind') in ('preview', ''):
            continue
        stages = {}
        for mark in s['stages']:
            stages.setdefault(mark['stage'], mark['ms'])
        if 'keyDown' not in stages or 'shown' not in stages:
            continue
        key = stages['keyDown']
        times = {stage: stages[stage] - key for stage in ('shown', 'handlerEnd', 'committed') if stage in stages}
        if 'presentedMs' in s:
            times['presented'] = s['presentedMs'] - key
        result.append((s.get('hdr', False), times))
    return result


def main():
    folder = sys.argv[1]
    files = sorted(glob.glob(os.path.join(folder, '*.json')))
    groups = {}
    for path in files:
        name = re.sub(r'-\d+\.json$', '', os.path.basename(path))
        groups.setdefault(name, []).append(path)
    expected = max(json.load(open(p))['samples'][0].get('count', 0) for p in files)
    table = {name: [press for p in paths for press in presses(p, expected)] for name, paths in groups.items()}
    names = list(table)
    print(f"{'':22}" + ''.join(f'{name + " n=" + str(len(table[name])):>24}' for name in names))
    print(f"{'':22}" + ''.join(f"{'median / p95':>24}" for _ in names))
    for title, stage in ROWS:
        line = f'{title:22}'
        for name in names:
            values = [times[stage] for _, times in table[name] if stage in times]
            cell = f'{statistics.median(values):.1f} / {percentile(values, 95):.1f}' if values else '-'
            line += f'{cell:>24}'
        print(line)


if __name__ == '__main__':
    main()
