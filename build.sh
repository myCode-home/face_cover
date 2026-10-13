#!/usr/bin/env bash
#
# 编译并打包成 dist/FaceCover.app
# 只需要 macOS 自带的 Command Line Tools，不需要装完整的 Xcode。
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="FaceCover"
APP="$ROOT/dist/$APP_NAME.app"
ARCH="$(uname -m)"
TARGET="${ARCH}-apple-macos14.0"

echo "==> 清理 dist/"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译 Swift 源码 (target: $TARGET)"
swiftc \
  -swift-version 5 \
  -O \
  -parse-as-library \
  -target "$TARGET" \
  -o "$APP/Contents/MacOS/$APP_NAME" \
  "$ROOT"/Sources/*.swift

echo "==> 拷贝 Info.plist"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

if [ -f "$ROOT/Resources/FaceCover.icns" ]; then
  echo "==> 拷贝图标"
  cp "$ROOT/Resources/FaceCover.icns" "$APP/Contents/Resources/FaceCover.icns"
fi

echo "==> ad-hoc 签名（访问摄像头/麦克风必须有签名，哪怕是临时的）"
codesign --force --sign - --identifier "com.local.facecover" "$APP"
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /' || true

echo
echo "==> 完成: $APP"
echo "    启动: open \"$APP\""
