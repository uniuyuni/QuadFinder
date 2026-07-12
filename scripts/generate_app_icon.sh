#!/bin/bash
# Rebuilds the complete macOS iconset and ICNS from the approved square master.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MASTER="$ROOT_DIR/Sources/QuadFinder/Resources/AppIconMaster.png"
ICONSET="$ROOT_DIR/Sources/QuadFinder/Resources/AppIcon.iconset"
ICNS="$ROOT_DIR/Sources/QuadFinder/Resources/AppIcon.icns"

if [[ ! -f "$MASTER" ]]; then
  echo "error: icon master is missing: $MASTER" >&2
  exit 1
fi

width="$(sips -g pixelWidth "$MASTER" | awk '/pixelWidth:/ { print $2 }')"
height="$(sips -g pixelHeight "$MASTER" | awk '/pixelHeight:/ { print $2 }')"
if [[ "$width" != "$height" || "$width" -lt 1024 ]]; then
  echo "error: icon master must be square and at least 1024px (got ${width}x${height})" >&2
  exit 1
fi

rm -rf "$ICONSET"
mkdir -p "$ICONSET"
# Lanczos gives materially cleaner small icons than sips. Explicit RGBA output is
# required by iconutil even when the approved artwork has an opaque background.
python3 - "$MASTER" "$ICONSET" <<'PY'
import sys
from pathlib import Path
from PIL import Image

master_path, iconset_path = Path(sys.argv[1]), Path(sys.argv[2])
specifications = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}
with Image.open(master_path) as source:
    source = source.convert("RGBA")
    for filename, size in specifications.items():
        source.resize((size, size), Image.Resampling.LANCZOS).save(iconset_path / filename)
    # Pillow writes the modern multi-representation ICNS format reliably on
    # macOS releases where iconutil rejects otherwise valid ten-file iconsets.
    source.resize((1024, 1024), Image.Resampling.LANCZOS).save(
        iconset_path.parent / "AppIcon.icns", format="ICNS"
    )
PY
echo "Generated: $ICNS"
