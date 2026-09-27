//
//  CrackLayer.swift
//  人机中国象棋 · 伤痕图层
//
//  与其他特效最大的不同: 它是**永久**的。裂痕在一瞬间炸开生长, 之后一直留在棋盘上,
//  每帧只是把已生成的点集重描一遍 —— 只有开新局或菜单手动清除才会消失。
//
//  ── 碎裂石板 · H (2026-09-27 定稿, 自 /tmp/xqcrk 预览台落地) ──
//  主体是 drawShatter: 碎块 + 块间宽缝 + 块缘坡口 + 石面颗粒 (见该方法注释)。
//  branches 里只剩**块内发丝裂**, 走下面的坡口画法补毛刺 —— 因为线很细,
//  七层全套是浪费, thin 模式只画 3 层 (每帧省 4 次填充)。
//
//  ── 怎么画出"刻痕"而不是"画上去的线" ──
//  坡口四层: 接触阴影(凹下去) → 背光侧壁 ┐ 一暗一亮构成坡口,
//            受光唇口(窄亮条)          ┘ 槽底(近黑一线 + 更黑的芯)。
//  每个顶点都有独立的宽度: 根部粗、尖端收细、确定性抖动, 中段掐细 1~2 处
//  —— 等宽且一根到底的线, 一眼就是画上去的。
//  两条铁律(搞反就是"鼓起来的棱"): 受光的是**背对光源那侧**的壁(deboss 规律);
//  唇口宽度要乘 |cross(纹路方向, 光线)|^0.6, 顺光走向时亮边自然消失。
//
//  几何上的坑: 每层把全部纹路合并成**一条** CGPath 一次填充(nonzero 取并集,
//  比逐段描边便宜两个数量级), 前提是每条带状多边形都是逆时针 —— Ribbon 构造时测好绕向。
//
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// 伤痕图层 (吃子留下的裂痕)。跟随震屏 —— 裂痕是棋盘的一部分。
final class CrackLayer: RenderLayer {
    let name = "cracks"
    var followsShake: Bool { true }

    // MARK: - 坡口配方 (要调"深浅/厚度"就改这几行; 只作用于发丝裂)

    /// ① 接触阴影: (相对缝宽的倍数, 这一圈的不透明度)。
    /// 圈数不要多、半径不要大, 否则会糊成一片"脏雾"而不是"凹下去"。
    private static let aoBands: [(mul: CGFloat, alpha: CGFloat)] = [
        (3.60, 0.050), (2.40, 0.078), (1.55, 0.105),
    ]
    /// ② 背光侧壁: 只贴在背光那一侧
    private static let wallBand: (mul: CGFloat, shift: CGFloat, alpha: CGFloat) = (0.90, -0.34, 0.32)
    /// ③ 受光唇口: 只贴在受光那一侧, 不超出槽口
    private static let litBand: (mul: CGFloat, shift: CGFloat, alpha: CGFloat) = (0.52, 0.36, 0.28)
    /// ④ 槽底: 近黑的窄槽 + 槽心更窄更黑的一条
    private static let coreBands: [(mul: CGFloat, alpha: CGFloat)] = [
        (1.00, 0.58), (0.55, 0.42),
    ]
    /// 光源方向 (绘制坐标系, y 向下; 与棋盘高光一致: 左上方)
    private static let lightDir = CGPoint(x: -0.62, y: -0.78)
    /// 暗区颜色: 带一点暖调的深褐, 纯黑会显脏
    private static let aoColor = (r: CGFloat(0.105), g: CGFloat(0.078), b: CGFloat(0.052))
    /// 槽底颜色
    private static let coreColor = (r: CGFloat(0.052), g: CGFloat(0.038), b: CGFloat(0.028))
    /// 唇口颜色: 略微偏暖的石色
    private static let litColor = (r: CGFloat(0.93), g: CGFloat(0.89), b: CGFloat(0.80))

    /// 裂痕一旦生成就永久留在棋盘上, 只有开新局才清空
    private(set) var decals: [Crack] = []

    /// 生长阶段也要让主循环转起来 (0.42 秒的炸开动画)
    var isAnimating: Bool { decals.contains { $0.born > 0 && CACurrentMediaTime() < $0.born + $0.dur } }

    var count: Int { decals.count }

    /// 上限 60 道 —— 再多也看不清, 只会拖慢每帧的填充
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

