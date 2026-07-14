#!/bin/bash
# Builds a locally runnable, ad-hoc-signed QuadFinder.app from this Swift package.
# The version is deliberately read from AppVersion.swift so development and bundle
# builds cannot drift.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION_SOURCE="$ROOT_DIR/Sources/QuadFinder/AppVersion.swift"
DIST_DIR="$ROOT_DIR/dist"
APP_PATH="$DIST_DIR/QuadFinder.app"
MACOS_DIR="$APP_PATH/Contents/MacOS"
RESOURCES_DIR="$APP_PATH/Contents/Resources"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
EXECUTABLE="$ROOT_DIR/.build/release/QuadFinder"
APP_ICON="$ROOT_DIR/Sources/QuadFinder/Resources/AppIcon.icns"
RESOURCE_BUNDLE="$ROOT_DIR/.build/release/QuadFinder_QuadFinder.bundle"
ICON_GENERATOR="$ROOT_DIR/scripts/generate_app_icon.sh"

if [[ ! -f "$VERSION_SOURCE" ]]; then
  echo "error: AppVersion.swift is missing: $VERSION_SOURCE" >&2
  exit 1
fi

# Only accepts literal Swift string assignments, preventing arbitrary source text
# from being used as a plist value.
marketing_version="$(sed -nE 's/^[[:space:]]*static let marketing = "([0-9]+(\.[0-9]+)*)"[[:space:]]*$/\1/p' "$VERSION_SOURCE")"
build_number="$(sed -nE 's/^[[:space:]]*static let build = "([0-9]+)"[[:space:]]*$/\1/p' "$VERSION_SOURCE")"
if [[ $(printf '%s\n' "$marketing_version" | sed '/^$/d' | wc -l | tr -d ' ') -ne 1 || \
      $(printf '%s\n' "$build_number" | sed '/^$/d' | wc -l | tr -d ' ') -ne 1 ]]; then
  echo "error: could not read exactly one literal marketing/build version from $VERSION_SOURCE" >&2
  exit 1
fi

cd "$ROOT_DIR"
"$ICON_GENERATOR"
swift build -c release

if [[ ! -x "$EXECUTABLE" ]]; then
  echo "error: release executable was not produced: $EXECUTABLE" >&2
  exit 1
fi

rm -rf "$APP_PATH"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$EXECUTABLE" "$MACOS_DIR/QuadFinder"
if [[ ! -f "$APP_ICON" ]]; then
  echo "error: app icon is missing: $APP_ICON" >&2
  exit 1
fi
cp "$APP_ICON" "$RESOURCES_DIR/AppIcon.icns"
if [[ ! -d "$RESOURCE_BUNDLE" ]]; then
  echo "error: SwiftPM resource bundle was not produced: $RESOURCE_BUNDLE" >&2
  exit 1
fi
# QuadFinder's localization loader checks the signed app resource directory
# before falling back to SwiftPM's generated development bundle.
cp -R "$RESOURCE_BUNDLE" "$RESOURCES_DIR/QuadFinder_QuadFinder.bundle"

cat > "$INFO_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleLocalizations</key>
    <array>
        <string>en</string>
        <string>ja</string>
    </array>
    <key>CFBundleExecutable</key>
    <string>QuadFinder</string>
    <key>CFBundleIdentifier</key>
    <string>com.quadfinder.app</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>QuadFinder</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${marketing_version}</string>
    <key>CFBundleVersion</key>
    <string>${build_number}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

plutil -lint "$INFO_PLIST"
codesign --force --deep --sign - "$APP_PATH"
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

echo "Built: $APP_PATH"
echo "Version: $marketing_version ($build_number)"
