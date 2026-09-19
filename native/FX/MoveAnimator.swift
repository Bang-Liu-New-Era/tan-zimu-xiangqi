//
//  MoveAnimator.swift
//  人机中国象棋 · 走子动画
//
//  负责"一次走子"的编排: 起手清掉抬起状态 → 交给轨迹引擎播飞行 → 落地回弹 →
//  顺带把吃子爆点、棋盘开裂、冲击震屏一起挂钩到「落地那一刻」。
//
import AppKit

extension BoardView {
    /// 一次走子动画的记录 (轨迹提供形状/缓动/姿态, 落地后接阻尼回弹)
    struct MoveAnim {
        let from: Int, to: Int, piece: Int
        let start: Double
        let traj: Trajectory
        var fly: Double { traj.fly }      // 飞行时长
        var land: Double { traj.land }    // 落地回弹时长
        var total: Double { fly + land }
    }

    /// 播放一次走子。
    /// - Parameter scar: 是否留下永久裂痕。模拟推演传 false —— 那是"假设", 不该弄脏棋盘。
    func animateMove(from: Int, to: Int, piece: Int, capture: Bool, captured: Int,
                     style: Trajectory? = nil, scar: Bool = true,
                     completion: @escaping () -> Void) {
        let now = CACurrentMediaTime()
        // 起手飞子: 立刻结束抬起状态, 让棋子从棋盘原位起飞
        liftT = 0; liftSq = nil; liftPiece = 0
        let t = style ?? traj
        let fly = t.fly, land = t.land
        anim = MoveAnim(from: from, to: to, piece: piece, start: now, traj: t)
        let landT = now + fly                       // 落地那一刻
        burstLayer.landRipple = (to, landT)
        if capture {
            let kind = (piece == 6 || piece == 14) ? 1   // 炮
                : (piece == 4 || piece == 12) ? 2          // 马
                : (piece == 5 || piece == 13) ? 3 : 0      // 车
            let (ox, oy, cellL) = layout
            let a = center(from, ox, oy, cellL), z = center(to, ox, oy, cellL)
            var dx = z.x - a.x, dy = z.y - a.y
            let len = max(0.001, (dx * dx + dy * dy).squareRoot())
            dx /= len; dy /= len
            // 特效在"落地那一刻"触发, 与压扁回弹同步
            burstLayer.effects.append(FX(sq: to, start: now + fly * 0.92, dur: 0.75, kind: kind,
                                         piece: captured, dir: CGPoint(x: dx, y: dy)))
            // 棋盘开裂: 裂纹在落地瞬间开始生长, 之后永久留在棋盘上。
            // 模拟推演(scar=false)是"假设", 不留痕。
            if crackEnabled && scar {
                let power: CGFloat = (piece == 5 || piece == 13) ? 1.00   // 车: 碾碎
                    : (piece == 6 || piece == 14) ? 0.92                  // 炮: 轰炸
                    : (piece == 4 || piece == 12) ? 0.80 : 0.72           // 马/其他
                let seed = UInt64(bitPattern: Int64(to &* 7919 &+ 104729))
                    &+ UInt64(now * 1000) &* 2_654_435_761
                crackLayer.add(CrackForge.forge(sq: to, born: landT, seed: seed, power: power))
                shakeUntil = max(shakeUntil, landT + 0.20)   // 冲击震屏
            }
        }
        kick()
        DispatchQueue.main.asyncAfter(deadline: .now() + fly + land + 0.01) { self.anim = nil; completion() }
    }
}
