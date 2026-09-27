//
//  Rng.swift
//  人机中国象棋 · 确定性随机数发生器
//
//  本文件由 native/XiangqiApp.swift 拆分而来 (tools/split_xiangqi.py, P1 纯搬运)。
//  拆分过程只做位置搬迁, 未改动任何逻辑。
//
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
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

    /// 由 (种子, 两个整数) 直接算出一个 0..1 的确定性伪随机值。
    /// 渲染层要用它给同一条裂纹的每一段算"宽度抖动 / 掐细位置"这类细节 ——
    /// 这些细节不必(也不该)存进 Crack 里, 每帧用同一个种子重算即可, 结果永远一致。
    static func hash01(_ seed: UInt64, _ a: Int, _ b: Int) -> CGFloat {
        var h = seed
        h ^= UInt64(bitPattern: Int64(a)) &* 0x9E37_79B9_7F4A_7C15
        h ^= UInt64(bitPattern: Int64(b)) &* 0xC2B2_AE3D_27D4_EB4F
        h ^= h >> 33; h = h &* 0xFF51_AFD7_ED55_8CCD
        h ^= h >> 29; h = h &* 0xC4CE_B9FE_1A85_EC53
        h ^= h >> 32
        return CGFloat(h % 100_000) / 100_000
    }
}

/// 一道裂纹。branches 里的点相对被吃子格中心, 单位是「格」。
