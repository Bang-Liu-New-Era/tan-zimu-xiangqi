//
//  PieceLayer.swift
//  人机中国象棋 · 棋子层
//
//  负责三件事, 三者的绘制次序不可调换 (抬起/飞行的棋子必须压在其余棋子之上):
//    ① 静止棋子 (跳过动画中的 from/to 与被抬起的那个)
//    ② 被选中抬起的棋子 + 它在棋盘原位的投影
//    ③ 走子动画中的棋子 (飞行段 / 落地回弹段)
//
import AppKit

/// 棋子层。跟随震屏。
final class PieceLayer: RenderLayer {
    let name = "pieces"
    var followsShake: Bool { true }

    /// 抬起/飞行的棋子在动 → 主循环继续跑
    var isAnimating: Bool { false }   // 状态在 BoardView, 由 BoardView 判断

    func draw(_ ctx: RenderContext) {
        let s = ctx.scene
        let cell = ctx.cell

        // ① 静止棋子 (动画期间跳过 from/to; 被选中抬起的棋子单独在最后绘制)
        for sq in 0..<90 {
            let p = s.board[sq]
            if p == 0 { continue }
            if let a = s.anim, sq == a.from || sq == a.to { continue }
            if s.liftT > 0.001, let ls = s.liftSq, sq == ls { continue }
            PieceRenderer.draw(sq, p, ctx)
        }

        // ② 被选中的棋子: 沿屏幕方向离板抬起 + 倾斜 15°, 棋盘原位留下一片投影
        if s.liftT > 0.001, let ls = s.liftSq, s.liftPiece != 0 {
            let c = ctx.center(ls)
            let lift = s.liftT
            // 投影: 留在棋盘原位。纯黑 + 45% 不透明度, 由中心向边缘平滑淡出,
            //       没有描边/没有可察觉的硬边(末端梯度平缓收敛到全透明)
            if let cg = ctx.cg {
                cg.saveGState()
                cg.translateBy(x: c.x, y: c.y - cell * 0.055 * lift)
                cg.scaleBy(x: 1.0, y: 0.94)
                let a = 0.45 * lift                       // 抬起到位时峰值 45%
                func sh(_ k: CGFloat) -> CGColor { NSColor(calibratedWhite: 0.0, alpha: a * k).cgColor }
                // 投影半径 = 棋子的可见半径 (可见直径 0.84 格 × 0.5 × 抬起放大倍数), 让投影占地面积与棋子一致。
                // 系数 1.02 是补偿渐变末端 alpha 趋 0 造成的"视觉缩小"。
                let rShadow = cell * 0.42 * (1.0 + 0.10 * lift) * 1.02
                // 峰值 30% 保持不变, 只把衰减放平缓 —— 让 30% 的灰有更大的可感知面积, 末端平滑收敛到 0(无硬边)
                let stops: [CGFloat] = [0.00, 0.28, 0.52, 0.72, 0.88, 1.00]
                let decay: [CGFloat] = [1.00, 0.95, 0.83, 0.62, 0.32, 0.00]
                let cols = decay.map { sh($0) } as CFArray
                if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: cols, locations: stops) {
                    cg.drawRadialGradient(g, startCenter: .zero, startRadius: 0,
                                          endCenter: .zero, endRadius: rShadow,
                                          options: [])
                }
                cg.restoreGState()
            }
            // 棋子本体: 朝观察者抬起。抬升 0.44 格(> 棋子半径 0.42 格), 原位才能完整露出下方的投影,
            //           否则棋子会把自己盖在棋盘上的影子全遮住; 同时略微放大并倾斜 15°
            PieceRenderer.drawAt(CGPoint(x: c.x, y: c.y + cell * 0.44 * lift), s.liftPiece, cell,
                                 rotate: CGFloat(15) * .pi / 180 * lift,
                                 sx: 1.0 + 0.10 * lift, sy: 1.0 + 0.10 * lift,
                                 castShadow: false)
        }

        // ③ 走子动画
        if let a = s.anim {
            let el = ctx.now - a.start
            let (fr, fc) = ctx.dispRC(a.from), (tr, tc) = ctx.dispRC(a.to)   // 必须经翻转映射, 否则动画走镜像路径
            let fx = ctx.ox + cell * CGFloat(fc), fy = ctx.oy + cell * CGFloat(fr)
            let tx = ctx.ox + cell * CGFloat(tc), ty = ctx.oy + cell * CGFloat(tr)
            if el <= a.fly {
                // ===== 飞行段: 沿轨迹推进(缓动) + 侧偏 + 抬升 + 空中翻转 =====
                let u = CGFloat(max(0, min(1, el / a.fly)))
                let e = a.traj.ease.f(u)                        // 推进节奏 (与形状解耦)
                let base = CGPoint(x: fx + (tx - fx) * e, y: fy + (ty - fy) * e)
                // 垂直于 A→B 的单位法线, 供"绕侧翼 / 贝塞尔 / 折线"做横向偏移
                var dx = tx - fx, dy = ty - fy
                let len = max(0.001, (dx * dx + dy * dy).squareRoot())
                dx /= len; dy /= len
                let nm = CGPoint(x: -dy, y: dx)
                let sp = a.traj.sample(u)                       // (侧偏, 抬升, 旋转, 缩放) 单位: 格
                let ground = CGPoint(x: base.x + nm.x * sp.perp * cell,
                                     y: base.y + nm.y * sp.perp * cell)
                let air = CGPoint(x: ground.x, y: ground.y + sp.lift * cell)
                // 影子留在棋盘上(不跟着飞), 随高度扩散变淡
                PieceRenderer.flightShadow(ground, cell, a.traj.hop > 0.0001 ? sp.lift / a.traj.hop : 0)
                PieceRenderer.drawAt(air, a.piece, cell, rotate: sp.rot, sx: sp.scale, sy: sp.scale,
                                     castShadow: false)
            } else {
                // ===== 落地段: 压扁 → 轻微过冲回弹 → 稳定 (阻尼振荡) =====
                let v = CGFloat(max(0, min(1, (el - a.fly) / a.land)))
                let amp = 0.13 * exp(-4.2 * v) * cos(6.2 * v)
                PieceRenderer.drawAt(CGPoint(x: tx, y: ty), a.piece, cell,
                                     sx: 1 + amp * 0.65, sy: 1 - amp, castShadow: false)
            }
        }
    }
}
