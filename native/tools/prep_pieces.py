#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
棋子贴图批处理: 去水印 -> 抠背景 -> 输出 512x512 透明 PNG (棋子占画幅 90%)

用法:
    python3 prep_pieces.py 输入图片或目录 [--out 输出目录] [--ratio 0.90] [--size 512]

命名规则 (与 App 内棋子编码一致):
    红: r1帅 r2仕 r3相 r4马 r5车 r6炮 r7兵
    黑: b9将 b10士 b11象 b12马 b13车 b14炮 b15卒
输出文件名由「颜色 + 字」推断, 例: 黑炮.png -> b14.png ; 红車.jpg -> r5.png
若文件名无法识别, 则沿用原文件名(拼音化)并给出提示, 可手动改名。

依赖: Pillow, numpy, scipy
"""
import argparse
import os
import sys

import numpy as np
from PIL import Image
from scipy import ndimage as ndi

# 字 -> 编码 (兼容繁体/异体)
CHAR2CODE = {
    "帅": 1, "帥": 1, "仕": 2, "相": 3, "马": 4, "馬": 4, "车": 5, "車": 5,
    "炮": 6, "兵": 7,
    "将": 9, "將": 9, "士": 10, "象": 11, "卒": 15,
}
# 同字异侧: 炮/马/车 红黑共用字形, 由颜色决定编码
RED_ALT = {"炮": 6, "马": 4, "馬": 4, "车": 5, "車": 5}
BLACK_ALT = {"炮": 14, "马": 12, "馬": 12, "车": 13, "車": 13}
BLACK_ONLY = {9, 10, 11, 15}
RED_ONLY = {1, 2, 3, 7}
CODE2NAME = {
    1: "r1", 2: "r2", 3: "r3", 4: "r4", 5: "r5", 6: "r6", 7: "r7",
    9: "b9", 10: "b10", 11: "b11", 12: "b12", 13: "b13", 14: "b14", 15: "b15",
}


def guess_name(path, arr, mask):
    """由文件名 + 棋子主色推断输出编码名, 失败返回 None"""
    stem = os.path.splitext(os.path.basename(path))[0]
    # 颜色: 文件名关键字优先
    is_black = any(k in stem.lower() for k in ("黑", "black", "b_"))
    is_red = any(k in stem.lower() for k in ("红", "紅", "red", "r_"))
    if not (is_black or is_red):
        # 用棋子区主色判断: 红色像素(R 明显大于 G/B) 多 -> 红方
        px = arr[mask]
        if len(px) == 0:
            return None
        reddish = ((px[:, 0] - (px[:, 1] + px[:, 2]) / 2) > 40).mean()
        is_red = reddish > 0.12
        is_black = not is_red
    # 字
    for ch in stem:
        if ch in CHAR2CODE:
            code = CHAR2CODE[ch]
            if code in BLACK_ONLY:
                return CODE2NAME[code] if is_black else None
            if code in RED_ONLY:
                return CODE2NAME[code] if is_red else None
            return CODE2NAME[BLACK_ALT[ch] if is_black else RED_ALT[ch]]
    return None


def process(src, out_path, ratio=0.90, size=512, d0=22.0, t1=200.0, verbose=True):
    im = Image.open(src)
    arr = np.asarray(im.convert("RGB")).astype(np.float32)
    H, W, _ = arr.shape

    # 1) 前景分割: 找最大连通块 = 棋子本体
    fg = np.abs(arr - 255).sum(2) > d0
    lab, n = ndi.label(fg)
    if n == 0:
        raise RuntimeError("未检测到棋子")
    sizes = ndi.sum(fg, lab, range(1, n + 1))
    main = int(np.argmax(sizes)) + 1

    # 2) 去水印: 非本体块中位于右下角的一律填白
    cleared = 0
    for i in range(1, n + 1):
        if i == main:
            continue
        m = lab == i
        if m.sum() < 8:
            continue
        yy, xx = np.where(m)
        if yy.mean() > H * 0.85 and xx.mean() > W * 0.55:
            wm = ndi.binary_dilation(m, iterations=4)
            arr[wm] = 255.0
            cleared += int(wm.sum())

    # 3) 抠背景 -> alpha (软阈值压掉外围烘焙阴影, 保留边缘抗锯齿)
    d = np.abs(arr - 255).sum(2)
    alpha = np.clip((d - d0) / (t1 - d0), 0, 1)
    af = alpha[..., None]
    color = np.clip(np.where(af > 0.02, (arr - 255.0 * (1 - af)) / np.maximum(af, 1e-3), arr), 0, 255)
    piece = ndi.binary_fill_holes(lab == main)
    core = ndi.binary_erosion(piece, iterations=4)   # 棋子内部强制不透明(保护浅色雕刻)
    alpha = np.where(core, 1.0, alpha)
    color = np.where(core[..., None], arr, color)

    # 4) 裁正方形 + 缩放, 使棋子直径占画幅 ratio
    ys, xs = np.where(piece)
    cy, cx = (ys.min() + ys.max()) / 2, (xs.min() + xs.max()) / 2
    side = max(xs.max() - xs.min() + 1, ys.max() - ys.min() + 1) / ratio
    S = int(round(side))
    cy0, cx0 = int(round(cy - side / 2)), int(round(cx - side / 2))
    out = np.zeros((S, S, 4), np.float32)
    sy0, sx0 = max(0, cy0), max(0, cx0)
    sy1, sx1 = min(H, cy0 + S), min(W, cx0 + S)
    dy0, dx0 = sy0 - cy0, sx0 - cx0
    out[dy0:dy0 + (sy1 - sy0), dx0:dx0 + (sx1 - sx0), :3] = color[sy0:sy1, sx0:sx1]
    out[dy0:dy0 + (sy1 - sy0), dx0:dx0 + (sx1 - sx0), 3] = alpha[sy0:sy1, sx0:sx1] * 255.0
    img = Image.fromarray(np.clip(out, 0, 255).astype(np.uint8), "RGBA").resize((size, size), Image.LANCZOS)
    img.save(out_path, optimize=True)

    if verbose:
        mm = np.asarray(img)[..., 3] > 200
        yy, xx = np.where(mm)
        print(f"  {os.path.basename(src)} -> {os.path.basename(out_path)}  "
              f"清除水印 {cleared}px | 占比 {(xx.max()-xx.min()+1)/size*100:.1f}%x{(yy.max()-yy.min()+1)/size*100:.1f}% "
              f"| 居中偏移 dx {(xx.min()+xx.max())/2-size/2:+.0f} dy {(yy.min()+yy.max())/2-size/2:+.0f}")
    return out_path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src", help="图片文件或目录")
    ap.add_argument("--out", default=None, help="输出目录 (默认 native/Resources/pieces)")
    ap.add_argument("--ratio", type=float, default=0.90, help="棋子直径占画幅比例 (默认 0.90)")
    ap.add_argument("--size", type=int, default=512, help="输出边长 (默认 512)")
    a = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    out_dir = a.out or os.path.join(here, "..", "Resources", "pieces")
    out_dir = os.path.abspath(out_dir)
    os.makedirs(out_dir, exist_ok=True)

    files = []
    if os.path.isdir(a.src):
        for f in sorted(os.listdir(a.src)):
            if f.lower().endswith((".png", ".jpg", ".jpeg", ".webp", ".bmp", ".tif", ".tiff")):
                files.append(os.path.join(a.src, f))
    else:
        files = [a.src]
    if not files:
        print("未找到图片"); sys.exit(1)

    done = 0
    for f in files:
        try:
            im = Image.open(f).convert("RGB")
            arr = np.asarray(im).astype(np.float32)
            fg = np.abs(arr - 255).sum(2) > 22
            lab, n = ndi.label(fg)
            main = int(np.argmax(ndi.sum(fg, lab, range(1, n + 1)))) + 1
            mask = lab == main
            name = guess_name(f, arr, mask)
            base = (name + ".png") if name else (os.path.splitext(os.path.basename(f))[0] + ".png")
            if not name:
                print(f"  [提示] 无法从文件名识别棋子: {os.path.basename(f)} -> 输出为 {base}, 请手动改名")
            process(f, os.path.join(out_dir, base), ratio=a.ratio, size=a.size)
            done += 1
        except Exception as e:
            print(f"  [失败] {f}: {e}")
    print(f"完成 {done}/{len(files)} -> {out_dir}")


if __name__ == "__main__":
    main()
