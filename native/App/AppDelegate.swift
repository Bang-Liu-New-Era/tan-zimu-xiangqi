//
//  AppDelegate.swift
//  人机中国象棋 · macOS 应用壳 (窗口 / 工具栏 / 菜单 / 调试钩子)
//
//  对局逻辑全部在 Core/GameController.swift (与 iOS 共享)。
//  本文件只做平台装配: NSWindow + NSSplitView + NSToolbar + NSMenu + 模拟遮罩 + 调试出图。
//
#if canImport(AppKit)
import AppKit
import AVFoundation
import JavaScriptCore
import CoreText

final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate, GameUI {
    var window: NSWindow!
    var controller = GameController()
    var simOverlay: SimOverlayView!
    var crackMenuItem: NSMenuItem?
    var fxMenus: [NSMenu] = []

    // MARK: - 启动

    func applicationDidFinishLaunching(_ n: Notification) {
        guard controller.start(ui: self),
              let boardView = controller.boardView, let coach = controller.coach
        else { NSApp.terminate(nil); return }

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
        simOverlay.panel.onPrev = { [weak controller] in controller?.simUndo() }
        simOverlay.panel.onNext = { [weak controller] in controller?.simRedoStep() }
        simOverlay.panel.onExit = { [weak controller] in controller?.exitSimulation() }

        let rect = NSRect(x: 0, y: 0, width: 1000, height: 720)
        window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "人机中国象棋 · 教学版 (原生)"
        window.center(); window.contentView = container; window.isReleasedWhenClosed = false
        setupToolbar(); window.makeKeyAndOrderFront(nil)

        // 模拟模式快捷键: ← 上一步 / → 下一步 / Esc 退出
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self = self, self.controller.simActive else { return e }
            switch e.keyCode {
            case 53: self.controller.exitSimulation(); return nil
            case 123: self.controller.simUndo(); return nil
            case 124: self.controller.simRedoStep(); return nil
            default: return e
            }
        }

        // 调试: XQ_FX=crack,paths 预置特效场景, 配合 XQ_SNAPSHOT 离屏出图验证
        if let fxSpec = ProcessInfo.processInfo.environment["XQ_FX"] {
            if fxSpec.contains("crack") {
                // crack_mid: 让裂痕在快照前 ~0.15s 才出生, 用来看"生长中"的中间态
                let born = fxSpec.contains("crack_mid")
                    ? CACurrentMediaTime() + 1.05
                    : CACurrentMediaTime() - 1.0
                // XQ_CRACKS=N 可指定裂纹数量 (默认 5) —— 用于测量"裂痕很多时"的每帧开销
                let want = Int(ProcessInfo.processInfo.environment["XQ_CRACKS"] ?? "") ?? 5
                let picks: [(Int, CGFloat)] = [(40, 1.00), (58, 0.92), (30, 0.80), (49, 0.72), (67, 0.85)]
                for i in 0..<max(0, want) {
                    let (sq, pw) = picks[i % picks.count]
                    // 超过 5 道时摊到整盘, 避免所有裂纹挤在同一格
                    let spread = i < picks.count ? sq : (i * 7 + 3) % 90
                    boardView.debugAddCrack(sq: spread, born: born, power: pw * (i < picks.count ? 1 : 0.9))
                }
            }
            if fxSpec.contains("paths") { boardView.debugShowPaths = true }
            boardView.kick()
        }

        // 调试: XQ_SCENE=lift(抬起投影)/fly(走子动画) 出图验证。正常使用不受影响。
        if let scene = ProcessInfo.processInfo.environment["XQ_SCENE"] {
            if scene.contains("lift") {
                boardView.selected = 84                    // 抬起一枚红兵, 看棋盘原位的投影
                boardView.kick()
            }
            if scene.contains("fly") {
                let piece = boardView.board[84]
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    boardView.animateMove(from: 84, to: 67, piece: piece,
                                          capture: false, captured: 0) {}
                }
            }
        }

        // 调试: 设定 XQ_SNAPSHOT=/path.png 时把当前棋盘离屏渲染成图片 (便于验证贴图对齐)
        if let sp = ProcessInfo.processInfo.environment["XQ_SNAPSHOT"] {
            let delay = Double(ProcessInfo.processInfo.environment["XQ_SNAP_DELAY"] ?? "") ?? 1.0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard let rep = boardView.bitmapImageRepForCachingDisplay(in: boardView.bounds) else { return }
                boardView.cacheDisplay(in: boardView.bounds, to: rep)
                if let d = rep.representation(using: .png, properties: [:]) {
                    try? d.write(to: URL(fileURLWithPath: sp))
                    print("snapshot ->", sp)
                }
            }
        }
    }

    // MARK: - GameUI 钩子 (对局逻辑上抛)

    func setSimActive(_ on: Bool) {
        simOverlay.isHidden = !on
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
    func simPanelUpdate(status: String, line: String, canPrev: Bool, canNext: Bool) {
        simOverlay.panel.update(status: status, line: line, canPrev: canPrev, canNext: canNext)
    }
    func showEngineError() {
        let a = NSAlert(); a.messageText = "引擎加载失败"; a.informativeText = "engine/*.js 未找到"
        a.runModal()
    }

    // MARK: - 窗口

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
                                      selected: controller.soundMode) { [weak controller] v in
            guard let c = controller else { return }
            c.soundMode = v
            c.applySoundMode()
        }
        case .side: return popupItem(id, "执子", [("我执红", RED), ("我执黑", BLACK)], selected: controller.currentSide) {
            [weak controller] v in guard let c = controller else { return }
            c.currentSide = v; c.newGame(side: v, diff: c.currentDiff)
        }
        case .difficulty: return popupItem(id, "难度", [("入门", "easy"), ("进阶", "medium"), ("高手", "hard")],
                                           selected: controller.currentDiff) { [weak controller] v in
            guard let c = controller else { return }
            c.currentDiff = v; c.difficulty = DIFFICULTIES.first { $0.id == v } ?? DIFFICULTIES[2]
            c.newGame(side: c.currentSide, diff: v)
        }
        case .engine: return popupItem(id, "引擎", [("自动", "auto"), ("内置引擎", "embedded"), ("皮卡鱼", "pikafish")],
                                       selected: controller.engineChoice) { [weak controller] v in
            guard let c = controller else { return }
            c.engineChoice = v
            let which = (v == "pikafish" && c.pika?.available == true) ? "皮卡鱼" :
                (v == "embedded" ? "内置引擎" : "自动(优先皮卡鱼)")
            c.coachSay("引擎已切换为：\(which)")
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
    @objc func doNewGame() { controller.newGame(side: controller.currentSide, diff: controller.currentDiff) }
    @objc func doUndo() { guard !controller.simActive else { return }; controller.undo() }
    @objc func doResign() { guard !controller.simActive else { return }; controller.resign() }
    @objc func doHint() { guard !controller.simActive else { return }; controller.hint() }
    @objc func doSimulate() { controller.toggleSimulation() }

    // MARK: - 特技菜单 (由 MenuBuilder 构建, 动作转发给 controller)

    @objc func pickTrajectory(_ s: NSMenuItem) { controller.pickTrajectory(s.tag); refreshFXMenu() }
    @objc func pickEase(_ s: NSMenuItem) { controller.pickEase(s.tag); refreshFXMenu() }
    @objc func toggleCrack() { controller.toggleCrack(); refreshFXMenu() }
    @objc func doClearDecals() { controller.doClearDecals() }
    func refreshFXMenu() {
        if fxMenus.count >= 2 {
            for it in fxMenus[0].items { it.state = it.tag == controller.fxShapeIdx ? .on : .off }
            for it in fxMenus[1].items { it.state = it.tag == controller.fxEaseIdx ? .on : .off }
        }
        crackMenuItem?.state = controller.fxCrack ? .on : .off
    }
}

#endif
