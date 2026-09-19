// XiangqiApp.swift — 人机中国象棋·教学版 (纯原生 macOS 程序)
// 完全原生渲染: AppKit + CoreGraphics 绘制棋盘/棋子/特效, 不再使用 WebView/HTML。
// 引擎: 内置 JS 引擎 (JavaScriptCore 桥接 engine/*.js) 或 可选 Pikafish (UCI 进程)。
import AppKit
import AVFoundation
import JavaScriptCore
import CoreText

// MARK: - 常量
let RED = "r"
let BLACK = "b"
let PIECE_CHARS: [Int: String] = [
    1: "帅", 2: "仕", 3: "相", 4: "马", 5: "车", 6: "炮", 7: "兵",
    9: "将", 10: "士", 11: "象", 12: "马", 13: "车", 14: "炮", 15: "卒",
]

struct Difficulty {
    let id: String
    let label: String
    let embeddedBudget: Int   // 内置引擎时间预算(ms)
    let pikaMovetime: Int      // Pikafish 思考时间(ms)
    let pikaElo: Int          // Pikafish 限制强度
}
let DIFFICULTIES = [
    Difficulty(id: "easy",   label: "入门", embeddedBudget: 350,  pikaMovetime: 250,  pikaElo: 1000),
    Difficulty(id: "medium", label: "进阶", embeddedBudget: 1000, pikaMovetime: 900,  pikaElo: 1500),
    Difficulty(id: "hard",   label: "高手", embeddedBudget: 2000, pikaMovetime: 2500, pikaElo: 2000),
]

func rc(_ i: Int) -> (Int, Int) { (i / 9, i % 9) }
func opp(_ c: String) -> String { c == RED ? BLACK : RED }

// 棋盘贴图几何: 贴图内每格 220px, 最外网格线距贴图边缘 7px, 程序化石板边框宽 0.30 格
let TEX_CELL_PX: CGFloat = 220
let TEX_INSET_PX: CGFloat = 7
let BOARD_RIM_CELLS: CGFloat = 0.30
let BOARD_EDGE_CELLS: CGFloat = BOARD_RIM_CELLS + TEX_INSET_PX / TEX_CELL_PX

// 棋子贴图几何: 贴图是正方形, 棋子直径占画幅 PIECE_TEX_RATIO, 显示直径 = 0.84 格
let PIECE_TEX_RATIO: CGFloat = 0.897
let PIECE_TEX_SPAN: CGFloat = 0.84 / PIECE_TEX_RATIO

// MARK: - JS 转换辅助
func boardFromJS(_ v: JSValue?) -> [Int] {
    guard let arr = v?.toArray() else { return [] }
    return arr.compactMap { ($0 as? NSNumber)?.intValue }
}
func movesFromJS(_ v: JSValue?) -> [[String: Any]] {
    guard let arr = v?.toArray() else { return [] }
    return arr.compactMap { $0 as? [String: Any] }
}
func dictFromJS(_ v: JSValue?) -> [String: Any]? {
    guard let d = v?.toDictionary() else { return nil }
    return d as? [String: Any]
}

// MARK: - 引擎桥 (JavaScriptCore)
class EngineBridge {
    let ctx: JSContext
    init?() {
        guard let c = JSContext() else { return nil }
        c.exceptionHandler = { _, e in print("JS error:", e?.toString() ?? "?") }
        for f in ["xiangqi", "ai", "coach"] {
            guard let url = Bundle.main.url(forResource: f, withExtension: "js"),
                  let src = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            c.evaluateScript(src)
        }
        ctx = c
    }
    func call(_ path: [String], _ args: [Any]) -> JSValue? {
        var ref: JSValue? = ctx.globalObject
        for p in path { ref = ref?.objectForKeyedSubscript(p) }
        return ref?.call(withArguments: args)
    }
    func initialBoard() -> [Int] { boardFromJS(call(["Xiangqi", "initialBoard"], [])) }
    func legalMoves(_ b: [Int], _ color: String) -> [[String: Any]] {
        movesFromJS(call(["Xiangqi", "generateLegalMoves"], [b, color]))
    }
    func applyMove(_ b: [Int], _ m: [String: Any]) -> [Int]? {
        guard let r = call(["Xiangqi", "applyMove"], [b, m]) else { return nil }
        let a = boardFromJS(r); return a.isEmpty ? nil : a
    }
    func isInCheck(_ b: [Int], _ color: String) -> Bool {
        call(["Xiangqi", "isInCheck"], [b, color])?.toBool() ?? false
    }
    func boardToFen(_ b: [Int], _ color: String) -> String {
        call(["Xiangqi", "boardToFen"], [b, color])?.toString() ?? ""
    }
    func moveToNotation(_ b: [Int], _ m: [String: Any], _ color: String) -> String {
        call(["Xiangqi", "moveToNotation"], [b, m, color])?.toString() ?? ""
    }
    // coach
    func coachEvaluate(_ b: [Int]) -> Int {
        call(["Xiangqi", "coach", "evaluate"], [b])?.toNumber()?.intValue ?? 0
    }
    func coachHint(_ b: [Int], _ c: String, _ budget: Int) -> [String: Any]? {
        dictFromJS(call(["Xiangqi", "coach", "hint"], [b, c, budget]))
    }
    func coachThreats(_ b: [Int], _ c: String) -> (inCheck: Bool, pieces: [[String: Any]]) {
        guard let d = dictFromJS(call(["Xiangqi", "coach", "threats"], [b, c])) else { return (false, []) }
        return (d["inCheck"] as? Bool ?? false, d["pieces"] as? [[String: Any]] ?? [])
    }
    func coachCommentary(before: [Int], move: [String: Any], after: [Int], mover: String, ply: Int) -> [String: Any]? {
        dictFromJS(call(["Xiangqi", "coach", "commentary"], [before, move, after, mover, ply]))
    }
}

// MARK: - 后台搜索 (独立 JSContext, 不阻塞主线程)
class BackgroundEngine {
    let queue = DispatchQueue(label: "xq.bg")
    var ctx: JSContext?
    func search(board: [Int], turn: String, budget: Int, depth: Int,
                completion: @escaping ([String: Any]?) -> Void) {
        queue.async {
            if self.ctx == nil {
                guard let c = JSContext() else { DispatchQueue.main.async { completion(nil) }; return }
                c.exceptionHandler = { _, e in print("bg JS err:", e?.toString() ?? "?") }
                for f in ["xiangqi", "ai", "coach"] {
                    guard let url = Bundle.main.url(forResource: f, withExtension: "js"),
                          let src = try? String(contentsOf: url, encoding: .utf8) else {
                        DispatchQueue.main.async { completion(nil) }; return
                    }
                    c.evaluateScript(src)
                }
                self.ctx = c
            }
            guard let res = self.ctx?.objectForKeyedSubscript("XiangqiAI")?
                    .objectForKeyedSubscript("search")?
                    .call(withArguments: [board, turn, budget, depth]) else {
                DispatchQueue.main.async { completion(nil) }; return
            }
            guard let from = res.objectForKeyedSubscript("from")?.toNumber()?.intValue,
                  let to = res.objectForKeyedSubscript("to")?.toNumber()?.intValue else {
                DispatchQueue.main.async { completion(nil) }; return
            }
            DispatchQueue.main.async { completion(["from": from, "to": to]) }
        }
    }
}

// MARK: - Pikafish 引擎 (UCI 进程)
class PikafishEngine {
    let path: String
    var process: Process?
    var inHandle: FileHandle?
    var outHandle: FileHandle?
    var readBuffer = ""
    var available = false
    var elo = 2000
    var movetime = 2500
    init?(path: String) {
        self.path = path
        start()
        if !available { return nil }
    }
    func start() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        let outPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe; p.standardInput = inPipe
        do { try p.run() } catch { return }
        inHandle = inPipe.fileHandleForWriting
        outHandle = outPipe.fileHandleForReading
        process = p
        var got = false
        let grp = DispatchGroup(); grp.enter()
        outHandle?.readabilityHandler = { [weak self] handle in
            guard let self = self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let s = String(data: data, encoding: .utf8) { self.readBuffer += s }
            if self.readBuffer.contains("uciok") { got = true; self.readBuffer = ""; grp.leave() }
        }
        inHandle?.write(Data("uci\n".utf8))
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) { if !got { grp.leave() } }
        grp.wait()
        outHandle?.readabilityHandler = nil
        if got {
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("pikafish.nnue").path) {
                inHandle?.write(Data("setoption name EvalFile value pikafish.nnue\n".utf8))
            }
            available = true
        }
    }
    func setStrength(elo: Int, movetime: Int) {
        self.elo = elo; self.movetime = movetime
        inHandle?.write(Data("setoption name UCI_LimitStrength value true\n".utf8))
        inHandle?.write(Data("setoption name UCI_Elo value \(elo)\n".utf8))
    }
    func bestMove(fen: String, completion: @escaping (String?) -> Void) {
        guard let inH = inHandle, let outH = outHandle, available else { completion(nil); return }
        var result: String? = nil
        var done = false
        let grp = DispatchGroup(); grp.enter()
        readBuffer = ""
        outH.readabilityHandler = { [weak self] handle in
            guard let self = self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let s = String(data: data, encoding: .utf8) { self.readBuffer += s }
            while let r = self.readBuffer.range(of: "\n") {
                let line = String(self.readBuffer[..<r.lowerBound])
                self.readBuffer.removeSubrange(self.readBuffer.startIndex..<r.upperBound)
                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.hasPrefix("bestmove") {
                    let ps = t.components(separatedBy: " ")
                    if ps.count >= 2 { result = ps[1] }
                    if !done { done = true; grp.leave() }
                }
            }
        }
        inH.write(Data("position fen \(fen)\n".utf8))
        inH.write(Data("go movetime \(movetime)\n".utf8))
        DispatchQueue.global().asyncAfter(deadline: .now() + Double(movetime + 3000) / 1000.0) {
            if !done { done = true; grp.leave() }
        }
        grp.notify(queue: .main) { outH.readabilityHandler = nil; completion(result) }
    }
    func quit() { inHandle?.write(Data("quit\n".utf8)) }
}

