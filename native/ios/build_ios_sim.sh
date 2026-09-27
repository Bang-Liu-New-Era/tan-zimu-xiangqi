#!/bin/bash
# build_ios_sim.sh — 把象棋 App 编译成 iPhone 模拟器版并安装启动。
#
# 用法:
#   bash ios/build_ios_sim.sh              # 编译 + 安装 + 启动 (默认 iPhone 17 Pro)
#   bash ios/build_ios_sim.sh "iPhone 17"  # 指定模拟器机型
#   BOOT=0 bash ios/build_ios_sim.sh       # 只编译不启动
#
# 不需要 Xcode 工程、不需要签名 —— 模拟器 App 免签。
# 真机安装请用 ios/XiangqiIOS.xcodeproj (见 ios/README_真机安装.md)。
set -e
cd "$(dirname "$0")/.."                   # -> native/

DEST="${DEST:-iPhone 17 Pro}"
OUT="$TMPDIR/xiangqi-ios-build/Xiangqi.app"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "== 编译 (iphonesimulator / arm64) =="
SOURCES=$(find . -name "*.swift" -not -path "./tools/*" -not -path "./build/*" \
          -not -path "./App/main.swift" | LC_ALL=C sort)
xcrun -sdk iphonesimulator swiftc -O \
  -target arm64-apple-ios17.0-simulator \
  $SOURCES \
  -o "$OUT/Xiangqi" \
  -framework UIKit -framework AVFoundation -framework JavaScriptCore

echo "== 打包资源 =="
cp ../engine/xiangqi.js ../engine/ai.js ../engine/coach.js "$OUT/"
mkdir -p "$OUT/sounds" "$OUT/pieces" "$OUT/boards"
cp Resources/sounds/*.wav "$OUT/sounds/"
cp Resources/pieces/*.png "$OUT/pieces/"
[ -f Resources/boards/board.jpg ] && cp Resources/boards/board.jpg "$OUT/boards/"
[ -f Resources/boards/board.png ] && cp Resources/boards/board.png "$OUT/boards/"

echo "== Info.plist =="
cat > "$OUT/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>人机中国象棋</string>
  <key>CFBundleDisplayName</key>     <string>人机中国象棋</string>
  <key>CFBundleIdentifier</key>      <string>com.example.xiangqi.ios</string>
  <key>CFBundleExecutable</key>      <string>Xiangqi</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleShortVersionString</key> <string>2.0</string>
  <key>CFBundleVersion</key>         <string>1</string>
  <key>LSRequiresIPhoneOS</key>      <true/>
  <key>UILaunchScreen</key>          <dict/>
  <key>UIRequiresFullScreen</key>    <true/>
  <key>UISupportedInterfaceOrientations</key>
  <array>
    <string>UIInterfaceOrientationPortrait</string>
    <string>UIInterfaceOrientationLandscapeLeft</string>
    <string>UIInterfaceOrientationLandscapeRight</string>
  </array>
</dict>
</plist>
PLIST

echo "== 安装到模拟器: $DEST =="
xcrun simctl boot "$DEST" 2>/dev/null || true          # 已开机也没关系
xcrun simctl install booted "$OUT"
echo "  已安装: $OUT"

if [ -z "$BOOT" ]; then
  xcrun simctl launch booted com.example.xiangqi.ios
  echo "== 已启动。截图: xcrun simctl io booted screenshot /tmp/xq_ios.png =="
  open -a Simulator 2>/dev/null || true
fi
