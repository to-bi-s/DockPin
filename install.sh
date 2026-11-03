#!/bin/zsh
# Copies DockPin.app to /Applications and registers it as a login item (LaunchAgent).
# Optional arguments are passed through to DockPin, e.g.:  ./install.sh --display "Built-in"
set -e
cd "$(dirname "$0")"

[[ -d DockPin.app ]] || ./build.sh

DEST="/Applications"
mkdir -p "$DEST"
rm -rf "$DEST/DockPin.app"
cp -R DockPin.app "$DEST/"

LABEL="dev.tobi.DockPin"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
mkdir -p "$HOME/Library/LaunchAgents"

ARGS=""
for a in "$@"; do ARGS+="        <string>$a</string>\n"; done

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$DEST/DockPin.app/Contents/MacOS/DockPin</string>
$(printf "$ARGS")    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><false/>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/DockPin.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed to $DEST/DockPin.app and started. It will also start at login."
echo "If macOS asks for Accessibility access, grant it; DockPin starts working as soon as you do."
