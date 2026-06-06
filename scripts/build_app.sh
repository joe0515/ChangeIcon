#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-debug}"
BUILD_DIR="$ROOT_DIR/.build/$CONFIGURATION"
APP_DIR="$ROOT_DIR/build/ChangeIcon.app"

cd "$ROOT_DIR"

echo "🔨 Building main app..."
swift build -c "$CONFIGURATION"

echo "🔧 Building helper..."
swiftc "$ROOT_DIR/seticon_helper.swift" -o "$ROOT_DIR/build/seticon"

echo "📦 Packaging..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Resources/menubar-icon.icns" "$APP_DIR/Contents/Resources/menubar-icon.icns" 2>/dev/null || true
cp "$ROOT_DIR/Resources/menubar-icon.png" "$APP_DIR/Contents/Resources/menubar-icon.png" 2>/dev/null || true
cp -R "$ROOT_DIR/icons" "$APP_DIR/Contents/Resources/icons" 2>/dev/null || true
ARCH_DIR="$ROOT_DIR/.build/arm64-apple-macosx/$CONFIGURATION"
if [[ -f "$ARCH_DIR/ChangeIcon" ]]; then
  cp "$ARCH_DIR/ChangeIcon" "$APP_DIR/Contents/MacOS/ChangeIcon"
elif [[ -f "$BUILD_DIR/ChangeIcon" ]]; then
  cp "$BUILD_DIR/ChangeIcon" "$APP_DIR/Contents/MacOS/ChangeIcon"
fi
cp "$ROOT_DIR/build/seticon" "$APP_DIR/Contents/MacOS/seticon"
chmod +x "$APP_DIR/Contents/MacOS/ChangeIcon"
chmod +x "$APP_DIR/Contents/MacOS/seticon"

echo "✍️ Signing..."
codesign --force --sign - "$APP_DIR/Contents/MacOS/ChangeIcon" 2>/dev/null || true
codesign --force --sign - "$APP_DIR" 2>/dev/null || true

echo "✅ Done: $APP_DIR"