// MARK: - 评估条
class EvalBarView: NSView {
    var eval = 0
    var color = RED
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let b = bounds
        NSColor(calibratedWhite: 0.85, alpha: 1).setFill()
        NSBezierPath(roundedRect: b, xRadius: 4, yRadius: 4).fill()
        let ratio = max(-1.0, min(1.0, Double(eval) / 1500.0))
        let mid = b.width / 2
        let w = abs(ratio) * (b.width / 2)
        let col: NSColor = ratio >= 0
            ? NSColor(calibratedRed: 0.78, green: 0.16, blue: 0.12, alpha: 1)
            : NSColor(calibratedRed: 0.12, green: 0.12, blue: 0.12, alpha: 1)
        col.setFill()
        let x = ratio >= 0 ? mid - w : mid
        NSBezierPath(roundedRect: NSRect(x: x, y: 1, width: w, height: b.height - 2), xRadius: 3, yRadius: 3).fill()
    }
}

// MARK: - 教学侧栏
class CoachPanel: NSView {
    let textView = NSTextView()
    let evalBar = EvalBarView()
    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }
    func setup() {
        wantsLayer = true
        let stack = NSStackView()
        stack.orientation = .vertical; stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        let title = NSTextField(labelWithString: "局势评估")
        title.font = NSFont.boldSystemFont(ofSize: 12)
        stack.addArrangedSubview(title)
        evalBar.translatesAutoresizingMaskIntoConstraints = false
        evalBar.heightAnchor.constraint(equalToConstant: 16).isActive = true
        stack.addArrangedSubview(evalBar)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false; textView.isSelectable = true
        textView.font = NSFont.systemFont(ofSize: 12)
        textView.backgroundColor = NSColor(calibratedWhite: 0.97, alpha: 1)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        scroll.documentView = textView
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        textView.setContentHuggingPriority(.defaultLow, for: .vertical)
        stack.addArrangedSubview(scroll)
    }
    func update(text: String, eval: Int, color: String) {
        textView.string = text
        textView.scrollToEndOfDocument(nil)
        evalBar.eval = eval; evalBar.color = color; evalBar.needsDisplay = true
    }
}

// MARK: - 棋盘视图 (原生绘制)
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
enum Ease: String, CaseIterable {
    case smooth, linear, easeIn, easeOut, easeInOut, snap, over
    var label: String {
        switch self {
        case .smooth:    return "平滑"
        case .linear:    return "匀速"
        case .easeIn:    return "渐快"
        case .easeOut:   return "渐慢"
        case .easeInOut: return "缓入缓出"
        case .snap:      return "抢子"
        case .over:      return "过冲"
        }
    }
    func f(_ t: CGFloat) -> CGFloat {
        let u = max(0, min(1, t))
        switch self {
        case .linear:             return u
        case .smooth, .easeInOut: return u * u * (3 - 2 * u)
        case .easeIn:             return u * u * u
        case .easeOut:            return 1 - pow(1 - u, 3)
        case .snap:               return 1 - pow(1 - u, 4)
        case .over:
            let c1: CGFloat = 1.70158
            return 1 + (c1 + 1) * pow(u - 1, 3) + c1 * pow(u - 1, 2)
        }
    }
}

/// 走子轨迹。所有几何量都在「格」坐标系里定义: 采样得到侧向偏移与抬升(单位=格),
/// 由绘制方乘以格子尺寸。因此与窗口缩放、棋盘 180° 翻转完全无关。
struct Trajectory {
    enum Shape: String, CaseIterable {
        case arc, straight, bezier, flank, zigzag, spiral
        var label: String {
            switch self {
            case .arc:      return "抛物线"
            case .straight: return "贴地推"
            case .bezier:   return "贝塞尔"
            case .flank:    return "绕侧翼"
            case .zigzag:   return "折线跃"
            case .spiral:   return "螺旋收"
            }
        }
    }
    var shape: Shape = .arc
    var ease: Ease = .smooth
    var fly: Double = 0.26          // 飞行时长(秒)
    var land: Double = 0.13         // 落地回弹时长
    var hop: CGFloat = 0.30         // 抬升峰值(格)
    var spin: CGFloat = 14          // 空中旋转(度)
    var scalePeak: CGFloat = 0.13   // 弧顶放大
    var bend: CGFloat = 1           // 侧向绕行方向 +1 / -1
    /// 途经格(可选)。非空时按折线依次经过这些交叉点, 覆盖 shape 的路径。
    var via: [Int] = []

    static func of(_ s: Shape) -> Trajectory { var t = Trajectory(); t.shape = s; return t }

    /// 采样飞行姿态 → (侧向偏移(格), 抬升(格), 旋转(rad), 缩放)
    func sample(_ t: CGFloat) -> (perp: CGFloat, lift: CGFloat, rot: CGFloat, scale: CGFloat) {
        let u = max(0, min(1, t))
        let (perp, lift) = shapeScalars(u)
        let rot = spin * .pi / 180 * sin(.pi * u)
        let k = hop > 0.0001 ? lift / hop : 0
        return (perp, lift, rot, 1 + scalePeak * k)
    }
    /// 形状只贡献两个标量: 垂直于 A→B 的侧偏, 与离板抬升。推进节奏由 Ease 单独负责。
    private func shapeScalars(_ u: CGFloat) -> (perp: CGFloat, lift: CGFloat) {
        let bell = 4 * u * (1 - u)                       // 0 → 1 → 0
        switch shape {
        case .arc:      return (0, hop * bell)
        case .straight: return (0, hop * 0.10 * bell)
        case .bezier:   return (bend * 0.55 * sin(.pi * u), hop * bell * 0.90)
        case .flank:    return (bend * 1.25 * sin(.pi * u), hop * 0.70 * bell)
        case .zigzag:   return (bend * 0.26 * sin(2 * .pi * u), hop * abs(sin(2 * .pi * u)) * 0.85)
        case .spiral:   return (bend * 0.46 * (1 - u) * sin(2.4 * .pi * u), hop * bell * (1 - 0.30 * u))
        }
    }
}

// MARK: - 伤痕贴花 (吃子后永久留在棋盘上的裂痕)
/// 确定性伪随机 (xorshift64): 同一个种子永远长出同一道裂纹 —— 便于复现与测试。
struct SeededRNG {
    private var s: UInt64
    init(_ seed: UInt64) { s = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> UInt64 { s ^= s << 13; s ^= s >> 7; s ^= s << 17; return s }
    mutating func unit() -> CGFloat { CGFloat(next() % 100_000) / 100_000 }
    mutating func range(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * unit() }
    mutating func chance(_ p: CGFloat) -> Bool { unit() < p }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(1, n))) }
}

/// 一道裂纹。branches 里的点相对被吃子格中心, 单位是「格」。
struct Crack {
    let sq: Int
    let born: Double              // 出生时刻(绝对秒): 落地那一刻才开始生长
    let branches: [[CGPoint]]
    let width: CGFloat            // 主裂纹线宽(格)
    let tint: CGFloat             // 0=浅 1=深
    let scorch: CGFloat           // 中心焦痕半径(格), 0 = 无
    let dur: Double = 0.42        // 生长时长
}

enum CrackForge {
    /// power: 0.7~1.0 的破坏力(车碾碎最大), 决定纹路密度、线宽与焦痕。
    static func forge(sq: Int, born: Double, seed: UInt64, power: CGFloat) -> Crack {
        var rng = SeededRNG(seed)
        var branches: [[CGPoint]] = []
        let mains = 5 + rng.int(4)                                   // 5~8 条主裂纹
        let baseLen = 0.17 + 0.15 * power                            // 单段基准长度(格)
        let base = rng.range(0, 2 * .pi)
        for i in 0..<mains {
            let ang = base + CGFloat(i) / CGFloat(mains) * 2 * .pi + rng.range(-0.30, 0.30)
            var line: [CGPoint] = [.zero]
            grow(&rng, &line, branches: &branches, from: .zero, angle: ang,
                 steps: 3 + rng.int(4), len: baseLen * rng.range(0.80, 1.25), depth: 0)
            branches.append(line)
        }
        return Crack(sq: sq, born: born, branches: branches,
                     width: 0.018 + 0.016 * power,
                     tint: 0.55 + 0.45 * power,
                     scorch: power > 0.9 ? 0.30 : 0.18)
    }

    /// 递归生长一条裂纹: 每段方向抖动、长度衰减, 并按概率分叉出细纹。
    private static func grow(_ rng: inout SeededRNG, _ line: inout [CGPoint], branches: inout [[CGPoint]],
                             from p: CGPoint, angle: CGFloat, steps: Int, len: CGFloat, depth: Int) {
        var pt = p, ang = angle, L = len
        for _ in 0..<steps {
            ang += rng.range(-0.45, 0.45)
            L *= rng.range(0.70, 0.94)
            pt = CGPoint(x: pt.x + cos(ang) * L, y: pt.y + sin(ang) * L)
            line.append(pt)
            if depth < 2, L > 0.05, rng.chance(0.42) {
                var sub: [CGPoint] = [pt]
                grow(&rng, &sub, branches: &branches, from: pt,
                     angle: ang + (rng.chance(0.5) ? -1 : 1) * rng.range(0.55, 1.15),
                     steps: max(1, steps / 2), len: L * 0.62, depth: depth + 1)
                if sub.count > 1 { branches.append(sub) }
            }
        }
    }
}

// MARK: - 天气系统 (雨)
struct RainDrop {
    var x: CGFloat = 0, y: CGFloat = 0
    var len: CGFloat = 20, spd: CGFloat = 700
    var alpha: CGFloat = 0.5
    var layer: Int = 0          // 0 = 远景(棋盘之下) 1 = 近景(棋子之上)
}

