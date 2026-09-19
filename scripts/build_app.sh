#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-debug}"
CONFIG_CAP="${CONFIGURATION:0:1:u}${CONFIGURATION:1}"   # 首字母大写：debug→Debug, release→Release
APP_DIR="$ROOT_DIR/build/ChangeIcon.app"

# Use Xcode toolchain (required for macOS 27 SDK builds)
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"

cd "$ROOT_DIR"

echo "🔨 Building main app..."
# `--disable-sandbox` 禁 manifest 编译沙箱；`-Xswiftc -disable-sandbox` 禁宏插件沙箱
# （某些系统 sandbox-exec 不可用时必需，否则 SwiftUI 宏无法展开）
swift build -c "$CONFIGURATION" --disable-sandbox -Xswiftc -disable-sandbox

echo "🔧 Building helper..."
swiftc "$ROOT_DIR/seticon_helper.swift" -o "$ROOT_DIR/build/seticon"

echo "📦 Packaging..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$ROOT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/AppIcon-dark.icns" "$APP_DIR/Contents/Resources/AppIcon-dark.icns" 2>/dev/null || true
cp "$ROOT_DIR/AppIcon-light.icns" "$APP_DIR/Contents/Resources/AppIcon-light.icns" 2>/dev/null || true
cp "$ROOT_DIR/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns" 2>/dev/null || true
cp "$ROOT_DIR/Sources/Resources/menubar-icon.icns" "$APP_DIR/Contents/Resources/menubar-icon.icns" 2>/dev/null || true
cp "$ROOT_DIR/Sources/Resources/menubar-icon.png" "$APP_DIR/Contents/Resources/menubar-icon.png" 2>/dev/null || true
cp "$ROOT_DIR/AppIcon-dark.png" "$APP_DIR/Contents/Resources/AppIcon-dark.png" 2>/dev/null || true
cp "$ROOT_DIR/AppIcon-light.png" "$APP_DIR/Contents/Resources/AppIcon-light.png" 2>/dev/null || true
cp -R "$ROOT_DIR/icons" "$APP_DIR/Contents/Resources/icons" 2>/dev/null || true
# Locate the compiled binary. SwiftPM 6.x uses the new `.build/out/Products/`
# layout; keep legacy layouts as fallback for older toolchains.
BINARY_SRC="$ROOT_DIR/.build/out/Products/$CONFIG_CAP/ChangeIcon"
if [[ ! -f "$BINARY_SRC" ]]; then
  BINARY_SRC="$ROOT_DIR/.build/arm64-apple-macosx/$CONFIGURATION/ChangeIcon"
fi
if [[ ! -f "$BINARY_SRC" ]]; then
  BINARY_SRC="$ROOT_DIR/.build/$CONFIGURATION/ChangeIcon"
fi
if [[ ! -f "$BINARY_SRC" ]]; then
  echo "❌ 未找到编译产物 ChangeIcon（已尝试 .build/out/Products/$CONFIG_CAP、arm64-apple-macosx、$CONFIGURATION）"
  exit 1
fi
cp "$BINARY_SRC" "$APP_DIR/Contents/MacOS/ChangeIcon"
cp "$ROOT_DIR/build/seticon" "$APP_DIR/Contents/MacOS/seticon"
chmod +x "$APP_DIR/Contents/MacOS/ChangeIcon"
chmod +x "$APP_DIR/Contents/MacOS/seticon"

echo "✍️ Signing..."
# 嵌套可执行文件（helper）必须先单独签名，否则签名整个 bundle 会失败
codesign --force --sign - --entitlements "$ROOT_DIR/Resources/ChangeIcon.entitlements" "$APP_DIR/Contents/MacOS/ChangeIcon" 2>/dev/null || true
codesign --force --sign - --entitlements "$ROOT_DIR/Resources/ChangeIcon.entitlements" "$APP_DIR/Contents/MacOS/seticon" 2>/dev/null || true
codesign --force --sign - --entitlements "$ROOT_DIR/Resources/ChangeIcon.entitlements" "$APP_DIR" 2>/dev/null || true

echo "✅ Done: $APP_DIR"
