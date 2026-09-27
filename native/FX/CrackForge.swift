//
//  CrackForge.swift
//  人机中国象棋 · 裂痕: Crack + CrackForge
//
//  ── 碎裂石板 · H 方案 (2026-09-27 定稿, 自 /tmp/xqcrk 预览台落地) ──
//  用户在 F/G/H/I 四套候选里选了 H「碎裂·细碎」: 碎区 56% 棋子面积、约 8 块碎块、
//  缝最细(0.034 格)、块内发丝裂最多(11 条) —— 近看是碎渣, 远看是一团麻。
//
//  主体不是"几条从中心射出的线", 而是棋子把石板**压碎成块**:
//    ① 在冲击点周围撒种子(比碎块数多两三倍), 做**功率图**(加权 Voronoi)切块。
//       权重随机 → 有的块大有的块小, 交界处出现 T 形接头 —— 等大的格子一眼是"生成"的。
//    ② 只取**离冲击点最近的一撮**碎块当"碎区", 凑到目标面积为止; 其余种子是"还没碎的
//       邻居", 不画。于是碎区轮廓 = 外侧碎块的边自己拼出来的锯齿口 —— 不是裁出来的圆弧。
//    ③ 缝只在**碎块与碎块之间**产生: 每块沿与碎邻居的交界往里缩半个缝宽; 与"没碎的邻居"
//       之间的那条边**不缩** —— 碎区外缘没有环绕一圈的黑沟(那是"贴上去的圆标签"的元凶)。
//    ④ 收完按**面积加权重心**把整片碎区拉回冲击点 —— "最近的一撮"不一定正对棋子下方。
//  收块规则两条一起用(缺一条都不行):
//    · 硬约束: 面积一旦超过 80% 棋子面积立刻停(只判"够没够"会冲到 83%);
//    · 逼近目标: 离目标更远就停(只有硬约束会过分保守, 实测掉到 46%)。
//
//  块内再补一点发丝裂(走 CrackLayer 的坡口画法, 细)与石面颗粒; 块间明暗差让"一堆石头"
//  的读感成立。缝的绘制(未缩块−内缩块, nonzero 一次填充)见 CrackLayer.drawShatter。
//
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

struct Crack {
    let sq: Int
    let born: Double              // 出生时刻(绝对秒): 落地那一刻才开始生长
    let branches: [[CGPoint]]     // 块内发丝裂 (走纹路坡口画法, 只做毛刺)
    let mainCount: Int            // 前这么多条是主裂纹
    let weights: [CGFloat]        // 与 branches 一一对应的粗细系数
    let width: CGFloat            // 发丝裂线宽(格)
    let tint: CGFloat             // 0=浅 1=深
    let scorch: CGFloat           // 中心焦痕半径(格), 碎裂版恒 0 (砸痕由碎区自己承担)
    let seed: UInt64              // 供渲染层做"逐段抖动/掐细"的确定性扰动
    let dur: Double = 0.46        // 生长时长 (含发丝裂的出场延迟)
    // ── 碎裂石板 ──
    let cells: [[CGPoint]]        // 内缩过的碎块 (真正画出来的形状)
    let cellsFull: [[CGPoint]]    // 未内缩的碎块 (只用来算出"缝"这条带子)
    let cellShade: [CGFloat]      // 逐块明暗差 (-1~1), 块与块不同才有"一堆石头"
    let seam: CGFloat             // 缝宽 (格)
    let stipple: [CGPoint]        // 砂粒暗点 (只撒在块内)
    let dust: [CGPoint]           // 石粉亮点 (只撒在块内)
}

/// 发丝裂的分桶容器 (主纹/细纹分开收, 渲染层按同一顺序配 weights)。
private final class CrackSink {
    var mains: [[CGPoint]] = [], mainW: [CGFloat] = []
    var fines: [[CGPoint]] = [], fineW: [CGFloat] = []
    func put(_ pts: [CGPoint], _ w: CGFloat, main: Bool) {
        guard pts.count >= 2 else { return }
        if main { mains.append(pts); mainW.append(w) } else { fines.append(pts); fineW.append(w) }
    }
}

