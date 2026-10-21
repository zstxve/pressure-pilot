#!/bin/bash
# Builds build/PressurePilot.app (ad-hoc signed). With --install: copies it to ~/Applications and starts it there.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
APP=build/PressurePilot.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/PressurePilot "$APP/Contents/MacOS/"
cp Info.plist "$APP/Contents/"
codesign --force --sign - "$APP"
echo "Fertig: $APP"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x PressurePilot || true
    while pgrep -x PressurePilot >/dev/null; do sleep 0.2; done
    mkdir -p ~/Applications
    rm -rf ~/Applications/PressurePilot.app
    cp -R "$APP" ~/Applications/
    # LaunchServices needs a moment after the old instance quit (error -600).
    for _ in 1 2 3 4 5; do open ~/Applications/PressurePilot.app 2>/dev/null && break; sleep 1; done
    echo "Installiert: ~/Applications/PressurePilot.app"
fi