struct Splash {                 // 雨点砸在棋盘上溅起的水花
    var x: CGFloat = 0, y: CGFloat = 0
    var t: CGFloat = 0
    var size: CGFloat = 1
}

struct Weather {
    enum Kind: String, CaseIterable {
        case none, drizzle, rain, storm
        var label: String {
            switch self {
            case .none:    return "无"
            case .drizzle: return "小雨"
            case .rain:    return "大雨"
            case .storm:   return "雷雨"
            }
        }
    }
    var kind: Kind = .none
    private var drops: [RainDrop] = []
    private var splashes: [Splash] = []
    private var clock: Double = 0
    private var nextBolt: Double = 5
    private(set) var flash: CGFloat = 0          // 闪电余辉 0~1

    var wind: CGFloat {
        switch kind {
        case .none:    return 0
        case .drizzle: return 0.16
        case .rain:    return 0.26
        case .storm:   return 0.42
        }
    }
    private var dropTarget: Int {
        switch kind {
        case .none:    return 0
        case .drizzle: return 150
        case .rain:    return 320
        case .storm:   return 500
        }
    }
    private var splashChance: CGFloat {
        switch kind {
        case .none, .drizzle: return 0.10
        case .rain:           return 0.42
        case .storm:          return 0.62
        }
    }
    var isActive: Bool { kind != .none || flash > 0.001 }

    mutating func setKind(_ k: Kind) {
        guard k != kind else { return }
        kind = k
        drops.removeAll(); splashes.removeAll()
        clock = 0; nextBolt = 4; flash = 0
    }

    private func makeDrop(_ view: CGRect, initial: Bool) -> RainDrop {
        let layer = Int.random(in: 0...1)
        var d = RainDrop()
        d.layer = layer
        d.x = CGFloat.random(in: -view.width * 0.15 ... view.width * 1.15)
        d.y = initial ? CGFloat.random(in: -40 ... view.height)
                      : CGFloat.random(in: view.height * 0.98 ... view.height * 1.12)
        if layer == 0 {                       // 远景: 细、慢、淡
            d.len = CGFloat.random(in: 10...20)
            d.spd = CGFloat.random(in: 380...560)
            d.alpha = CGFloat.random(in: 0.16...0.30)
        } else {                              // 近景: 粗、快、亮
            d.len = CGFloat.random(in: 24...50)
            d.spd = CGFloat.random(in: 780...1300)
            d.alpha = CGFloat.random(in: 0.32...0.58)
        }
        return d
    }

    mutating func update(_ dt: Double, board: CGRect, view: CGRect) {
        if kind == .none {
            if flash > 0 { flash = max(0, flash - CGFloat(dt) * 2.4) }
            return
        }
        clock += dt
        if kind == .storm, clock >= nextBolt {
            flash = 1.0
            nextBolt = clock + Double.random(in: 3.5...9.5)
        }
        if flash > 0 { flash = max(0, flash - CGFloat(dt) * 3.2) }

        let want = dropTarget
        while drops.count < want { drops.append(makeDrop(view, initial: true)) }
        if drops.count > want { drops.removeLast(drops.count - want) }

        let w = wind
        for i in drops.indices {
            drops[i].y -= drops[i].spd * CGFloat(dt)
            drops[i].x += w * drops[i].spd * CGFloat(dt) * 0.5
            if drops[i].y < -60 || drops[i].x > view.width + 120 {
                // 雨滴触底: 若落在棋盘横向范围内, 就在棋盘上砸出一朵水花
                if board.width > 0, drops[i].x > board.minX, drops[i].x < board.maxX,
                   CGFloat.random(in: 0...1) < splashChance {
                    splashes.append(Splash(x: drops[i].x,
                                           y: CGFloat.random(in: board.minY...board.maxY),
                                           t: 0, size: CGFloat.random(in: 0.7...1.4)))
                    if splashes.count > 90 { splashes.removeFirst(splashes.count - 90) }
                }
                drops[i] = makeDrop(view, initial: false)
            }
        }
        for i in splashes.indices { splashes[i].t += CGFloat(dt) / 0.42 }
        splashes.removeAll { $0.t >= 1 }
    }

    /// 远景雨: 画在棋盘之前, 制造「棋盘之外在下雨」的纵深感。
    func drawBack(_ cg: CGContext, _ view: CGRect) {
        drawDrops(cg, view, layer: 0)
    }
    /// 近景雨 + 水花 + 闪电: 画在棋子之后, 雨幕压在画面前方。
    func drawFront(_ cg: CGContext, _ view: CGRect) {
        drawDrops(cg, view, layer: 1)
        drawSplashes(cg)
        if flash > 0.001 {
            cg.saveGState()
            cg.setFillColor(NSColor(calibratedRed: 0.86, green: 0.90, blue: 1.0,
                                    alpha: 0.42 * flash).cgColor)
            cg.fill(view)
            cg.restoreGState()
        }
    }
    private func drawDrops(_ cg: CGContext, _ view: CGRect, layer: Int) {
        guard kind != .none else { return }
        let w = wind
        let norm = (w * w + 1).squareRoot()
        let ux = w / norm, uy = -1 / norm
        let path = CGMutablePath()
        for d in drops where d.layer == layer {
            let hx = d.x - ux * d.len * 0.5, hy = d.y - uy * d.len * 0.5
            let tx = d.x + ux * d.len * 0.5, ty = d.y + uy * d.len * 0.5
            path.move(to: CGPoint(x: hx, y: hy))
            path.addLine(to: CGPoint(x: tx, y: ty))
        }
        cg.saveGState()
        cg.addPath(path)
        cg.setLineWidth(layer == 0 ? 1.5 : 2.8)
        cg.setLineCap(.round)
        // 远景偏灰蓝、近景偏亮白 —— 靠颜色与线宽拉开纵深, 让雨幕是两层而不是一片
        let col = layer == 0
            ? NSColor(calibratedRed: 0.58, green: 0.68, blue: 0.82, alpha: 0.34)
            : NSColor(calibratedRed: 0.84, green: 0.91, blue: 1.00, alpha: 0.62)
        cg.setStrokeColor(col.cgColor)
        cg.strokePath()
        cg.restoreGState()
    }
    private func drawSplashes(_ cg: CGContext) {
        for s in splashes {
            let fade = 1 - s.t
            let r = 7 * s.size * (0.30 + 1.7 * s.t)
            cg.saveGState()
            cg.setStrokeColor(NSColor(calibratedRed: 0.86, green: 0.93, blue: 1.00,
                                      alpha: 0.95 * fade).cgColor)
            cg.setLineWidth(max(1.0, 2.6 * fade))
            cg.strokeEllipse(in: CGRect(x: s.x - r, y: s.y - r * 0.38,
                                        width: 2 * r, height: r * 0.76))
            if s.t < 0.5 {                                   // 中心溅起的小水柱
                let h = 11 * s.size * (1 - s.t / 0.5)
                cg.setFillColor(NSColor(calibratedRed: 0.94, green: 0.97, blue: 1.00,
                                        alpha: 0.95 * fade).cgColor)
                cg.fillEllipse(in: CGRect(x: s.x - 1.5, y: s.y, width: 3.0, height: h))
            }
            cg.restoreGState()
        }
    }
}

// MARK: - 屏幕演员 (序列帧精灵: 马跑过画面)
struct SpriteSheet {
    let frames: [NSImage]
    let fps: Double
}

enum ActorAssets {
    private static var cache: [String: SpriteSheet] = [:]
    private static var misses: Set<String> = []

    /// 扫描 Resources/actors/<name>/ 下的 run_NN.png 序列帧, 按文件名排序 (帧序由文件名保证)。
    /// 找不到就返回 nil, 由调用方退回到程序化绘制的剪影。
    static func load(_ name: String) -> SpriteSheet? {
        if let hit = cache[name] { return hit }
        if misses.contains(name) { return nil }
        var seen: [String: NSImage] = [:]
        let dirs: [String?] = ["actors/\(name)", "actors", nil]
        for sub in dirs {
            guard let urls = Bundle.main.urls(forResourcesWithExtension: "png", subdirectory: sub) else { continue }
            for u in urls {
                let base = u.deletingPathExtension().lastPathComponent
                guard base.hasPrefix("run_") else { continue }
                if let img = NSImage(contentsOf: u), img.size.width > 4 { seen[base] = img }
            }
            if !seen.isEmpty { break }
        }
        guard !seen.isEmpty else { misses.insert(name); return nil }
        let sheet = SpriteSheet(frames: seen.keys.sorted().compactMap { seen[$0] }, fps: 16)
        cache[name] = sheet
        return sheet
    }
}

/// 程序化奔马剪影 —— 没有提供序列帧素材时的退路, 保证「马跑过」现在就能看。
/// 设计坐标系: 高 100, 蹄底 y=0, 马头朝 +x。
enum HorseArt {
    static func draw(_ cg: CGContext, phase: CGFloat, h: CGFloat, color: NSColor) {
        let u = h / 100
        cg.saveGState()
        cg.setStrokeColor(color.cgColor)
        cg.setFillColor(color.cgColor)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)