enum CrackForge {

    /// 棋子可见半径 (格) —— 碎区面积的参照
    private static let pieceR: CGFloat = 0.42

    /// H「碎裂·细碎」配方: 碎区 56% 棋子面积、8 块碎块、细缝、发丝裂多
    private static let area: CGFloat = 0.56
    private static let pieces = 8
    private static let seamW: CGFloat = 0.034
    private static let spread: CGFloat = 1.60      // 功率图权重幅度 (碎块大小差异)
    private static let chips = 11                  // 块内发丝裂数
    private static let grit: CGFloat = 520         // 石面颗粒密度 (点/格²)
    private static let hairW: CGFloat = 0.026      // 发丝裂线宽 (格)

    /// power: 0.7~1.0 的破坏力(车碾碎最大)。碎区面积按 H 定稿固定, power 只调线宽与深浅。
    static func forge(sq: Int, born: Double, seed: UInt64, power: CGFloat) -> Crack {
        var rng = SeededRNG(seed)
        let sink = CrackSink()
        let rz = pieceR * area.squareRoot()        // 碎区等效半径 (0.42·√0.56 ≈ 0.314 格)

        var mo = shatter(&rng, rz: rz, pieces: pieces, seam: seamW, spread: spread, offset: 0)

        // 块内发丝裂: 从块的某条边往里钻, 短、不齐 —— 块的"碎"是缝给的, 块内只需一点毛刺
        for _ in 0..<max(1, chips + rng.int(3) - 1) where !mo.cells.isEmpty {
            let ci = rng.int(mo.cells.count)
            let poly = mo.cells[ci]
            guard poly.count >= 3 else { continue }
            let ei = rng.int(poly.count)
            let a = poly[ei], b = poly[(ei + 1) % poly.count]
            let t = rng.range(0.15, 0.85)
            let p0 = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            let cx = poly.reduce(0) { $0 + $1.x } / CGFloat(poly.count)
            let cy = poly.reduce(0) { $0 + $1.y } / CGFloat(poly.count)
            let inward = atan2(cy - p0.y, cx - p0.x)
            sink.put(walk(&rng, from: p0, a0: inward + rng.range(-0.70, 0.70),
                          total: min(hypot(cx - p0.x, cy - p0.y) * rng.range(0.45, 0.95),
                                     rz * rng.range(0.14, 0.34)),
                          steps: 2 + rng.int(2), spread: 0.52),
                     rng.range(0.45, 0.80), main: false)
        }

        // 石面颗粒: 只落在碎块内部 (落在缝里会被缝盖掉, 白画)
        var zrng = SeededRNG(seed &* 31 &+ 7)
        let n0 = Int(grit * rz * rz * 3.14)
        let stipple = inCells(&zrng, cells: mo.cells, count: n0)
        let dust = inCells(&zrng, cells: mo.cells, count: max(6, n0 / 9))

        return Crack(sq: sq, born: born,
                     branches: sink.mains + sink.fines,
                     mainCount: sink.mains.count,
                     weights: sink.mainW + sink.fineW,
                     width: hairW * (0.92 + 0.16 * power),
                     tint: min(1, 0.82 + 0.18 * power),
                     scorch: 0,
                     seed: seed,
                     cells: mo.cells, cellsFull: mo.full,
                     cellShade: mo.shade, seam: mo.seam,
                     stipple: stipple, dust: dust)
    }

    // MARK: - 碎裂几何

    /// 碎裂切块的结果
    private struct Mosaic {
        var cells: [[CGPoint]] = []       // 内缩过的碎块 (真正画出来的形状)
        var full: [[CGPoint]] = []        // 未内缩的碎块 (只用于算出"缝"这条带子)
        var shade: [CGFloat] = []
        var seam: CGFloat = 0.034
    }

