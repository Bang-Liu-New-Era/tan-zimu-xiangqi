//
//  AppDelegate.swift
//  人机中国象棋 · 应用委托 (待 P1b 再按职责细分)
//
//  本文件由 native/XiangqiApp.swift 拆分而来 (tools/split_xiangqi.py, P1 纯搬运)。
//  拆分过程只做位置搬迁, 未改动任何逻辑。
//
import AppKit
import AVFoundation
import JavaScriptCore
import CoreText

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
