//
//  RenderLayer.swift
//  人机中国象棋 · 渲染图层协议与帧上下文
//
//  ── 这一层解决什么问题 ──
//  改造前: 所有绘制都堆在 BoardView.draw() 里, 于是「加一个特效」必须改 BoardView,
//  而 BoardView 同时扛着对局交互、命中测试、定时器 —— 改一处就牵动全局。
//  改造后: 每种视觉元素是一个 RenderLayer。新增特效 = 新建一个文件实现协议,
//  再在 BoardView 里加一行注册。BoardView 本体、对局逻辑、菜单都不用动。
//
import AppKit

// MARK: - 帧快照

/// 一帧棋盘的只读快照 —— 图层通过它读局面, 不需要反向持有 BoardView。
/// 新增一种特效需要读新的局面字段时, 在这里加一个字段并让 BoardView 填上即可。
struct BoardScene {
    var board: [Int] = Array(repeating: 0, count: 90)
    var lastMove: (Int, Int)?
    var legalTargets: [Int] = []
    var hintSq: (Int, Int)?
    var threats: [Int] = []
    var selected: Int?
    var simMode = false
    var flipBoard = true
    /// 选中棋子"离板抬起"的进度 (0 平放 ~ 1 完全抬起) 与目标格/棋子
    var liftT: CGFloat = 0
    var liftSq: Int?
    var liftPiece: Int = 0
    /// 正在播放的走子动画 (nil = 无)
    var anim: BoardView.MoveAnim?
    /// 调试: 叠加显示全部轨迹形状
    var debugShowPaths = false
}

// MARK: - 帧上下文

/// 一帧的渲染上下文: 布局 + 时刻 + 局面快照。每帧只构造一次, 传给所有图层。
struct RenderContext {
    var bounds: CGRect = .zero
    /// 棋盘网格原点 (左下角第 0 行第 0 列的交叉点) 与格宽
    var ox: CGFloat = 0
    var oy: CGFloat = 0
    var cell: CGFloat = 0
    var now: Double = 0
    /// 本帧与上一帧的间隔(秒) —— 需要积分的图层(雨滴)用它
    var dt: Double = 1.0 / 60
    /// 震屏横向偏移 (0 = 不抖)
    var shakeX: CGFloat = 0
    /// 将军红闪与提示发光的截止时刻
    var flashUntil: Double = 0
    var hintUntil: Double = 0
    var scene = BoardScene()

    var boardW: CGFloat { cell * 8 }
    var boardH: CGFloat { cell * 9 }
    var cg: CGContext? { NSGraphicsContext.current?.cgContext }

    /// 棋盘石板(含边框)在视图里的范围 —— 天气系统用它判断雨滴落点该不该溅水花
    var plateRect: CGRect {
        let rim = cell * BOARD_RIM_CELLS
        return CGRect(x: ox - rim, y: oy - rim,
                      width: boardW + 2 * rim, height: boardH + 2 * rim)
    }

    /// 棋盘坐标 -> 视图显示坐标 (按 flipBoard 整体旋转)
    func dispRC(_ sq: Int) -> (Int, Int) {
        let row = sq / 9, col = sq % 9
        return scene.flipBoard ? (9 - row, 8 - col) : (row, col)
    }

    /// 棋盘坐标 -> 交叉点在视图里的位置
    func center(_ sq: Int) -> CGPoint {
        let (r, c) = dispRC(sq)
        return CGPoint(x: ox + cell * CGFloat(c), y: oy + cell * CGFloat(r))
    }
}

// MARK: - 图层协议

/// 可插拔的渲染图层。管线按注册顺序绘制。
protocol RenderLayer: AnyObject {
    /// 层名 (调试与性能统计用)
    var name: String { get }
    /// 是否仍在活动 —— 直接影响 60fps 定时器的存续
    var isAnimating: Bool { get }
    /// 是否跟随棋盘震屏。棋盘/裂痕/棋子跟随; 天气/演员/大字不跟随, 否则会被棋盘带着抖。
    var followsShake: Bool { get }
    /// 每帧推进状态 (可选)
    func update(_ ctx: RenderContext)
    /// 绘制 (可选)
    func draw(_ ctx: RenderContext)
}

extension RenderLayer {
    var isAnimating: Bool { false }
    var followsShake: Bool { false }
    func update(_ ctx: RenderContext) {}
    func draw(_ ctx: RenderContext) {}
}
