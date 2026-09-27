#!/bin/bash
# icon_from_photo.sh — 一条命令把一张人像照片换成 App 图标。
#
# 用法:
#   bash tools/icon_from_photo.sh ~/Pictures/照片.jpg          # 自动定位人脸并抠图
#   bash tools/icon_from_photo.sh 照片.jpg 480                 # 手动指定裁剪边长(像素)
#   NO_CUT=1 bash tools/icon_from_photo.sh 照片.jpg            # 不抠图(不做人像模式)
#
# 流程: Vision 找人脸 → Vision 抠出人物 → 由人脸框推裁剪框 → 人像模式 → squircle → .icns
# 做完后跑 `bash build_app.sh` 才会装到 /Applications。
set -e
cd "$(dirname "$0")/.."                     # -> native/
PHOTO="$1"
[ -z "$PHOTO" ] && { echo "用法: bash tools/icon_from_photo.sh <照片路径> [裁剪边长px]"; exit 2; }
[ -f "$PHOTO" ] || { echo "找不到文件: $PHOTO"; exit 2; }

# 找一个带 Pillow 的 python (系统自带的没有)
PY="${PY:-}"
if [ -z "$PY" ]; then
  for c in /Users/kenttt/.workbuddy/binaries/python/envs/default/bin/python python3 python; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c "import PIL" >/dev/null 2>&1; then PY="$c"; break; fi
  done
fi
[ -z "$PY" ] && { echo "找不到带 Pillow 的 python, 可用 PY=/path/to/python 指定"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "== 编译视觉工具 =="
swiftc -O tools/iconvision.swift -o "$TMP/iconvision" \
  -framework Vision -framework AppKit -framework CoreImage

echo "== 定位人脸 / 抠出人物 =="
"$TMP/iconvision" "$PHOTO" "$TMP/cut.png" "$TMP/face.txt"
read FX FY FW FH < "$TMP/face.txt" || true   # 文件末尾没换行时 read 会返回 1, set -e 下会误退

# 由人脸框推裁剪框。比例取自第一张实拍照片的调参结果:
#   边长 = 1.78 × 脸高,  中心 = 脸中心 + (0.01 脸高, -0.20 脸高)
if [ -n "$2" ]; then
  SIDE="$2"
else
  SIDE=$(awk -v fh="$FH" 'BEGIN{printf "%d", fh*1.78}')
fi
CX=$(awk -v fx="$FX" -v fw="$FW" -v fh="$FH" 'BEGIN{printf "%d", fx+fw/2+0.01*fh}')
CY=$(awk -v fy="$FY" -v fh="$FH" 'BEGIN{printf "%d", fy+fh/2-0.20*fh}')
echo "  裁剪框: 中心 ($CX,$CY) 边长 $SIDE"

echo "== 生成 AppIcon.icns =="
mkdir -p Resources/iconwork
cp "$PHOTO" Resources/iconwork/source.jpg
CUT_ARG=()
if [ -z "$NO_CUT" ] && [ -f "$TMP/cut.png" ]; then
  cp "$TMP/cut.png" Resources/iconwork/cutout.png
  CUT_ARG=(--cut Resources/iconwork/cutout.png)
  echo "  已保存抠图 Resources/iconwork/cutout.png (人像模式)"
fi

"$PY" tools/make_appicon.py \
  --src Resources/iconwork/source.jpg "${CUT_ARG[@]}" \
  --box "$CX,$CY,$SIDE" \
  --out Resources/AppIcon.icns \
  --preview-dir "$TMP/preview"

mkdir -p "../效果预览"
for n in 1024 256 128 64; do
  [ -f "$TMP/preview/AppIcon_$n.png" ] && cp "$TMP/preview/AppIcon_$n.png" "../效果预览/App图标_${n}.png"
done

echo
echo "完成。接着跑:  bash build_app.sh"
echo "(只换 icns 不重新构建的话, /Applications 里的 App 不会变)"
