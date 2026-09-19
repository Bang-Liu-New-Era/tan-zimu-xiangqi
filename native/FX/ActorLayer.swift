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

// MARK: - 演员图层

/// 屏幕演员层 (马跑过画面)。
/// 不参与震屏 —— 演员是画面前方的独立表演, 不该被棋盘带着抖。
final class ActorLayer: RenderLayer {
    let name = "actors"
    var actors: [Actor] = []

    var isAnimating: Bool { !actors.isEmpty }

    /// 让一匹马从画面外跑过。有 run_NN.png 序列帧素材就用素材, 否则用程序化剪影。
    func runHorse() {
        let sheet = ActorAssets.load("horse")
        actors.append(Actor(born: CACurrentMediaTime(), dur: 3.6, dir: 1,
                            baseY: 0.07, heightRatio: 0.30, sheet: sheet, name: "horse"))
    }

    /// 跑完就摘掉 —— 主循环靠它判断还要不要继续跑
    func update(_ ctx: RenderContext) {
        if !actors.isEmpty { actors.removeAll { ctx.now >= $0.born + $0.dur } }
    }

    /// 沿屏幕横向跑过, 带奔跑起伏与蹄后扬尘。
    func draw(_ ctx: RenderContext) {
        guard !actors.isEmpty, let cg = ctx.cg else { return }
        let view = ctx.bounds
        let now = ctx.now
        for a in actors {
            let t = (now - a.born) / a.dur
            guard t >= 0, t <= 1 else { continue }
            let fade: CGFloat = t < 0.08 ? CGFloat(t / 0.08)
                : (t > 0.92 ? CGFloat((1 - t) / 0.08) : 1)       // 两端淡入淡出
            let h = view.height * a.heightRatio
            let prog = -0.18 + 1.36 * CGFloat(t)
            let x = a.dir > 0 ? prog * view.width : (1 - prog) * view.width
            let bob = sin(CGFloat(t) * 22) * h * 0.028           // 奔跑起伏
            let y = view.height * a.baseY + bob
            let phase = CGFloat((now - a.born) * 2.6)
            cg.saveGState()
            cg.setAlpha(fade)
            // 蹄后扬尘: 一路淡出的小土团
            for i in 0..<7 {
                let k = CGFloat(i) / 7
                let px = x - a.dir * (0.4 + CGFloat(i)) * h * 0.13
                let py = y + h * 0.05 + sin(phase * 0.7 + k * 3) * h * 0.02
                let r = h * (0.062 - 0.005 * CGFloat(i))
                cg.setFillColor(NSColor(calibratedWhite: 0.88, alpha: 0.42 * (1 - k)).cgColor)
                cg.fillEllipse(in: CGRect(x: px - r, y: py - r * 0.62, width: 2 * r, height: 1.24 * r))
            }
            if let sheet = a.sheet, !sheet.frames.isEmpty {
                let idx = Int((now - a.born) * sheet.fps) % sheet.frames.count
                let img = sheet.frames[idx]
                let ar = img.size.height > 1 ? img.size.width / img.size.height : 1
                let w = h * ar
                let rect = CGRect(x: x - w / 2, y: y, width: w, height: h)
                cg.saveGState()
                if a.dir < 0 {                                   // 反向跑: 水平镜像
                    cg.translateBy(x: x, y: 0); cg.scaleBy(x: -1, y: 1); cg.translateBy(x: -x, y: 0)
                }
                img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: fade)
                cg.restoreGState()
            } else {
                cg.translateBy(x: x, y: y)
                if a.dir < 0 { cg.scaleBy(x: -1, y: 1) }
                HorseArt.draw(cg, phase: phase, h: h,
                              color: NSColor(calibratedRed: 0.16, green: 0.11,
                                             blue: 0.07, alpha: 0.92))
            }
            cg.restoreGState()
        }
    }
}
