#!/bin/bash
# Builds App/AppIcon.icns from the riso icon: a blue frame and a yellow bolt printed off-register.
# The drawings come from promo/src/icon.py (needs Pillow): promo/icon/outline-1024.png, and
# outline-flat-1024.png without halftone and grain for the sizes where dots turn to mud.
# Usage: scripts/make-icon.sh
set -euo pipefail
cd "$(dirname "$0")/.."

FULL=promo/icon/outline-1024.png
FLAT=promo/icon/outline-flat-1024.png
WORK="$(mktemp -d)"
SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"

# The flat drawing up to 32 px, the full one above.
drawing() { if [ "$1" -le 32 ]; then echo "$FLAT"; else echo "$FULL"; fi; }

for size in 16 32 128 256 512; do
    double=$((size * 2))
    sips -z "$size" "$size" "$(drawing "$size")" --out "$SET/icon_${size}x${size}.png" >/dev/null
    sips -z "$double" "$double" "$(drawing "$double")" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$SET" -o App/AppIcon.icns
rm -rf "$WORK"
echo "App/AppIcon.icns"
