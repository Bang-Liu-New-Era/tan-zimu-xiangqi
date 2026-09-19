//
//  BurstLayer.swift
//  人机中国象棋 · 吃子爆点层
//
//  一次性的瞬时特效: 落地涟漪 + 四种吃子爆点 (普通红圈 / 炮·爆炸 / 马·踢飞 / 车·碾碎)。
//  生命周期很短, 播完即从列表里剔除 —— 它同时也是"主循环还要不要跑"的判据之一。
//
import AppKit

/// 一次吃子特效的记录
struct FX {
    let sq: Int; let start: Double; let dur: Double; let kind: Int
    let piece: Int; let dir: CGPoint
}

/// 瞬态特效层。跟随震屏 (爆点属于棋盘上的事件)。
final class BurstLayer: RenderLayer {
    let name = "bursts"
    var followsShake: Bool { true }

    /// kind 0=普通 1=炮·爆炸 2=马·踢飞 3=车·碾碎
    var effects: [FX] = []
    /// 最近一次落地涟漪 (落点轻轻荡开的一圈淡光)
    var landRipple: (sq: Int, start: Double)?

    var isAnimating: Bool { !effects.isEmpty || landRipple != nil }

    /// 主循环每帧调用: 剔除已播完的特效 (以前写在 draw() 里, 现在收敛到推进阶段)
    func update(_ ctx: RenderContext) {
        if !effects.isEmpty { effects.removeAll { ctx.now >= $0.start + $0.dur } }
        if let r = landRipple, ctx.now >= r.start + 0.26 { landRipple = nil }
    }

    func draw(_ ctx: RenderContext) {
        let cell = ctx.cell, now = ctx.now

        // 落地涟漪: 落子瞬间从落点荡开的一圈淡影
        if let r = landRipple, now >= r.start, now < r.start + 0.26 {
            let v = CGFloat((now - r.start) / 0.26)
            let c = ctx.center(r.sq)
            let fade = (1 - v) * (1 - v)
            NSColor(calibratedWhite: 0.12, alpha: 0.30 * fade).setStroke()
            NSBezierPath.defaultLineWidth = max(1, cell * 0.04 * (1 - v))
            let rr = cell * (0.40 + 0.38 * v)
            NSBezierPath(ovalIn: NSRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr)).stroke()
        }