    /// 每道裂纹在诞生后的 dur 秒内"炸开生长", 之后只是静态重绘 —— 裂纹点集只生成一次, 不再变化。
    ///
    /// 关于缓存: 曾试过把定型后的裂痕缓存成整屏位图 (省掉每帧重绘), 实测不划算 ——
    /// 整屏位图往返的内存搬运比直接重画还贵, 且回贴会引入颜色空间转换导致无法逐像素相同。
    func draw(_ ctx: RenderContext) {
        guard !decals.isEmpty, let cg = ctx.cg else { return }
        let cell = ctx.cell, now = ctx.now
        for c in decals {
            let age = now - c.born
            if age < 0 { continue }                                   // 还没落地, 先不出现
            let e = 1 - pow(1 - CGFloat(min(1, age / c.dur)), 3)       // easeOutCubic: 炸开快、收尾慢
            let ctr = ctx.center(c.sq)
            cg.saveGState()
            cg.translateBy(x: ctr.x, y: ctr.y)

            let appear = CGFloat(min(1, age / (c.dur * 0.55)))         // 生长期间的浮现
            let tint = 0.60 + 0.40 * c.tint

            // ── 碎裂石板 (H): 碎块 + 缝网 + 坡口 + 颗粒 ──
            if !c.cells.isEmpty {
                drawShatter(c, cg, cell: cell, appear: appear, tint: tint, e: e)
            }

            // 中心砸痕: 几团偏心叠出来的暗斑。单个完美圆的径向渐变一眼就是"画上去的黑洞",
            // 偏心叠加才像被砸出来的一块(而且总是不对称的)。碎裂版 scorch = 0, 不走这里。
            if c.scorch > 0 {
                let rr = cell * c.scorch * (0.55 + 0.45 * e)
                let a = 0.19 * c.tint
                func sc(_ k: CGFloat) -> CGColor {
                    XColor(crossRed: 0.10, green: 0.07, blue: 0.045, alpha: a * k).cgColor
                }
                if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                      colors: [sc(1), sc(0.66), sc(0.30), sc(0)] as CFArray,
                                      locations: [0, 0.38, 0.72, 1]) {
                    let lobes: [(dx: CGFloat, dy: CGFloat, r: CGFloat)] = [
                        (0.000, 0.000, 1.00),
                        (0.052, -0.034, 0.68),
                        (-0.044, 0.040, 0.62),
                    ]
                    for (li, l) in lobes.enumerated() {
                        let jx = (SeededRNG.hash01(c.seed, 300 + li, 1) - 0.5) * 0.07
                        let jy = (SeededRNG.hash01(c.seed, 300 + li, 2) - 0.5) * 0.07
                        cg.drawRadialGradient(g, startCenter: .zero, startRadius: 0,
                                              endCenter: CGPoint(x: (l.dx + jx) * cell,
                                                                 y: (l.dy + jy) * cell),
                                              endRadius: rr * l.r, options: [])
                    }
                }
            }

            // 发丝纹路: 先把生长中可见的部分、逐段宽度、带状骨架算出来, 各层共用
            var bones: [Ribbon] = []
            var lips: [[CGFloat]] = []
            for (bi, branch) in c.branches.enumerated() {
                let scale = bi < c.weights.count ? c.weights[bi] : 0.55
                // 出场错开: 主纹按 hash 差 0~55ms 依次窜出, 细纹再整体晚 55~90ms ——
                // 于是"碎块先崩开、毛刺最后补上", 而不是所有纹路齐刷刷一起亮。
                let lag: CGFloat = bi < c.mainCount
                    ? 0.055 * SeededRNG.hash01(c.seed, bi, 7)
                    : (scale >= 0.50 ? 0.055 : 0.090)
                let eg = max(0, min(1, (e - lag) / (1 - lag)))
                let grown = visible(branch, eg)
                guard grown.count >= 2 else { continue }
                // 宽度按**整条分支**算好再截断 —— 跟着已生长长度走的话, 每多裂出一段
                // 前面的宽度就会重排一次, 看起来像整条在抽动。
                var w = Array(segmentWidths(count: branch.count, seed: c.seed, branch: bi)
                                .prefix(grown.count))
                // 尖端: 生长期间一直保持"楔形", 钻到头才恢复 —— 这是"正在裂开"的关键读数
                if eg < 0.999 {
                    w[w.count - 1] *= 0.42
                    if w.count >= 3 { w[w.count - 2] *= 0.74 }
                }
                bones.append(makeRibbon(grown, w.map { $0 * c.width * scale },
                                        cell: cell, shiftSign: shiftSign(of: grown)))
                lips.append(lipVisibility(grown))
            }
            guard !bones.isEmpty else { cg.restoreGState(); continue }

            /// 把全部纹路按同一"宽度倍数"铺一层, 合并成一条路径一次填充。
            /// lipOnly: 只给受光唇口用 —— 逐顶点再乘一个可见度, 让亮边随走向自然出现/消失。
            func stamp(_ mul: CGFloat, shift: CGFloat, lipOnly: Bool,
                       _ col: (r: CGFloat, g: CGFloat, b: CGFloat), _ alpha: CGFloat) {
                guard alpha > 0.002 else { return }
                let path = CGMutablePath()
                for (i, r) in bones.enumerated() {
                    appendRing(path, r, mul: mul, shift: shift, lip: lipOnly ? lips[i] : nil)
                }
                cg.setFillColor(XColor(crossRed: col.r, green: col.g, blue: col.b,
                                        alpha: alpha).cgColor)
                cg.addPath(path)
                cg.fillPath()
            }

            // 接触阴影 → 背光侧壁 → 槽底 → 受光唇口 (顺序即叠压关系)
            // 发丝裂很细, 七层全套是浪费 —— thin 模式只画最中间那圈 AO + 槽底 + 唇口。
            let thin = !c.cells.isEmpty
            let aos = thin ? [CrackLayer.aoBands[1]] : CrackLayer.aoBands
            for b in aos { stamp(b.mul, shift: 0, lipOnly: false, CrackLayer.aoColor, b.alpha * tint * appear) }
            if !thin {
                let wb = CrackLayer.wallBand
                stamp(wb.mul, shift: wb.shift, lipOnly: false, CrackLayer.coreColor, wb.alpha * tint * appear)
            }
            for b in CrackLayer.coreBands { stamp(b.mul, shift: 0, lipOnly: false, CrackLayer.coreColor, b.alpha * tint * appear) }
            let lb = CrackLayer.litBand
            stamp(lb.mul, shift: lb.shift, lipOnly: true, CrackLayer.litColor, lb.alpha * appear)

            cg.restoreGState()
        }
    }

    // MARK: - 碎裂石板 (H)

    /// 把一块"被压碎的区域"画出来: 碎块 + 块间宽缝 + 块缘坡口 + 石面颗粒。
    ///
    /// 参考图上最容易被忽略的一点: **缝才是主体**。碎块之间是真的没有料, 露出来的是黑洞,
    /// 所以缝要宽(相对块尺寸 10%~18%)、要近黑、要等宽; 碎块只是被缝围出来的若干块石头。
    /// 反过来说, 只在石板表面画几条深色线 —— 无论多不齐 —— 都读不出"碎", 只会读成"划痕"。
    ///
    /// 五个绘制单元 (共 7~8 次填充, 与旧做法同量级):
    ///   ① 碎块面: 逐块明暗差(不整体提亮 —— 整体提亮会留下"亮补丁" = 贴上去的标签)
    ///   ② 缝外圈接触阴影: 块整体缩 0.82 的一圈淡暗 → "凹下去"
    ///   ③ 缝网 = 未缩块 − 内缩块, nonzero 一次填充 (不是逐块描边 —— 那会多一个数量级,
    ///      而且共享边叠成双倍黑, 缝宽会跟着"有几条边"变化)
    ///   ④ 块缘坡口: 朝光的边贴亮唇(又窄又淡, |法线·光线|^1.7 只留正对光的边)、
    ///      背光的边贴暗坡 —— 沿轮廓一圈均匀亮边 = 玻璃碎片, 不是石头断口
    ///   ⑤ 颗粒: 石粉亮点 + 砂粒暗点, 只撒在块内 (撒进缝里的会被缝盖掉)
    private func drawShatter(_ c: Crack, _ cg: CGContext, cell: CGFloat,
                             appear: CGFloat, tint: CGFloat, e: CGFloat) {
        let seam = c.seam * cell
        let gapA = 0.90 * min(1, tint) * appear
        guard gapA > 0.004, c.cells.count >= 2, seam > 0.4 else { return }

        // 崩开位移: 碎块沿"远离碎区中心"的方向再窜出去一点, 随 e 收敛回位 ——
        // 落地那一瞬是"炸开", 然后归位。归位后各块正好拼回原来那块区域。
        let push = 0.036 * (1 - e) * cell

        var cells: [[CGPoint]] = []
        cells.reserveCapacity(c.cells.count)
        for poly in c.cells {
            let n = CGFloat(poly.count)
            let cx = poly.reduce(0) { $0 + $1.x } / n
            let cy = poly.reduce(0) { $0 + $1.y } / n
            let L = max(0.0001, (cx * cx + cy * cy).squareRoot())
            let dx = cx / L * push, dy = cy / L * push
            cells.append(poly.map { CGPoint(x: $0.x * cell + dx, y: $0.y * cell + dy) })
        }

        func polyPath(_ p: [CGPoint], into path: CGMutablePath) {
            path.addLines(between: p)
            path.closeSubpath()
        }

        // ③ 缝 = **未缩块 − 内缩块**。内缩只发生在"碎块与碎块之间"的交界上,
        //    所以外缘那条边两块重合, 相减之后什么都没有 —— 碎区外围干干净净, 没有环绕的黑沟。
        //    (先画个圆再把碎块裁进去就会出现那圈黑沟, 整片立刻变成"贴上去的圆标签"。)
        //    一次填充: 未缩块正绕、内缩块反绕, nonzero 规则在块内抵消。
        let gap = CGMutablePath()
        let fullCount = min(c.cellsFull.count, cells.count)
        for (i, p) in cells.enumerated() {
            guard i < fullCount else { continue }
            polyPath(c.cellsFull[i].map { CGPoint(x: $0.x * cell, y: $0.y * cell) }, into: gap)
        }
        for p in cells { polyPath(Array(p.reversed()), into: gap) }

        // ① 碎块面: 只做**逐块明暗差**, 不做整体提亮。
        //    整体提亮会在石板上留下一块比周围亮的补丁 —— 那正是"贴上去的标签"的来源。
        //    参考图里碎块与周围是同一块石头, 亮度差只发生在块与块之间。
        let bright = CGMutablePath()
        let dark = CGMutablePath()
        for (i, p) in cells.enumerated() {
            let sh = i < c.cellShade.count ? c.cellShade[i] : 0
            if sh > 0.22 { polyPath(p, into: bright) }
            if sh < -0.22 { polyPath(p, into: dark) }
        }
        if !bright.isEmpty {
            cg.addPath(bright)
            cg.setFillColor(XColor(crossRed: 0.97, green: 0.96, blue: 0.93,
                                    alpha: 0.028 * appear).cgColor)
            cg.fillPath()
        }
        if !dark.isEmpty {
            cg.addPath(dark)
            cg.setFillColor(XColor(crossRed: 0.11, green: 0.085, blue: 0.060,
                                    alpha: 0.052 * appear).cgColor)
            cg.fillPath()
        }

        // ② 缝外圈接触阴影 (先铺淡暗, 再压缝 —— 有"凹下去"的一圈, 缝才不像画上去的黑线)
        let halo = CGMutablePath()
        for (i, p) in cells.enumerated() {
            guard i < fullCount else { continue }
            polyPath(c.cellsFull[i].map { CGPoint(x: $0.x * cell, y: $0.y * cell) }, into: halo)
            let n = CGFloat(p.count)
            let cx = p.reduce(0) { $0 + $1.x } / n
            let cy = p.reduce(0) { $0 + $1.y } / n
            polyPath(p.map { CGPoint(x: cx + ($0.x - cx) * 0.82, y: cy + ($0.y - cy) * 0.82) },
                     into: halo)
        }
        cg.addPath(halo)
        cg.setFillColor(XColor(crossRed: 0.10, green: 0.078, blue: 0.055,
                                alpha: 0.14 * gapA).cgColor)
        cg.fillPath()

        cg.addPath(gap)
        cg.setFillColor(XColor(crossRed: 0.052, green: 0.038, blue: 0.027,
                                alpha: gapA * 0.92).cgColor)
        cg.fillPath()

        // ④ 块缘坡口
        let L = CrackLayer.lightDir
        let ll = (L.x * L.x + L.y * L.y).squareRoot()
        let lx = L.x / ll, ly = L.y / ll
        let lit = CGMutablePath(), shade = CGMutablePath()
        for p in cells {
            let n = p.count
            guard n >= 3 else { continue }
            for i in 0..<n {
                let a = p[i], b = p[(i + 1) % n]
                let dx = b.x - a.x, dy = b.y - a.y
                let len = (dx * dx + dy * dy).squareRoot()
                if len < 0.8 { continue }
                let nx = dy / len, ny = -dx / len          // 正面积多边形的外法线
                let d = nx * lx + ny * ly
                // 亮唇只留给**正对光**的那几条边(1.7 次方把斜着的边快速压掉), 且又窄又淡 ——
                // 沿轮廓一圈均匀的亮边 = 玻璃碎片, 不是石头断口。断口的主体读数是"暗"。
                let up = pow(abs(d), 1.7)
                let w = seam * (d > 0 ? 0.34 * (0.10 + 0.90 * up) : 0.62 * (0.35 + 0.65 * abs(d)))
                let ix = -nx * w, iy = -ny * w
                let q = CGMutablePath()
                q.move(to: a)
                q.addLine(to: b)
                q.addLine(to: CGPoint(x: b.x + ix, y: b.y + iy))
                q.addLine(to: CGPoint(x: a.x + ix, y: a.y + iy))
                q.closeSubpath()
                (d > 0 ? lit : shade).addPath(q)
            }
        }
        if !lit.isEmpty {
            cg.addPath(lit)
            cg.setFillColor(XColor(crossRed: 0.95, green: 0.92, blue: 0.85,
                                    alpha: 0.17 * appear).cgColor)
            cg.fillPath()
        }
        if !shade.isEmpty {
            cg.addPath(shade)
            cg.setFillColor(XColor(crossRed: 0.10, green: 0.076, blue: 0.054,
                                    alpha: 0.36 * appear).cgColor)
            cg.fillPath()
        }

        // ⑤ 颗粒 (石粉亮点 / 砂粒暗点)
        func dots(_ pts: [CGPoint], _ rad: CGFloat, _ r: CGFloat, _ g: CGFloat,
                  _ b: CGFloat, _ a: CGFloat) {
            guard !pts.isEmpty, a > 0.002 else { return }
            let path = CGMutablePath()
            let d = cell * rad
            for q in pts {
                path.addEllipse(in: CGRect(x: q.x * cell - d, y: q.y * cell - d,
                                           width: d * 2, height: d * 2))
            }
            cg.addPath(path)
            cg.setFillColor(XColor(crossRed: r, green: g, blue: b, alpha: a).cgColor)
            cg.fillPath()
        }
        dots(c.stipple, 0.023, 0.070, 0.054, 0.038, 0.30 * gapA)
        dots(c.dust, 0.026, 0.90, 0.87, 0.79, 0.11 * appear)
    }

    // MARK: - 带状骨架

    /// 一条纹路的骨架: 中心点 + 单位法线(含斜接加长) + 半宽。
    /// 各层只是在同一副骨架上换"宽度倍数"和"侧移量", 所以骨架每帧只算一次,
    /// 省掉每层重复的开方与斜接计算。`flip` 记录绕向, 保证所有带子都是逆时针。
    private struct Ribbon {
        var n = 0
        var px: [CGFloat] = [], py: [CGFloat] = []
        var nx: [CGFloat] = [], ny: [CGFloat] = []
        var half: [CGFloat] = []
        var flip = false
    }

    private func makeRibbon(_ pts: [CGPoint], _ widths: [CGFloat], cell: CGFloat,
                            shiftSign: CGFloat) -> Ribbon {
        var r = Ribbon()
        let n = pts.count
        guard n >= 2, widths.count == n else { return r }
        r.n = n
        r.px = pts.map { $0.x * cell }
        r.py = pts.map { $0.y * cell }
        r.nx = [CGFloat](repeating: 0, count: n)
        r.ny = [CGFloat](repeating: 0, count: n)
        r.half = [CGFloat](repeating: 0, count: n)
        for i in 0..<n {
            let dPrev = i > 0 ? unit(pts[i - 1], pts[i]) : nil
            let dNext = i < n - 1 ? unit(pts[i], pts[i + 1]) : nil
            var dir = dNext ?? dPrev ?? CGPoint(x: 1, y: 0)
            var miter: CGFloat = 1
            if let a = dPrev, let b = dNext {                       // 拐角取角平分线, 并按 1/cos 加长
                let sx = a.x + b.x, sy = a.y + b.y
                let l = (sx * sx + sy * sy).squareRoot()
                if l > 0.0001 {
                    dir = CGPoint(x: sx / l, y: sy / l)
                    let c = max(0.35, dir.x * b.x + dir.y * b.y)
                    miter = min(1.9, 1 / c)
                } else { dir = b }
            }
            var nx = -dir.y, ny = dir.x
            if shiftSign < 0 { nx = -nx; ny = -ny }                 // 受光侧的正负烘进法线
            r.nx[i] = nx; r.ny[i] = ny
            r.half[i] = widths[i] * cell * 0.5 * miter
        }
        r.flip = ringArea(r, mul: 1, shift: 0) < 0
        return r
    }

    /// 把一条骨架摊成闭合多边形写进 path (不产生中间数组)。
    /// lip 非空时逐顶点再乘一次宽度; shift 是"相对半宽的侧移比例"。
    private func appendRing(_ path: CGMutablePath, _ r: Ribbon, mul: CGFloat, shift: CGFloat,
                            lip: [CGFloat]?) {
        let n = r.n
        guard n >= 2 else { return }
        func half(_ i: Int) -> CGFloat { r.half[i] * (lip?[i] ?? 1) }
        func put(_ i: Int, _ off: CGFloat, _ first: inout Bool) {
            let p = CGPoint(x: r.px[i] + r.nx[i] * off, y: r.py[i] + r.ny[i] * off)
            if first { path.move(to: p); first = false } else { path.addLine(to: p) }
        }
        // 外侧(+法线) 走一遍, 再沿内侧(-法线)折回来; flip 时整体反向, 绕向统一为逆时针
        let seq: [Int] = r.flip ? Array((0..<n).reversed()) : Array(0..<n)
        var first = true
        for i in seq { let h = half(i); put(i, h * mul + h * shift, &first) }
        for i in seq.reversed() { let h = half(i); put(i, h * shift - h * mul, &first) }
        path.closeSubpath()
    }

    /// 骨架摊平后多边形的有向面积 (只用于判绕向)
    private func ringArea(_ r: Ribbon, mul: CGFloat, shift: CGFloat) -> CGFloat {
        var s: CGFloat = 0, prevX: CGFloat = 0, prevY: CGFloat = 0
        var firstX: CGFloat = 0, firstY: CGFloat = 0, k = 0
        func emit(_ px: CGFloat, _ py: CGFloat) {
            if k == 0 { firstX = px; firstY = py } else { s += prevX * py - px * prevY }
            prevX = px; prevY = py; k += 1
        }
        let n = r.n
        for i in 0..<n {
            let off = r.half[i] * mul + r.half[i] * shift
            emit(r.px[i] + r.nx[i] * off, r.py[i] + r.ny[i] * off)
        }
        for i in stride(from: n - 1, through: 0, by: -1) {
            let off = r.half[i] * shift - r.half[i] * mul
            emit(r.px[i] + r.nx[i] * off, r.py[i] + r.ny[i] * off)
        }
        s += prevX * firstY - firstX * prevY
        return s * 0.5
    }

    // MARK: - 纹路细节

    /// 按生长进度 e 截断折线, 只保留已经"裂开"的部分 (末尾一段按比例插值到中间)。
    private func visible(_ branch: [CGPoint], _ e: CGFloat) -> [CGPoint] {
        let segs = branch.count - 1
        guard segs > 0 else { return [] }
        let f = e * CGFloat(segs)
        let full = min(segs, Int(f))
        var pts = Array(branch.prefix(full + 1))
        let frac = f - CGFloat(full)
        if full < segs, frac > 0.001 {
            let p0 = branch[full], p1 = branch[full + 1]
            pts.append(CGPoint(x: p0.x + (p1.x - p0.x) * frac,
                               y: p0.y + (p1.y - p0.y) * frac))
        }
        return pts.count >= 2 ? pts : []
    }

    /// 逐顶点的宽度系数: 根部粗、尖端收细, 叠加确定性抖动, 再挑 1~2 处"掐细"到几乎闭合。
    /// 掐细是关键 —— 等宽且一根到底的线条, 一眼就是画上去的。
    private func segmentWidths(count n: Int, seed: UInt64, branch bi: Int) -> [CGFloat] {
        var w = [CGFloat](repeating: 1, count: n)
        for i in 0..<n {
            let t = n > 2 ? CGFloat(i) / CGFloat(n - 1) : 0
            // 根部最粗、尖端收到几乎闭合 —— 收得沿整条都看得出来, 才读得出"楔形"。
            let taper = 0.14 + 0.86 * pow(1 - t, 0.85)
            let jitter = 0.82 + 0.46 * SeededRNG.hash01(seed, bi, i)
            w[i] = taper * jitter
        }
        if n >= 4 {                                                // 掐细只做中段, 避开根部与尖端
            let holes = SeededRNG.hash01(seed, bi, 91) > 0.55 ? 2 : 1
            for h in 0..<holes {
                let at = 1 + Int(SeededRNG.hash01(seed, bi, 100 + h) * CGFloat(n - 3))
                w[at] *= 0.14                                      // 收到几乎闭合, 但不要"断成两截"
                if at > 0 { w[at - 1] *= 0.58 }
                if at + 1 < n { w[at + 1] *= 0.58 }
            }
        }
        w[0] *= 0.82                                               // 根部收一点, 免得中心叠成一团黑
        return w
    }

    /// 这条纹路的"受光侧"在左法线的哪一边, 用 +1 / -1 表示 (ribbon 里烘进法线符号)。
    ///
    /// 刻进石头里的槽, 受光的是**背对光源那一侧**的壁 (它正对着光), 迎着光的那侧壁反而在暗处;
    /// 于是槽口表现为"靠光的一边暗、背光的一边亮" —— 也就是常见的"压印/deboss"规律:
    /// 光从左上来, 亮边落在下边。判定符号搞反, 槽看起来就会是"鼓起来"的一条棱。
    private func shiftSign(of pts: [CGPoint]) -> CGFloat {
        let n = averageNormal(of: pts)
        return (n.x * CrackLayer.lightDir.x + n.y * CrackLayer.lightDir.y) >= 0 ? -1 : 1
    }

    /// 逐顶点的"唇口可见度"。侧壁最亮的时候, 是裂纹走向**横切**光线方向的时候;
    /// 裂纹顺着光的方向走时两侧壁受光几乎相同, 唇口就看不见了。
    /// 用宽度乘上它, 亮边就沿着纹路自然出现/消失, 而不是通体一条均匀的亮线
    /// —— 后者正是"像画上去的线"的元凶。
    private func lipVisibility(_ pts: [CGPoint]) -> [CGFloat] {
        let L = CrackLayer.lightDir
        let llen = (L.x * L.x + L.y * L.y).squareRoot()
        let lx = L.x / llen, ly = L.y / llen
        var out = [CGFloat](repeating: 1, count: pts.count)
        for i in 0..<pts.count {
            let a = i > 0 ? pts[i - 1] : pts[i]
            let b = i < pts.count - 1 ? pts[i + 1] : pts[i]
            let dx = b.x - a.x, dy = b.y - a.y
            let l = (dx * dx + dy * dy).squareRoot()
            out[i] = l < 0.0001 ? 0 : pow(abs(dx / l * ly - dy / l * lx), 0.6)   // |cross(方向, 光线)|
        }
        return out
    }

    /// 纹路的平均左法线 (用整条走向而不是逐顶点, 免得绕光摆动时亮边来回跳)
    private func averageNormal(of pts: [CGPoint]) -> CGPoint {
        var sx: CGFloat = 0, sy: CGFloat = 0
        for i in 0..<(pts.count - 1) { sx += pts[i + 1].x - pts[i].x; sy += pts[i + 1].y - pts[i].y }
        let len = (sx * sx + sy * sy).squareRoot()
        guard len > 0.0001 else { return CGPoint(x: 0, y: 0) }
        return CGPoint(x: -sy / len, y: sx / len)
    }

    private func unit(_ a: CGPoint, _ b: CGPoint) -> CGPoint? {
        let dx = b.x - a.x, dy = b.y - a.y
        let l = (dx * dx + dy * dy).squareRoot()
        return l < 0.0001 ? nil : CGPoint(x: dx / l, y: dy / l)
    }
}
