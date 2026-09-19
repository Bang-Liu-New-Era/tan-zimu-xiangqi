//
//  BoardView.swift
//  人机中国象棋 · 棋盘视图 (待 P1b 再按职责细分)
//
//  本文件由 native/XiangqiApp.swift 拆分而来 (tools/split_xiangqi.py, P1 纯搬运)。
//  拆分过程只做位置搬迁, 未改动任何逻辑。
//
import AppKit
import AVFoundation
import JavaScriptCore
import CoreText

class BoardView: NSView {
    var board: [Int] = Array(repeating: 0, count: 90)
    var lastMove: (Int, Int)? = nil
    /// 当前选中的棋子位置。改变时自动驱动"离板抬起"动画。
    var selected: Int? = nil {
        didSet {
            if let s = selected, s >= 0, s < 90 { liftSq = s; liftPiece = board[s] }
            kick()
        }
    }
    var legalTargets: [Int] = []
    var hintSq: (Int, Int)? = nil
    var threats: [Int] = []
    var flipBoard = true   // true = 红方在下方 (棋盘整体 180° 旋转); false = 黑方在下方
    var simMode = false    // 模拟模式: 高亮改用琥珀色, 与实战的蓝/绿区分
    var onSquareClick: ((Int) -> Void)?
    // 走子动画: 轨迹由 Trajectory 提供 (形状/缓动/姿态可编排), 落地后接阻尼回弹
    private struct MoveAnim {
        let from: Int, to: Int, piece: Int
        let start: Double
        let traj: Trajectory
        var fly: Double { traj.fly }      // 飞行时长
        var land: Double { traj.land }    // 落地回弹时长
        var total: Double { fly + land }
    }
    private var anim: MoveAnim?
    /// 走子轨迹风格 (菜单可切换)
    var traj = Trajectory()
    /// 吃子是否在棋盘上留下裂痕, 并永久保留
    var crackEnabled = true
    /// 伤痕贴花层: 裂痕一旦生成就永久留在棋盘上, 只有开新局才清空
    private var decals: [Crack] = []
    /// 天气层 (雨)
    var weather = Weather()
    /// 屏幕演员层 (马跑过画面)
    var actors: [Actor] = []
    /// 调试: 叠加显示全部轨迹形状 (XQ_FX=paths)
    var debugShowPaths = false
    // 最近一次落地涟漪 (落点轻轻荡开的一圈淡光)
    private var landRipple: (sq: Int, start: Double)? = nil
    // 选中棋子的"离板抬起"状态: 抬起进度 0(平放)~1(完全抬起), 以及正在抬起的位置/棋子
    private var liftT: CGFloat = 0
    private var liftSq: Int? = nil
    private var liftPiece: Int = 0
    private var lastTickT: Double = 0
    // 吃子特效: kind 0=普通 1=炮·爆炸 2=马·踢飞 3=车·碾碎
    private struct FX {
        let sq: Int; let start: Double; let dur: Double; let kind: Int
        let piece: Int; let dir: CGPoint
    }
    private var effects: [FX] = []
    var bigText: (text: String, start: Double, dur: Double)? = nil
    private var shakeUntil: Double = 0
    private var flashUntil: Double = 0
    private var hintUntil: Double = 0
    private var timer: Timer?
    /// 棋盘贴图 (Resources/boards/board.jpg|png)。缺失时回退为程序化绘制。
    private lazy var boardImage: NSImage? = {
        for ext in ["jpg", "jpeg", "png"] {
            if let u = Bundle.main.url(forResource: "board", withExtension: ext, subdirectory: "boards"),
               let img = NSImage(contentsOf: u), img.size.width > 10 { return img }
            if let u = Bundle.main.url(forResource: "board", withExtension: ext),
               let img = NSImage(contentsOf: u), img.size.width > 10 { return img }
        }
        return nil
    }()
    /// 棋子贴图 (Resources/pieces/<编码>.png, 例 r1.png 红帅 / b14.png 黑炮)。
    /// 任一棋子缺图时该子回退为程序化绘制, 不影响其他棋子。
    private var pieceTexCache: [Int: NSImage] = [:]
    private var pieceTexMiss: Set<Int> = []
    func pieceTexture(_ p: Int) -> NSImage? {
        if let hit = pieceTexCache[p] { return hit }
        if pieceTexMiss.contains(p) { return nil }
        let code = p <= 7 ? "r\(p)" : "b\(p)"
        for sub in ["pieces", nil] as [String?] {
            for ext in ["png", "jpg"] {
                if let u = Bundle.main.url(forResource: code, withExtension: ext, subdirectory: sub),
                   let img = NSImage(contentsOf: u), img.size.width > 10 {
                    pieceTexCache[p] = img
                    return img
                }
            }
        }
        pieceTexMiss.insert(p)
        return nil
    }
    private var layout: (ox: CGFloat, oy: CGFloat, cell: CGFloat) {
        let b = bounds
        let pad: CGFloat = 10
        let cell = min((b.width - 2 * pad) / (8 + 2 * BOARD_EDGE_CELLS),
                       (b.height - 2 * pad) / (9 + 2 * BOARD_EDGE_CELLS))
        let bw = cell * 8, bh = cell * 9
        return ((b.width - bw) / 2, (b.height - bh) / 2, cell)
    }
    override var isOpaque: Bool { true }

