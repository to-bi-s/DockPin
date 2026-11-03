#!/bin/zsh
# Builds DockPin.app next to this script. Needs Xcode Command Line Tools (xcode-select --install).
set -e
cd "$(dirname "$0")"

APP="DockPin.app"
VERSION="${VERSION:-1.0.0}"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -o "$APP/Contents/MacOS/DockPin" DockPin.swift

# menu status dots (same assets as Neutron Calendar Bridge)
cp resources/status-*.png "$APP/Contents/Resources/"

# macOS 26 app icon, compiled from the Icon Composer bundle (needs full Xcode)
ICON_KEY=""
if [[ -d DockPin.icon ]]; then
    TMP=$(mktemp -d)
    if xcrun actool DockPin.icon --compile "$TMP" --app-icon DockPin \
        --enable-on-demand-resources NO --development-region en \
        --target-device mac --platform macosx \
        --enable-icon-stack-fallback-generation=disabled \
        --include-all-app-icons --minimum-deployment-target 11.0 \
        --output-partial-info-plist "$TMP/partial.plist" >/dev/null 2>&1 \
        && [[ -f "$TMP/Assets.car" ]]; then
        cp "$TMP/Assets.car" "$APP/Contents/Resources/"
        ICON_KEY='<key>CFBundleIconName</key>       <string>DockPin</string>'
        echo "App icon compiled from DockPin.icon"
    else
        echo "warning: actool could not compile DockPin.icon (full Xcode selected?); building without app icon"
    fi
    rm -rf "$TMP"
fi

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>      <string>dev.tobi.DockPin</string>
    <key>CFBundleName</key>            <string>DockPin</string>
    <key>CFBundleExecutable</key>      <string>DockPin</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleVersion</key>         <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
    $ICON_KEY
</dict>
</plist>
EOF

# Sign with a real identity if there is one: the Accessibility grant then survives rebuilds.
# Ad-hoc signing ties the grant to this exact binary, so every rebuild needs a re-grant.
# DOCKPIN_RELEASE=1 signs for distribution: Developer ID, hardened runtime, timestamp
# (what notarization requires; release.sh does the rest).
if [[ -n "$DOCKPIN_RELEASE" ]]; then
    IDENTITY="${DOCKPIN_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
    [[ -n "$IDENTITY" ]] || { echo "No 'Developer ID Application' identity in the keychain" >&2; exit 1; }
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
else
    IDENTITY="${DOCKPIN_SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')}"
    codesign --force --sign "${IDENTITY:--}" "$APP"
fi
echo "Signed with: ${IDENTITY:-ad-hoc} (version $VERSION)"
echo "Built $PWD/$APP"
