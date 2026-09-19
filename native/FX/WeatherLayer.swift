//
//  WeatherLayer.swift
//  人机中国象棋 · 天气: RainDrop / Splash / Weather
//
//  本文件由 native/XiangqiApp.swift 拆分而来 (tools/split_xiangqi.py, P1 纯搬运)。
//  拆分过程只做位置搬迁, 未改动任何逻辑。
//
import AppKit
import AVFoundation
import JavaScriptCore
import CoreText

struct RainDrop {
    var x: CGFloat = 0, y: CGFloat = 0
    var len: CGFloat = 20, spd: CGFloat = 700
    var alpha: CGFloat = 0.5
    var layer: Int = 0          // 0 = 远景(棋盘之下) 1 = 近景(棋子之上)
}

struct Splash {                 // 雨点砸在棋盘上溅起的水花
    var x: CGFloat = 0, y: CGFloat = 0
    var t: CGFloat = 0
    var size: CGFloat = 1
}

struct Weather {
    enum Kind: String, CaseIterable {
        case none, drizzle, rain, storm
        var label: String {
            switch self {
            case .none:    return "无"
            case .drizzle: return "小雨"
            case .rain:    return "大雨"
            case .storm:   return "雷雨"
            }
        }
    }
    var kind: Kind = .none
    private var drops: [RainDrop] = []
    private var splashes: [Splash] = []
    private var clock: Double = 0
    private var nextBolt: Double = 5
    private(set) var flash: CGFloat = 0          // 闪电余辉 0~1

    var wind: CGFloat {
        switch kind {
        case .none:    return 0
        case .drizzle: return 0.16
        case .rain:    return 0.26
        case .storm:   return 0.42
        }
    }
    private var dropTarget: Int {
        switch kind {
        case .none:    return 0
        case .drizzle: return 150
        case .rain:    return 320
        case .storm:   return 500
        }
    }
    private var splashChance: CGFloat {
        switch kind {
        case .none, .drizzle: return 0.10
        case .rain:           return 0.42
        case .storm:          return 0.62
        }
    }
    var isActive: Bool { kind != .none || flash > 0.001 }

    mutating func setKind(_ k: Kind) {
        guard k != kind else { return }
        kind = k
        drops.removeAll(); splashes.removeAll()
        clock = 0; nextBolt = 4; flash = 0
    }

    private func makeDrop(_ view: CGRect, initial: Bool) -> RainDrop {
        let layer = Int.random(in: 0...1)
        var d = RainDrop()
        d.layer = layer
        d.x = CGFloat.random(in: -view.width * 0.15 ... view.width * 1.15)
        d.y = initial ? CGFloat.random(in: -40 ... view.height)
                      : CGFloat.random(in: view.height * 0.98 ... view.height * 1.12)
        if layer == 0 {                       // 远景: 细、慢、淡
            d.len = CGFloat.random(in: 10...20)
            d.spd = CGFloat.random(in: 380...560)
            d.alpha = CGFloat.random(in: 0.16...0.30)
        } else {                              // 近景: 粗、快、亮
            d.len = CGFloat.random(in: 24...50)
            d.spd = CGFloat.random(in: 780...1300)
            d.alpha = CGFloat.random(in: 0.32...0.58)
        }
        return d
    }

    mutating func update(_ dt: Double, board: CGRect, view: CGRect) {
        if kind == .none {
            if flash > 0 { flash = max(0, flash - CGFloat(dt) * 2.4) }
            return
        }
        clock += dt
        if kind == .storm, clock >= nextBolt {
            flash = 1.0
            nextBolt = clock + Double.random(in: 3.5...9.5)
        }
        if flash > 0 { flash = max(0, flash - CGFloat(dt) * 3.2) }

        let want = dropTarget
        while drops.count < want { drops.append(makeDrop(view, initial: true)) }
        if drops.count > want { drops.removeLast(drops.count - want) }

        let w = wind
        for i in drops.indices {
            drops[i].y -= drops[i].spd * CGFloat(dt)
            drops[i].x += w * drops[i].spd * CGFloat(dt) * 0.5
            if drops[i].y < -60 || drops[i].x > view.width + 120 {
                // 雨滴触底: 若落在棋盘横向范围内, 就在棋盘上砸出一朵水花
                if board.width > 0, drops[i].x > board.minX, drops[i].x < board.maxX,
                   CGFloat.random(in: 0...1) < splashChance {
                    splashes.append(Splash(x: drops[i].x,
                                           y: CGFloat.random(in: board.minY...board.maxY),
                                           t: 0, size: CGFloat.random(in: 0.7...1.4)))
                    if splashes.count > 90 { splashes.removeFirst(splashes.count - 90) }
                }
                drops[i] = makeDrop(view, initial: false)
            }
        }
        for i in splashes.indices { splashes[i].t += CGFloat(dt) / 0.42 }
        splashes.removeAll { $0.t >= 1 }
    }

