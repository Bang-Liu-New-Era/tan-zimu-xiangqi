#!/usr/bin/env python3
"""make_appicon.py — 把一张人像照片做成 macOS App 图标 (.icns)。

做法: 人脸处的正方形区域 → 「人像模式」处理(背景虚化压暗 + 主体保持清晰) →
      裁成 macOS squircle(内容区 824/1024, 圆角 0.2237) → 各档 PNG → iconutil 打包 icns。

抠图是可选的: 传了 --cut(Vision 前景分割出来的 RGBA png)才做背景虚化,
否则整张照片直接用 —— 那就是普通的「照片填满圆角方块」图标。

用法:
  python3 make_appicon.py --src face.jpg --cut cut.png --box 664,552,478 \\
      --out ../Resources/AppIcon.icns
  --box 是「中心x,中心y,边长」(相对原图左上角)。
"""
import argparse
import os
import shutil
import subprocess
import sys
import tempfile
from PIL import Image, ImageDraw, ImageEnhance, ImageFilter

CANVAS = 1024
MARGIN = 100                       # macOS 图标内容区留白: 824/1024
INNER = CANVAS - MARGIN * 2
RADIUS = int(INNER * 0.2237)       # Big Sur 之后的 squircle 圆角
# iconset 需要的档位: (文件名, 像素)
SLOTS = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]


def squircle_mask(size, margin, radius):
    ss = 4
    m = Image.new("L", (size * ss, size * ss), 0)
    ImageDraw.Draw(m).rounded_rectangle(
        [margin * ss, margin * ss, (size - margin) * ss - 1, (size - margin) * ss - 1],
        radius=radius * ss, fill=255)
    return m.resize((size, size), Image.LANCZOS)


def build(src, cut, box, blur, dim, sat, lift):
    cx, cy, side = box
    crop = (cx - side // 2, cy - side // 2, cx + side // 2, cy + side // 2)
    photo = Image.open(src).convert("RGB").crop(crop).resize((INNER, INNER), Image.LANCZOS)

    if cut and os.path.exists(cut):
        a = Image.open(cut).convert("RGBA").crop(crop).resize((INNER, INNER), Image.LANCZOS)
        alpha = a.split()[3].filter(ImageFilter.GaussianBlur(1.2))
        bgp = photo.filter(ImageFilter.GaussianBlur(blur))
        bgp = ImageEnhance.Brightness(bgp).enhance(dim)
        bgp = ImageEnhance.Color(bgp).enhance(sat)
        fgp = ImageEnhance.Contrast(photo).enhance(1.06)
        fgp = ImageEnhance.Brightness(fgp).enhance(lift)
        photo = Image.composite(fgp, bgp, alpha)

    layer = Image.new("RGBA", (INNER, INNER), (0, 0, 0, 0))
    layer.paste(photo, (0, 0))
    layer.putalpha(squircle_mask(INNER, 0, RADIUS))
    out = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    out.paste(layer, (MARGIN, MARGIN))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True)
    ap.add_argument("--cut", default="")
    ap.add_argument("--box", required=True, help="中心x,中心y,边长")
    ap.add_argument("--out", required=True)
    ap.add_argument("--blur", type=float, default=16)
    ap.add_argument("--dim", type=float, default=0.82)
    ap.add_argument("--sat", type=float, default=0.72)
    ap.add_argument("--lift", type=float, default=1.0)
    ap.add_argument("--preview-dir", default="")
    a = ap.parse_args()

    box = tuple(int(v) for v in a.box.split(","))
    icon = build(a.src, a.cut, box, a.blur, a.dim, a.sat, a.lift)

    tmp = tempfile.mkdtemp(prefix="appicon-")
    iconset = os.path.join(tmp, "AppIcon.iconset")
    os.makedirs(iconset)
    for name, px in SLOTS:
        icon.resize((px, px), Image.LANCZOS).save(os.path.join(iconset, name))
    icon.save(os.path.join(tmp, "icon_1024.png"))

    out = os.path.abspath(a.out)
    os.makedirs(os.path.dirname(out), exist_ok=True)
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", out], check=True)
    print("icns ->", out, os.path.getsize(out), "bytes")

    if a.preview_dir:
        os.makedirs(a.preview_dir, exist_ok=True)
        for px in (1024, 512, 256, 128, 64, 32):
            icon.resize((px, px), Image.LANCZOS).save(
                os.path.join(a.preview_dir, f"AppIcon_{px}.png"))
        print("preview ->", a.preview_dir)
    shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
