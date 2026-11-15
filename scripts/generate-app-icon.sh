#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
SOURCE="$PROJECT_DIR/Resources/AppIcon.png"
OUTPUT="${1:-$PROJECT_DIR/dist/AppIcon.icns}"
ICON_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agent-island-icon.XXXXXX")"
trap 'rm -rf "$ICON_WORK_DIR"' EXIT
ICONSET="$ICON_WORK_DIR/AppIcon.iconset"
mkdir -p "$ICONSET" "${OUTPUT:h}"

# Include both standard and Retina representations, up to 1024 pixels.
for size in 16 32 128 256 512; do
  /usr/bin/sips -z "$size" "$size" "$SOURCE" \
    --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  retina_size=$((size * 2))
  /usr/bin/sips -z "$retina_size" "$retina_size" "$SOURCE" \
    --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

/usr/bin/iconutil --convert icns --output "$OUTPUT" "$ICONSET"
