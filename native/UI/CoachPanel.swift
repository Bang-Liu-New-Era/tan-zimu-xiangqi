//
//  CoachPanel.swift
//  人机中国象棋 · 教学侧栏
//
//  本文件由 native/XiangqiApp.swift 拆分而来 (tools/split_xiangqi.py, P1 纯搬运)。
//  拆分过程只做位置搬迁, 未改动任何逻辑。
//
import AppKit
import AVFoundation
import JavaScriptCore
import CoreText

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
