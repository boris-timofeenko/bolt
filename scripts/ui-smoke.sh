#!/bin/bash
# Drives the built app through the main scenarios with real key events and checks what it shows.
# Usage: scripts/build-app.sh release && scripts/ui-smoke.sh
#
# Bolt's preferences are exported first and restored at the end, so bucket folders set here don't stick.
set -uo pipefail
cd "$(dirname "$0")/.."

APP="$PWD/build/Bolt.app"
WORK="$(mktemp -d)"
PHOTOS="$WORK/photos"
CTL=".build/boltctl"
DOMAIN="org.boltviewer.Bolt"
FAILED=0

[ -x "$CTL" ] || swiftc -O scripts/boltctl.swift -o "$CTL"
defaults export "$DOMAIN" "$WORK/prefs.plist" 2>/dev/null
defaults delete "$DOMAIN" buckets 2>/dev/null
defaults delete "$DOMAIN" recentFolders 2>/dev/null
swift scripts/make-test-photos.swift "$PHOTOS" 12 --size 1200x900 > /dev/null

cleanup() {
    pkill -x Bolt
    defaults delete "$DOMAIN" 2>/dev/null
    [ -f "$WORK/prefs.plist" ] && defaults import "$DOMAIN" "$WORK/prefs.plist"
    rm -rf "$WORK"
}
trap cleanup EXIT

key() { "$CTL" key "$@"; sleep 0.35; }
type_text() { "$CTL" type "$1"; sleep 0.2; }

# Prints one field of the app's state, e.g. `field name`.
field() {
    rm -f "$WORK/state.json"
    "$CTL" state "$WORK/state.json"
    for _ in $(seq 1 30); do [ -f "$WORK/state.json" ] && break; sleep 0.1; done
    python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$WORK/state.json" "$1"
}

check() {
    local what="$1" expected="$2" actual="$3"
    if [ "$expected" == "$actual" ]; then
        echo "ok    $what"
    else
        echo "FAIL  $what: expected '$expected', got '$actual'"
        FAILED=1
    fi
}

pkill -x Bolt; sleep 0.5
open -a "$APP" "$PHOTOS/IMG_3.HEIC" --args --debug-control
sleep 2

check "opens the double-clicked photo" "IMG_3.HEIC" "$(field name)"
check "lists the whole folder" "12" "$(field count)"

key 124
check "right arrow shows the next photo" "IMG_4.HEIC" "$(field name)"

key 51
check "Delete shows the next photo at once" "IMG_5.HEIC" "$(field name)"
check "the photo is in the Trash" "no" "$([ -e "$PHOTOS/IMG_4.HEIC" ] && echo yes || echo no)"
key 6 command
sleep 0.3
check "Cmd+Z puts it back and shows it" "IMG_4.HEIC" "$(field name)"
check "the file is back in place" "yes" "$([ -e "$PHOTOS/IMG_4.HEIC" ] && echo yes || echo no)"

key 18
check "an unassigned digit asks for a folder" "True" "$(field picker)"
type_text "Picks"
key 36
sleep 0.3
check "the photo moved into the new folder" "yes" "$([ -e "$PHOTOS/Picks/IMG_4.HEIC" ] && echo yes || echo no)"
key 18
sleep 0.3
check "the second press uses the same folder" "yes" "$([ -e "$PHOTOS/Picks/IMG_5.HEIC" ] && echo yes || echo no)"
key 6 command
key 6 command
sleep 0.3
check "two undos bring both back" "yes yes" "$([ -e "$PHOTOS/IMG_4.HEIC" ] && echo yes) $([ -e "$PHOTOS/IMG_5.HEIC" ] && echo yes)"

key 36
type_text "beach"
key 36
sleep 0.3
check "Return renames and keeps the extension" "beach.HEIC" "$(field name)"
key 6 command
sleep 0.3

before="$(field frameSize)"
key 30
sleep 0.4
after="$(field frameSize)"
check "] turns the photo" "$(echo "$before" | awk -Fx '{print $2"x"$1}')" "$after"
key 6 command

flagged="$(field name)"
key 35
sleep 0.3
check "P writes a Finder tag" "yes" "$(xattr -p com.apple.metadata:_kMDItemUserTags "$PHOTOS/$flagged" >/dev/null 2>&1 && echo yes || echo no)"

key 5
check "G opens the grid" "True" "$(field grid)"
key 53
check "Esc closes it" "False" "$(field grid)"

key 124 shift
key 40
check "K compares the selected photos" "True" "$(field compare)"
key 53

key 3
check "F goes full screen" "True" "$(field fullscreen)"
key 53
check "Esc leaves full screen" "False" "$(field fullscreen)"

exit $FAILED
