//
//  Rng.swift
//  人机中国象棋 · 确定性随机数发生器
//
//  本文件由 native/XiangqiApp.swift 拆分而来 (tools/split_xiangqi.py, P1 纯搬运)。
//  拆分过程只做位置搬迁, 未改动任何逻辑。
//
import AppKit
import AVFoundation
import JavaScriptCore
import CoreText

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