    /// 远景雨: 画在棋盘之前, 制造「棋盘之外在下雨」的纵深感。
    func drawBack(_ cg: CGContext, _ view: CGRect) {
        drawDrops(cg, view, layer: 0)
    }
    /// 近景雨 + 水花 + 闪电: 画在棋子之后, 雨幕压在画面前方。
    func drawFront(_ cg: CGContext, _ view: CGRect) {
        drawDrops(cg, view, layer: 1)
        drawSplashes(cg)
        if flash > 0.001 {
            cg.saveGState()
            cg.setFillColor(NSColor(calibratedRed: 0.86, green: 0.90, blue: 1.0,
                                    alpha: 0.42 * flash).cgColor)
            cg.fill(view)
            cg.restoreGState()
        }
    }
    private func drawDrops(_ cg: CGContext, _ view: CGRect, layer: Int) {
        guard kind != .none else { return }
        let w = wind
        let norm = (w * w + 1).squareRoot()
        let ux = w / norm, uy = -1 / norm
        let path = CGMutablePath()
        for d in drops where d.layer == layer {
            let hx = d.x - ux * d.len * 0.5, hy = d.y - uy * d.len * 0.5
            let tx = d.x + ux * d.len * 0.5, ty = d.y + uy * d.len * 0.5
            path.move(to: CGPoint(x: hx, y: hy))
            path.addLine(to: CGPoint(x: tx, y: ty))
        }
        cg.saveGState()
        cg.addPath(path)
        cg.setLineWidth(layer == 0 ? 1.5 : 2.8)
        cg.setLineCap(.round)
        // 远景偏灰蓝、近景偏亮白 —— 靠颜色与线宽拉开纵深, 让雨幕是两层而不是一片
        let col = layer == 0
            ? NSColor(calibratedRed: 0.58, green: 0.68, blue: 0.82, alpha: 0.34)
            : NSColor(calibratedRed: 0.84, green: 0.91, blue: 1.00, alpha: 0.62)
        cg.setStrokeColor(col.cgColor)
        cg.strokePath()
        cg.restoreGState()
    }
    private func drawSplashes(_ cg: CGContext) {
        for s in splashes {
            let fade = 1 - s.t
            let r = 7 * s.size * (0.30 + 1.7 * s.t)
            cg.saveGState()
            cg.setStrokeColor(NSColor(calibratedRed: 0.86, green: 0.93, blue: 1.00,
                                      alpha: 0.95 * fade).cgColor)
            cg.setLineWidth(max(1.0, 2.6 * fade))
            cg.strokeEllipse(in: CGRect(x: s.x - r, y: s.y - r * 0.38,
                                        width: 2 * r, height: r * 0.76))
            if s.t < 0.5 {                                   // 中心溅起的小水柱
                let h = 11 * s.size * (1 - s.t / 0.5)
                cg.setFillColor(NSColor(calibratedRed: 0.94, green: 0.97, blue: 1.00,
                                        alpha: 0.95 * fade).cgColor)
                cg.fillEllipse(in: CGRect(x: s.x - 1.5, y: s.y, width: 3.0, height: h))
            }
            cg.restoreGState()
        }
    }
}

// MARK: - 屏幕演员 (序列帧精灵: 马跑过画面)

// MARK: - 天气图层

/// 天气状态盒。用 class 包一层, 让"远景雨"与"近景雨"两个图层共享同一份雨滴状态
/// (Weather 是 struct, 直接放在两个图层里会各下一场雨)。
final class WeatherState {
    var weather = Weather()
}

/// 天气图层。
///   .back  —— 远景雨幕, 注册在棋盘**之前**: 制造"棋盘之外也在下雨"的纵深
///   .front —— 近景雨幕 + 水花 + 闪电, 注册在棋子**之后**: 雨幕压在画面前方
/// 只有 .back 负责推进状态, 否则雨滴会被两个图层各推进一次 → 双倍速。
final class WeatherLayer: RenderLayer {
    enum Pass { case back, front }

    let name: String
    let pass: Pass
    var followsShake: Bool { false }        // 雨是"环境", 不该跟着棋盘抖
    private let state: WeatherState

    init(_ pass: Pass, _ state: WeatherState) {
        self.pass = pass
        self.state = state
        self.name = pass == .back ? "rainBack" : "rainFront"
    }

    var isAnimating: Bool { state.weather.isActive }

    func update(_ ctx: RenderContext) {
        guard pass == .back else { return }
        state.weather.update(ctx.dt, board: ctx.plateRect, view: ctx.bounds)
    }

    func draw(_ ctx: RenderContext) {
        guard let cg = ctx.cg else { return }
        switch pass {
        case .back:  state.weather.drawBack(cg, ctx.bounds)
        case .front: state.weather.drawFront(cg, ctx.bounds)
        }
    }
}
