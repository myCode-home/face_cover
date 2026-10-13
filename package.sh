#!/usr/bin/env bash
#
# 打包成可以直接双击安装的分发件：
#   dist/FaceCover-<版本>.dmg   —— 拖进「应用程序」
#   dist/FaceCover-<版本>.zip   —— 方便发给别人
#
# 会先重新生成图标、重新编译，然后校验产物。
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="FaceCover"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT/Resources/Info.plist")"
APP="$ROOT/dist/$APP_NAME.app"
DMG="$ROOT/dist/$APP_NAME-$VERSION.dmg"
ZIP="$ROOT/dist/$APP_NAME-$VERSION.zip"
BUILD="$ROOT/.build"

cd "$ROOT"
mkdir -p "$BUILD"

# ---------------------------------------------------------------- 1. 图标
echo "==> [1/5] 生成图标"
swiftc -O -target "$(uname -m)-apple-macos14.0" \
  -o "$BUILD/genicon" "$ROOT/Tools/IconGenerator/main.swift"
"$BUILD/genicon" "$BUILD"

ICONSET="$BUILD/AppIcon.iconset"
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
for spec in "16 icon_16x16" "32 icon_16x16@2x" "32 icon_32x32" "64 icon_32x32@2x" \
            "128 icon_128x128" "256 icon_128x128@2x" "256 icon_256x256" \
            "512 icon_256x256@2x" "512 icon_512x512" "1024 icon_512x512@2x"; do
  set -- $spec
  sips -z "$1" "$1" "$BUILD/AppIcon.png" --out "$ICONSET/$2.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$ROOT/Resources/FaceCover.icns"
echo "    Resources/FaceCover.icns"

# ---------------------------------------------------------------- 2. 编译
echo
echo "==> [2/5] 编译 App"
"$ROOT/build.sh"

# ---------------------------------------------------------------- 3. 自检
echo
echo "==> [3/5] 跑自检"
"$ROOT/test.sh" >/dev/null
echo "    全部自检通过"

# ---------------------------------------------------------------- 4. DMG
echo
echo "==> [4/5] 制作 DMG"
rm -rf "$ROOT/dist/dmg"
mkdir -p "$ROOT/dist/dmg"
cp -R "$APP" "$ROOT/dist/dmg/"
ln -s /Applications "$ROOT/dist/dmg/Applications"
rm -f "$DMG"
hdiutil create -volname "脸罩 $APP_NAME" \
  -srcfolder "$ROOT/dist/dmg" \
  -ov -format UDZO -quiet "$DMG"

# 关键：先注销临时副本，再删目录。
# dist/dmg 下的这份 .app 被 LaunchServices 登记过（打包时访达/系统扫到过），
# 如果直接 rm -rf，LS 数据库里就留一条指向已删除路径的死记录。
# 系统按 bundle id 查图标（Cmd+Tab 切换器、调度中心就是这么查的）会命中这条死记录，
# 取不到图标文件 → 回落成通用图标；而 Dock 直接持有 /Applications 下的真实路径，所以不受影响。
# 症状就是「Dock 里看得到 logo，Cmd+Tab 里没有」。
LR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LR" ] && "$LR" -u "$ROOT/dist/dmg/$APP_NAME.app" 2>/dev/null
rm -rf "$ROOT/dist/dmg"

# ---------------------------------------------------------------- 5. ZIP
echo
echo "==> [5/5] 制作 ZIP"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# ---------------------------------------------------------------- 校验
echo
echo "==> 校验产物"
echo "--- App 包完整性"
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'
test -f "$APP/Contents/Resources/FaceCover.icns" && echo "    ✅ 图标已打进包" || echo "    ❌ 缺图标"

echo "--- 挂载 DMG 检查内容"
MOUNT_POINT="$(mktemp -d)"
hdiutil attach "$DMG" -mountpoint "$MOUNT_POINT" -nobrowse -quiet
trap 'hdiutil detach "$MOUNT_POINT" -quiet || true; rmdir "$MOUNT_POINT" 2>/dev/null || true' EXIT
ls -1 "$MOUNT_POINT" | sed 's/^/    /'
codesign --verify --verbose=1 "$MOUNT_POINT/$APP_NAME.app" 2>&1 | sed 's/^/    /'
defaults read "$MOUNT_POINT/$APP_NAME.app/Contents/Info.plist" CFBundleIconFile 2>/dev/null | sed 's/^/    图标: /'
hdiutil detach "$MOUNT_POINT" -quiet
rmdir "$MOUNT_POINT" 2>/dev/null || true
trap - EXIT

echo
echo "==> 完成"
ls -lh "$DMG" "$ZIP" | awk '{print "    " $5 "\t" $9}'
echo
echo "    安装: 双击 DMG，把「${APP_NAME}」拖进「应用程序」"
