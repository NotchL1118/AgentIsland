#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
CONFIGURATION="${1:-release}"
if [[ "$CONFIGURATION" != release && "$CONFIGURATION" != debug ]]; then
  print -u2 'Usage: scripts/build-app.sh [release|debug]'
  exit 2
fi
swift build --configuration "$CONFIGURATION"
BIN_DIR="$(swift build --configuration "$CONFIGURATION" --show-bin-path)"
APP_DIR="$PROJECT_DIR/dist/Agent Island.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/AgentIsland" "$APP_DIR/Contents/MacOS/AgentIsland"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
if [[ -d "$APP_DIR/Contents/Resources/Integrations" ]]; then
  rm -rf "$APP_DIR/Contents/Resources/Integrations"
fi
COPYFILE_DISABLE=1 /usr/bin/tar -C "$PROJECT_DIR" --exclude='__pycache__' --exclude='*.pyc' -cf - Integrations | /usr/bin/tar -C "$APP_DIR/Contents/Resources" -xf -
/usr/bin/codesign --force --deep --sign - "$APP_DIR"
print "Built: $APP_DIR"
