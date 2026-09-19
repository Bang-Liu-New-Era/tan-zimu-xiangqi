//
//  CrackForge.swift
//  人机中国象棋 · 裂痕: Crack + CrackForge
//
//  本文件由 native/XiangqiApp.swift 拆分而来 (tools/split_xiangqi.py, P1 纯搬运)。
//  拆分过程只做位置搬迁, 未改动任何逻辑。
//
import AppKit
import AVFoundation
import JavaScriptCore
import CoreText

struct Crack {
    let sq: Int
    let born: Double              // 出生时刻(绝对秒): 落地那一刻才开始生长
    let branches: [[CGPoint]]
    let width: CGFloat            // 主裂纹线宽(格)
    let tint: CGFloat             // 0=浅 1=深
    let scorch: CGFloat           // 中心焦痕半径(格), 0 = 无
    let dur: Double = 0.42        // 生长时长
}

enum CrackForge {
    /// power: 0.7~1.0 的破坏力(车碾碎最大), 决定纹路密度、线宽与焦痕。
    static func forge(sq: Int, born: Double, seed: UInt64, power: CGFloat) -> Crack {
        var rng = SeededRNG(seed)
        var branches: [[CGPoint]] = []
        let mains = 5 + rng.int(4)                                   // 5~8 条主裂纹
        let baseLen = 0.17 + 0.15 * power                            // 单段基准长度(格)
        let base = rng.range(0, 2 * .pi)
        for i in 0..<mains {
            let ang = base + CGFloat(i) / CGFloat(mains) * 2 * .pi + rng.range(-0.30, 0.30)
            var line: [CGPoint] = [.zero]
            grow(&rng, &line, branches: &branches, from: .zero, angle: ang,
                 steps: 3 + rng.int(4), len: baseLen * rng.range(0.80, 1.25), depth: 0)
            branches.append(line)
        }
        return Crack(sq: sq, born: born, branches: branches,
                     width: 0.018 + 0.016 * power,
                     tint: 0.55 + 0.45 * power,
                     scorch: power > 0.9 ? 0.30 : 0.18)
    }

    /// 递归生长一条裂纹: 每段方向抖动、长度衰减, 并按概率分叉出细纹。
    private static func grow(_ rng: inout SeededRNG, _ line: inout [CGPoint], branches: inout [[CGPoint]],
                             from p: CGPoint, angle: CGFloat, steps: Int, len: CGFloat, depth: Int) {
        var pt = p, ang = angle, L = len
        for _ in 0..<steps {
            ang += rng.range(-0.45, 0.45)
            L *= rng.range(0.70, 0.94)
            pt = CGPoint(x: pt.x + cos(ang) * L, y: pt.y + sin(ang) * L)
            line.append(pt)
            if depth < 2, L > 0.05, rng.chance(0.42) {
                var sub: [CGPoint] = [pt]
                grow(&rng, &sub, branches: &branches, from: pt,
                     angle: ang + (rng.chance(0.5) ? -1 : 1) * rng.range(0.55, 1.15),
                     steps: max(1, steps / 2), len: L * 0.62, depth: depth + 1)
                if sub.count > 1 { branches.append(sub) }
            }
        }
    }
}

// MARK: - 天气系统 (雨)
