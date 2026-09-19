//
//  SimMove.swift
//  人机中国象棋 · 模拟模式: 走子记录
//
//  本文件由 native/XiangqiApp.swift 拆分而来 (tools/split_xiangqi.py, P1 纯搬运)。
//  拆分过程只做位置搬迁, 未改动任何逻辑。
//
import AppKit
import AVFoundation
import JavaScriptCore
import CoreText

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