    func kick() {
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in self?.tick() }
        }
    }
    func tick() {
        let now = CACurrentMediaTime()
        let dt = lastTickT > 0 ? min(0.12, now - lastTickT) : (1.0 / 60)
        lastTickT = now
        // 抬起/落回: 约 0.14s 完成一次过渡
        let target: CGFloat = (selected != nil && liftPiece != 0) ? 1 : 0
        if abs(liftT - target) > 0.0005 {
            let step = CGFloat(dt) / 0.14
            liftT = liftT < target ? min(target, liftT + step) : max(target, liftT - step)
        } else {
            liftT = target
            if target == 0 { liftSq = nil; liftPiece = 0 }
        }
        if let r = landRipple, now >= r.start + 0.26 { landRipple = nil }
        // 天气与演员需要自己的时钟: 雨滴靠 dt 积分推进, 演员按绝对时间取帧
        weather.update(dt, board: boardPlateRect, view: bounds)
        if !actors.isEmpty { actors.removeAll { now >= $0.born + $0.dur } }
        setNeedsDisplay(bounds)
        let rippleOn = landRipple.map { now < $0.start + 0.26 } ?? false
        let active = anim != nil || !effects.isEmpty || bigText != nil
            || now < shakeUntil || now < flashUntil || now < hintUntil
            || rippleOn
            || abs(liftT - target) > 0.0005
            || weather.isActive || !actors.isEmpty
        if !active { timer?.invalidate(); timer = nil; lastTickT = 0 }
    }
    func animateMove(from: Int, to: Int, piece: Int, capture: Bool, captured: Int,
                     style: Trajectory? = nil, scar: Bool = true,
                     completion: @escaping () -> Void) {
        let now = CACurrentMediaTime()
        // 起手飞子: 立刻结束抬起状态, 让棋子从棋盘原位起飞
        liftT = 0; liftSq = nil; liftPiece = 0
        let t = style ?? traj
        let fly = t.fly, land = t.land
        anim = MoveAnim(from: from, to: to, piece: piece, start: now, traj: t)
        landRipple = (to, now + fly)
        let landT = now + fly                       // 落地那一刻
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
            effects.append(FX(sq: to, start: now + fly * 0.92, dur: 0.75, kind: kind, piece: captured,
                              dir: CGPoint(x: dx, y: dy)))
            // 棋盘开裂: 裂纹在落地瞬间开始生长, 之后永久留在棋盘上。
            // 模拟推演(scar=false)是"假设", 不留痕。
            if crackEnabled && scar {
                let power: CGFloat = (piece == 5 || piece == 13) ? 1.00   // 车: 碾碎
                    : (piece == 6 || piece == 14) ? 0.92                  // 炮: 轰炸
                    : (piece == 4 || piece == 12) ? 0.80 : 0.72           // 马/其他
                let seed = UInt64(bitPattern: Int64(to &* 7919 &+ 104729))
                    &+ UInt64(now * 1000) &* 2_654_435_761
                decals.append(CrackForge.forge(sq: to, born: landT, seed: seed, power: power))
                if decals.count > 60 { decals.removeFirst(decals.count - 60) }
                shakeUntil = max(shakeUntil, landT + 0.20)   // 冲击震屏
            }
        }
        kick()
        DispatchQueue.main.asyncAfter(deadline: .now() + fly + land + 0.01) { self.anim = nil; completion() }
    }

    /// 清空棋盘上的全部伤痕 (开新局 / 手动清除)
    func clearDecals() { decals.removeAll(); setNeedsDisplay(bounds) }
    var decalCount: Int { decals.count }

    /// 调试用: 直接在指定格上放一道成熟的裂痕 (供 XQ_FX=crack 出图验证)
    func debugAddCrack(sq: Int, born: Double, power: CGFloat) {
        decals.append(CrackForge.forge(sq: sq, born: born,
                                       seed: UInt64(sq &* 2_654_435_761 &+ 12345), power: power))
        setNeedsDisplay(bounds)
    }

    /// 调试用: 把每种轨迹形状从同一起点画到同一终点, 一眼比对形状差异 (XQ_FX=paths)
    func debugDrawPaths(_ ox: CGFloat, _ oy: CGFloat, _ cell: CGFloat) {
        guard debugShowPaths, let cg = NSGraphicsContext.current?.cgContext else { return }
        let from = 76, to = 40
        let (fr, fc) = dispRC(from), (tr, tc) = dispRC(to)
        let fx = ox + cell * CGFloat(fc), fy = oy + cell * CGFloat(fr)
        let tx = ox + cell * CGFloat(tc), ty = oy + cell * CGFloat(tr)
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

    /// 让一匹马从画面外跑过。有序列帧素材就用素材, 否则用程序化剪影。
    func runHorse() {
        let sheet = ActorAssets.load("horse")
        actors.append(Actor(born: CACurrentMediaTime(), dur: 3.6, dir: 1,
                            baseY: 0.07, heightRatio: 0.30, sheet: sheet, name: "horse"))
        kick()
    }

    /// 棋盘石板(含边框)在视图坐标里的范围 —— 供天气系统判断水花落点。
    var boardPlateRect: CGRect {
        let (ox, oy, cell) = layout
        let rim = cell * BOARD_RIM_CELLS
        return CGRect(x: ox - rim, y: oy - rim,
                      width: cell * 8 + 2 * rim, height: cell * 9 + 2 * rim)
    }
    func showBigText(_ text: String, dur: Double = 2.4) {
        bigText = (text, CACurrentMediaTime(), dur); kick()
    }
    func flashCheck() { flashUntil = CACurrentMediaTime() + 0.45; kick() }
    func kickHint() { hintUntil = CACurrentMediaTime() + 3.0; kick() }
    func setThreats(_ sqs: [Int]) { threats = sqs; setNeedsDisplay(bounds) }

    // 棋盘坐标 -> 屏幕显示坐标 (按 flipBoard 旋转)
    func dispRC(_ sq: Int) -> (Int, Int) {
        let (r, c) = rc(sq)
        return flipBoard ? (9 - r, 8 - c) : (r, c)
    }
    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let (ox, oy, cell) = layout
        let col = Int(round((p.x - ox) / cell))
        let row = Int(round((p.y - oy) / cell))
        guard row >= 0, row < 10, col >= 0, col < 9 else { return }
        let (r, c) = flipBoard ? (9 - row, 8 - col) : (row, col)   // 显示坐标 -> 棋盘坐标
        onSquareClick?(r * 9 + c)
    }
    func center(_ sq: Int, _ ox: CGFloat, _ oy: CGFloat, _ cell: CGFloat) -> CGPoint {
        let (r, c) = dispRC(sq)
        return CGPoint(x: ox + cell * CGFloat(c), y: oy + cell * CGFloat(r))
    }
    func drawPiece(_ sq: Int, _ p: Int, _ ox: CGFloat, _ oy: CGFloat, _ cell: CGFloat) {
        drawPieceAt(center(sq, ox, oy, cell), p, cell)
    }
    func drawPieceAt(_ ctr: CGPoint, _ p: Int, _ cell: CGFloat,
                     rotate: CGFloat = 0, sx: CGFloat = 1, sy: CGFloat = 1, alpha: CGFloat = 1,
                     castShadow: Bool = true) {
        let isRed = p <= 7
        let name = PIECE_CHARS[p] ?? "?"
        let r = cell * 0.42                 // 棋子半径 = 0.42 格 (直径 0.84 格)
        let rect = NSRect(x: -r, y: -r, width: 2 * r, height: 2 * r)
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext.current?.cgContext
        // ① 投影: 用棋子轮廓在正下方投一圈暗影, 让棋子"坐"在棋盘上。
        //    影子偏移 = 棋子直径的 1/16 (≈0.05 格), 模糊收窄到棋子下沿, 形成一圈厚度感。
        //    阴影固定在交叉点方向(不参与棋子自身的旋转/压扁变换), 所以飞子时影子仍落在棋盘上。
        if castShadow, alpha > 0.55, let cg = ctx {
            cg.saveGState()
            cg.setShadow(offset: CGSize(width: 0, height: -(r * 2) / 16),
                         blur: cell * 0.045,
                         color: NSColor(calibratedWhite: 0, alpha: 0.55).cgColor)
            cg.setFillColor(NSColor.black.cgColor)
            let s = r * 0.96
            cg.fillEllipse(in: CGRect(x: ctr.x - s, y: ctr.y - s, width: 2 * s, height: 2 * s))
            cg.restoreGState()
        }
        // ② 棋子本体
        ctx?.translateBy(x: ctr.x, y: ctr.y)
        if rotate != 0 { ctx?.rotate(by: rotate) }
        if sx != 1 || sy != 1 { ctx?.scaleBy(x: sx, y: sy) }
        if alpha < 1 { ctx?.setAlpha(alpha) }
        // 优先使用棋子贴图; 缺图时回退为程序化绘制
        if let tex = pieceTexture(p) {
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
            if let cg = ctx {
                cg.textPosition = CGPoint(x: -gb.midX, y: -gb.midY)
                CTLineDraw(line, cg)
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    /// 飞行中棋子投在棋盘上的影子: 固定落在棋子正下方的地面位置, 随抬升高度扩散、变淡。
    /// (飞行棋子的 castShadow 必须关掉, 否则影子会跟着棋子一起飞。)
    func drawFlightShadow(_ ground: CGPoint, _ cell: CGFloat, _ arc: CGFloat) {
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

    // MARK: - 伤痕层 (裂痕永久保留)
    /// 每道裂纹在诞生后的 dur 秒内"炸开生长", 之后只是静态重描 —— 裂纹点集只生成一次, 不再变化。
    func drawDecals(_ ox: CGFloat, _ oy: CGFloat, _ cell: CGFloat, _ now: Double) {
        guard !decals.isEmpty, let cg = NSGraphicsContext.current?.cgContext else { return }
        for c in decals {
            let age = now - c.born
            if age < 0 { continue }                              // 还没落地, 先不出现
            let e = 1 - pow(1 - CGFloat(min(1, age / c.dur)), 3)  // easeOutCubic: 炸开快、收尾慢
            let ctr = center(c.sq, ox, oy, cell)
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

    // MARK: - 演员层 (马跑过画面)
    /// 沿屏幕横向跑过, 带奔跑起伏与蹄后扬尘。有 run_NN.png 序列帧就用素材, 否则用程序化剪影。
    func drawActors(_ view: CGRect, _ now: Double) {
        guard !actors.isEmpty, let cg = NSGraphicsContext.current?.cgContext else { return }
        for a in actors {
            let t = (now - a.born) / a.dur
            guard t >= 0, t <= 1 else { continue }
            let fade: CGFloat = t < 0.08 ? CGFloat(t / 0.08)
                : (t > 0.92 ? CGFloat((1 - t) / 0.08) : 1)       // 两端淡入淡出
            let h = view.height * a.heightRatio
            let prog = -0.18 + 1.36 * CGFloat(t)
            let x = a.dir > 0 ? prog * view.width : (1 - prog) * view.width
            let bob = sin(CGFloat(t) * 22) * h * 0.028           // 奔跑起伏
            let y = view.height * a.baseY + bob
            let phase = CGFloat((now - a.born) * 2.6)
            cg.saveGState()
            cg.setAlpha(fade)
            // 蹄后扬尘: 一路淡出的小土团
            for i in 0..<7 {
                let k = CGFloat(i) / 7
                let px = x - a.dir * (0.4 + CGFloat(i)) * h * 0.13
                let py = y + h * 0.05 + sin(phase * 0.7 + k * 3) * h * 0.02
                let r = h * (0.062 - 0.005 * CGFloat(i))
                cg.setFillColor(NSColor(calibratedWhite: 0.88, alpha: 0.42 * (1 - k)).cgColor)
                cg.fillEllipse(in: CGRect(x: px - r, y: py - r * 0.62, width: 2 * r, height: 1.24 * r))
            }
            if let sheet = a.sheet, !sheet.frames.isEmpty {
                let idx = Int((now - a.born) * sheet.fps) % sheet.frames.count
                let img = sheet.frames[idx]
                let ar = img.size.height > 1 ? img.size.width / img.size.height : 1
                let w = h * ar
                let rect = CGRect(x: x - w / 2, y: y, width: w, height: h)
                cg.saveGState()
                if a.dir < 0 {                                   // 反向跑: 水平镜像
                    cg.translateBy(x: x, y: 0); cg.scaleBy(x: -1, y: 1); cg.translateBy(x: -x, y: 0)
                }
                img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: fade)
                cg.restoreGState()
            } else {
                cg.translateBy(x: x, y: y)
                if a.dir < 0 { cg.scaleBy(x: -1, y: 1) }
                HorseArt.draw(cg, phase: phase, h: h,
                              color: NSColor(calibratedRed: 0.16, green: 0.11,
                                             blue: 0.07, alpha: 0.92))
            }
            cg.restoreGState()
        }
    }

    // MARK: - 棋盘绘制
    /// 贴图版: 程序化石板边框 + 贴图网格面 (贴图网格线与棋盘坐标精确对齐)
    func drawTexturedBoard(_ img: NSImage, _ ox: CGFloat, _ oy: CGFloat, _ cell: CGFloat) {
        let rim = cell * BOARD_RIM_CELLS
        let k = cell / TEX_CELL_PX
        let tw = img.size.width * k, th = img.size.height * k
        let gx = ox - TEX_INSET_PX * k, gy = oy - TEX_INSET_PX * k      // 贴图原点(网格坐标系)
        let plate = NSRect(x: gx - rim, y: gy - rim, width: tw + 2 * rim, height: th + 2 * rim)
        let rr = rim * 0.35
        // 投影
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowBlurRadius = cell * 0.25
        sh.shadowOffset = NSSize(width: 0, height: -cell * 0.06)
        sh.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.38)
        sh.set()
        NSColor(calibratedRed: 0.62, green: 0.64, blue: 0.52, alpha: 1).setFill()
        NSBezierPath(roundedRect: plate, xRadius: rr, yRadius: rr).fill()
        NSGraphicsContext.restoreGraphicsState()
        // 倒角: 上/左受光, 下/右背光
        let bw = max(1, rim * 0.55)
        NSBezierPath.defaultLineWidth = bw
        NSColor(calibratedRed: 0.80, green: 0.82, blue: 0.72, alpha: 0.85).setStroke()
        NSBezierPath.strokeLine(from: NSPoint(x: plate.minX + bw / 2, y: plate.maxY - bw / 2),
                                to: NSPoint(x: plate.maxX - bw / 2, y: plate.maxY - bw / 2))
        NSBezierPath.strokeLine(from: NSPoint(x: plate.minX + bw / 2, y: plate.maxY - bw / 2),
                                to: NSPoint(x: plate.minX + bw / 2, y: plate.minY + bw / 2))
        NSColor(calibratedRed: 0.42, green: 0.44, blue: 0.34, alpha: 0.7).setStroke()
        NSBezierPath.strokeLine(from: NSPoint(x: plate.minX + bw / 2, y: plate.minY + bw / 2),
                                to: NSPoint(x: plate.maxX - bw / 2, y: plate.minY + bw / 2))
        NSBezierPath.strokeLine(from: NSPoint(x: plate.maxX - bw / 2, y: plate.minY + bw / 2),
                                to: NSPoint(x: plate.maxX - bw / 2, y: plate.maxY - bw / 2))
        // 贴图
        let face = NSRect(x: gx, y: gy, width: tw, height: th)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: face).addClip()
        NSGraphicsContext.current?.imageInterpolation = .high
        if !flipBoard {   // 我执黑(黑方在下方): 贴图整体旋转 180°
            let ctx = NSGraphicsContext.current?.cgContext
            ctx?.translateBy(x: face.midX, y: face.midY)
            ctx?.rotate(by: .pi)
            ctx?.translateBy(x: -face.midX, y: -face.midY)
        }
        img.draw(in: face, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        // 网格外框凹槽
        NSColor(calibratedRed: 0.30, green: 0.32, blue: 0.24, alpha: 0.85).setStroke()
        NSBezierPath.defaultLineWidth = max(1, cell * 0.018)
        NSBezierPath.stroke(face)
    }
    /// 回退版: 纯程序化棋盘 (无贴图时)
    func drawProceduralBoard(_ ox: CGFloat, _ oy: CGFloat, _ cell: CGFloat, _ bw: CGFloat, _ bh: CGFloat) {
        NSColor(calibratedRed: 0.96, green: 0.80, blue: 0.55, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: ox - cell * 0.25, y: oy - cell * 0.25,
                                         width: bw + cell * 0.5, height: bh + cell * 0.5),
                     xRadius: 8, yRadius: 8).fill()
        NSColor(calibratedRed: 0.35, green: 0.22, blue: 0.1, alpha: 1).setStroke()
        NSBezierPath.defaultLineWidth = 1.2
        for r in 0...9 {
            let y = oy + cell * CGFloat(r)
            NSBezierPath.strokeLine(from: CGPoint(x: ox, y: y), to: CGPoint(x: ox + bw, y: y))
        }
        for c in 0...8 {
            let x = ox + cell * CGFloat(c)
            if c == 0 || c == 8 {
                NSBezierPath.strokeLine(from: CGPoint(x: x, y: oy), to: CGPoint(x: x, y: oy + bh))
            } else {
                NSBezierPath.strokeLine(from: CGPoint(x: x, y: oy), to: CGPoint(x: x, y: oy + cell * 4))
                NSBezierPath.strokeLine(from: CGPoint(x: x, y: oy + cell * 5), to: CGPoint(x: x, y: oy + bh))
            }
        }
        func diag(_ r1: Int, _ c1: Int, _ r2: Int, _ c2: Int) {
            let (dr1, dc1) = dispRC(r1 * 9 + c1), (dr2, dc2) = dispRC(r2 * 9 + c2)
            NSBezierPath.strokeLine(from: CGPoint(x: ox + cell * CGFloat(dc1), y: oy + cell * CGFloat(dr1)),
                                    to: CGPoint(x: ox + cell * CGFloat(dc2), y: oy + cell * CGFloat(dr2)))
        }
        diag(0, 3, 2, 5); diag(0, 5, 2, 3); diag(7, 3, 9, 5); diag(7, 5, 9, 3)
        let rattr: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: cell * 0.5),
            .foregroundColor: NSColor(calibratedRed: 0.4, green: 0.25, blue: 0.1, alpha: 0.5),
        ]
        // 楚河/漢界 按下方执子方的视角摆放 (红在下→楚河居左; 黑在下→漢界居左)
        let (leftTxt, rightTxt) = flipBoard ? ("楚 河", "漢 界") : ("漢 界", "楚 河")
        NSAttributedString(string: leftTxt, attributes: rattr)
            .draw(at: NSPoint(x: ox + cell * 1.1, y: oy + cell * 4.3))
        NSAttributedString(string: rightTxt, attributes: rattr)
            .draw(at: NSPoint(x: ox + cell * 5.0, y: oy + cell * 4.3))
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let b = bounds
        NSColor(calibratedRed: 0.88, green: 0.87, blue: 0.83, alpha: 1).setFill()
        NSBezierPath.fill(b)
        let (ox, oy, cell) = layout
        let bw = cell * 8, bh = cell * 9
        let now = CACurrentMediaTime()
        // 远景雨幕: 画在棋盘之前, 制造"棋盘之外正在下雨"的纵深
        if let cg = NSGraphicsContext.current?.cgContext { weather.drawBack(cg, b) }
        var shake: CGFloat = 0
        if now < shakeUntil { shake = sin(now * 40) * 4 }
        NSGraphicsContext.saveGraphicsState()
        if shake != 0 { NSGraphicsContext.current?.cgContext.translateBy(x: shake, y: 0) }

        // 棋盘 (优先用贴图; 无贴图则程序化绘制)
        if let tex = boardImage {
            drawTexturedBoard(tex, ox, oy, cell)
        } else {
            drawProceduralBoard(ox, oy, cell, bw, bh)
        }

        // 伤痕层: 吃子留下的裂痕, 永久保留在棋盘上
        drawDecals(ox, oy, cell, now)

        // 上一步起点标记: 只用一个小圆点(直径 = 棋子直径的 1/10) + 蓝色光晕, 标出走棋前的位置
        if let lm = lastMove {
            let a = center(lm.0, ox, oy, cell)
            let dot = cell * 0.84 / 10                 // 棋子直径(0.84 格)的 1/10
            let rr = dot / 2
            if let cg = NSGraphicsContext.current?.cgContext {
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
        for t in legalTargets {
            let c = center(t, ox, oy, cell)
            let cap = board[t] != 0
            if cap {
                if simMode {
                    NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.1, alpha: 0.95).setStroke()
                } else {
                    NSColor(calibratedRed: 0.9, green: 0.2, blue: 0.15, alpha: 0.9).setStroke()
                }
                NSBezierPath.defaultLineWidth = 2.5
                NSBezierPath(ovalIn: NSRect(x: c.x - cell * 0.46, y: c.y - cell * 0.46,
                                            width: cell * 0.92, height: cell * 0.92)).stroke()
            } else {
                if simMode {
                    NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.2, alpha: 0.9).setFill()
                } else {
                    NSColor(calibratedRed: 0.2, green: 0.5, blue: 0.2, alpha: 0.8).setFill()
                }
                NSBezierPath(ovalIn: NSRect(x: c.x - cell * 0.12, y: c.y - cell * 0.12,
                                           width: cell * 0.24, height: cell * 0.24)).fill()
            }
        }
        // 提示发光
        if let h = hintSq, now < hintUntil {
            let pulse = 0.5 + 0.5 * sin(now * 6)
            for sq in [h.0, h.1] {
                let c = center(sq, ox, oy, cell)
                NSColor(calibratedRed: 1, green: 0.85, blue: 0.2, alpha: 0.3 + 0.4 * pulse).setFill()
                NSBezierPath(ovalIn: NSRect(x: c.x - cell * 0.5, y: c.y - cell * 0.5,
                                           width: cell, height: cell)).fill()
            }
        }
        // 威胁红圈
        for sq in threats {
            let c = center(sq, ox, oy, cell)
            NSColor(calibratedRed: 0.9, green: 0.1, blue: 0.1, alpha: 0.85).setStroke()
            NSBezierPath.defaultLineWidth = 3
            NSBezierPath(ovalIn: NSRect(x: c.x - cell * 0.46, y: c.y - cell * 0.46,
                                        width: cell * 0.92, height: cell * 0.92)).stroke()
        }
        // 棋子 (动画期间跳过 from/to; 被选中抬起的棋子单独在最后绘制)
        for sq in 0..<90 {
            let p = board[sq]
            if p == 0 { continue }
            if let a = anim, sq == a.from || sq == a.to { continue }
            if liftT > 0.001, let ls = liftSq, sq == ls { continue }
            drawPiece(sq, p, ox, oy, cell)
        }
        // 被选中的棋子: 沿屏幕方向离板抬起 + 倾斜 15°, 棋盘原位留下一片投影
        if liftT > 0.001, let ls = liftSq, liftPiece != 0 {
            let c = center(ls, ox, oy, cell)
            let lift = liftT
            // 投影: 留在棋盘原位。纯黑 + 45% 不透明度, 由中心向边缘平滑淡出,
            //       没有描边/没有可察觉的硬边(末端梯度平缓收敛到全透明)
            if let cg = NSGraphicsContext.current?.cgContext {
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
            drawPieceAt(CGPoint(x: c.x, y: c.y + cell * 0.44 * lift), liftPiece, cell,
                        rotate: CGFloat(15) * .pi / 180 * lift,
                        sx: 1.0 + 0.10 * lift, sy: 1.0 + 0.10 * lift,
                        castShadow: false)
        }
        if let a = anim {
            let el = now - a.start
            let (fr, fc) = dispRC(a.from), (tr, tc) = dispRC(a.to)   // 必须经翻转映射, 否则动画走镜像路径
            let fx = ox + cell * CGFloat(fc), fy = oy + cell * CGFloat(fr)
            let tx = ox + cell * CGFloat(tc), ty = oy + cell * CGFloat(tr)
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
                let s = a.traj.sample(u)                        // (侧偏, 抬升, 旋转, 缩放) 单位: 格
                let ground = CGPoint(x: base.x + nm.x * s.perp * cell,
                                     y: base.y + nm.y * s.perp * cell)
                let air = CGPoint(x: ground.x, y: ground.y + s.lift * cell)
                // 影子留在棋盘上(不跟着飞), 随高度扩散变淡
                drawFlightShadow(ground, cell, a.traj.hop > 0.0001 ? s.lift / a.traj.hop : 0)
                drawPieceAt(air, a.piece, cell, rotate: s.rot, sx: s.scale, sy: s.scale,
                            castShadow: false)
            } else {
                // ===== 落地段: 压扁 → 轻微过冲回弹 → 稳定 (阻尼振荡) =====
                let v = CGFloat(max(0, min(1, (el - a.fly) / a.land)))
                let amp = 0.13 * exp(-4.2 * v) * cos(6.2 * v)
                drawPieceAt(CGPoint(x: tx, y: ty), a.piece, cell,
                            sx: 1 + amp * 0.65, sy: 1 - amp, castShadow: false)
            }
        }
        // 落地涟漪: 落子瞬间从落点荡开的一圈淡影
        if let r = landRipple, now >= r.start, now < r.start + 0.26 {
            let v = CGFloat((now - r.start) / 0.26)
            let c = center(r.sq, ox, oy, cell)
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
            let c = center(e.sq, ox, oy, cell)
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
                drawPieceAt(pos, e.piece, cell, rotate: ft * 11, alpha: 1 - ft * ft)
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
                drawPieceAt(c, e.piece, cell, sx: sx, sy: sy, alpha: fade)
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
        effects.removeAll { now >= $0.start + $0.dur }
        NSGraphicsContext.restoreGraphicsState()

        // 演员层 (马跑过画面) 与 近景雨幕 —— 都在震屏变换之外, 不会被棋盘带着抖
        drawActors(b, now)
        if let cg = NSGraphicsContext.current?.cgContext { weather.drawFront(cg, b) }
        debugDrawPaths(ox, oy, cell)

        // 将军红闪
        if now < flashUntil {
            let a = (flashUntil - now) / 0.45 * 0.35
            NSColor(calibratedRed: 0.9, green: 0.1, blue: 0.1, alpha: a).setFill()
            NSBezierPath.fill(b)
        }

        // 绝杀大字 (全棋盘)
        if let bt = bigText {
            let t = (now - bt.start) / bt.dur
            if t >= 1 { bigText = nil }
            else {
                var scale: CGFloat = 1, alpha: CGFloat = 1
                if t < 0.16 { let u = CGFloat(t / 0.16); scale = 3.4 - 2.4 * u; alpha = u }   // 砸入
                else if t > 0.7 { alpha = CGFloat((1 - t) / 0.3) }                              // 淡出
                let fs = min(cell * 2.3 * scale, b.height * 0.42)
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
    }
}

// MARK: - 轨迹引擎 (走子路径可编排)
/// 缓动曲线: 决定「什么时候走到哪儿」, 与路径形状解耦。
