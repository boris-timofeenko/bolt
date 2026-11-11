#!/bin/bash
# Runs the unit tests. With only the Command Line Tools installed, SwiftPM can't find
# the Swift Testing macro plugin and framework on its own, so point it there.
set -euo pipefail
cd "$(dirname "$0")/.."
CLT=/Library/Developer/CommandLineTools
if [ -d "$CLT/usr/lib/swift/host/plugins/testing" ] && ! xcode-select -p | grep -q Xcode.app; then
    exec swift test \
        -Xswiftc -plugin-path -Xswiftc "$CLT/usr/lib/swift/host/plugins/testing" \
        -Xswiftc -F -Xswiftc "$CLT/Library/Developer/Frameworks" \
        -Xlinker -rpath -Xlinker "$CLT/Library/Developer/Frameworks" "$@"
fi
exec swift test "$@"
