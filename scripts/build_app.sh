#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-debug}"
BUILD_DIR="$ROOT_DIR/.build/$CONFIGURATION"
APP_DIR="$ROOT_DIR/build/ChangeIcon.app"

cd "$ROOT_DIR"
swift build -c "$CONFIGURATION"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/AppIcon-dark.icns" "$APP_DIR/Contents/Resources/AppIcon-dark.icns"
cp "$ROOT_DIR/AppIcon-light.icns" "$APP_DIR/Contents/Resources/AppIcon-light.icns"
cp "$ROOT_DIR/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"
cp "$ROOT_DIR/AppIcon-dark.png" "$APP_DIR/Contents/Resources/AppIcon-dark.png"
cp "$ROOT_DIR/AppIcon-light.png" "$APP_DIR/Contents/Resources/AppIcon-light.png"
cp -R "$ROOT_DIR/icons" "$APP_DIR/Contents/Resources/icons"
cp "$BUILD_DIR/ChangeIcon" "$APP_DIR/Contents/MacOS/ChangeIcon"
chmod +x "$APP_DIR/Contents/MacOS/ChangeIcon"

codesign --force --deep --sign - "$APP_DIR" >/dev/null

echo "$APP_DIR"