        // 四条腿: hip → knee → hoof, 相位各差 1/4 周期
        struct Leg { let x: CGFloat; let ph: CGFloat; let w: CGFloat; let len: CGFloat }
        let legs = [Leg(x: -26, ph: 0.00, w: 7.5, len: 50),
                    Leg(x: -16, ph: 0.50, w: 7.0, len: 47),
                    Leg(x:  20, ph: 0.25, w: 8.0, len: 51),
                    Leg(x:  31, ph: 0.75, w: 7.5, len: 48)]
        for l in legs {
            let a = (phase + l.ph) * 2 * .pi
            let swing = sin(a)
            let lift = max(0, sin(a + 1.15)) * 15
            let hip = CGPoint(x: l.x, y: 52)
            let knee = CGPoint(x: l.x + swing * 15, y: 27)
            let hoof = CGPoint(x: l.x + swing * 25, y: lift)
            let p = CGMutablePath()
            p.move(to: CGPoint(x: hip.x * u, y: hip.y * u))
            p.addQuadCurve(to: CGPoint(x: hoof.x * u, y: hoof.y * u),
                           control: CGPoint(x: knee.x * u, y: knee.y * u))
            cg.addPath(p)
            cg.setLineWidth(l.w * u)
            cg.strokePath()
        }
        // 躯干
        let body = CGMutablePath()
        body.addEllipse(in: CGRect(x: -34 * u, y: 46 * u, width: 70 * u, height: 31 * u))
        cg.addPath(body); cg.fillPath()
        // 脖颈 (从躯干前上方捅出去)
        let neck = CGMutablePath()
        neck.move(to: CGPoint(x: 24 * u, y: 58 * u))
        neck.addQuadCurve(to: CGPoint(x: 50 * u, y: 92 * u),
                          control: CGPoint(x: 44 * u, y: 66 * u))
        neck.addQuadCurve(to: CGPoint(x: 32 * u, y: 74 * u),
                          control: CGPoint(x: 36 * u, y: 74 * u))
        neck.closeSubpath()
        cg.addPath(neck); cg.fillPath()
        // 头: 圆润的脸颊 + 斜向下的口鼻 (方块头会显得像机械马)
        let head = CGMutablePath()
        head.move(to: CGPoint(x: 43 * u, y: 96 * u))
        head.addCurve(to: CGPoint(x: 69 * u, y: 81 * u),
                      control1: CGPoint(x: 57 * u, y: 98 * u),
                      control2: CGPoint(x: 68 * u, y: 90 * u))
        head.addCurve(to: CGPoint(x: 59 * u, y: 71 * u),
                      control1: CGPoint(x: 71 * u, y: 76 * u),
                      control2: CGPoint(x: 66 * u, y: 71 * u))
        head.addCurve(to: CGPoint(x: 42 * u, y: 80 * u),
                      control1: CGPoint(x: 50 * u, y: 71 * u),
                      control2: CGPoint(x: 45 * u, y: 74 * u))
        head.closeSubpath()
        cg.addPath(head); cg.fillPath()
        // 耳朵
        let ear = CGMutablePath()
        ear.move(to: CGPoint(x: 45 * u, y: 95 * u))
        ear.addLine(to: CGPoint(x: 42 * u, y: 105 * u))
        ear.addLine(to: CGPoint(x: 52 * u, y: 96 * u))
        ear.closeSubpath()
        cg.addPath(ear); cg.fillPath()
        // 鬃毛: 沿颈背的锯齿带, 随奔跑相位摆动
        let mane = CGMutablePath()
        mane.move(to: CGPoint(x: 26 * u, y: 66 * u))
        for i in 0...6 {
            let k = CGFloat(i) / 6
            let wob = sin((phase + k * 0.8) * 2 * .pi) * 3.8
            mane.addLine(to: CGPoint(x: (29 + 24 * k) * u, y: (72 + 24 * k) * u + (wob + 5) * u))
            mane.addLine(to: CGPoint(x: (24 + 24 * k) * u, y: (68 + 24 * k) * u + wob * u))
        }
        mane.closeSubpath()
        cg.addPath(mane); cg.fillPath()
        // 尾巴: 随奔跑甩动
        let tw = sin(phase * 2 * .pi) * 5
        let tail = CGMutablePath()
        tail.move(to: CGPoint(x: -33 * u, y: 73 * u))
        tail.addCurve(to: CGPoint(x: -63 * u, y: (42 + tw) * u),
                      control1: CGPoint(x: -57 * u, y: 79 * u),
                      control2: CGPoint(x: -68 * u, y: (58 + tw) * u))
        tail.addCurve(to: CGPoint(x: -33 * u, y: 63 * u),
                      control1: CGPoint(x: -52 * u, y: (48 + tw) * u),
                      control2: CGPoint(x: -42 * u, y: 56 * u))
        tail.closeSubpath()
        cg.addPath(tail); cg.fillPath()
        cg.restoreGState()
    }
}

struct Actor {
    let born: Double
    let dur: Double
    let dir: CGFloat             // +1 从左跑到右, -1 反向
    let baseY: CGFloat           // 屏幕归一化 y (0=底 1=顶), 蹄底所在高度
    let heightRatio: CGFloat     // 马高 = 视图高度 × 该系数
    let sheet: SpriteSheet?
    let name: String
}

// MARK: - 模拟模式 (沙盘推演) 数据结构
struct SimMove {
    let before: [Int]
    let after: [Int]
    let move: [String: Any]
    let from: Int
    let to: Int
    let mover: String
    let piece: Int
    let capture: Bool
    let notation: String
}

// MARK: - 模拟模式控制台 (浮在变暗画面之上的深色卡片)
final class SimPanel: NSView {
    var onPrev: (() -> Void)?
    var onNext: (() -> Void)?
    var onExit: (() -> Void)?
    private let statusLabel = NSTextField(labelWithString: "")
    private let movesLabel = NSTextField(labelWithString: "（暂无推演）")
    private var prevBtn: NSButton!
    private var nextBtn: NSButton!

    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }

    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 4, dy: 4)
        let path = NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14)
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow()
        sh.shadowBlurRadius = 14
        sh.shadowOffset = NSSize(width: 0, height: -4)
        sh.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.55)
        sh.set()
        NSColor(calibratedWhite: 0.09, alpha: 0.96).setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor(calibratedWhite: 1, alpha: 0.22).setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private func setup() {
        let title = NSTextField(labelWithString: "模拟模式")
        title.font = NSFont.boldSystemFont(ofSize: 15); title.textColor = .white
        let sub = NSTextField(labelWithString: "沙盘推演 · 不影响实战")
        sub.font = NSFont.systemFont(ofSize: 11)
        sub.textColor = NSColor(calibratedWhite: 0.62, alpha: 1)

        statusLabel.font = NSFont.boldSystemFont(ofSize: 12.5)
        statusLabel.textColor = NSColor(calibratedRed: 1, green: 0.82, blue: 0.36, alpha: 1)
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.preferredMaxLayoutWidth = 220

        let tip = NSTextField(labelWithString: "点击任意一方的棋子即可走子\n← / → 键 = 上一步 / 下一步，Esc 退出")
        tip.font = NSFont.systemFont(ofSize: 11)
        tip.textColor = NSColor(calibratedWhite: 0.66, alpha: 1)
        tip.maximumNumberOfLines = 3
        tip.lineBreakMode = .byWordWrapping
        tip.preferredMaxLayoutWidth = 220

        let lineTitle = NSTextField(labelWithString: "推演着法")
        lineTitle.font = NSFont.boldSystemFont(ofSize: 11)
        lineTitle.textColor = NSColor(calibratedWhite: 0.72, alpha: 1)
        movesLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        movesLabel.textColor = NSColor(calibratedWhite: 0.88, alpha: 1)
        movesLabel.maximumNumberOfLines = 10
        movesLabel.lineBreakMode = .byWordWrapping
        movesLabel.preferredMaxLayoutWidth = 220
        movesLabel.isSelectable = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 15),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -15),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 15),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -15),
        ])
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(sub)
        stack.setCustomSpacing(12, after: sub)
        stack.addArrangedSubview(statusLabel)
        stack.setCustomSpacing(12, after: statusLabel)
        prevBtn = mkButton("上一步", #selector(doPrev))
        nextBtn = mkButton("下一步", #selector(doNext))
        let exitBtn = mkButton("退出模拟", #selector(doExit))
        for b in [prevBtn!, nextBtn!, exitBtn] { stack.addArrangedSubview(b) }
        stack.setCustomSpacing(14, after: exitBtn)
        stack.addArrangedSubview(tip)
        stack.setCustomSpacing(14, after: tip)
        stack.addArrangedSubview(lineTitle)
        stack.addArrangedSubview(movesLabel)
    }
    private func mkButton(_ title: String, _ sel: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: sel)
        b.bezelStyle = .rounded
        b.font = NSFont.systemFont(ofSize: 13)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 220).isActive = true
        b.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return b
    }
    @objc private func doPrev() { onPrev?() }
    @objc private func doNext() { onNext?() }
    @objc private func doExit() { onExit?() }
    func update(status: String, line: String, canPrev: Bool, canNext: Bool) {
        statusLabel.stringValue = status
        movesLabel.stringValue = line
        prevBtn.isEnabled = canPrev
        nextBtn.isEnabled = canNext
    }
}

// MARK: - 模拟模式遮罩 (整幅画面变暗; 只有控制台接收点击, 其余区域穿透到棋盘)
final class SimOverlayView: NSView {
    let panel = SimPanel()
    override init(frame: NSRect) { super.init(frame: frame); setup() }
    required init?(coder: NSCoder) { super.init(coder: coder); setup() }
    private func setup() {
        wantsLayer = true
        panel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(panel)
        NSLayoutConstraint.activate([
            panel.widthAnchor.constraint(equalToConstant: 250),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            panel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.02, alpha: 0.46).setFill()
        NSBezierPath.fill(bounds)
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, to: panel)
        if panel.bounds.contains(p) { return super.hitTest(point) }
        return nil   // 穿透: 让棋盘继续接收点击
    }
}

