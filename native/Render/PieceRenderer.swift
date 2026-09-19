//
//  PieceRenderer.swift
//  人机中国象棋 · 棋子渲染
//
//  纯函数式渲染器: 只依赖入参与当前 NSGraphicsContext, 不持有任何状态。
//  因此棋盘层、瞬态特效层、演员层都能直接复用, 不需要绕回 BoardView。
//
import AppKit
import CoreText

enum PieceRenderer {
    /// 在网格交叉点上画一枚棋子
    static func draw(_ sq: Int, _ p: Int, _ ctx: RenderContext) {
        drawAt(ctx.center(sq), p, ctx.cell)
    }

    /// 在任意位置画一枚棋子 (供飞行中的棋子、被踢飞的棋子复用)
    static func drawAt(_ ctr: CGPoint, _ p: Int, _ cell: CGFloat,
                       rotate: CGFloat = 0, sx: CGFloat = 1, sy: CGFloat = 1, alpha: CGFloat = 1,
                       castShadow: Bool = true) {
        let isRed = p <= 7
        let name = PIECE_CHARS[p] ?? "?"
        let r = cell * 0.42                 // 棋子半径 = 0.42 格 (直径 0.84 格)
        let rect = NSRect(x: -r, y: -r, width: 2 * r, height: 2 * r)
        NSGraphicsContext.saveGraphicsState()
        let cg = NSGraphicsContext.current?.cgContext
        // ① 投影: 用棋子轮廓在正下方投一圈暗影, 让棋子"坐"在棋盘上。
        //    影子偏移 = 棋子直径的 1/16 (≈0.05 格), 模糊收窄到棋子下沿, 形成一圈厚度感。
        //    阴影固定在交叉点方向(不参与棋子自身的旋转/压扁变换), 所以飞子时影子仍落在棋盘上。
        if castShadow, alpha > 0.55, let c = cg {
            c.saveGState()
            c.setShadow(offset: CGSize(width: 0, height: -(r * 2) / 16),
                        blur: cell * 0.045,
                        color: NSColor(calibratedWhite: 0, alpha: 0.55).cgColor)
            c.setFillColor(NSColor.black.cgColor)
            let s = r * 0.96
            c.fillEllipse(in: CGRect(x: ctr.x - s, y: ctr.y - s, width: 2 * s, height: 2 * s))
            c.restoreGState()
        }
        // ② 棋子本体
        cg?.translateBy(x: ctr.x, y: ctr.y)
        if rotate != 0 { cg?.rotate(by: rotate) }
        if sx != 1 || sy != 1 { cg?.scaleBy(x: sx, y: sy) }
        if alpha < 1 { cg?.setAlpha(alpha) }
        // 优先使用棋子贴图; 缺图时回退为程序化绘制
        if let tex = PieceTextures.image(p) {
            let side = cell * PIECE_TEX_SPAN
            let box = NSRect(x: -side / 2, y: -side / 2, width: side, height: side)
            NSGraphicsContext.current?.imageInterpolation = .high
            tex.draw(in: box, from: .zero, operation: .sourceOver, fraction: alpha)
        } else {
            NSColor(calibratedRed: 0.97, green: 0.93, blue: 0.82, alpha: 1).setFill()
            NSBezierPath(ovalIn: rect).fill()
            let ring = isRed
                ? NSColor(calibratedRed: 0.75, green: 0.16, blue: 0.12, alpha: 1)
                : NSColor(calibratedRed: 0.1, green: 0.1, blue: 0.1, alpha: 1)
            ring.setStroke()
            let bp = NSBezierPath(ovalIn: rect); bp.lineWidth = cell * 0.05; bp.stroke()
            NSBezierPath(ovalIn: NSRect(x: -r * 0.8, y: -r * 0.8, width: 1.6 * r, height: 1.6 * r)).stroke()
            let color = isRed
                ? NSColor(calibratedRed: 0.78, green: 0.13, blue: 0.1, alpha: 1)
                : NSColor.black
            let font = NSFont(name: "STKaiti", size: cell * 0.5) ?? NSFont.boldSystemFont(ofSize: cell * 0.5)
            // 用 CoreText 字形包围盒精确居中 (不受字体行高/基线影响)
            let attr = NSAttributedString(string: name, attributes: [.font: font, .foregroundColor: color])
            let line = CTLineCreateWithAttributedString(attr)
            let gb = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
            if let c = cg {
                c.textPosition = CGPoint(x: -gb.midX, y: -gb.midY)
                CTLineDraw(line, c)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 飞行中棋子投在棋盘上的影子: 固定落在棋子正下方的地面位置, 随抬升高度扩散、变淡。
    /// (飞行棋子的 castShadow 必须关掉, 否则影子会跟着棋子一起飞。)
    static func flightShadow(_ ground: CGPoint, _ cell: CGFloat, _ arc: CGFloat) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState()
        cg.translateBy(x: ground.x, y: ground.y)
        cg.scaleBy(x: 1.0, y: 0.94)
        let a = 0.34 - 0.10 * arc                       // 越高越淡
        func sh(_ k: CGFloat) -> CGColor { NSColor(calibratedWhite: 0, alpha: a * k).cgColor }
        let stops: [CGFloat] = [0.00, 0.28, 0.52, 0.72, 0.88, 1.00]
        let decay: [CGFloat] = [1.00, 0.95, 0.83, 0.62, 0.32, 0.00]
        if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                              colors: decay.map(sh) as CFArray, locations: stops) {
            let rr = cell * 0.42 * (1.0 + 0.24 * arc)   // 越高越散, 但占地仍与棋子相当
            cg.drawRadialGradient(g, startCenter: .zero, startRadius: 0,
                                  endCenter: .zero, endRadius: rr, options: [])
        }
        cg.restoreGState()
    }
}
