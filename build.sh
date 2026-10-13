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

# 重建后立刻刷新 LaunchServices 登记。
# 开头 rm -rf 掉旧 .app，LS 数据库里那条记录的 inode 就失效了。
# 不重新登记的话，按 bundle id 查图标（Cmd+Tab 切换器、调度中心就是这么查的）
# 会取不到图标文件而回落成通用图标；Dock 因为直接持有路径所以不受影响。
LR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
if [ -x "$LR" ]; then
  echo "==> 刷新 LaunchServices 登记"
  "$LR" -f -R "$APP" 2>&1 | sed 's/^/    /' || true
fi

echo
echo "==> 完成: $APP"
echo "    启动: open \"$APP\""