    /// 碎裂切块 (功率图 + 就近收块)。算法说明见文件头。
    private static func shatter(_ rng: inout SeededRNG, rz: CGFloat, pieces: Int,
                                seam: CGFloat, spread: CGFloat, offset: CGFloat) -> Mosaic {
        var mo = Mosaic(seam: seam)
        let a0 = rng.range(0, 2 * .pi)
        let cx = cos(a0) * rz * offset, cy = sin(a0) * rz * offset
        let R = rz * 1.95                                   // 撒种子的范围 (远大于碎区)
        let target = CGFloat.pi * rz * rz                   // 目标碎区面积

        let nSeed = max(12, Int(CGFloat(pieces) * 3.8))
        var seeds: [CGPoint] = []
        let minD = 1.45 * R / CGFloat(nSeed).squareRoot()
        var tries = 0
        while seeds.count < nSeed && tries < nSeed * 240 {
            tries += 1
            let a = rng.range(0, 2 * .pi)
            let r = R * rng.range(0, 1.0).squareRoot()      // r = R√u 才是面积均匀
            let p = CGPoint(x: cx + cos(a) * r, y: cy + sin(a) * r)
            if seeds.allSatisfy({ hypot($0.x - p.x, $0.y - p.y) > minD * 0.55 }) { seeds.append(p) }
        }
        guard seeds.count >= 8 else { return mo }

        let disk = circlePoly(cx: cx, cy: cy, r: R, k: 26)
        let wUnit = R * R / CGFloat(seeds.count) * spread
        let wt = seeds.map { _ in wUnit * rng.range(-0.85, 0.85) }
        let hseed = rng.next()

        // 每块的裁切半平面: (邻居序号, 法线, 常数)。先算好 —— 后面要按"邻居碎没碎"决定缩不缩半条缝。
        var planes: [[(j: Int, nx: CGFloat, ny: CGFloat, c: CGFloat)]] = []
        for i in 0..<seeds.count {
            var pl: [(j: Int, nx: CGFloat, ny: CGFloat, c: CGFloat)] = []
            for j in 0..<seeds.count where j != i {
                let dx = seeds[j].x - seeds[i].x, dy = seeds[j].y - seeds[i].y
                let L = (dx * dx + dy * dy).squareRoot()
                if L < 0.0001 { continue }
                // |p−si|² − wi ≤ |p−sj|² − wj  ⟹  p·n ≤ (|sj|² − |si|² − wj + wi) / 2L
                let c = ((seeds[j].x * seeds[j].x + seeds[j].y * seeds[j].y)
                         - (seeds[i].x * seeds[i].x + seeds[i].y * seeds[i].y)
                         - wt[j] + wt[i]) / (2 * L)
                pl.append((j, dx / L, dy / L, c))
            }
            planes.append(pl)
        }

        /// 切出第 i 块: 邻居 j 也碎了的话, 这条边往里缩半个缝宽 (缝只在碎块之间产生)
        func build(_ i: Int, _ broken: [Bool]) -> [CGPoint] {
            var poly = disk
            for p in planes[i] {
                let off = (p.j < broken.count && broken[p.j]) ? seam * 0.5 : 0
                poly = clipHalf(poly, p.nx, p.ny, p.c - off)
                if poly.count < 3 { return [] }
            }
            return poly
        }

        // 先按"未缩"的块算面积, 再按离冲击点的距离由近到远收, 凑到目标面积
        let none = [Bool](repeating: false, count: seeds.count)
        var whole: [[CGPoint]] = []
        var dist: [CGFloat] = []
        for i in 0..<seeds.count {
            whole.append(build(i, none))
            dist.append(hypot(seeds[i].x - cx, seeds[i].y - cy))
        }
        let order = (0..<seeds.count).sorted { dist[$0] < dist[$1] }
        var broken = none
        var acc: CGFloat = 0
        let cap = CGFloat.pi * pieceR * pieceR * 0.80        // 硬上界: 80% 棋子面积
        for i in order {
            let a = abs(signsArea(whole[i]))
            let cand = acc + a
            if cand > cap { break }
            if abs(cand - target) > abs(acc - target) { break }
            broken[i] = true
            acc = cand
        }
        if acc <= 0 {   // 兜底: 第一块就超也要有东西可画
            broken[order[0]] = true
        }

        // 收完之后整片碎区会偏离冲击点 (最近的一撮碎块不一定是"正对面"那一撮)。
        // 按**面积加权重心**把它拉回冲击点 —— 压痕理应在棋子正下方。
        var picked: [(full: [CGPoint], inset: [CGPoint], shade: CGFloat)] = []
        var totA: CGFloat = 0, gx: CGFloat = 0, gy: CGFloat = 0
        for i in 0..<seeds.count where broken[i] {
            let full = whole[i]
            let inset = build(i, broken)
            guard full.count >= 3, inset.count >= 3 else { continue }
            var a: CGFloat = 0, px: CGFloat = 0, py: CGFloat = 0
            for k in 0..<full.count {
                let p0 = full[k], p1 = full[(k + 1) % full.count]
                let cross = p0.x * p1.y - p1.x * p0.y
                a += cross
                px += (p0.x + p1.x) * cross
                py += (p0.y + p1.y) * cross
            }
            a *= 0.5
            let ax = abs(a)
            totA += ax
            if ax > 0.0000001 { gx += px / (6 * a) * ax; gy += py / (6 * a) * ax }
            picked.append((full, inset, rng.range(-1, 1)))
        }
        guard totA > 0 else { return mo }
        let sx = cx - gx / totA, sy = cy - gy / totA
        for it in picked {
            mo.full.append(it.full.map { CGPoint(x: $0.x + sx, y: $0.y + sy) })
            mo.cells.append(chipEdges(&rng,
                it.inset.map { jittered(CGPoint(x: $0.x + sx, y: $0.y + sy), seed: hseed,
                                        amp: seam * 0.30) }, seam: seam))
            mo.shade.append(it.shade)
        }
        return mo
    }