// MARK: - 应用代理 (同时承担对局逻辑)
final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate {
    var window: NSWindow!
    var boardView: BoardView!
    var coach: CoachPanel!
    var bridge: EngineBridge!
    var bg = BackgroundEngine()
    var pika: PikafishEngine?
    var currentSide = RED
    var currentDiff = "hard"
    var engineChoice = "auto"
    var soundMode = "all"   // all | sfx | voice | off

    // 特技设置 (菜单可调, 持久化到 UserDefaults)
    var fxShapeIdx = UserDefaults.standard.integer(forKey: "xq.fxShape")
    var fxEaseIdx = UserDefaults.standard.integer(forKey: "xq.fxEase")
    var fxWeatherIdx = UserDefaults.standard.integer(forKey: "xq.fxWeather")
    var fxCrack = (UserDefaults.standard.object(forKey: "xq.fxCrack") as? Bool) ?? true
    var fxMenus: [NSMenu] = []
    var crackMenuItem: NSMenuItem?

    // 对局状态
    var board: [Int] = []
    var turn = RED
    var humanColor = RED
    var over = false
    var aiThinking = false
    var difficulty = DIFFICULTIES[2]
    var teaching = true
    var ply = 0
    var selected: Int?
    var legalTargets: [Int] = []
    var history: [(before: [Int], after: [Int], from: Int, to: Int, mover: String, ply: Int, log: String)] = []
    var logText = ""
    var commentText = ""
    var threatText = "暂无威胁"
    var repCount: [String: Int] = [:]

    // 模拟模式 (沙盘推演) 状态
    var simOverlay: SimOverlayView!
    var simActive = false
    var simBaseBoard: [Int] = []        // 进入模拟时的实战局面 (退出时还原)
    var simBaseTurn = RED
    var simBaseLastMove: (Int, Int)? = nil
    var simBoard: [Int] = []            // 推演中的局面
    var simTurn = RED
    var simSel: Int? = nil
    var simBusy = false                  // 走子动画进行中, 锁定输入避免连走同一方
    var simMoves: [SimMove] = []
    var simRedo: [SimMove] = []

    // MARK: - 启动
    func applicationDidFinishLaunching(_ n: Notification) {
        guard let b = EngineBridge() else {
            let a = NSAlert(); a.messageText = "引擎加载失败"; a.informativeText = "engine/*.js 未找到"
            a.runModal(); NSApp.terminate(nil); return
        }
        bridge = b
        SoundEngine.shared.preload()   // 预载音效/语音, 避免首次走子卡顿
        applySoundMode()
        if let p = Bundle.main.url(forResource: "pikafish", withExtension: nil)?.path
            ?? ProcessInfo.processInfo.environment["ENGINE_PATH"] {
            pika = PikafishEngine(path: p)
        }

        boardView = BoardView(); boardView.wantsLayer = true
        boardView.onSquareClick = { [weak self] sq in self?.click(sq: sq) }
        coach = CoachPanel(); coach.wantsLayer = true

        // 棋盘/侧栏 用一个容器包住, 便于把模拟模式遮罩盖在最上层
        let container = NSView()
        let split = NSSplitView(); split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addSubview(boardView); split.addSubview(coach)
        coach.widthAnchor.constraint(equalToConstant: 270).isActive = true
        container.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            split.topAnchor.constraint(equalTo: container.topAnchor),
            split.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        simOverlay = SimOverlayView()
        simOverlay.translatesAutoresizingMaskIntoConstraints = false
        simOverlay.isHidden = true
        container.addSubview(simOverlay, positioned: .above, relativeTo: split)
        NSLayoutConstraint.activate([
            simOverlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            simOverlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            simOverlay.topAnchor.constraint(equalTo: container.topAnchor),
            simOverlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        simOverlay.panel.onPrev = { [weak self] in self?.simUndo() }
        simOverlay.panel.onNext = { [weak self] in self?.simRedoStep() }
        simOverlay.panel.onExit = { [weak self] in self?.exitSimulation() }

        let rect = NSRect(x: 0, y: 0, width: 1000, height: 720)
        window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "人机中国象棋 · 教学版 (原生)"
        window.center(); window.contentView = container; window.isReleasedWhenClosed = false
        setupToolbar(); window.makeKeyAndOrderFront(nil)

        // 模拟模式快捷键: ← 上一步 / → 下一步 / Esc 退出
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self, self.simActive else { return e }
            switch e.keyCode {
            case 53: self.exitSimulation(); return nil
            case 123: self.simUndo(); return nil
            case 124: self.simRedoStep(); return nil
            default: return e
            }
        }

        applyFX()   // 恢复上次的轨迹/天气/裂痕设置
        newGame(side: currentSide, diff: currentDiff)

        // 调试: XQ_FX=crack,rain,horse,paths 预置特效场景, 配合 XQ_SNAPSHOT 离屏出图验证
        if let fxSpec = ProcessInfo.processInfo.environment["XQ_FX"] {
            if fxSpec.contains("crack") {
                // crack_mid: 让裂痕在快照前 ~0.15s 才出生, 用来看"生长中"的中间态
                let born = fxSpec.contains("crack_mid")
                    ? CACurrentMediaTime() + 1.05
                    : CACurrentMediaTime() - 1.0
                let picks: [(Int, CGFloat)] = [(40, 1.00), (58, 0.92), (30, 0.80), (49, 0.72), (67, 0.85)]
                for (sq, pw) in picks { boardView.debugAddCrack(sq: sq, born: born, power: pw) }
            }
            if fxSpec.contains("storm")        { boardView.weather.setKind(.storm) }
            else if fxSpec.contains("rain")    { boardView.weather.setKind(.rain) }
            else if fxSpec.contains("drizzle") { boardView.weather.setKind(.drizzle) }
            if fxSpec.contains("horse") { boardView.runHorse() }
            if fxSpec.contains("paths") { boardView.debugShowPaths = true }
            boardView.kick()
        }

        // 调试: 设定 XQ_SNAPSHOT=/path.png 时把当前棋盘离屏渲染成图片 (便于验证贴图对齐)
        if let sp = ProcessInfo.processInfo.environment["XQ_SNAPSHOT"] {
            let delay = Double(ProcessInfo.processInfo.environment["XQ_SNAP_DELAY"] ?? "") ?? 1.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let v = self.boardView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                if let d = rep.representation(using: .png, properties: [:]) {
                    try? d.write(to: URL(fileURLWithPath: sp))
                    print("snapshot ->", sp)
                }
            }
        }
    }

    /// 在访达/Dock 里再次点击 App 时(或窗口被关掉后再点), 把主窗口找回来。
    /// 否则会出现"点了没反应"的假象 —— 进程还在, 只是没有可见窗口。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 把主窗口重新显示并置于最前(最小化的话先还原)
    @objc func showMainWindow() {
        guard let w = window else { return }
        if w.isMiniaturized { w.deminiaturize(nil) }
        if !w.isVisible { w.makeKeyAndOrderFront(nil) }
        w.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - 工具栏
    func setupToolbar() {
        let tb = NSToolbar(identifier: "xq"); tb.delegate = self
        tb.displayMode = .iconAndLabel; tb.allowsUserCustomization = false
        window.toolbar = tb
    }
    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.newGame, .undo, .resign, .hint, .simulate, .sound, .flex, .side, .difficulty, .engine]
    }
    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(t)
    }
    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .newGame: return btnItem(id, "新对局", #selector(doNewGame))
        case .undo:    return btnItem(id, "悔棋", #selector(doUndo))
        case .resign:  return btnItem(id, "认输", #selector(doResign))
        case .hint:    return btnItem(id, "提示", #selector(doHint))
        case .simulate: return btnItem(id, "模拟", #selector(doSimulate))
        case .sound: return popupItem(id, "声音",
                                      [("全部开", "all"), ("仅音效", "sfx"), ("仅语音", "voice"), ("全部关", "off")],
                                      selected: soundMode) { [weak self] v in
            guard let self = self else { return }
            self.soundMode = v
            self.applySoundMode()
        }
        case .side: return popupItem(id, "执子", [("我执红", RED), ("我执黑", BLACK)], selected: currentSide) {
            [weak self] v in guard let s = self else { return }
            s.currentSide = v; s.newGame(side: v, diff: s.currentDiff)
        }
        case .difficulty: return popupItem(id, "难度", [("入门", "easy"), ("进阶", "medium"), ("高手", "hard")],
                                           selected: currentDiff) { [weak self] v in
            guard let s = self else { return }
            s.currentDiff = v; s.difficulty = DIFFICULTIES.first { $0.id == v } ?? DIFFICULTIES[2]
            s.newGame(side: s.currentSide, diff: v)
        }
        case .engine: return popupItem(id, "引擎", [("自动", "auto"), ("内置引擎", "embedded"), ("皮卡鱼", "pikafish")],
                                       selected: engineChoice) { [weak self] v in
            self?.engineChoice = v
            let which = (v == "pikafish" && self?.pika?.available == true) ? "皮卡鱼" :
                (v == "embedded" ? "内置引擎" : "自动(优先皮卡鱼)")
            self?.coachSay("引擎已切换为：\(which)")
        }
        default: return nil
        }
    }
    private func btnItem(_ id: NSToolbarItem.Identifier, _ title: String, _ action: Selector) -> NSToolbarItem {
        let it = NSToolbarItem(itemIdentifier: id); it.label = title; it.paletteLabel = title
        it.view = NSButton(title: title, target: self, action: action); return it
    }
    private func popupItem(_ id: NSToolbarItem.Identifier, _ title: String,
                           _ opts: [(String, String)], selected: String,
                           _ onChange: @escaping (String) -> Void) -> NSToolbarItem {
        let it = NSToolbarItem(itemIdentifier: id); it.label = title; it.paletteLabel = title
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItem(withTitle: title + ":")
        for (label, val) in opts {
            let mi = NSMenuItem(title: label, action: nil, keyEquivalent: "")
            mi.representedObject = val; popup.menu?.addItem(mi)
        }
        if let i = opts.firstIndex(where: { $0.1 == selected }) { popup.selectItem(at: i + 1) }
        popup.action = #selector(popupChanged(_:)); popup.target = self
        objc_setAssociatedObject(popup, &PopupKey.key, PopupClosureWrapper(onChange), .OBJC_ASSOCIATION_RETAIN)
        it.view = popup; return it
    }
    struct PopupKey { static var key: Int = 0 }
    final class PopupClosureWrapper: NSObject { let f: (String) -> Void; init(_ f: @escaping (String) -> Void) { self.f = f } }
    @objc func popupChanged(_ s: NSPopUpButton) {
        guard let mi = s.selectedItem, let v = mi.representedObject as? String else { return }
        if let w = objc_getAssociatedObject(s, &PopupKey.key) as? PopupClosureWrapper { w.f(v) }
    }
    @objc func doNewGame() { newGame(side: currentSide, diff: currentDiff) }
    @objc func doUndo() { guard !simActive else { return }; undo() }
    @objc func doResign() { guard !simActive else { return }; resign() }
    @objc func doHint() { guard !simActive else { return }; hint() }
    @objc func doSimulate() { simActive ? exitSimulation() : enterSimulation() }

    // MARK: - 特技 (轨迹 / 缓动 / 天气 / 裂痕 / 演员)
    /// 把菜单里的选择推给棋盘视图。轨迹与天气都是"随时切换立即生效"的运行期参数。
    func applyFX() {
        guard let v = boardView else { return }
        let shapes = Trajectory.Shape.allCases
        var t = Trajectory.of(shapes[max(0, min(shapes.count - 1, fxShapeIdx))])
        let eases = Ease.allCases
        t.ease = eases[max(0, min(eases.count - 1, fxEaseIdx))]
        v.traj = t
        v.crackEnabled = fxCrack
        let kinds = Weather.Kind.allCases
        v.weather.setKind(kinds[max(0, min(kinds.count - 1, fxWeatherIdx))])
        v.kick()
    }
    func refreshFXMenu() {
        if fxMenus.count >= 3 {
            for it in fxMenus[0].items { it.state = it.tag == fxShapeIdx ? .on : .off }
            for it in fxMenus[1].items { it.state = it.tag == fxEaseIdx ? .on : .off }
            for it in fxMenus[2].items { it.state = it.tag == fxWeatherIdx ? .on : .off }
        }
        crackMenuItem?.state = fxCrack ? .on : .off
    }
    @objc func pickTrajectory(_ s: NSMenuItem) {
        fxShapeIdx = s.tag; UserDefaults.standard.set(fxShapeIdx, forKey: "xq.fxShape")
        applyFX(); refreshFXMenu()
    }
    @objc func pickEase(_ s: NSMenuItem) {
        fxEaseIdx = s.tag; UserDefaults.standard.set(fxEaseIdx, forKey: "xq.fxEase")
        applyFX(); refreshFXMenu()
    }
    @objc func pickWeather(_ s: NSMenuItem) {
        fxWeatherIdx = s.tag; UserDefaults.standard.set(fxWeatherIdx, forKey: "xq.fxWeather")
        applyFX(); refreshFXMenu()
    }
    @objc func toggleCrack() {
        fxCrack.toggle(); UserDefaults.standard.set(fxCrack, forKey: "xq.fxCrack")
        applyFX(); refreshFXMenu()
    }
    @objc func doClearDecals() { boardView?.clearDecals() }
    @objc func doRunHorse() { boardView?.runHorse() }

    /// 声音模式: all=音效+语音, sfx=仅音效, voice=仅语音, off=静音
    func applySoundMode() {
        let e = SoundEngine.shared
        e.sfxOn = (soundMode == "all" || soundMode == "sfx")
        e.voiceOn = (soundMode == "all" || soundMode == "voice")
        if !e.voiceOn { e.stopVoice() }
    }

    /// 模拟模式期间: 置灰其他对局操作, 并把「模拟」按钮变为「退出模拟」
    func setToolbarSimState(_ on: Bool) {
        guard let items = window.toolbar?.items else { return }
        for it in items {
            switch it.itemIdentifier {
            case .undo, .resign, .hint, .side, .difficulty, .engine:
                it.isEnabled = !on
                (it.view as? NSControl)?.isEnabled = !on
            case .simulate:
                let t = on ? "退出模拟" : "模拟"
                it.label = t; it.paletteLabel = t
                if let b = it.view as? NSButton { b.title = t }
            default: break
            }
        }
    }

    // MARK: - 模拟模式 (沙盘推演)
    func enterSimulation() {
        guard !simActive else { return }
        simActive = true
        aiThinking = false
        simBaseBoard = board
        simBaseTurn = turn
        simBaseLastMove = boardView.lastMove
        simBoard = board
        simTurn = turn
        simSel = nil
        simBusy = false
        simMoves = []; simRedo = []
        boardView.simMode = true
        boardView.selected = nil; boardView.legalTargets = []
        boardView.hintSq = nil; boardView.setThreats([])
        boardView.board = simBoard
        boardView.setNeedsDisplay(boardView.bounds)
        simOverlay.isHidden = false
        setToolbarSimState(true)
        refreshSimPanel()
        coachSay("已进入模拟模式：可自由推演任意一方的走法。")
    }
    func exitSimulation() {
        guard simActive else { return }
        simActive = false
        simSel = nil
        simBusy = false
        simMoves = []; simRedo = []
        simOverlay.isHidden = true
        setToolbarSimState(false)
        // 还原实战局面 (推演只是沙盘, 不改变对局)
        board = simBaseBoard
        turn = simBaseTurn
        boardView.simMode = false
        boardView.board = board
        boardView.lastMove = simBaseLastMove
        boardView.selected = nil; boardView.legalTargets = []
        boardView.setNeedsDisplay(boardView.bounds)
        coachSay("已退出模拟模式，回到实战局面。")
        renderCoach()
        if !over, turn == opp(humanColor) { aiThinking = true; aiTurn() }
    }
    func simColorOf(_ sq: Int) -> String? {
        let p = simBoard[sq]; if p == 0 { return nil }; return p <= 7 ? RED : BLACK
    }
    func simClick(_ sq: Int) {
        guard !simBusy, !bridge.legalMoves(simBoard, simTurn).isEmpty else { return }
        if let sel = simSel {
            if boardView.legalTargets.contains(sq) { simPlay(from: sel, to: sq); return }
            if simBoard[sq] != 0, simColorOf(sq) == simTurn { simSelect(sq); return }
            simSel = nil; boardView.selected = nil; boardView.legalTargets = []
            boardView.setNeedsDisplay(boardView.bounds)
        } else if simBoard[sq] != 0, simColorOf(sq) == simTurn {
            simSelect(sq)
        }
    }
    func simSelect(_ sq: Int) {
        simSel = sq
        boardView.selected = sq
        boardView.legalTargets = bridge.legalMoves(simBoard, simTurn)
            .filter { ($0["from"] as? Int) == sq }.compactMap { $0["to"] as? Int }
        boardView.setNeedsDisplay(boardView.bounds)
    }
    func simPlay(from: Int, to: Int) {
        guard !simBusy, simBoard[from] != 0 else { return }
        // 自校验: 必须是当前行棋方的合法着法 (applyMove 本身不做校验)
        let legal = bridge.legalMoves(simBoard, simTurn).contains {
            ($0["from"] as? Int) == from && ($0["to"] as? Int) == to
        }
        guard legal else { return }
        simBusy = true
        let piece = simBoard[from]
        let capture = simBoard[to] != 0
        let captured = simBoard[to]
        let mover = simTurn
        let before = simBoard
        let mv: [String: Any] = ["from": from, "to": to, "piece": piece, "capture": capture]
        guard let nb = bridge.applyMove(simBoard, mv) else { return }
        let note = bridge.moveToNotation(simBoard, mv, mover)
        simSel = nil; boardView.selected = nil; boardView.legalTargets = []
        playSound("lift")
        boardView.animateMove(from: from, to: to, piece: piece, capture: capture, captured: captured,
                              scar: false) { [weak self] in
            guard let self = self else { return }
            self.simBusy = false
            guard self.simActive else { return }
            self.simBoard = nb
            self.simMoves.append(SimMove(before: before, after: nb, move: mv, from: from, to: to,
                                         mover: mover, piece: piece, capture: capture, notation: note))
            self.simRedo.removeAll()
            self.simTurn = opp(mover)
            self.boardView.board = nb
            self.boardView.lastMove = (from, to)
            self.boardView.setNeedsDisplay(self.boardView.bounds)
            self.playSound(capture ? "capture" : "move")
            self.refreshSimPanel()
        }
    }
    func simUndo() {
        guard simActive, !simBusy, let last = simMoves.popLast() else { return }
        simRedo.append(last)
        simBoard = last.before
        simTurn = last.mover
        simSel = nil
        boardView.selected = nil; boardView.legalTargets = []
        boardView.board = simBoard
        boardView.lastMove = simMoves.last.map { ($0.from, $0.to) } ?? simBaseLastMove
        boardView.setNeedsDisplay(boardView.bounds)
        playSound("move")
        refreshSimPanel()
    }
    func simRedoStep() {
        guard simActive, !simBusy, let m = simRedo.popLast() else { return }
        simMoves.append(m)
        simBoard = m.after
        simTurn = opp(m.mover)
        simSel = nil
        boardView.selected = nil; boardView.legalTargets = []
        boardView.board = simBoard
        boardView.lastMove = (m.from, m.to)
        boardView.setNeedsDisplay(boardView.bounds)
        playSound(m.capture ? "capture" : "move")
        refreshSimPanel()
    }
    func refreshSimPanel() {
        let colName = simTurn == RED ? "红方" : "黑方"
        let status: String
        if bridge.legalMoves(simBoard, simTurn).isEmpty {
            status = "\(colName)被将死 / 困毙 · 推演结束"
        } else if bridge.isInCheck(simBoard, simTurn) {
            status = "轮到\(colName)走子（被将军）\n已推演 \(simMoves.count) 步"
        } else {
            status = "轮到\(colName)走子 · 已推演 \(simMoves.count) 步"
        }
        let recent = simMoves.suffix(10).map { "\($0.mover == RED ? "红" : "黑") \($0.notation)" }
        let line = recent.isEmpty ? "（暂无推演）" : recent.joined(separator: "\n")
        simOverlay.panel.update(status: status, line: line,
                                canPrev: !simMoves.isEmpty, canNext: !simRedo.isEmpty)
    }

    // MARK: - 声音
    func playSound(_ name: String) { SoundEngine.shared.play(name) }
    func speak(_ key: String, delay: Double = 0.0) { SoundEngine.shared.speak(key, delay: delay) }

    // MARK: - 对局逻辑
    func newGame(side: String, diff: String) {
        // 新开一局时强制结束模拟模式
        if simActive {
            simActive = false
            simMoves = []; simRedo = []; simSel = nil; simBusy = false
            boardView.simMode = false
            simOverlay.isHidden = true
            setToolbarSimState(false)
        }
        humanColor = side
        difficulty = DIFFICULTIES.first { $0.id == diff } ?? DIFFICULTIES[2]
        board = bridge.initialBoard(); turn = RED; over = false; aiThinking = false
        history = []; ply = 0; selected = nil; legalTargets = []; repCount = [:]
        logText = ""; commentText = ""; threatText = "暂无威胁"
        boardView.board = board; boardView.lastMove = nil; boardView.selected = nil
        boardView.legalTargets = []; boardView.hintSq = nil; boardView.setThreats([])
        boardView.flipBoard = (humanColor == RED)   // 我执红→红方在下方; 我执黑→黑方在下方
        boardView.bigText = nil
        boardView.clearDecals()          // 新对局: 棋盘上的旧裂痕一并清掉
        boardView.setNeedsDisplay(boardView.bounds)
        coachSay("新对局开始，你执\(humanColor == RED ? "红" : "黑")方。")
        renderCoach()
        if humanColor == BLACK { aiThinking = true; aiTurn() }
    }
    func click(sq: Int) {
        if simActive { simClick(sq); return }   // 模拟模式: 双方棋子都可自由推演
        guard !over, !aiThinking, turn == humanColor else { return }
        if let sel = selected {
            if legalTargets.contains(sq) { performMove(from: sel, to: sq, mover: humanColor, byHuman: true); return }
            if board[sq] != 0, colorOf(sq) == humanColor { select(sq); return }
            selected = nil; legalTargets = []; boardView.selected = nil; boardView.legalTargets = []
            boardView.setNeedsDisplay(boardView.bounds)
        } else if board[sq] != 0, colorOf(sq) == humanColor {
            select(sq)
        }
    }
    func select(_ sq: Int) {
        selected = sq
        legalTargets = bridge.legalMoves(board, humanColor)
            .filter { ($0["from"] as? Int) == sq }.compactMap { $0["to"] as? Int }
        boardView.selected = sq; boardView.legalTargets = legalTargets
        boardView.setNeedsDisplay(boardView.bounds)
        playSound("click")   // 手指触到棋子的轻响
    }
    func colorOf(_ sq: Int) -> String? {
        let p = board[sq]; if p == 0 { return nil }; return p <= 7 ? RED : BLACK
    }
    func performMove(from: Int, to: Int, mover: String, byHuman: Bool, completion: (() -> Void)? = nil) {
        guard !simActive else { completion?(); return }   // 模拟期间冻结实战走子
        aiThinking = false
        guard board[from] != 0 else { completion?(); return }
        let piece = board[from]
        let capture = board[to] != 0
        let move: [String: Any] = ["from": from, "to": to, "piece": piece, "capture": capture]
        guard let newBoard = bridge.applyMove(board, move) else { completion?(); return }
        let before = board
        let captured = board[to]
        playSound("lift")   // 提子离板的轻微摩擦
        boardView.animateMove(from: from, to: to, piece: piece, capture: capture, captured: captured) { [weak self] in
            guard let self = self else { return }
            self.board = newBoard; self.boardView.lastMove = (from, to); self.ply += 1
            let oppColor = opp(mover)
            let inCheck = self.bridge.isInCheck(newBoard, oppColor)
            let c = self.bridge.coachCommentary(before: before, move: move, after: newBoard, mover: mover, ply: self.ply)
            var line = ""
            if let c = c {
                let note = c["notation"] as? String ?? ""
                let open = c["opening"] as? String
                let tx = (c["tactics"] as? [String]) ?? []
                let txt = c["text"] as? String ?? ""
                line = note
                if let o = open { line += "（\(o)）" }
                if !tx.isEmpty { line += " " + tx.joined(separator: "·") }
                if !txt.isEmpty { line += " — " + txt }
            }
            self.history.append((before, newBoard, from, to, mover, self.ply, line))
            self.logText = self.history.map { $0.log }.joined(separator: "\n")
            self.commentText = line
            self.selected = nil; self.legalTargets = []
            self.boardView.selected = nil; self.boardView.legalTargets = []; self.boardView.hintSq = nil
            self.boardView.board = newBoard; self.boardView.lastMove = (from, to)
            self.boardView.setNeedsDisplay(self.boardView.bounds)

            // ── 音效层: 棋子落板 → 将军/吃子提示 → 人声播报 ──
            let end = self.detectEnd(mover: mover, board: newBoard)
            let mate = (end?.reason == "将死")
            self.playSound(capture ? "capture" : "move")
            if inCheck {
                self.boardView.flashCheck()
                if !mate { self.playSound("check") }
                self.speak(mate ? "juesha" : "jiangjun", delay: mate ? 0.5 : 0.34)
            } else if capture {
                self.speak("chi", delay: 0.15)   // 「吃」
            }

            if let end = end {
                self.endGame(end); completion?(); return
            }
            self.turn = oppColor
            if !self.over, self.turn == opp(self.humanColor) { self.aiThinking = true; self.aiTurn() }
            self.renderCoach()
            completion?()
        }
    }
    func aiTurn() {
        guard !over, !simActive else { return }
        let aiColor = opp(humanColor)
        guard turn == aiColor else { aiThinking = false; return }
        if (engineChoice == "auto" || engineChoice == "pikafish"), let p = pika, p.available {
            p.setStrength(elo: difficulty.pikaElo, movetime: difficulty.pikaMovetime)
            let fen = bridge.boardToFen(board, turn)
            p.bestMove(fen: fen) { [weak self] str in
                guard let self = self, !self.simActive else { return }
                if let s = str, let (f, t) = self.mapPika(s) {
                    self.performMove(from: f, to: t, mover: aiColor, byHuman: false)
                } else {
                    self.coachSay("皮卡鱼未返回有效着法，改用内置引擎。"); self.embeddedMove(mover: aiColor)
                }
            }
        } else {
            embeddedMove(mover: aiColor)
        }
    }
    func embeddedMove(mover: String) {
        bg.search(board: board, turn: mover, budget: difficulty.embeddedBudget, depth: 8) { [weak self] res in
            guard let self = self, !self.simActive else { return }
            var mv = res
            if mv == nil, let first = self.bridge.legalMoves(self.board, mover).first {
                mv = ["from": first["from"] as? Int ?? 0, "to": first["to"] as? Int ?? 0]
            }
            guard let m = mv, let f = m["from"] as? Int, let t = m["to"] as? Int, f >= 0, t >= 0 else { return }
            self.performMove(from: f, to: t, mover: mover, byHuman: false)
        }
    }
    func mapPika(_ s: String) -> (Int, Int)? {
        guard s.count == 4 else { return nil }
        let ch = Array(s)
        guard let f0 = ch[0].asciiValue, let r0 = ch[1].asciiValue,
              let f1 = ch[2].asciiValue, let r1 = ch[3].asciiValue else { return nil }
        let cf0 = Int(f0) - 97, cr0 = Int(r0) - 48, cf1 = Int(f1) - 97, cr1 = Int(r1) - 48
        guard (0...8).contains(cf0), (0...9).contains(cr0), (0...8).contains(cf1), (0...9).contains(cr1) else { return nil }
        let from = cr0 * 9 + cf0, to = cr1 * 9 + cf1
        let legal = bridge.legalMoves(board, turn).contains { ($0["from"] as? Int) == from && ($0["to"] as? Int) == to }
        if legal { return (from, to) }
        let from2 = cr0 * 9 + (8 - cf0), to2 = cr1 * 9 + (8 - cf1)
        let legal2 = bridge.legalMoves(board, turn).contains { ($0["from"] as? Int) == from2 && ($0["to"] as? Int) == to2 }
        return legal2 ? (from2, to2) : nil
    }
    func detectEnd(mover: String, board: [Int]) -> (winner: String, reason: String)? {
        let oppc = opp(mover)
        if bridge.legalMoves(board, oppc).isEmpty {
            return (mover, bridge.isInCheck(board, oppc) ? "将死" : "困毙")
        }
        let key = bridge.boardToFen(board, oppc)
        repCount[key, default: 0] += 1
        if repCount[key] ?? 0 >= 3 { return ("", "三次重复判和") }
        return nil
    }
    func endGame(_ r: (winner: String, reason: String)) {
        over = true; aiThinking = false
        let won = r.winner == humanColor
        let text: String
        if r.winner == "" { text = "和棋（\(r.reason)）" }
        else if won { text = "🎉 你赢了！（\(r.reason)）" }
        else { text = "电脑胜（\(r.reason)）" }
        coachSay(text)
        if r.reason == "将死" { boardView.showBigText("绝　杀") }   // 绝杀全屏大字
        if r.winner != "" { playSound(won ? "win" : "lose") }
        else { speak("heqi", delay: 0.25) }                        // 「和棋」
        renderCoach()
    }
    func undo() {
        guard !simActive, !history.isEmpty else { return }
        while !history.isEmpty {
            let last = history.removeLast()
            board = last.before; ply = last.ply - 1
            if last.mover == humanColor { break }
        }
        over = false; aiThinking = false; turn = humanColor
        logText = history.map { $0.log }.joined(separator: "\n")
        commentText = history.last?.log ?? ""
        let lastMove = history.last.map { ($0.from, $0.to) }
        selected = nil; legalTargets = []
        boardView.board = board; boardView.lastMove = lastMove; boardView.selected = nil; boardView.legalTargets = []
        boardView.hintSq = nil; boardView.setNeedsDisplay(boardView.bounds)
        coachSay("已悔棋，轮到你走。")
        renderCoach()
    }
    func resign() {
        guard !over, !simActive else { return }
        endGame((winner: opp(humanColor), reason: "认输"))
    }
    func hint() {
        guard !over, !simActive, turn == humanColor, !aiThinking else { return }
        if let h = bridge.coachHint(board, humanColor, difficulty.embeddedBudget),
           let f = h["from"] as? Int, let t = h["to"] as? Int {
            boardView.hintSq = (f, t); boardView.kickHint()
            let note = bridge.moveToNotation(board,
                ["from": f, "to": t, "piece": board[f], "capture": board[t] != 0], humanColor)
            coachSay("提示：\(note)")
        }
    }
    // MARK: - 教学渲染
    func coachSay(_ s: String) { coachSay(text: s) }
    func coachSay(text: String) {
        commentText = text
        renderCoach()
    }
    func renderCoach() {
        let th = bridge.coachThreats(board, humanColor)
        var thTxt = ""
        if th.inCheck { thTxt += "⚠️ 你被将军！\n" }
        if !th.pieces.isEmpty {
            let names = th.pieces.map { $0["name"] as? String ?? "子" }.joined(separator: "、")
            thTxt += "你的 \(names) 正被攻击"
        }
        if thTxt.isEmpty { thTxt = "暂无威胁" }
        threatText = thTxt
        boardView.setThreats(th.pieces.compactMap { $0["sq"] as? Int })
        let eval = bridge.coachEvaluate(board)
        var s = ""
        if over {
            s += (commentText.isEmpty ? "对局结束" : commentText) + "\n"
        } else if aiThinking {
            s += "电脑思考中…\n"
        } else {
            s += "轮到你走棋（\(humanColor == RED ? "红方" : "黑方")）\n"
        }
        s += "───────\n"
        if !commentText.isEmpty { s += "【讲解】\(commentText)\n" }
        s += "【威胁】\(thTxt)\n"
        s += "───────\n【棋谱】\n" + (logText.isEmpty ? "（暂无）" : logText)
        coach.update(text: s, eval: eval, color: humanColor)
    }
}

// MARK: - 音效引擎 (真实感音效 + 中文人声播报)
// 落子/吃子等为物理建模合成的石板撞击声(每类多个变体), 播放时再加随机微调音高,
// 避免连续走子出现"机关枪"式的重复感; 语音播报走独立声道, 可与音效叠加。
final class SoundEngine {
    static let shared = SoundEngine()

    var sfxOn = true
    var voiceOn = true
    var sfxVolume: Float = 1.0

    /// 每类音效的变体文件 (随机取一个)
    private static let groups: [String: [String]] = [
        "move":    ["move_1", "move_2", "move_3", "move_4"],
        "lift":    ["lift_1", "lift_2"],
        "capture": ["capture_1", "capture_2", "capture_3"],
        "check":   ["check_1", "check_2", "check_3"],
        "click":   ["click"],
        "win":     ["win"],
        "lose":    ["lose"],
    ]
    private static let voiceFiles: [String: String] = [
        "chi": "voice_chi", "jiangjun": "voice_jiangjun",
        "juesha": "voice_juesha", "heqi": "voice_heqi",
    ]
    /// 每类的音量微调 (落子要清脆但不吵, 吃子强调, 将军厚重)
    private static let gains: [String: Float] = [
        "move": 0.85, "lift": 0.45, "capture": 1.0, "check": 0.95,
        "click": 0.5, "win": 0.85, "lose": 0.85,
    ]

    private var pools: [String: [AVAudioPlayer]] = [:]
    private var cursor: [String: Int] = [:]
    private var voicePlayer: AVAudioPlayer?
    private var lastVoiceTime: Double = 0

    /// 启动时预载, 避免第一次走子时卡顿
    func preload() {
        for (_, files) in SoundEngine.groups { for f in files { _ = players(f) } }
        for (_, f) in SoundEngine.voiceFiles { _ = voice(f) }
    }

    private func url(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "sounds")
    }

    /// 每个文件建 3 个播放器轮转, 保证快速连续触发时互不打断
    private func players(_ name: String) -> [AVAudioPlayer] {
        if let p = pools[name] { return p }
        guard let u = url(name) else { pools[name] = []; return [] }
        var list: [AVAudioPlayer] = []
        for _ in 0..<3 {
            if let p = try? AVAudioPlayer(contentsOf: u) {
                p.prepareToPlay(); p.enableRate = true; list.append(p)
            }
        }
        pools[name] = list
        return list
    }

    private func voice(_ name: String) -> AVAudioPlayer? {
        if let p = voicePlayer, p.url?.lastPathComponent == name + ".wav" { return p }
        guard let u = url(name), let p = try? AVAudioPlayer(contentsOf: u) else { return nil }
        p.prepareToPlay(); voicePlayer = p
        return p
    }

    /// 播放一类音效 (自动随机变体 + 音高微扰)
    func play(_ key: String, volume: Float = 1.0, jitter: Double = 0.05) {
        guard sfxOn, let files = SoundEngine.groups[key], let name = files.randomElement() else { return }
        let list = players(name)
        guard !list.isEmpty else { return }
        let i = (cursor[name] ?? 0) % list.count
        cursor[name] = i + 1
        let p = list[i]
        p.stop(); p.currentTime = 0
        p.rate = Float(1.0 + Double.random(in: -jitter...jitter))
        p.volume = min(1.0, volume * (SoundEngine.gains[key] ?? 1.0) * sfxVolume)
        p.play()
    }

    /// 人声播报。delay 用于让撞击声先落, 再出人声, 听感更自然。
    func speak(_ key: String, delay: Double = 0.0, volume: Float = 1.0) {
        guard voiceOn, let f = SoundEngine.voiceFiles[key] else { return }
        let fire = { [weak self] in
            guard let self = self, self.voiceOn, let p = self.voice(f) else { return }
            p.stop(); p.currentTime = 0; p.volume = min(1.0, volume); p.play()
            self.lastVoiceTime = CACurrentMediaTime()
        }
        if delay > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: fire) } else { fire() }
    }

    func stopVoice() { voicePlayer?.stop() }
}

