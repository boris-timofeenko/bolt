#!/usr/bin/env python3
"""Lists interface strings missing from translations. Usage: scripts/check-strings.py [ru de …] (all by default)"""
import pathlib, re, sys

root = pathlib.Path(__file__).resolve().parent.parent
langs = sys.argv[1:] or sorted(p.parent.stem for p in (root / "App").glob("*.lproj/Localizable.strings") if p.parent.stem != "en")
keys = set()
pattern = re.compile(r'\b(?:L|NSLocalizedString)\(\s*"((?:[^"\\]|\\.)*)"')
for source in (root / "Sources").rglob("*.swift"):
    keys.update(pattern.findall(source.read_text()))

failed = False
for lang in langs:
    table = (root / "App" / f"{lang}.lproj" / "Localizable.strings").read_text()
    translated = set(re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=', table, re.M))
    for key in sorted(keys - translated):
        print(f"{lang} missing: {key}")
        failed = True
    for key in sorted(translated - keys):
        print(f"{lang} unused:  {key}")
sys.exit(1 if failed else 0)
