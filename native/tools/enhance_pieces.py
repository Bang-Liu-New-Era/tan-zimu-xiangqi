#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
棋子贴图后期增强: 把雕刻字的颜色提亮为"亮色/荧光色", 并加一层同色柔光,
让字在深色石质底上更醒目。红方 -> 荧光亮红; 黑方 -> 亮银白。

用法:
    python3 enhance_pieces.py [目标目录] [--out 输出目录] [--no-glow]

默认目标目录 = native/Resources/pieces, 原地覆盖(自动备份到同级 pieces_orig_<时间>)。
仅修改 RGB, alpha 通道原样保留。
"""
import argparse
import os
import shutil
import time

import numpy as np
from PIL import Image, ImageFilter
from scipy import ndimage as ndi


def otsu(vals):
    """一维 Otsu 自动阈值"""
    hist, _ = np.histogram(vals, bins=256, range=(0, 256))
    hist = hist.astype(np.float64)
    total = hist.sum()
    if total <= 0:
        return 128.0
    prob = hist / total
    omega = np.cumsum(prob)
    mu = np.cumsum(prob * np.arange(256))
    mu_t = mu[-1]
    denom = omega * (1.0 - omega)
    denom[denom <= 0] = 1e-12
    sigma_b = (mu_t * omega - mu) ** 2 / denom
    return float(np.argmax(sigma_b))


def screen(a, b):
    """滤色混合 (两图均在 0-255)"""
    return 255.0 - (255.0 - a) * (255.0 - b) / 255.0


def enhance(path, out_path, glow=True, ratio_core=0.055, ring_exclude=0.72, verbose=True):
    im = Image.open(path).convert("RGBA")
    arr = np.asarray(im).astype(np.float32)
    rgb = arr[..., :3].copy()
    alpha = arr[..., 3].copy()
    H, W, _ = rgb.shape

    piece = alpha > 128
    # 内缩, 排除棋子边缘的高光/倒角
    core = ndi.binary_erosion(piece, iterations=max(3, int(W * ratio_core)))
    lum = rgb.max(2)
    vals = lum[core]
    if vals.size < 50:
        raise RuntimeError("棋子区域过小")

    t = otsu(vals)
    # 阈值夹到合理区间, 避免 Otsu 在极端直方图上跑偏
    t = float(np.clip(t, np.percentile(vals, 55), np.percentile(vals, 94)))

    mask = core & (lum > t)
    st = np.ones((3, 3), bool)
    mask = ndi.binary_opening(mask, structure=st, iterations=1)      # 去细小噪点
    mask = ndi.binary_closing(mask, structure=st, iterations=2)      # 连断笔
    mask = ndi.binary_dilation(mask, iterations=max(1, int(W * 0.008)))
    mask &= piece

    # 只提亮"字", 排除外圈装饰环 (环在 ~0.80R 处, 一并提亮会喧宾夺主)
    ys, xs = np.where(piece)
    cy, cx = (ys.min() + ys.max()) / 2.0, (xs.min() + xs.max()) / 2.0
    maxr = max(xs.max() - xs.min(), ys.max() - ys.min()) / 2.0
    yy, xx = np.mgrid[0:H, 0:W]
    rad = np.sqrt((yy - cy) ** 2 + (xx - cx) ** 2)
    mask &= rad < maxr * ring_exclude

    if mask.sum() < 50:
        raise RuntimeError("未识别到刻字")

    # 判断红/黑
    px = rgb[mask]
    reddish = ((px[:, 0] > px[:, 1] + 25) & (px[:, 0] > px[:, 2] + 25)).mean()
    is_red = reddish > 0.45

    hsv = np.asarray(im.convert("RGB").convert("HSV")).astype(np.float32)
    Hc, Sc, Vc = hsv[..., 0], hsv[..., 1], hsv[..., 2]
    vmed = float(np.median(Vc[mask]))

    if is_red:
        # 荧光亮红: 高亮度 + 高饱和, 保留原有明暗起伏
        Vn = np.clip(192.0 + (Vc - vmed) * 0.46, 60, 255)
        Sn = np.clip(Sc * 0.5 + 142.0, 0, 255)
    else:
        # 亮银白: 高亮度 + 极低饱和
        Vn = np.clip(216.0 + (Vc - vmed) * 0.42, 90, 255)
        Sn = np.clip(Sc * 0.35, 0, 255)

    mv = np.where(mask, Vn, Vc)
    ms = np.where(mask, Sn, Sc)
    new_hsv = np.stack([Hc, ms, mv], -1).astype(np.uint8)
    lit = np.asarray(Image.fromarray(new_hsv, "HSV").convert("RGB")).astype(np.float32)

    if glow:
        # 字缘柔光: 仅取字色层做高斯模糊, 滤色叠回, 形成荧光外溢
        g = Image.fromarray(np.clip(lit * mask[..., None], 0, 255).astype(np.uint8))
        g = g.filter(ImageFilter.GaussianBlur(W * 0.016))
        garr = np.asarray(g).astype(np.float32)
        # 只在棋子内部发光
        inner = ndi.binary_erosion(piece, iterations=2)
        lit = np.where(inner[..., None], screen(lit, garr * 0.55), lit)

    out_rgb = np.where(piece[..., None], np.clip(lit, 0, 255), rgb)
    res = np.dstack([out_rgb, alpha]).astype(np.uint8)
    Image.fromarray(res, "RGBA").save(out_path, optimize=True)

    if verbose:
        bg = 255.0
        print(f"  {os.path.basename(path):8s} {'红方' if is_red else '黑方'} "
              f"字区占比 {mask.sum()/piece.sum()*100:4.1f}%  "
              f"字色 {rgb[mask].mean(0).round(0)} -> {out_rgb[mask].mean(0).round(0)}")
    return out_path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src", nargs="?", default=None, help="贴图目录 (默认 native/Resources/pieces)")
    ap.add_argument("--out", default=None, help="输出目录 (默认原地覆盖, 自动备份)")
    ap.add_argument("--no-glow", action="store_true", help="不添加荧光外溢")
    ap.add_argument("--no-backup", action="store_true", help="不备份原图")
    a = ap.parse_args()

    here = os.path.dirname(os.path.abspath(__file__))
    src = os.path.abspath(a.src or os.path.join(here, "..", "Resources", "pieces"))
    out_dir = os.path.abspath(a.out) if a.out else src
    os.makedirs(out_dir, exist_ok=True)

    files = sorted(f for f in os.listdir(src) if f.lower().endswith(".png"))
    if not files:
        print("未找到贴图"); return

    if out_dir == src and not a.no_backup:
        bak = os.path.join(os.path.dirname(src), "pieces_orig_" + time.strftime("%m%d_%H%M"))
        os.makedirs(bak, exist_ok=True)
        for f in files:
            shutil.copy2(os.path.join(src, f), os.path.join(bak, f))
        print(f"已备份原图 -> {bak}")

    ok = 0
    for f in files:
        try:
            enhance(os.path.join(src, f), os.path.join(out_dir, f), glow=not a.no_glow)
            ok += 1
        except Exception as e:
            print(f"  [失败] {f}: {e}")
    print(f"完成 {ok}/{len(files)} -> {out_dir}")


if __name__ == "__main__":
    main()
