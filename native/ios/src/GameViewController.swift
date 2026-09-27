//
//  GameViewController.swift
//  人机中国象棋 · iOS 游戏控制器 (平台壳)
//
//  对局逻辑全部在 Core/GameController.swift (与 macOS 共享)。
//  本文件只做 UIKit 装配: 棋盘 + 教学侧栏 + 底部工具栏(替代 macOS 的菜单/工具栏)
//  + 模拟模式操作条。
//
#if canImport(UIKit)
import UIKit

final class GameViewController: UIViewController, GameUI {

    let controller = GameController()

    private var boardView: BoardView!
    private var coach: CoachPanel!
    private let toolbar = UIStackView()
    private let simBar = UIStackView()
    private let simLabel = UILabel()

    // 工具栏按钮 (模拟模式期间要置灰)
    private var gameButtons: [UIButton] = []

    // MARK: - 生命周期

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.88, green: 0.87, blue: 0.83, alpha: 1)

        diag("GameViewController.viewDidLoad 到达")
        guard controller.start(ui: self),
              let bv = controller.boardView, let cp = controller.coach else {
            diag("controller.start 失败 (引擎?)")
            return
        }
        diag("controller.start 成功")
        boardView = bv
        coach = cp
        view.addSubview(boardView)
        view.addSubview(coach)
        diag("boardView.frame=\(boardView.frame) coach.frame=\(coach.frame)")
        buildToolbar()
        buildSimBar()
        runSelfTestIfRequested()
    }

    // MARK: - 布局 (竖屏: 棋盘上/侧栏下/工具栏底; 横屏: 棋盘左/侧栏右)

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard boardView != nil else { return }
        let b = view.bounds
        let safe = view.safeAreaInsets
        let barH: CGFloat = 48
        let toolbarY = b.height - safe.bottom - barH

        toolbar.frame = CGRect(x: 0, y: toolbarY, width: b.width, height: barH)
        simBar.frame = CGRect(x: 0, y: toolbarY, width: b.width, height: barH)

        if b.height >= b.width {   // 竖屏
            let coachH = min(200, b.height * 0.26)
            coach.frame = CGRect(x: 8, y: toolbarY - coachH - 6, width: b.width - 16, height: coachH)
            boardView.frame = CGRect(x: 0, y: safe.top, width: b.width,
                                     height: coach.frame.minY - safe.top - 6)
        } else {                    // 横屏: 棋盘在左占主要区域
            let coachW: CGFloat = 280
            coach.frame = CGRect(x: b.width - safe.right - coachW - 8, y: safe.top + 4,
                                 width: coachW, height: toolbarY - safe.top - 12)
            let bw = min(b.width - safe.left - safe.right - coachW - 16,
                         (toolbarY - safe.top) / 9.0 * 10.6)   // 棋盘连边框近似 8.6:9.6 的横向比
            let bx = (b.width - safe.right - coachW - 12 - bw) / 2
            boardView.frame = CGRect(x: max(safe.left, bx), y: safe.top,
                                     width: bw, height: toolbarY - safe.top)
        }
    }

    // MARK: - 工具栏 (macOS 的 NSToolbar / NSMenu 在 iOS 上的等价物)

    private func buildToolbar() {
        toolbar.axis = .horizontal
        toolbar.distribution = .fillEqually
        toolbar.spacing = 6
        toolbar.frame = CGRect(x: 0, y: 0, width: view.bounds.width, height: 48)
        toolbar.backgroundColor = UIColor(white: 0.92, alpha: 1)

        func btn(_ title: String, _ action: Selector) -> UIButton {
            let b = UIButton(type: .system)
            b.setTitle(title, for: .normal)
            b.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .medium)
            b.addTarget(self, action: action, for: .touchUpInside)
            return b
        }
        let items = [
            btn("新对局", #selector(doNewGame)),
            btn("悔棋", #selector(doUndo)),
            btn("提示", #selector(doHint)),
            btn("认输", #selector(doResign)),
            btn("更多…", #selector(doMore)),
        ]
        gameButtons = items
        for it in items { toolbar.addArrangedSubview(it) }
        view.addSubview(toolbar)
    }

    /// 模拟模式操作条 (平时隐藏; 对应 macOS 的 SimOverlayView 浮层)
    private func buildSimBar() {
        simBar.axis = .horizontal
        simBar.spacing = 6
        simBar.backgroundColor = UIColor(white: 0.16, alpha: 0.94)
        simBar.isHidden = true
        simBar.layer.cornerRadius = 10

        func btn(_ title: String, _ action: Selector) -> UIButton {
            let b = UIButton(type: .system)
            b.setTitle(title, for: .normal)
            b.setTitleColor(.white, for: .normal)
            b.setTitleColor(.darkGray, for: .disabled)
            b.titleLabel?.font = UIFont.systemFont(ofSize: 15, weight: .medium)
            b.addTarget(self, action: action, for: .touchUpInside)
            return b
        }
        let prev = btn("◀ 上一步", #selector(simPrev))
        let next = btn("下一步 ▶", #selector(simNext))
        let exit = btn("退出模拟", #selector(simExit))
        prev.tag = 1; next.tag = 2        // setSimActive 里按 tag 取用
        simLabel.textColor = UIColor(white: 0.85, alpha: 1)
        simLabel.font = UIFont.systemFont(ofSize: 12)
        simLabel.numberOfLines = 3
        simLabel.adjustsFontSizeToFitWidth = true
        simLabel.minimumScaleFactor = 0.6

        simBar.addArrangedSubview(prev)
        simBar.addArrangedSubview(simLabel)
        simBar.addArrangedSubview(next)
        simBar.addArrangedSubview(exit)
        view.addSubview(simBar)
    }

    // MARK: - 动作

    @objc private func doNewGame() {
        controller.newGame(side: controller.currentSide, diff: controller.currentDiff)
    }
    @objc private func doUndo() { controller.undo() }
    @objc private func doHint() { controller.hint() }
    @objc private func doResign() { controller.resign() }
    @objc private func simPrev() { controller.simUndo() }
    @objc private func simNext() { controller.simRedoStep() }
    @objc private func simExit() { controller.exitSimulation() }

    @objc private func doMore() {
        let sheet = UIAlertController(title: "设置", message: nil, preferredStyle: .actionSheet)
        func side(_ label: String, _ v: String) {
            sheet.addAction(UIAlertAction(title: label, style: .default) { [weak self] _ in
                guard let self = self else { return }
                self.controller.currentSide = v
                self.controller.newGame(side: v, diff: self.controller.currentDiff)
            })
        }
        func diff(_ label: String, _ v: String) {
            sheet.addAction(UIAlertAction(title: "难度 · \(label)", style: .default) { [weak self] _ in
                guard let self = self else { return }
                self.controller.currentDiff = v
                self.controller.difficulty = DIFFICULTIES.first { $0.id == v } ?? DIFFICULTIES[2]
                self.controller.newGame(side: self.controller.currentSide, diff: v)
            })
        }
        func sound(_ label: String, _ v: String) {
            sheet.addAction(UIAlertAction(title: "声音 · \(label)", style: .default) { [weak self] _ in
                guard let self = self else { return }
                self.controller.soundMode = v
                self.controller.applySoundMode()
            })
        }
        side("我执红棋", RED)
        side("我执黑棋", BLACK)
        diff("入门", "easy")
        diff("进阶", "medium")
        diff("高手", "hard")
        sound("全部开", "all")
        sound("仅音效", "sfx")
        sound("仅语音", "voice")
        sound("全部关", "off")
        sheet.addAction(UIAlertAction(title: "进入模拟推演", style: .default) { [weak self] _ in
            self?.controller.enterSimulation()
        })
        sheet.addAction(UIAlertAction(title: "清除棋盘裂痕", style: .default) { [weak self] _ in
            self?.controller.doClearDecals()
        })
        sheet.addAction(UIAlertAction(title: "取消", style: .cancel))
        if let p = sheet.popoverPresentationController {   // iPad
            p.sourceView = view
            p.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 60,
                                  width: 1, height: 1)
        }
        present(sheet, animated: true)
    }

    // MARK: - GameUI 钩子 (对局逻辑上抛)

    func setSimActive(_ on: Bool) {
        simBar.isHidden = !on
        toolbar.isHidden = on
        for b in gameButtons where b.currentTitle != "更多…" { b.isEnabled = !on }
    }

    func simPanelUpdate(status: String, line: String, canPrev: Bool, canNext: Bool) {
        simLabel.text = status
        for case let b as UIButton in simBar.arrangedSubviews {
            if b.tag == 1 { b.isEnabled = canPrev }
            if b.tag == 2 { b.isEnabled = canNext }
        }
    }

    func showEngineError() {
        let a = UIAlertController(title: "引擎加载失败", message: "engine/*.js 未找到",
                                  preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "好", style: .default))
        present(a, animated: true)
    }
}

#endif

#if canImport(UIKit)
extension GameViewController {
    /// 模拟器上的自检: XQ_IOS_TEST=1 时执行 (真机不会触发)。
    /// ① 触摸坐标映射往返 ② 程序化走一步看动画/AI 是否接上。
    private func runSelfTestIfRequested() {
        guard ProcessInfo.processInfo.environment["XQ_IOS_TEST"] != nil else { return }
        let bv = boardView!
        let (ox, oy, cell) = bv.layout
        for sq in [0, 40, 84, 89] {
            let c = bv.center(sq, ox, oy, cell)
            let back = bv.squareAt(CGPoint(x: c.x, y: bv.bounds.height - c.y))
            diag("坐标往返 sq=\(sq) -> 屏幕(\(Int(c.x)),\(Int(c.y))) -> 回推 \(String(describing: back))")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            guard let self = self else { return }
            diag("走子测试: 点兵 84")
            self.controller.click(sq: 84)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self else { return }
            let legal = self.controller.legalTargets
            diag("选中结果: selected=\(String(describing: self.controller.selected)) 合法落点=\(legal)")
            if let to = legal.first {
                diag("走子测试: 走到 \(to)")
                self.controller.click(sq: to)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            guard let self = self else { return }
            diag("走子后: ply=\(self.controller.ply) (2=玩家+电脑各一步) 棋谱=\(self.controller.logText.replacingOccurrences(of: "\n", with: " | "))")
            // 顺带验证裂痕层在 iOS 坐标系下能画出来
            self.boardView.debugAddCrack(sq: 40, born: CACurrentMediaTime() - 1.0, power: 1.0)
            diag("已放入一道裂痕 (sq=40) 供截图检查")
        }
        // 之后每 1.5s 记一次局面, 用来判定"电脑是否连走"
        var tick = 0
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            tick += 1
            diag("tick\(tick) ply=\(self.controller.ply) turn=\(self.controller.turn) human=\(self.controller.humanColor) aiThinking=\(self.controller.aiThinking) 末着=\(self.controller.logText.split(separator: "\n").last ?? "-")")
        }
    }
}
#endif
