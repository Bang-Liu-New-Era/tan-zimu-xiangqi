//
//  GameController.swift
//  人机中国象棋 · 对局控制器 (平台无关)
//
//  从 AppDelegate 拆出来的全部对局逻辑: 局面/走子/悔棋/AI 回合/模拟推演/教学渲染/音效。
//  平台差异(窗口/菜单/工具栏/遮罩)全部通过 GameUI 钩子上抛, 由各平台的壳实现:
//    macOS → App/AppDelegate.swift (NSWindow + NSToolbar + NSMenu)
//    iOS   → ios/GameViewController.swift (UIKit 工具栏)
//
import Foundation
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import AVFoundation
import JavaScriptCore

// MARK: - 平台 UI 钩子

/// 对局逻辑需要平台壳做的三件事。不直接持有任何视图类型。
protocol GameUI: AnyObject {
    /// 进入/退出模拟模式: 显示/隐藏遮罩、置灰对局控件、切换模拟按钮文案
    func setSimActive(_ on: Bool)
    /// 模拟面板内容刷新 (不支持模拟的平台给空实现即可)
    func simPanelUpdate(status: String, line: String, canPrev: Bool, canNext: Bool)
    /// 引擎加载失败 (致命)。macOS 弹窗后终止; iOS 弹窗后停在这。
    func showEngineError()
}
extension GameUI {
    func simPanelUpdate(status: String, line: String, canPrev: Bool, canNext: Bool) {}
}

// MARK: - 对局控制器

final class GameController: NSObject {
    var boardView: BoardView!
    var coach: CoachPanel!
    var bridge: EngineBridge!
    var bg = BackgroundEngine()
    #if os(macOS)
    var pika: PikafishEngine?      // 皮卡鱼是外部进程, iOS 上不存在 → 只用内置 JS 引擎
    #endif
    weak var ui: GameUI?

    var currentSide = RED
    var currentDiff = "hard"
    var engineChoice = "auto"
    var soundMode = "all"   // all | sfx | voice | off

    // 特技设置 (菜单可调, 持久化到 UserDefaults)
    var fxShapeIdx = UserDefaults.standard.integer(forKey: "xq.fxShape")
    var fxEaseIdx = UserDefaults.standard.integer(forKey: "xq.fxEase")
    var fxCrack = (UserDefaults.standard.object(forKey: "xq.fxCrack") as? Bool) ?? true

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

    // MARK: - 启动 (各平台壳在创建完自己的窗口结构后调用)

    /// 引擎就绪返回 true。失败时已通过 ui.showEngineError() 上报, 调用方应停止装配 UI。
    @discardableResult
    func start(ui: GameUI) -> Bool {
        self.ui = ui
        guard let b = EngineBridge() else { ui.showEngineError(); return false }
        bridge = b
        SoundEngine.shared.preload()   // 预载音效/语音, 避免首次走子卡顿
        applySoundMode()
        #if os(macOS)
        if let p = Bundle.main.url(forResource: "pikafish", withExtension: nil)?.path
            ?? ProcessInfo.processInfo.environment["ENGINE_PATH"] {
            pika = PikafishEngine(path: p)
        }
        #endif

        boardView = BoardView()
        boardView.onSquareClick = { [weak self] sq in self?.click(sq: sq) }
        coach = CoachPanel()

        applyFX()   // 恢复上次的轨迹/裂痕设置
        newGame(side: currentSide, diff: currentDiff)
        return true
    }

    // MARK: - 特技 (轨迹 / 缓动 / 裂痕)
    /// 把菜单里的选择推给棋盘视图。轨迹是"随时切换立即生效"的运行期参数。
    func applyFX() {
        guard let v = boardView else { return }
        let shapes = Trajectory.Shape.allCases
        var t = Trajectory.of(shapes[max(0, min(shapes.count - 1, fxShapeIdx))])
        let eases = Ease.allCases
        t.ease = eases[max(0, min(eases.count - 1, fxEaseIdx))]
        v.traj = t
        v.crackEnabled = fxCrack
        v.kick()
    }
    func pickTrajectory(_ idx: Int) {
        fxShapeIdx = idx; UserDefaults.standard.set(fxShapeIdx, forKey: "xq.fxShape")
        applyFX()
    }
    func pickEase(_ idx: Int) {
        fxEaseIdx = idx; UserDefaults.standard.set(fxEaseIdx, forKey: "xq.fxEase")
        applyFX()
    }
    func toggleCrack() {
        fxCrack.toggle(); UserDefaults.standard.set(fxCrack, forKey: "xq.fxCrack")
        applyFX()
    }
    func doClearDecals() { boardView?.clearDecals() }

    /// 声音模式: all=音效+语音, sfx=仅音效, voice=仅语音, off=静音
    func applySoundMode() {
        let e = SoundEngine.shared
        e.sfxOn = (soundMode == "all" || soundMode == "sfx")
        e.voiceOn = (soundMode == "all" || soundMode == "voice")
        if !e.voiceOn { e.stopVoice() }
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
        ui?.setSimActive(true)
        refreshSimPanel()
        coachSay("已进入模拟模式：可自由推演任意一方的走法。")
    }
    func exitSimulation() {
        guard simActive else { return }
        simActive = false
        simSel = nil
        simBusy = false
        simMoves = []; simRedo = []
        ui?.setSimActive(false)
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
    func toggleSimulation() { simActive ? exitSimulation() : enterSimulation() }
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
        ui?.simPanelUpdate(status: status, line: line,
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
            ui?.setSimActive(false)
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
        #if os(macOS)
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
            return
        }
        #endif
        embeddedMove(mover: aiColor)
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
