#!/bin/bash
# Builds Bolt for the Mac App Store: universal, sandboxed, without the command-line helper.
#   scripts/build-appstore.sh           build/appstore/Bolt.pkg, signed for upload with Transporter
#   scripts/build-appstore.sh --local   build/appstore/Bolt.app, signed ad hoc with the sandbox, to try here
#
# The store build needs the "Apple Distribution" and "3rd Party Mac Developer Installer" certificates in the
# keychain and the Mac App Store provisioning profile at App/embedded.provisionprofile (not in git).
# Raise CFBundleVersion in App/Info.plist before every upload.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=build/appstore
APP="$OUT/Bolt.app"
rm -rf "$OUT"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Both architectures land at the same path, so each binary is copied before the next build.
for arch in arm64 x86_64; do
    swift build -c release --arch "$arch" --product Bolt
    cp "$(swift build -c release --arch "$arch" --show-bin-path)/Bolt" "$OUT/Bolt-$arch"
done
lipo -create "$OUT/Bolt-arm64" "$OUT/Bolt-x86_64" -output "$APP/Contents/MacOS/Bolt"
rm "$OUT"/Bolt-arm64 "$OUT"/Bolt-x86_64
cp App/Info.plist "$APP/Contents/Info.plist"
cp -R App/*.lproj "$APP/Contents/Resources/"
cp App/Resources/* App/AppIcon.icns "$APP/Contents/Resources/"

if [ "${1:-}" = --local ]; then
    # Without the team keys: those need the provisioning profile.
    entitlements="$OUT/local.entitlements"
    cp App/AppStore.entitlements "$entitlements"
    /usr/libexec/PlistBuddy -c "Delete :com.apple.application-identifier" "$entitlements"
    /usr/libexec/PlistBuddy -c "Delete :com.apple.developer.team-identifier" "$entitlements"
    codesign --force --sign - --entitlements "$entitlements" "$APP"
    echo "$APP"
    exit
fi

cp App/embedded.provisionprofile "$APP/Contents/embedded.provisionprofile"
codesign --force --sign "${SIGN_IDENTITY:-Apple Distribution}" --entitlements App/AppStore.entitlements "$APP"
productbuild --component "$APP" /Applications \
    --sign "${INSTALLER_IDENTITY:-3rd Party Mac Developer Installer}" "$OUT/Bolt.pkg"
echo "$OUT/Bolt.pkg"
