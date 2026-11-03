#!/bin/zsh
# Builds a distributable DockPin.app: Developer ID signature with hardened runtime, notarized,
# stapled, zipped to release/DockPin-<version>.zip.
#   ./release.sh 1.0.0
# Notarization uses the notarytool keychain profile in NOTARY_PROFILE (default neutron-notary);
# create one with:  xcrun notarytool store-credentials <name> --apple-id <id> --team-id <team>
set -e
cd "$(dirname "$0")"

VERSION="${1:?usage: ./release.sh <version>}"
PROFILE="${NOTARY_PROFILE:-neutron-notary}"
ZIP="release/DockPin-$VERSION.zip"

DOCKPIN_RELEASE=1 VERSION="$VERSION" ./build.sh
mkdir -p release
rm -f "$ZIP"
ditto -c -k --keepParent DockPin.app "$ZIP"

echo "Submitting for notarization ($PROFILE)…"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple DockPin.app

# re-zip so the archive carries the stapled ticket
rm -f "$ZIP"
ditto -c -k --keepParent DockPin.app "$ZIP"
spctl -a -vv DockPin.app

# DMG with an Applications shortcut, from the same stapled app; signed, notarized and
# stapled itself so Gatekeeper accepts the disk image as well.
DMG="release/DockPin-$VERSION.dmg"
IDENTITY="${DOCKPIN_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
STAGE=$(mktemp -d)
cp -R DockPin.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "DockPin $VERSION" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
echo "Submitting the DMG for notarization…"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG"
echo "Release ready: $PWD/$ZIP and $PWD/$DMG"
