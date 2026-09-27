#!/usr/bin/env python3
"""transform_shared.py — 把共享源码里的 AppKit 专有符号换成跨平台名字(一次性迁移工具)。
之后再跑不需要。改完后 macOS 构建必须像素级不变。"""
import re
import sys

FILES = [
    "Render/BoardMarkers.swift", "Render/BoardRenderer.swift",
    "Render/OverlayLayer.swift", "Render/PieceLayer.swift",
    "Render/PieceRenderer.swift", "Render/PieceTextures.swift",
    "Render/RenderLayer.swift", "Render/RenderPipeline.swift",
    "FX/BurstLayer.swift", "FX/CrackLayer.swift", "FX/MoveAnimator.swift",
    "FX/Trajectory.swift", "FX/CrackForge.swift",
    "Core/Constants.swift", "Core/Rng.swift",
    "Core/Engine/BackgroundEngine.swift", "Core/Engine/EngineBridge.swift",
    "Core/Engine/PikafishEngine.swift",
    "Audio/SoundEngine.swift",
]

CROSS_IMPORT = """#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif"""

def transform(s: str) -> str:
    # ① BoardRenderer 的 NSShadow 块 → 垫片函数 (先于其它规则, 避免被 NSColor 替换污染)
    shadow_block = """        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowBlurRadius = cell * 0.25
        sh.shadowOffset = NSSize(width: 0, height: -cell * 0.06)
        sh.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.38)
        sh.set()"""
    shadow_new = """        xqSaveGState()
        xqSetShadow(blur: cell * 0.25, offsetY: -cell * 0.06, alpha: 0.38)"""
    s = s.replace(shadow_block, shadow_new)

    # ② import AppKit → 条件导入
    s = s.replace("import AppKit", CROSS_IMPORT)

    # ③ 图形上下文
    s = s.replace("NSGraphicsContext.saveGraphicsState()", "xqSaveGState()")
    s = s.replace("NSGraphicsContext.restoreGraphicsState()", "xqRestoreGState()")
    s = s.replace("NSGraphicsContext.current?.cgContext", "currentCGContext()")
    s = s.replace("NSGraphicsContext.current?.imageInterpolation = .high",
                  "xqSetImageInterpolation(.high)")
    s = s.replace("NSBezierPath.defaultLineWidth", "xqDefaultLineWidth")

    # ④ 图片加载与绘制
    s = re.sub(r"NSImage\(contentsOf:", "xqImage(contentsOf:", s)
    s = re.sub(r"(\w+)\.draw\(in: ([^,]+), from: \.zero, operation: \.sourceOver, fraction: ([^)]+)\)",
               r"xqDrawImage(\1, in: \2, alpha: \3)", s)

    # ⑤ 文本绘制
    s = s.replace(".draw(at: ", ".xqDraw(at: ")

    # ⑥ 颜色 / 路径 / 字体
    s = s.replace("NSColor(calibratedRed:", "XColor(crossRed:")
    s = s.replace("NSColor(calibratedWhite:", "XColor(crossWhite:")
    s = s.replace("NSColor", "XColor")
    s = s.replace("NSBezierPath", "XBezierPath")
    s = s.replace("NSFont", "XFont")
    s = re.sub(r"xRadius: ([^,\)]+), yRadius: [^,\)]+", r"cornerRadius: \1", s)

    # ⑦ 几何类型 (macOS 上是 typealias, 换了等价)
    s = re.sub(r"\bNSRect\b", "CGRect", s)
    s = re.sub(r"\bNSSize\b", "CGSize", s)
    s = re.sub(r"\bNSPoint\b", "CGPoint", s)
    return s


if __name__ == "__main__":
    import os
    os.chdir(os.path.dirname(os.path.abspath(__file__)) + "/..")
    changed = []
    for f in FILES:
        src = open(f, encoding="utf-8").read()
        out = transform(src)
        if out != src:
            open(f, "w", encoding="utf-8").write(out)
            changed.append(f)
    print("transformed:", len(changed))
    for f in changed:
        print(" ", f)