// MARK: - 工具栏标识符
extension NSToolbarItem.Identifier {
    static let newGame = NSToolbarItem.Identifier("xq.newGame")
    static let undo = NSToolbarItem.Identifier("xq.undo")
    static let resign = NSToolbarItem.Identifier("xq.resign")
    static let hint = NSToolbarItem.Identifier("xq.hint")
    static let simulate = NSToolbarItem.Identifier("xq.simulate")
    static let sound = NSToolbarItem.Identifier("xq.sound")
    static let side = NSToolbarItem.Identifier("xq.side")
    static let difficulty = NSToolbarItem.Identifier("xq.difficulty")
    static let engine = NSToolbarItem.Identifier("xq.engine")
    static let flex = NSToolbarItem.Identifier("xq.flex")
}

// MARK: - 入口
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.mainMenu = buildMainMenu()
app.activate(ignoringOtherApps: true)
app.run()

func buildMainMenu() -> NSMenu {
    let main = NSMenu()
    let appItem = NSMenuItem(title: "象棋", action: nil, keyEquivalent: "")
    let appMenu = NSMenu()
    appMenu.addItem(NSMenuItem(title: "关于人机中国象棋",
        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
    appMenu.addItem(.separator())
    appMenu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    appItem.submenu = appMenu; main.addItem(appItem)

    // 「特技」菜单: 走子轨迹 / 缓动 / 天气 / 裂痕 / 演员。勾选项即时生效并被记到 UserDefaults。
    let fxItem = NSMenuItem(title: "特技", action: nil, keyEquivalent: "")
    let fxMenu = NSMenu()
    func submenu(_ title: String, _ sel: Selector, _ labels: [String]) -> NSMenu {
        let m = NSMenu()
        for (i, lb) in labels.enumerated() {
            let it = NSMenuItem(title: lb, action: sel, keyEquivalent: "")
            it.target = delegate; it.tag = i
            m.addItem(it)
        }
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = m
        fxMenu.addItem(holder)
        return m
    }
    let trajMenu = submenu("走子轨迹", #selector(AppDelegate.pickTrajectory(_:)),
                           Trajectory.Shape.allCases.map { $0.label })
    let easeMenu = submenu("缓动曲线", #selector(AppDelegate.pickEase(_:)),
                           Ease.allCases.map { $0.label })
    let weatherMenu = submenu("天气", #selector(AppDelegate.pickWeather(_:)),
                              Weather.Kind.allCases.map { $0.label })
    fxMenu.addItem(.separator())
    let crackIt = NSMenuItem(title: "吃子留裂痕", action: #selector(AppDelegate.toggleCrack), keyEquivalent: "")
    crackIt.target = delegate; fxMenu.addItem(crackIt)
    delegate.crackMenuItem = crackIt
    let clearIt = NSMenuItem(title: "清除棋盘裂痕", action: #selector(AppDelegate.doClearDecals), keyEquivalent: "")
    clearIt.target = delegate; fxMenu.addItem(clearIt)
    fxMenu.addItem(.separator())
    let horseIt = NSMenuItem(title: "马跑过画面", action: #selector(AppDelegate.doRunHorse), keyEquivalent: "")
    horseIt.target = delegate; fxMenu.addItem(horseIt)
    fxItem.submenu = fxMenu; main.addItem(fxItem)
    delegate.fxMenus = [trajMenu, easeMenu, weatherMenu]
    delegate.refreshFXMenu()

    let winItem = NSMenuItem(title: "窗口", action: nil, keyEquivalent: "")
    let winMenu = NSMenu()
    let show = NSMenuItem(title: "显示主窗口", action: #selector(AppDelegate.showMainWindow), keyEquivalent: "0")
    show.target = delegate
    winMenu.addItem(show)
    winMenu.addItem(.separator())
    winMenu.addItem(NSMenuItem(title: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
    winItem.submenu = winMenu; main.addItem(winItem)
    return main
}
