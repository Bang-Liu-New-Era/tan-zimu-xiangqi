//
//  Trajectory.swift
//  人机中国象棋 · 轨迹引擎: Ease + Trajectory
//
//  本文件由 native/XiangqiApp.swift 拆分而来 (tools/split_xiangqi.py, P1 纯搬运)。
//  拆分过程只做位置搬迁, 未改动任何逻辑。
//
import AppKit
import AVFoundation
import JavaScriptCore
import CoreText

enum Ease: String, CaseIterable {
    case smooth, linear, easeIn, easeOut, easeInOut, snap, over
    var label: String {
        switch self {
        case .smooth:    return "平滑"
        case .linear:    return "匀速"
        case .easeIn:    return "渐快"
        case .easeOut:   return "渐慢"
        case .easeInOut: return "缓入缓出"
        case .snap:      return "抢子"
        case .over:      return "过冲"
        }
    }
    func f(_ t: CGFloat) -> CGFloat {
        let u = max(0, min(1, t))
        switch self {
        case .linear:             return u
        case .smooth, .easeInOut: return u * u * (3 - 2 * u)
        case .easeIn:             return u * u * u
        case .easeOut:            return 1 - pow(1 - u, 3)
        case .snap:               return 1 - pow(1 - u, 4)
        case .over:
            let c1: CGFloat = 1.70158
            return 1 + (c1 + 1) * pow(u - 1, 3) + c1 * pow(u - 1, 2)
        }
    }
}

/// 走子轨迹。所有几何量都在「格」坐标系里定义: 采样得到侧向偏移与抬升(单位=格),
/// 由绘制方乘以格子尺寸。因此与窗口缩放、棋盘 180° 翻转完全无关。
struct Trajectory {
    enum Shape: String, CaseIterable {
        case arc, straight, bezier, flank, zigzag, spiral
        var label: String {
            switch self {
            case .arc:      return "抛物线"
            case .straight: return "贴地推"
            case .bezier:   return "贝塞尔"
            case .flank:    return "绕侧翼"
            case .zigzag:   return "折线跃"
            case .spiral:   return "螺旋收"
            }
        }
    }
    var shape: Shape = .arc
    var ease: Ease = .smooth
    var fly: Double = 0.26          // 飞行时长(秒)
    var land: Double = 0.13         // 落地回弹时长
    var hop: CGFloat = 0.30         // 抬升峰值(格)
    var spin: CGFloat = 14          // 空中旋转(度)
    var scalePeak: CGFloat = 0.13   // 弧顶放大
    var bend: CGFloat = 1           // 侧向绕行方向 +1 / -1
    /// 途经格(可选)。非空时按折线依次经过这些交叉点, 覆盖 shape 的路径。
    var via: [Int] = []

    static func of(_ s: Shape) -> Trajectory { var t = Trajectory(); t.shape = s; return t }

    /// 采样飞行姿态 → (侧向偏移(格), 抬升(格), 旋转(rad), 缩放)
    func sample(_ t: CGFloat) -> (perp: CGFloat, lift: CGFloat, rot: CGFloat, scale: CGFloat) {
        let u = max(0, min(1, t))
        let (perp, lift) = shapeScalars(u)
        let rot = spin * .pi / 180 * sin(.pi * u)
        let k = hop > 0.0001 ? lift / hop : 0
        return (perp, lift, rot, 1 + scalePeak * k)
    }
    /// 形状只贡献两个标量: 垂直于 A→B 的侧偏, 与离板抬升。推进节奏由 Ease 单独负责。
    private func shapeScalars(_ u: CGFloat) -> (perp: CGFloat, lift: CGFloat) {
        let bell = 4 * u * (1 - u)                       // 0 → 1 → 0
        switch shape {
        case .arc:      return (0, hop * bell)
        case .straight: return (0, hop * 0.10 * bell)
        case .bezier:   return (bend * 0.55 * sin(.pi * u), hop * bell * 0.90)
        case .flank:    return (bend * 1.25 * sin(.pi * u), hop * 0.70 * bell)
        case .zigzag:   return (bend * 0.26 * sin(2 * .pi * u), hop * abs(sin(2 * .pi * u)) * 0.85)
        case .spiral:   return (bend * 0.46 * (1 - u) * sin(2.4 * .pi * u), hop * bell * (1 - 0.30 * u))
        }
    }
}

// MARK: - 伤痕贴花 (吃子后永久留在棋盘上的裂痕)
/// 确定性伪随机 (xorshift64): 同一个种子永远长出同一道裂纹 —— 便于复现与测试。