    /// 正多边形 (裁切框用)。要 26 边 —— 边数太少, 裁出来的碎块外缘全是同一段圆弧的切片。
    private static func circlePoly(cx: CGFloat, cy: CGFloat, r: CGFloat, k: Int) -> [CGPoint] {
        var pts: [CGPoint] = []
        for i in 0..<k {
            let t = CGFloat(i) / CGFloat(k) * 2 * .pi
            pts.append(CGPoint(x: cx + cos(t) * r, y: cy + sin(t) * r))
        }
        return pts
    }

    /// 顶点按坐标决定性地抖动 (共享顶点必须落到同一处, 否则碎块之间会裂开)
    private static func jittered(_ p: CGPoint, seed: UInt64, amp: CGFloat) -> CGPoint {
        let qx = Int((p.x * 8192).rounded()), qy = Int((p.y * 8192).rounded())
        let a = SeededRNG.hash01(seed, qx & 0x7FFF, qy & 0x7FFF)
        let b = SeededRNG.hash01(seed &+ 5171, qx & 0x7FFF, qy & 0x7FFF)
        return CGPoint(x: p.x + (a - 0.5) * 2 * amp, y: p.y + (b - 0.5) * 2 * amp)
    }

    /// 把每条边打断成 2~3 段短直边, 并让中点侧向偏一点。
    /// 功率图的一条边是两个种子之间的中垂线 —— 一个 cell 常常只有两三条长直边,
    /// 描出来就是"切开的饼"; 参考图里的断口全是一小段一小段的折线。
    /// 侧移量只有缝宽的 ±1/3: 于是缝宽自己会时宽时窄, 但不会把缝掐断或撑成两倍。
    private static func chipEdges(_ rng: inout SeededRNG, _ poly: [CGPoint], seam: CGFloat) -> [CGPoint] {
        guard poly.count >= 3 else { return poly }
        var out: [CGPoint] = []
        let n = poly.count
        for i in 0..<n {
            let a = poly[i], b = poly[(i + 1) % n]
            out.append(a)
            let dx = b.x - a.x, dy = b.y - a.y
            let L = (dx * dx + dy * dy).squareRoot()
            if L < seam * 2.6 { continue }                      // 太短的边不再细分, 否则整片都是碎点
            let parts = L > seam * 5.5 ? 3 : 2
            let nx = dy / max(0.0001, L), ny = -dx / max(0.0001, L)
            for k in 1..<parts {
                let t = CGFloat(k) / CGFloat(parts) + rng.range(-0.10, 0.10)
                let off = rng.range(-0.34, 0.34) * seam
                out.append(CGPoint(x: a.x + dx * t + nx * off, y: a.y + dy * t + ny * off))
            }
        }
        return out
    }

