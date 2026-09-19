//
//  ActorLayer.swift
//  人机中国象棋 · 屏幕演员: SpriteSheet / ActorAssets / HorseArt / Actor
//
//  本文件由 native/XiangqiApp.swift 拆分而来 (tools/split_xiangqi.py, P1 纯搬运)。
//  拆分过程只做位置搬迁, 未改动任何逻辑。
//
import AppKit
import AVFoundation
import JavaScriptCore
import CoreText

struct SpriteSheet {
    let frames: [NSImage]
    let fps: Double
}

enum ActorAssets {
    private static var cache: [String: SpriteSheet] = [:]
    private static var misses: Set<String> = []

    /// 扫描 Resources/actors/<name>/ 下的 run_NN.png 序列帧, 按文件名排序 (帧序由文件名保证)。
    /// 找不到就返回 nil, 由调用方退回到程序化绘制的剪影。
    static func load(_ name: String) -> SpriteSheet? {
        if let hit = cache[name] { return hit }
        if misses.contains(name) { return nil }
        var seen: [String: NSImage] = [:]
        let dirs: [String?] = ["actors/\(name)", "actors", nil]
        for sub in dirs {
            guard let urls = Bundle.main.urls(forResourcesWithExtension: "png", subdirectory: sub) else { continue }
            for u in urls {
                let base = u.deletingPathExtension().lastPathComponent
                guard base.hasPrefix("run_") else { continue }
                if let img = NSImage(contentsOf: u), img.size.width > 4 { seen[base] = img }
            }
            if !seen.isEmpty { break }
        }
        guard !seen.isEmpty else { misses.insert(name); return nil }
        let sheet = SpriteSheet(frames: seen.keys.sorted().compactMap { seen[$0] }, fps: 16)
        cache[name] = sheet
        return sheet
    }
}

/// 程序化奔马剪影 —— 没有提供序列帧素材时的退路, 保证「马跑过」现在就能看。
/// 设计坐标系: 高 100, 蹄底 y=0, 马头朝 +x。
enum HorseArt {
    static func draw(_ cg: CGContext, phase: CGFloat, h: CGFloat, color: NSColor) {
        let u = h / 100
        cg.saveGState()
        cg.setStrokeColor(color.cgColor)
        cg.setFillColor(color.cgColor)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)

        // 四条腿: hip → knee → hoof, 相位各差 1/4 周期
        struct Leg { let x: CGFloat; let ph: CGFloat; let w: CGFloat; let len: CGFloat }
        let legs = [Leg(x: -26, ph: 0.00, w: 7.5, len: 50),
                    Leg(x: -16, ph: 0.50, w: 7.0, len: 47),
                    Leg(x:  20, ph: 0.25, w: 8.0, len: 51),
                    Leg(x:  31, ph: 0.75, w: 7.5, len: 48)]
        for l in legs {
            let a = (phase + l.ph) * 2 * .pi
            let swing = sin(a)
            let lift = max(0, sin(a + 1.15)) * 15
            let hip = CGPoint(x: l.x, y: 52)
            let knee = CGPoint(x: l.x + swing * 15, y: 27)
            let hoof = CGPoint(x: l.x + swing * 25, y: lift)
            let p = CGMutablePath()
            p.move(to: CGPoint(x: hip.x * u, y: hip.y * u))
            p.addQuadCurve(to: CGPoint(x: hoof.x * u, y: hoof.y * u),
                           control: CGPoint(x: knee.x * u, y: knee.y * u))
            cg.addPath(p)
            cg.setLineWidth(l.w * u)
            cg.strokePath()
        }
        // 躯干
        let body = CGMutablePath()
        body.addEllipse(in: CGRect(x: -34 * u, y: 46 * u, width: 70 * u, height: 31 * u))
        cg.addPath(body); cg.fillPath()
        // 脖颈 (从躯干前上方捅出去)
        let neck = CGMutablePath()
        neck.move(to: CGPoint(x: 24 * u, y: 58 * u))
        neck.addQuadCurve(to: CGPoint(x: 50 * u, y: 92 * u),
                          control: CGPoint(x: 44 * u, y: 66 * u))
        neck.addQuadCurve(to: CGPoint(x: 32 * u, y: 74 * u),
                          control: CGPoint(x: 36 * u, y: 74 * u))
        neck.closeSubpath()
        cg.addPath(neck); cg.fillPath()
        // 头: 圆润的脸颊 + 斜向下的口鼻 (方块头会显得像机械马)
        let head = CGMutablePath()
        head.move(to: CGPoint(x: 43 * u, y: 96 * u))
        head.addCurve(to: CGPoint(x: 69 * u, y: 81 * u),
                      control1: CGPoint(x: 57 * u, y: 98 * u),
                      control2: CGPoint(x: 68 * u, y: 90 * u))
        head.addCurve(to: CGPoint(x: 59 * u, y: 71 * u),
                      control1: CGPoint(x: 71 * u, y: 76 * u),
                      control2: CGPoint(x: 66 * u, y: 71 * u))
        head.addCurve(to: CGPoint(x: 42 * u, y: 80 * u),
                      control1: CGPoint(x: 50 * u, y: 71 * u),
                      control2: CGPoint(x: 45 * u, y: 74 * u))
        head.closeSubpath()
        cg.addPath(head); cg.fillPath()
        // 耳朵
        let ear = CGMutablePath()
        ear.move(to: CGPoint(x: 45 * u, y: 95 * u))
        ear.addLine(to: CGPoint(x: 42 * u, y: 105 * u))
        ear.addLine(to: CGPoint(x: 52 * u, y: 96 * u))
        ear.closeSubpath()
        cg.addPath(ear); cg.fillPath()
        // 鬃毛: 沿颈背的锯齿带, 随奔跑相位摆动
        let mane = CGMutablePath()
        mane.move(to: CGPoint(x: 26 * u, y: 66 * u))
        for i in 0...6 {
            let k = CGFloat(i) / 6
            let wob = sin((phase + k * 0.8) * 2 * .pi) * 3.8
            mane.addLine(to: CGPoint(x: (29 + 24 * k) * u, y: (72 + 24 * k) * u + (wob + 5) * u))
            mane.addLine(to: CGPoint(x: (24 + 24 * k) * u, y: (68 + 24 * k) * u + wob * u))
        }
        mane.closeSubpath()
        cg.addPath(mane); cg.fillPath()
        // 尾巴: 随奔跑甩动
        let tw = sin(phase * 2 * .pi) * 5
        let tail = CGMutablePath()
        tail.move(to: CGPoint(x: -33 * u, y: 73 * u))
        tail.addCurve(to: CGPoint(x: -63 * u, y: (42 + tw) * u),
                      control1: CGPoint(x: -57 * u, y: 79 * u),
                      control2: CGPoint(x: -68 * u, y: (58 + tw) * u))
        tail.addCurve(to: CGPoint(x: -33 * u, y: 63 * u),
                      control1: CGPoint(x: -52 * u, y: (48 + tw) * u),
                      control2: CGPoint(x: -42 * u, y: 56 * u))
        tail.closeSubpath()
        cg.addPath(tail); cg.fillPath()
        cg.restoreGState()
    }
}

struct Actor {
    let born: Double
    let dur: Double
    let dir: CGFloat             // +1 从左跑到右, -1 反向
    let baseY: CGFloat           // 屏幕归一化 y (0=底 1=顶), 蹄底所在高度
    let heightRatio: CGFloat     // 马高 = 视图高度 × 该系数
    let sheet: SpriteSheet?
    let name: String
}

// MARK: - 模拟模式 (沙盘推演) 数据结构
