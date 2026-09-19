//
//  OverlayLayer.swift
//  人机中国象棋 · 全屏提示层
//
//  将军红闪 + 绝杀大字。全屏性质, 不参与震屏 (否则整块画面会跟着棋盘一起晃)。
//
import AppKit

/// 全屏提示层: 将军红闪 + 绝杀大字。
final class OverlayLayer: RenderLayer {
    let name = "overlay"

    /// 绝杀大字 (全棋盘居中)。nil = 当前没有大字。
    var bigText: (text: String, start: Double, dur: Double)? = nil

    var isAnimating: Bool { bigText != nil }

    func update(_ ctx: RenderContext) {
        // 大字播完即清 —— 以前写在 draw() 里, 现在收敛到本层的推进阶段
        if let bt = bigText, ctx.now - bt.start >= bt.dur { bigText = nil }
    }

    func draw(_ ctx: RenderContext) {
        let b = ctx.bounds
        let now = ctx.now

        // 将军红闪
        if now < ctx.flashUntil {
            let a = (ctx.flashUntil - now) / 0.45 * 0.35
            NSColor(calibratedRed: 0.9, green: 0.1, blue: 0.1, alpha: a).setFill()
            NSBezierPath.fill(b)
        }

        // 绝杀大字 (全棋盘)
        guard let bt = bigText else { return }
        let t = (now - bt.start) / bt.dur
        guard t < 1 else { return }
        var scale: CGFloat = 1, alpha: CGFloat = 1
        if t < 0.16 { let u = CGFloat(t / 0.16); scale = 3.4 - 2.4 * u; alpha = u }   // 砸入
        else if t > 0.7 { alpha = CGFloat((1 - t) / 0.3) }                              // 淡出
        let fs = min(ctx.cell * 2.3 * scale, b.height * 0.42)
        let font = NSFont(name: "STKaiti", size: fs) ?? NSFont.boldSystemFont(ofSize: fs)
        let para = NSMutableParagraphStyle(); para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(calibratedRed: 0.84, green: 0.08, blue: 0.06, alpha: alpha),
            .strokeWidth: -5.0,
            .strokeColor: NSColor(calibratedWhite: 0.12, alpha: alpha),
            .paragraphStyle: para,
        ]
        let s = NSAttributedString(string: bt.text, attributes: attrs)
        let sz = s.size()
        NSColor(calibratedWhite: 0.98, alpha: 0.6 * alpha).setFill()
        NSBezierPath(roundedRect: NSRect(x: b.midX - sz.width / 2 - 30, y: b.midY - sz.height / 2 - 8,
                                         width: sz.width + 60, height: sz.height + 16),
                     xRadius: 16, yRadius: 16).fill()
        s.draw(at: NSPoint(x: b.midX - sz.width / 2, y: b.midY - sz.height / 2))
    }
}
