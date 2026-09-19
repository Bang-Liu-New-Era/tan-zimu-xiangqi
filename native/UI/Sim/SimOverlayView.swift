//
//  SimOverlayView.swift
//  人机中国象棋 · 模拟模式: 暗黑遮罩
//
//  本文件由 native/XiangqiApp.swift 拆分而来 (tools/split_xiangqi.py, P1 纯搬运)。
//  拆分过程只做位置搬迁, 未改动任何逻辑。
//
import AppKit
import AVFoundation
import JavaScriptCore
import CoreText

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