        // 吃子特效 (炮=爆炸 / 马=踢飞 / 车=碾碎 / 其他=红圈)
        for e in effects {
            let t = (now - e.start) / e.dur
            if t >= 1 || t < 0 { continue }
            let ft = CGFloat(t)
            let c = ctx.center(e.sq)
            switch e.kind {
            case 1: // ===== 炮·爆炸 =====
                // 爆炸白闪
                let flash = max(0, 1 - ft * 3.5)
                if flash > 0 {
                    NSColor(calibratedRed: 1, green: 0.96, blue: 0.75, alpha: flash * 0.95).setFill()
                    NSBezierPath(ovalIn: NSRect(x: c.x - cell * 0.6, y: c.y - cell * 0.6,
                                                width: cell * 1.2, height: cell * 1.2)).fill()
                }
                // 三层火环
                let rings: [(CGFloat, NSColor)] = [
                    (0.95, NSColor(calibratedRed: 0.95, green: 0.25, blue: 0.08, alpha: 1 - ft)),
                    (0.7,  NSColor(calibratedRed: 1, green: 0.55, blue: 0.1, alpha: 0.85 * (1 - ft))),
                    (1.3,  NSColor(calibratedRed: 0.4, green: 0.15, blue: 0.05, alpha: 0.6 * (1 - ft))),
                ]
                for (spd, col) in rings {
                    col.setStroke()
                    NSBezierPath.defaultLineWidth = cell * 0.12 * (1 - ft) + 1
                    let rr = cell * (0.25 + spd * ft)
                    NSBezierPath(ovalIn: NSRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr)).stroke()
                }
                // 放射火花
                for i in 0..<10 {
                    let ang = CGFloat(i) / 10 * 2 * .pi + 0.31
                    let d = cell * (0.3 + 1.15 * ft)
                    let px = c.x + cos(ang) * d, py = c.y + sin(ang) * d
                    let rad = cell * 0.075 * (1 - ft) + 0.5
                    NSColor(calibratedRed: 1, green: 0.45 + 0.35 * (1 - ft), blue: 0.1, alpha: 1 - ft).setFill()
                    NSBezierPath(ovalIn: NSRect(x: px - rad, y: py - rad, width: 2 * rad, height: 2 * rad)).fill()
                }
            case 2: // ===== 马·踢飞 =====
                // 被吃棋子沿走子方向踢飞 (抛物线 + 旋转 + 淡出)
                let d = cell * 2.5 * ft
                let arc = sin(.pi * ft) * cell * 1.0
                let pos = CGPoint(x: c.x + e.dir.x * d, y: c.y + e.dir.y * d + arc)
                PieceRenderer.drawAt(pos, e.piece, cell, rotate: ft * 11, alpha: 1 - ft * ft)
                // 原地扬起的尘土
                for i in 0..<5 {
                    let ang = CGFloat(i) * 1.3 + 0.5
                    let dd = cell * (0.15 + 0.55 * ft)
                    let px = c.x + cos(ang) * dd, py = c.y + sin(ang) * dd * 0.4 + cell * 0.2 * ft
                    let rad = cell * 0.1 * (1 - ft) + 0.5
                    NSColor(calibratedWhite: 0.55, alpha: 0.5 * (1 - ft)).setFill()
                    NSBezierPath(ovalIn: NSRect(x: px - rad, y: py - rad, width: 2 * rad, height: 2 * rad)).fill()
                }
            case 3: // ===== 车·碾碎 =====
                // 被吃棋子被压扁
                let crush = min(1, ft * 2.2)
                let sy = 1 - 0.74 * crush
                let sx = 1 + 0.42 * crush
                let fade = ft < 0.55 ? 1 : CGFloat(1 - (ft - 0.55) / 0.45)
                PieceRenderer.drawAt(c, e.piece, cell, sx: sx, sy: sy, alpha: fade)
                // 裂纹
                if ft > 0.15 {
                    NSColor(calibratedRed: 0.15, green: 0.05, blue: 0.02, alpha: fade).setStroke()
                    NSBezierPath.defaultLineWidth = 2
                    let w = cell * 0.4 * sx
                    for i in 0..<4 {
                        let ang = CGFloat(i) * 1.7 + 0.4
                        NSBezierPath.strokeLine(
                            from: CGPoint(x: c.x + cos(ang) * w * 0.12, y: c.y + sin(ang) * w * 0.12),
                            to: CGPoint(x: c.x + cos(ang) * w * 0.95, y: c.y + sin(ang) * w * 0.45))
                    }
                }
                // 冲击波 + 横向碎屑
                let wr = cell * (0.3 + 1.1 * ft)
                NSColor(calibratedRed: 0.5, green: 0.3, blue: 0.1, alpha: 0.5 * (1 - ft)).setStroke()
                NSBezierPath.defaultLineWidth = 3 * (1 - ft) + 0.5
                NSBezierPath(ovalIn: NSRect(x: c.x - wr, y: c.y - wr * 0.35,
                                            width: 2 * wr, height: wr * 0.7)).stroke()
                for i in 0..<6 {
                    let sgn: CGFloat = i % 2 == 0 ? 1 : -1
                    let dd = cell * (0.35 + 0.9 * ft) * sgn
                    let py = c.y + CGFloat(i / 2) * cell * 0.12 - cell * 0.12
                    let rad = cell * 0.06 * (1 - ft) + 0.5
                    NSColor(calibratedRed: 0.35, green: 0.2, blue: 0.1, alpha: 1 - ft).setFill()
                    NSBezierPath(ovalIn: NSRect(x: c.x + dd - rad, y: py - rad,
                                                width: 2 * rad, height: 2 * rad)).fill()
                }
            default: // ===== 普通吃子: 红圈 =====
                NSColor(calibratedRed: 0.95, green: 0.2, blue: 0.15, alpha: 1 - ft).setStroke()
                NSBezierPath.defaultLineWidth = 3 * (1 - ft)
                let rr = cell * (0.2 + 0.5 * ft)
                NSBezierPath(ovalIn: NSRect(x: c.x - rr, y: c.y - rr, width: 2 * rr, height: 2 * rr)).stroke()
            }
        }
    }
}
