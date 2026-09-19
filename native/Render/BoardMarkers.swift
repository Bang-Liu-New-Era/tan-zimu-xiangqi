//
//  BoardMarkers.swift
//  人机中国象棋 · 棋盘标记层
//
//  四类标记: 上一步起点蓝点 / 合法落点 / 提示发光 / 威胁红圈。
//  它们都是「在棋盘上叠的标记」, 与棋子本体无关, 所以自成一层的。
//
import AppKit

/// 棋盘标记层: 起点蓝点 + 合法落点 + 提示 + 威胁。跟随震屏。
final class MarkerLayer: RenderLayer {
    let name = "markers"
    var followsShake: Bool { true }

    func draw(_ ctx: RenderContext) {
        let cell = ctx.cell, now = ctx.now
        let s = ctx.scene

        // 上一步起点标记: 只用一个小圆点(直径 = 棋子直径的 1/10) + 蓝色光晕, 标出走棋前的位置
        if let lm = s.lastMove {
            let a = ctx.center(lm.0)
            let dot = cell * 0.84 / 10                 // 棋子直径(0.84 格)的 1/10
            let rr = dot / 2
            if let cg = ctx.cg {
                cg.saveGState()
                let cols = [
                    NSColor(calibratedRed: 0.28, green: 0.64, blue: 1.0, alpha: 0.85).cgColor,
                    NSColor(calibratedRed: 0.28, green: 0.64, blue: 1.0, alpha: 0.38).cgColor,
                    NSColor(calibratedRed: 0.28, green: 0.64, blue: 1.0, alpha: 0.00).cgColor,
                ] as CFArray
                if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: cols, locations: [0.0, 0.40, 1.0]) {
                    cg.drawRadialGradient(g, startCenter: a, startRadius: 0,
                                          endCenter: a, endRadius: rr * 5.0, options: [])
                }
                cg.restoreGState()
            }
            NSColor(calibratedRed: 0.20, green: 0.55, blue: 1.0, alpha: 0.95).setFill()
            NSBezierPath(ovalIn: NSRect(x: a.x - rr, y: a.y - rr, width: dot, height: dot)).fill()
            NSColor(calibratedWhite: 1, alpha: 0.85).setFill()
            let cr = rr * 0.38
            NSBezierPath(ovalIn: NSRect(x: a.x - cr, y: a.y - cr, width: 2 * cr, height: 2 * cr)).fill()
        }
        // 选中高亮: 不额外画填充/描边 —— 棋子已离板抬起, 原位只留那片深灰投影, 避免在投影边缘形成"边框"
        // (模拟模式的选中反馈同样由"抬起"承担)

        // 合法落点
        for t in s.legalTargets {
            let c = ctx.center(t)
            let cap = s.board[t] != 0
            if cap {
                if s.simMode {
                    NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.1, alpha: 0.95).setStroke()
                } else {
                    NSColor(calibratedRed: 0.9, green: 0.2, blue: 0.15, alpha: 0.9).setStroke()
                }
                NSBezierPath.defaultLineWidth = 2.5
                NSBezierPath(ovalIn: NSRect(x: c.x - cell * 0.46, y: c.y - cell * 0.46,
                                            width: cell * 0.92, height: cell * 0.92)).stroke()
            } else {
                if s.simMode {
                    NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.2, alpha: 0.9).setFill()
                } else {
                    NSColor(calibratedRed: 0.2, green: 0.5, blue: 0.2, alpha: 0.8).setFill()
                }
                NSBezierPath(ovalIn: NSRect(x: c.x - cell * 0.12, y: c.y - cell * 0.12,
                                           width: cell * 0.24, height: cell * 0.24)).fill()
            }
        }
        // 提示发光
        if let h = s.hintSq, now < ctx.hintUntil {
            let pulse = 0.5 + 0.5 * sin(now * 6)
            for sq in [h.0, h.1] {
                let c = ctx.center(sq)
                NSColor(calibratedRed: 1, green: 0.85, blue: 0.2, alpha: 0.3 + 0.4 * pulse).setFill()
                NSBezierPath(ovalIn: NSRect(x: c.x - cell * 0.5, y: c.y - cell * 0.5,
                                           width: cell, height: cell)).fill()
            }
        }
        // 威胁红圈
        for sq in s.threats {
            let c = ctx.center(sq)
            NSColor(calibratedRed: 0.9, green: 0.1, blue: 0.1, alpha: 0.85).setStroke()
            NSBezierPath.defaultLineWidth = 3
            NSBezierPath(ovalIn: NSRect(x: c.x - cell * 0.46, y: c.y - cell * 0.46,
                                        width: cell * 0.92, height: cell * 0.92)).stroke()
        }
    }
}

/// 调试层: 把每种轨迹形状从同一起点画到同一终点, 一眼比对形状差异 (XQ_FX=paths)。
/// 只在 debugShowPaths 打开时工作, 不参与震屏。
final class DebugPathLayer: RenderLayer {
    let name = "debugPaths"

    func draw(_ ctx: RenderContext) {
        guard ctx.scene.debugShowPaths, let cg = ctx.cg else { return }
        let cell = ctx.cell
        let from = 76, to = 40
        let (fr, fc) = ctx.dispRC(from), (tr, tc) = ctx.dispRC(to)
        let fx = ctx.ox + cell * CGFloat(fc), fy = ctx.oy + cell * CGFloat(fr)
        let tx = ctx.ox + cell * CGFloat(tc), ty = ctx.oy + cell * CGFloat(tr)
        var dx = tx - fx, dy = ty - fy
        let len = max(0.001, (dx * dx + dy * dy).squareRoot()); dx /= len; dy /= len
        let nm = CGPoint(x: -dy, y: dx)
        let shapes = Trajectory.Shape.allCases
        for (i, shape) in shapes.enumerated() {
            var t = Trajectory.of(shape)
            t.hop = 0.30
            let path = CGMutablePath()
            var started = false
            for k in 0...48 {
                let u = CGFloat(k) / 48
                let e = t.ease.f(u)
                let base = CGPoint(x: fx + (tx - fx) * e, y: fy + (ty - fy) * e)
                let s = t.sample(u)
                let p = CGPoint(x: base.x + nm.x * s.perp * cell,
                                y: base.y + nm.y * s.perp * cell + s.lift * cell)
                if started { path.addLine(to: p) } else { path.move(to: p); started = true }
            }
            cg.setStrokeColor(NSColor(calibratedHue: CGFloat(i) / CGFloat(shapes.count),
                                      saturation: 0.85, brightness: 0.95, alpha: 0.92).cgColor)
            cg.setLineWidth(3.0)
            cg.setLineCap(.round)
            cg.addPath(path); cg.strokePath()
        }
    }
}
