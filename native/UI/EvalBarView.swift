//
//  EvalBarView.swift
//  人机中国象棋 · 形势评估条
//
//  本文件由 native/XiangqiApp.swift 拆分而来 (tools/split_xiangqi.py, P1 纯搬运)。
//  拆分过程只做位置搬迁, 未改动任何逻辑。
//
import AppKit
import AVFoundation
import JavaScriptCore
import CoreText

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
