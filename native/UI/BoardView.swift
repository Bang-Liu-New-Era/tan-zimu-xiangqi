//
//  BoardView.swift
//  人机中国象棋 · 棋盘视图 (壳)
//
//  ── 这一层现在只做四件事 ──
//    ① 持有局面 (board/lastMove/选中/落点/威胁) 与鼠标命中测试
//    ② 维护 60fps 主循环: 按需启动, 全部图层都不动了就停
//    ③ 每帧把状态打成 RenderContext, 交给 RenderPipeline 画
//    ④ 向对局逻辑暴露一组动作接口 (animateMove / runHorse / showBigText …)
//
//  绘制本身已经不在这里了 —— 每种视觉元素是一个 RenderLayer:
//    Render/BoardPlateLayer    棋盘石板
//    FX/CrackLayer             永久裂痕
//    Render/MarkerLayer        起点蓝点 / 合法落点 / 提示 / 威胁
//    Render/PieceLayer         棋子 + 抬起 + 走子动画
//    FX/BurstLayer             落地涟漪 + 吃子爆点
//    FX/ActorLayer             屏幕演员 (马)
//    FX/WeatherLayer ×2        远景雨 / 近景雨
//    Render/DebugPathLayer     调试轨迹叠加
//    Render/OverlayLayer       将军红闪 + 绝杀大字
//
//  新增一种特效: 新建一个文件实现 RenderLayer, 再在 buildPipeline() 里加一行。
//  不需要动本文件的其它部分, 也不需要动对局逻辑与菜单。
//
import AppKit

class BoardView: NSView {

    // MARK: - 局面 (由对局逻辑写入)

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

    // MARK: - 特技设置 (菜单写入)

    /// 走子轨迹风格
    var traj = Trajectory()
    /// 吃子是否在棋盘上留下裂痕, 并永久保留
    var crackEnabled = true
    /// 调试: 叠加显示全部轨迹形状 (XQ_FX=paths)
    var debugShowPaths = false

    // MARK: - 内部动画状态

    /// 正在播放的走子动画
    var anim: MoveAnim?
    // 选中棋子的"离板抬起"状态
    var liftT: CGFloat = 0
    var liftSq: Int? = nil
    var liftPiece: Int = 0
    private var lastTickT: Double = 0
    var shakeUntil: Double = 0
    var flashUntil: Double = 0
    var hintUntil: Double = 0
    private var timer: Timer?

    // MARK: - 图层

    let crackLayer = CrackLayer()
    let burstLayer = BurstLayer()
    let actorLayer = ActorLayer()
    let overlayLayer = OverlayLayer()
    let weatherState = WeatherState()
    private let pipeline = RenderPipeline()

