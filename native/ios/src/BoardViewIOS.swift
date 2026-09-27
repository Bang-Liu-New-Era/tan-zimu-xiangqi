//
//  BoardViewIOS.swift
//  人机中国象棋 · 棋盘视图 (iOS / UIKit 版)
//
//  与 macOS 版 (UI/BoardView.swift) 公开面完全一致 —— GameController / MoveAnimator /
//  各 RenderLayer 不区分平台。两份文件须同步维护: 改公开属性/方法时两边都要改。
//
//  与 macOS 版仅有的真实差异:
//    ① draw() 开头把上下文整体翻成 y 向上 (UIKit 默认 y 向下), 之后所有渲染
//       代码与 macOS 完全同构 —— 文本除外 (文本经 xqDraw/局部反翻处理, 见 CrossPlatform)。
//    ② 鼠标点击 → 触摸 (触点 y 要从"上原点"换算回"下原点")。
//    ③ backingScaleFactor → UIScreen.scale。
//
#if canImport(UIKit)
import UIKit

class BoardView: UIView {

    // MARK: - 震屏强度

    /// 全局震屏强度系数, 所有落子震幅都会乘上它。
    /// 1.0 = 原始力度; 0.5 = 减弱 50%; 0 = 完全关闭震屏。
    /// 调"震感强弱"只改这一处, 不用去翻各个特效分支里的数字。
    static let shakeScale: CGFloat = 0.5

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
    var shakeAmp: CGFloat = 4 * BoardView.shakeScale   // 震屏幅度(px): 吃子砸裂 = 6, 普通落子 = 3 (再乘全局系数)
    var flashUntil: Double = 0
    var hintUntil: Double = 0
    private var timer: Timer?

    // MARK: - 图层

    let crackLayer = CrackLayer()
    let burstLayer = BurstLayer()
    let overlayLayer = OverlayLayer()
    private let pipeline = RenderPipeline()

    // MARK: - 组装

    override init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        isOpaque = true          // iOS 上这是存储属性, 不能用计算属性覆写
        buildPipeline()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isOpaque = true
        buildPipeline()
    }

    /// 图层注册表 —— 新增特效唯一的接入点。顺序 = 绘制顺序 (从下往上)。
    private func buildPipeline() {
        pipeline.register(BoardPlateLayer())                   // 棋盘石板
        pipeline.register(crackLayer)                          // 永久裂痕
        pipeline.register(MarkerLayer())                       // 各类标记
        pipeline.register(PieceLayer())                        // 棋子 + 抬起 + 走子动画
        pipeline.register(burstLayer)                          // 涟漪 + 吃子爆点
        pipeline.register(DebugPathLayer())                    // 调试轨迹
        pipeline.register(overlayLayer)                        // 将军红闪 + 绝杀大字
    }

    /// 图层栈快照, 形如 "board → cracks* → pieces …" (带 * 表示该层仍在动)
    var layerSummary: String { pipeline.summary }

    // MARK: - 兼容旧调用点的转发

    /// 绝杀大字
    var bigText: (text: String, start: Double, dur: Double)? {
        get { overlayLayer.bigText }
        set { overlayLayer.bigText = newValue }
    }
    /// 棋盘上的裂痕数量
    var decalCount: Int { crackLayer.count }
    /// 棋子贴图 (薄封装, 便于调试与复用)
    func pieceTexture(_ p: Int) -> UIImage? { PieceTextures.image(p) }

    // MARK: - 布局

    var layout: (ox: CGFloat, oy: CGFloat, cell: CGFloat) {
        let b = bounds
        let pad: CGFloat = 10
        let cell = min((b.width - 2 * pad) / (8 + 2 * BOARD_EDGE_CELLS),
                       (b.height - 2 * pad) / (9 + 2 * BOARD_EDGE_CELLS))
        let bw = cell * 8, bh = cell * 9
        return ((b.width - bw) / 2, (b.height - bh) / 2, cell)
    }
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
        // 让图层推进各自的状态
        pipeline.update(makeContext(now: now, dt: dt))
        setNeedsDisplay()
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
        ctx.shakeX = now < shakeUntil ? sin(now * 40) * shakeAmp : 0
        ctx.flashUntil = flashUntil
        ctx.hintUntil = hintUntil
        ctx.scale = UIScreen.main.scale
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

    override func draw(_ rect: CGRect) {
        guard let cg = UIGraphicsGetCurrentContext() else { return }
        cg.saveGState()
        // UIKit 上下文 y 向下; 整套渲染数学按 y 向上写 → 整体翻一次,
        // 之后所有图层与 macOS 完全同构 (文本在 xqDraw 里局部反翻)。
        cg.translateBy(x: 0, y: bounds.height)
        cg.scaleBy(x: 1, y: -1)
        let t0 = PerfMonitor.enabled ? CACurrentMediaTime() : 0
        XColor(crossRed: 0.88, green: 0.87, blue: 0.83, alpha: 1).setFill()
        XBezierPath.fill(bounds)
        pipeline.draw(makeContext(now: CACurrentMediaTime()))
        if PerfMonitor.enabled { PerfMonitor.record(CACurrentMediaTime() - t0) }
        cg.restoreGState()
    }

    // MARK: - 交互

    /// 视图坐标(UIKit, 原点左上) -> 棋盘格号。
    /// 抽成独立函数是为了可自检: 用 center(sq) 反推一个点再喂回来, 必须得到同一个 sq。
    func squareAt(_ p: CGPoint) -> Int? {
        let yUp = bounds.height - p.y          // UIKit 触点是"上原点", 渲染坐标是"下原点"
        let (ox, oy, cell) = layout
        let col = Int(round((p.x - ox) / cell))
        let row = Int(round((yUp - oy) / cell))
        guard row >= 0, row < 10, col >= 0, col < 9 else { return nil }
        let (r, c) = flipBoard ? (9 - row, 8 - col) : (row, col)   // 显示坐标 -> 棋盘坐标
        return r * 9 + c
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, let sq = squareAt(t.location(in: self)) else { return }
        onSquareClick?(sq)
    }

    // MARK: - 对局逻辑调用的动作接口

    func showBigText(_ text: String, dur: Double = 2.4) {
        bigText = (text, CACurrentMediaTime(), dur); kick()
    }
    func flashCheck() { flashUntil = CACurrentMediaTime() + 0.45; kick() }
    func kickHint() { hintUntil = CACurrentMediaTime() + 3.0; kick() }
    func setThreats(_ sqs: [Int]) { threats = sqs; setNeedsDisplay() }

    /// 清空棋盘上的全部伤痕 (开新局 / 手动清除)
    func clearDecals() { crackLayer.clear(); setNeedsDisplay() }

    /// 调试用: 直接在指定格上放一道成熟的裂痕
    func debugAddCrack(sq: Int, born: Double, power: CGFloat) {
        crackLayer.forge(sq: sq, born: born, power: power)
        setNeedsDisplay()
    }
}

#endif
