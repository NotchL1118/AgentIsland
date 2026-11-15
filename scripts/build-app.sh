#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
cd "$PROJECT_DIR"
CONFIGURATION="${1:-release}"
if [[ "$CONFIGURATION" != release && "$CONFIGURATION" != debug ]]; then
  print -u2 'Usage: scripts/build-app.sh [release|debug]'
  exit 2
fi
swift build --configuration "$CONFIGURATION" --product AgentIsland
swift build --configuration "$CONFIGURATION" --product agent-island-hook
BIN_DIR="$(swift build --configuration "$CONFIGURATION" --show-bin-path)"
APP_DIR="$PROJECT_DIR/dist/Agent Island.app"
rm -rf "$APP_DIR/Contents/Resources/Integrations"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Helpers" "$APP_DIR/Contents/Resources/Integrations"
cp "$BIN_DIR/AgentIsland" "$APP_DIR/Contents/MacOS/AgentIsland"
# Compiled hook runtime used by Claude Code / Codex hooks (via the stable shim).
cp "$BIN_DIR/agent-island-hook" "$APP_DIR/Contents/Helpers/agent-island-hook"
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
zsh "$PROJECT_DIR/scripts/generate-app-icon.sh" "$APP_DIR/Contents/Resources/AppIcon.icns"
# Session-scoped extensions only; persistent hooks no longer ship as scripts.
cp "$PROJECT_DIR/Integrations/pi-extension.ts" "$APP_DIR/Contents/Resources/Integrations/"
/usr/bin/codesign --force --deep --sign - "$APP_DIR"
print "Built: $APP_DIR"