    // MARK: - 组装

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildPipeline()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildPipeline()
    }

    /// 图层注册表 —— 新增特效唯一的接入点。顺序 = 绘制顺序 (从下往上)。
    private func buildPipeline() {
        pipeline.register(WeatherLayer(.back, weatherState))   // 远景雨幕 (棋盘之下)
        pipeline.register(BoardPlateLayer())                   // 棋盘石板
        pipeline.register(crackLayer)                          // 永久裂痕
        pipeline.register(MarkerLayer())                       // 各类标记
        pipeline.register(PieceLayer())                        // 棋子 + 抬起 + 走子动画
        pipeline.register(burstLayer)                          // 涟漪 + 吃子爆点
        pipeline.register(actorLayer)                          // 演员 (马)
        pipeline.register(WeatherLayer(.front, weatherState))  // 近景雨幕 + 水花 + 闪电
        pipeline.register(DebugPathLayer())                    // 调试轨迹
        pipeline.register(overlayLayer)                        // 将军红闪 + 绝杀大字
    }

    /// 图层栈快照, 形如 "rainBack → board → cracks* …" (带 * 表示该层仍在动)
    var layerSummary: String { pipeline.summary }

    // MARK: - 兼容旧调用点的转发

    /// 天气 (雨)。AppDelegate 用 `boardView.weather.setKind(...)` 切换。
    var weather: Weather {
        get { weatherState.weather }
        set { weatherState.weather = newValue }
    }
    /// 绝杀大字
    var bigText: (text: String, start: Double, dur: Double)? {
        get { overlayLayer.bigText }
        set { overlayLayer.bigText = newValue }
    }
    /// 棋盘上的裂痕数量
    var decalCount: Int { crackLayer.count }
    /// 棋子贴图 (薄封装, 便于调试与复用)
    func pieceTexture(_ p: Int) -> NSImage? { PieceTextures.image(p) }

    // MARK: - 布局

    var layout: (ox: CGFloat, oy: CGFloat, cell: CGFloat) {
        let b = bounds
        let pad: CGFloat = 10
        let cell = min((b.width - 2 * pad) / (8 + 2 * BOARD_EDGE_CELLS),
                       (b.height - 2 * pad) / (9 + 2 * BOARD_EDGE_CELLS))
        let bw = cell * 8, bh = cell * 9
        return ((b.width - bw) / 2, (b.height - bh) / 2, cell)
    }
    override var isOpaque: Bool { true }

    /// 棋盘石板(含边框)在视图坐标里的范围
    var boardPlateRect: CGRect {
        let (ox, oy, cell) = layout
        let rim = cell * BOARD_RIM_CELLS
        return CGRect(x: ox - rim, y: oy - rim,
                      width: cell * 8 + 2 * rim, height: cell * 9 + 2 * rim)
    }

    // MARK: - 坐标映射

    /// 棋盘坐标 -> 屏幕显示坐标 (按 flipBoard 旋转)
    func dispRC(_ sq: Int) -> (Int, Int) {
        let (r, c) = rc(sq)
        return flipBoard ? (9 - r, 8 - c) : (r, c)
    }
    func center(_ sq: Int, _ ox: CGFloat, _ oy: CGFloat, _ cell: CGFloat) -> CGPoint {
        let (r, c) = dispRC(sq)
        return CGPoint(x: ox + cell * CGFloat(c), y: oy + cell * CGFloat(r))
    }

    // MARK: - 主循环

    /// 唤醒 60fps 重绘 (已经在跑就什么都不做)。
    /// 定时器是"按需"的: tick 里发现所有图层都静止就自己停掉。
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
        // 让图层推进各自的状态 (雨滴积分、剔除尘粒、摘掉演员、清大字)
        pipeline.update(makeContext(now: now, dt: dt))
        setNeedsDisplay(bounds)
        // 只要还有任何东西在动就继续跑; 全静了就熄火, 不再空转
        let animating = pipeline.isAnimating
            || anim != nil
            || now < shakeUntil || now < flashUntil || now < hintUntil
            || abs(liftT - target) > 0.0005
        if !animating { timer?.invalidate(); timer = nil; lastTickT = 0 }
    }

    /// 把当前状态打成一份帧快照 —— 图层只能通过它读局面
    private func makeContext(now: Double, dt: Double = 1.0 / 60) -> RenderContext {
        let (ox, oy, cell) = layout
        var ctx = RenderContext()
        ctx.bounds = bounds
        ctx.ox = ox; ctx.oy = oy; ctx.cell = cell
        ctx.now = now; ctx.dt = dt
        ctx.shakeX = now < shakeUntil ? sin(now * 40) * 4 : 0
        ctx.flashUntil = flashUntil
        ctx.hintUntil = hintUntil
        ctx.scene.board = board
        ctx.scene.lastMove = lastMove
        ctx.scene.legalTargets = legalTargets
        ctx.scene.hintSq = hintSq
        ctx.scene.threats = threats
        ctx.scene.selected = selected
        ctx.scene.simMode = simMode
        ctx.scene.flipBoard = flipBoard
        ctx.scene.liftT = liftT
        ctx.scene.liftSq = liftSq
        ctx.scene.liftPiece = liftPiece
        ctx.scene.anim = anim
        ctx.scene.debugShowPaths = debugShowPaths
        return ctx
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor(calibratedRed: 0.88, green: 0.87, blue: 0.83, alpha: 1).setFill()
        NSBezierPath.fill(bounds)
        pipeline.draw(makeContext(now: CACurrentMediaTime()))
    }

    // MARK: - 交互

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let (ox, oy, cell) = layout
        let col = Int(round((p.x - ox) / cell))
        let row = Int(round((p.y - oy) / cell))
        guard row >= 0, row < 10, col >= 0, col < 9 else { return }
        let (r, c) = flipBoard ? (9 - row, 8 - col) : (row, col)   // 显示坐标 -> 棋盘坐标
        onSquareClick?(r * 9 + c)
    }

    // MARK: - 对局逻辑调用的动作接口

    func showBigText(_ text: String, dur: Double = 2.4) {
        bigText = (text, CACurrentMediaTime(), dur); kick()
    }
    func flashCheck() { flashUntil = CACurrentMediaTime() + 0.45; kick() }
    func kickHint() { hintUntil = CACurrentMediaTime() + 3.0; kick() }
    func setThreats(_ sqs: [Int]) { threats = sqs; setNeedsDisplay(bounds) }

    /// 清空棋盘上的全部伤痕 (开新局 / 手动清除)
    func clearDecals() { crackLayer.clear(); setNeedsDisplay(bounds) }

    /// 调试用: 直接在指定格上放一道成熟的裂痕 (供 XQ_FX=crack 出图验证)
    func debugAddCrack(sq: Int, born: Double, power: CGFloat) {
        crackLayer.forge(sq: sq, born: born, power: power)
        setNeedsDisplay(bounds)
    }

    /// 让一匹马从画面外跑过
    func runHorse() { actorLayer.runHorse(); kick() }
}
