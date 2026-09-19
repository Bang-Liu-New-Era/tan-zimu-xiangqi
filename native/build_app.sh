#!/bin/bash
# build_app.sh — 把象棋教学程序打包成纯原生 macOS .app (完全原生渲染, 无 WebView, 无需联网)
set -e
cd "$(dirname "$0")"

APP_NAME="人机中国象棋"
EXE="Xiangqi"
# 构建输出放到非 iCloud 同步目录。
# 项目在「文稿」下会被 iCloud 同步, 同一 bundle id 的 .app 一旦出现多份副本,
# LaunchServices 会认错目标 —— 表现为在访达里双击 App「没反应」。
OUT="${TMPDIR:-/tmp}/xiangqi-build/${APP_NAME}.app"
CONTENTS="$OUT/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

echo "== 结束正在运行的旧实例 =="
if pkill -f "Contents/MacOS/${EXE}" 2>/dev/null; then sleep 1; echo "  已结束旧实例(否则它会占着 bundle id 不放)"; else echo "  (无运行中的实例)"; fi

echo "== 清理旧构建 =="
rm -rf "$OUT"
mkdir -p "$MACOS" "$RES/sounds"
# 顺手清掉项目内遗留的 build 目录(会被 iCloud 同步出重复 App 副本)
if [ -d "$PWD/build" ] && ls "$PWD/build"/*.app >/dev/null 2>&1; then
  rm -rf "$PWD/build" && echo "  已清理项目内 build/ 目录 (避免 iCloud 生成重复副本)"
fi

echo "== 复制引擎(JS)与音效资源 =="
cp ../engine/xiangqi.js ../engine/ai.js ../engine/coach.js "$RES/"
cp Resources/sounds/*.wav "$RES/sounds/"

echo "== 复制棋盘贴图 (Resources/boards/board.jpg|png) =="
mkdir -p "$RES/boards"
if [ -f Resources/boards/board.jpg ]; then
  cp Resources/boards/board.jpg "$RES/boards/"
  echo "  已打包棋盘贴图 board.jpg"
elif [ -f Resources/boards/board.png ]; then
  cp Resources/boards/board.png "$RES/boards/"
  echo "  已打包棋盘贴图 board.png"
else
  echo "  (未提供贴图, 将使用程序化棋盘)"
fi

echo "== 复制棋子贴图 (Resources/pieces/rN.png|bN.png) =="
mkdir -p "$RES/pieces"
if ls Resources/pieces/*.png >/dev/null 2>&1; then
  cp Resources/pieces/*.png "$RES/pieces/"
  echo "  已打包 $(ls Resources/pieces/*.png | wc -l | tr -d ' ') 个棋子贴图"
else
  echo "  (未提供棋子贴图, 将使用程序化棋子)"
fi

echo "== 复制演员素材 (Resources/actors/<名称>/run_00.png, run_01.png ...) =="
if [ -d Resources/actors ]; then
  mkdir -p "$RES/actors"
  cp -R Resources/actors/. "$RES/actors/" 2>/dev/null || true
  echo "  已打包演员序列帧 $(find Resources/actors -name '*.png' 2>/dev/null | wc -l | tr -d ' ') 张"
else
  echo "  (未提供演员素材, 马将使用程序化剪影)"
fi

# 可选: 若上层提供了已编译的 pikafish 二进制(以及权重 pikafish.nnue), 一并打包
if [ -f ../pikafish ]; then
  cp ../pikafish "$MACOS/pikafish"
  chmod +x "$MACOS/pikafish"
  echo "  已打包 pikafish 二进制 (引擎菜单可选'皮卡鱼')"
  if [ -f ../pikafish.nnue ]; then cp ../pikafish.nnue "$RES/pikafish.nnue"; fi
fi

echo "== 编译 Swift 原生程序 (完全原生渲染) =="
swiftc -O XiangqiApp.swift -o "$MACOS/$EXE" \
  -framework AppKit -framework AVFoundation -framework JavaScriptCore

echo "== 写入 Info.plist =="
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>        <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key> <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>  <string>com.example.xiangqi</string>
  <key>CFBundleExecutable</key>  <string>${EXE}</string>
  <key>CFBundlePackageType</key> <string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
  <key>CFBundleShortVersionString</key> <string>2.0</string>
  <key>CFBundleVersion</key>     <string>1</string>
  <key>LSMinimumSystemVersion</key> <string>11.0</string>
  <key>NSPrincipalClass</key>    <string>NSApplication</string>
  <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

echo "== 本地签名 (ad-hoc, 去除隔离属性) =="
xattr -cr "$OUT" 2>/dev/null || true
codesign --force --deep --sign - "$OUT" 2>&1 | grep -v "^$" || echo "(codesign 失败, 但会重试)"
codesign -vv "$OUT" >/dev/null 2>&1 || { xattr -cr "$OUT"; codesign --force --deep --sign - "$OUT"; }

echo "== 安装到 /Applications (避开 iCloud 同步目录, 防止签名被同步破坏) =="
rm -rf "/Applications/${APP_NAME}.app"
cp -R "$OUT" "/Applications/" && xattr -cr "/Applications/${APP_NAME}.app"

echo "== 刷新 LaunchServices 注册 =="
"$LSREG" -u "$OUT" 2>/dev/null || true          # 构建副本不必注册, 免得与正式版抢 bundle id
"$LSREG" -f "/Applications/${APP_NAME}.app" 2>/dev/null && echo "  已注册 /Applications/${APP_NAME}.app" || true

echo "== 完成 =="
echo "App 位置: /Applications/${APP_NAME}.app (推荐从这里启动)"
echo "构建产物: $OUT (非同步目录, 不会被 iCloud 复制出重复副本)"
open -R "/Applications/${APP_NAME}.app" 2>/dev/null || true