    /// 保留 dot(p, n) ≤ c 的一侧 (Sutherland–Hodgman, 只裁一条半平面)
    private static func clipHalf(_ poly: [CGPoint], _ nx: CGFloat, _ ny: CGFloat,
                                 _ c: CGFloat) -> [CGPoint] {
        guard poly.count >= 3 else { return [] }
        var out: [CGPoint] = []
        let n = poly.count
        for i in 0..<n {
            let a = poly[i], b = poly[(i + 1) % n]
            let da = a.x * nx + a.y * ny - c
            let db = b.x * nx + b.y * ny - c
            if da <= 0 { out.append(a) }
            if (da < 0 && db > 0) || (da > 0 && db < 0) {
                let t = da / (da - db)
                out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
        }
        return out
    }

    /// 从 p0 沿 a0 走一条不规则折线 (发丝裂用)
    private static func walk(_ rng: inout SeededRNG, from p0: CGPoint, a0: CGFloat,
                             total: CGFloat, steps: Int, spread: CGFloat) -> [CGPoint] {
        var pts: [CGPoint] = [p0]
        var p = p0, a = a0
        let step = total / CGFloat(max(1, steps))
        for _ in 0..<steps {
            a += rng.range(-spread, spread)
            let L = step * rng.range(0.70, 1.30)
            p = CGPoint(x: p.x + cos(a) * L, y: p.y + sin(a) * L)
            pts.append(p)
        }
        return pts
    }

    private static func signsArea(_ p: [CGPoint]) -> CGFloat {
        guard p.count >= 3 else { return 0 }
        var s: CGFloat = 0
        for i in 0..<p.count {
            let a = p[i], b = p[(i + 1) % p.count]
            s += a.x * b.y - b.x * a.y
        }
        return s * 0.5
    }

    private static func pointIn(_ poly: [CGPoint], _ p: CGPoint) -> Bool {
        guard poly.count >= 3 else { return false }
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y),
               p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    /// 撒在碎块内部的颗粒 (落在缝里的会被缝盖掉, 白画)
    private static func inCells(_ rng: inout SeededRNG, cells: [[CGPoint]], count: Int) -> [CGPoint] {
        guard !cells.isEmpty else { return [] }
        var out: [CGPoint] = []
        var guardN = 0
        while out.count < min(360, count) && guardN < min(360, count) * 12 {
            guardN += 1
            let poly = cells[rng.int(cells.count)]
            guard poly.count >= 3 else { continue }
            let a = poly[rng.int(poly.count)], b = poly[(rng.int(poly.count) + 1) % poly.count]
            let t = rng.range(0, 1)
            let c0 = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            let cx = poly.reduce(0) { $0 + $1.x } / CGFloat(poly.count)
            let cy = poly.reduce(0) { $0 + $1.y } / CGFloat(poly.count)
            let u = rng.range(0.03, 0.92)
            let q = CGPoint(x: c0.x + (cx - c0.x) * u, y: c0.y + (cy - c0.y) * u)
            if pointIn(poly, q) { out.append(q) }
        }
        return out
    }
}
