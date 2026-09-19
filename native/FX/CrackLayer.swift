//
//  CrackLayer.swift
//  人机中国象棋 · 伤痕图层
//
//  与其他特效最大的不同: 它是**永久**的。裂痕在一瞬间炸开生长, 之后一直留在棋盘上,
//  每帧只是把已生成的点集重描一遍 —— 只有开新局或菜单手动清除才会消失。
//
import AppKit

/// 伤痕图层 (吃子留下的裂痕)。跟随震屏 —— 裂痕是棋盘的一部分。
final class CrackLayer: RenderLayer {
    let name = "cracks"
    var followsShake: Bool { true }

    /// 裂痕一旦生成就永久留在棋盘上, 只有开新局才清空
    private(set) var decals: [Crack] = []

    /// 生长阶段也要让主循环转起来 (0.42 秒的炸开动画)
    var isAnimating: Bool { decals.contains { $0.born > 0 && CACurrentMediaTime() < $0.born + $0.dur } }

    var count: Int { decals.count }

    /// 上限 60 道 —— 再多也看不清, 只会拖慢每帧的三层描边
    private let maxDecals = 60

    func add(_ c: Crack) {
        decals.append(c)
        if decals.count > maxDecals { decals.removeFirst(decals.count - maxDecals) }
    }
    func clear() { decals.removeAll() }

    /// 在指定格上放一道成熟的裂痕 (调试/开新局用)
    func forge(sq: Int, born: Double, power: CGFloat) {
        add(CrackForge.forge(sq: sq, born: born,
                             seed: UInt64(sq &* 2_654_435_761 &+ 12345), power: power))
    }

    /// 每道裂纹在诞生后的 dur 秒内"炸开生长", 之后只是静态重描 —— 裂纹点集只生成一次, 不再变化。
    func draw(_ ctx: RenderContext) {
        guard !decals.isEmpty, let cg = ctx.cg else { return }
        let cell = ctx.cell, now = ctx.now
        for c in decals {
            let age = now - c.born
            if age < 0 { continue }                              // 还没落地, 先不出现
            let e = 1 - pow(1 - CGFloat(min(1, age / c.dur)), 3)  // easeOutCubic: 炸开快、收尾慢
            let ctr = ctx.center(c.sq)
            cg.saveGState()
            cg.translateBy(x: ctr.x, y: ctr.y)
            // ① 中心焦痕: 石板被砸出的暗坑, 梯度末端 alpha 收敛到 0, 没有硬边
            if c.scorch > 0 {
                let rr = cell * c.scorch * (0.55 + 0.45 * e)
                let a = 0.42 * c.tint
                func sc(_ k: CGFloat) -> CGColor {
                    NSColor(calibratedRed: 0.10, green: 0.07, blue: 0.045, alpha: a * k).cgColor
                }
                if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: [sc(1), sc(0.72), sc(0.34), sc(0)] as CFArray,
                                      locations: [0, 0.35, 0.70, 1]) {
                    cg.drawRadialGradient(g, startCenter: .zero, startRadius: 0,
                                          endCenter: .zero, endRadius: rr, options: [])
                }
            }
            // ② 纹路: 宽的缝隙暗带 → 深色主缝 → 浅色断口亮边, 三层叠出"裂开"的立体感。
            //    每层都按生长进度 e 截断, 所以裂纹是"炸开"出来的而不是瞬间出现。
            func strokeBranch(_ branch: [CGPoint], _ off: CGFloat) {
                guard branch.count > 1 else { return }
                let pts = branch.map { CGPoint(x: $0.x * cell + off, y: $0.y * cell + off) }
                let segs = pts.count - 1
                let f = e * CGFloat(segs)
                let full = min(segs, Int(f))
                let frac = f - CGFloat(full)
                let path = CGMutablePath()
                path.move(to: pts[0])
                for i in 0..<full { path.addLine(to: pts[i + 1]) }
                if full < segs, frac > 0.001 {
                    let p0 = pts[full], p1 = pts[full + 1]
                    path.addLine(to: CGPoint(x: p0.x + (p1.x - p0.x) * frac,
                                             y: p0.y + (p1.y - p0.y) * frac))
                }
                cg.addPath(path); cg.strokePath()
            }
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            // ① 缝隙暗带: 让主裂纹读起来是"裂开的缝", 而不是"画上去的线"
            cg.setStrokeColor(NSColor(calibratedRed: 0.14, green: 0.10, blue: 0.07,
                                      alpha: (0.26 + 0.14 * c.tint) * CGFloat(min(1, age / c.dur))).cgColor)
            cg.setLineWidth(cell * c.width * 3.4)
            for (bi, b) in c.branches.enumerated() where bi < 6 { strokeBranch(b, 0) }
            // ② 深色主缝: 前 6 条是主裂纹(粗), 其余是分叉细纹
            cg.setStrokeColor(NSColor(calibratedRed: 0.09, green: 0.06, blue: 0.04,
                                      alpha: 0.55 + 0.35 * c.tint).cgColor)
            for (bi, b) in c.branches.enumerated() {
                cg.setLineWidth(cell * c.width * (bi < 6 ? 1.0 : 0.62))
                strokeBranch(b, 0)
            }
            // ③ 断口亮边: 偏移半像素, 模拟裂缝一侧被光照到的断面
            cg.setStrokeColor(NSColor(calibratedRed: 0.92, green: 0.87, blue: 0.78,
                                      alpha: 0.30).cgColor)
            cg.setLineWidth(cell * c.width * 0.45)
            for b in c.branches { strokeBranch(b, -cell * 0.006) }
            cg.restoreGState()
        }
    }
}
