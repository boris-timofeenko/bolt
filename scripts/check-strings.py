#!/usr/bin/env python3
"""Lists interface strings missing from a translation. Usage: scripts/check-strings.py [ru]"""
import pathlib, re, sys

root = pathlib.Path(__file__).resolve().parent.parent
lang = sys.argv[1] if len(sys.argv) > 1 else "ru"
keys = set()
pattern = re.compile(r'\b(?:L|NSLocalizedString)\(\s*"((?:[^"\\]|\\.)*)"')
for source in (root / "Sources").rglob("*.swift"):
    keys.update(pattern.findall(source.read_text()))

table = (root / "App" / f"{lang}.lproj" / "Localizable.strings").read_text()
translated = set(re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=', table, re.M))
missing = sorted(keys - translated)
unused = sorted(translated - keys)
for key in missing:
    print(f"missing: {key}")
for key in unused:
    print(f"unused:  {key}")
sys.exit(1 if missing else 0)
