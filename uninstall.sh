#!/bin/zsh
# Stops DockPin, removes the login item and the app. Quit DockPin from its menu first so it
# restores your display arrangement (stopping it here does not).
set -e
LABEL="dev.tobi.DockPin"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "/Applications/DockPin.app"
echo "DockPin removed. Accessibility access can be cleared in System Settings → Privacy & Security."
