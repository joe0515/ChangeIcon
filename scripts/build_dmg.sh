#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

ARCH="${1:-arm64}"
# Version is read from Info.plist to keep it in sync with the bundled build
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT_DIR/Resources/Info.plist" 2>/dev/null || echo '0.6.2')"

# Use Xcode toolchain (required for macOS 27 SDK builds)
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
echo "🛠  Toolchain: $DEVELOPER_DIR"
DMG_NAME="ChangeIcon-${VERSION}-${ARCH}.dmg"
APP_DIR="$ROOT_DIR/build/ChangeIcon.app"
STAGING="$ROOT_DIR/build/staging-${ARCH}"

echo "📱 构建 $ARCH DMG: $DMG_NAME"

# Clean
rm -rf "$APP_DIR" "$STAGING"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy Info.plist (use build-time version)
cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

# Copy resources (menubar-icon from Sources/Resources — single source of truth,
# matching Package.swift's declared resources)
cp "$ROOT_DIR/Sources/Resources/menubar-icon.icns" "$APP_DIR/Contents/Resources/" 2>/dev/null || true
cp "$ROOT_DIR/Sources/Resources/menubar-icon.png" "$APP_DIR/Contents/Resources/" 2>/dev/null || true
cp "$ROOT_DIR/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns" 2>/dev/null || true
cp "$ROOT_DIR/AppIcon-dark.icns" "$APP_DIR/Contents/Resources/AppIcon-dark.icns" 2>/dev/null || true
cp "$ROOT_DIR/AppIcon-light.icns" "$APP_DIR/Contents/Resources/AppIcon-light.icns" 2>/dev/null || true
cp "$ROOT_DIR/AppIcon-dark.png" "$APP_DIR/Contents/Resources/AppIcon-dark.png" 2>/dev/null || true
cp "$ROOT_DIR/AppIcon-light.png" "$APP_DIR/Contents/Resources/AppIcon-light.png" 2>/dev/null || true
cp -R "$ROOT_DIR/icons" "$APP_DIR/Contents/Resources/icons" 2>/dev/null || true

# Build binary (release)
echo "🔨 Compiling main binary..."
# `--disable-sandbox` 禁 manifest 编译沙箱；`-Xswiftc -disable-sandbox` 禁宏插件沙箱
swift build -c release --arch "$ARCH" --disable-sandbox -Xswiftc -disable-sandbox 2>&1 | tail -1
# Copy release binary (SwiftPM may use either old or new build layout)
BINARY_SRC="$ROOT_DIR/.build/out/Products/Release/ChangeIcon"
if [ ! -f "$BINARY_SRC" ]; then
    BINARY_SRC="$ROOT_DIR/.build/release/ChangeIcon"
fi
if [ ! -f "$BINARY_SRC" ]; then
    echo "❌ Release binary not found. Build may have failed."
    exit 1
fi
cp "$BINARY_SRC" "$APP_DIR/Contents/MacOS/ChangeIcon"
chmod +x "$APP_DIR/Contents/MacOS/ChangeIcon"

# Build and copy helper（指定目标架构，避免交叉编译时 helper 与本机架构不一致）
swiftc "$ROOT_DIR/seticon_helper.swift" -target "${ARCH}-apple-macosx14.0" -o "$ROOT_DIR/build/seticon-${ARCH}"
cp "$ROOT_DIR/build/seticon-${ARCH}" "$APP_DIR/Contents/MacOS/seticon"
chmod +x "$APP_DIR/Contents/MacOS/seticon"

# Ad-hoc signing with explicit entitlements (declares non-sandboxed app)
# 嵌套可执行文件（helper）必须先单独签名，否则签名整个 bundle 会失败
codesign --force --sign - --entitlements "$ROOT_DIR/Resources/ChangeIcon.entitlements" "$APP_DIR/Contents/MacOS/ChangeIcon" 2>/dev/null || true
codesign --force --sign - --entitlements "$ROOT_DIR/Resources/ChangeIcon.entitlements" "$APP_DIR/Contents/MacOS/seticon" 2>/dev/null || true
codesign --force --sign - --entitlements "$ROOT_DIR/Resources/ChangeIcon.entitlements" "$APP_DIR" 2>/dev/null || true

# Create DMG
mkdir -p "$STAGING"
cp -R "$APP_DIR" "$STAGING/"
ln -sf /Applications "$STAGING/Applications"

hdiutil create -volname "ChangeIcon" -srcfolder "$STAGING" -ov -format UDZO "$ROOT_DIR/build/$DMG_NAME"

# Cleanup
rm -rf "$STAGING" "$APP_DIR"

echo "✅ $ROOT_DIR/build/$DMG_NAME"
ls -lh "$ROOT_DIR/build/$DMG_NAME"
