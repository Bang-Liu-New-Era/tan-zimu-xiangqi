//
//  SimPanel.swift
//  人机中国象棋 · 模拟模式: 控制面板
//
//  本文件由 native/XiangqiApp.swift 拆分而来 (tools/split_xiangqi.py, P1 纯搬运)。
//  拆分过程只做位置搬迁, 未改动任何逻辑。
//
import AppKit
import AVFoundation
import JavaScriptCore
import CoreText

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
