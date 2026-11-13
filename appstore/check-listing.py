#!/usr/bin/env python3
"""Checks every appstore/listing.*.md against the App Store Connect limits. Usage: appstore/check-listing.py"""
import pathlib, re, sys

LIMITS = [30, 170, 4000, 100]  # subtitle, promotional text, description, keywords, in this order in every file
NAMES = ["subtitle", "promo", "description", "keywords"]

failed = False
for path in sorted(pathlib.Path(__file__).parent.glob("listing.*.md")):
    sections = [body.strip() for body in re.split(r"^## .*$", path.read_text(), flags=re.M)[1:]]
    if len(sections) != 4:
        print(f"{path.name}: expected 4 sections, found {len(sections)}")
        failed = True
        continue
    cells = []
    for name, text, limit in zip(NAMES, sections, LIMITS):
        over = len(text) > limit
        failed |= over
        cells.append(f"{name} {len(text)}/{limit}" + (" OVER" if over else ""))
    if ", " in sections[3] or "，" in sections[3]:
        cells.append("keywords: use ',' without spaces")
        failed = True
    print(f"{path.name:22} " + "  ".join(cells))
sys.exit(1 if failed else 0)
