//
//  RenderPipeline.swift
//  人机中国象棋 · 渲染管线
//
//  职责单一: 按注册顺序把所有图层画一遍。
//
//  震屏的处理 —— 这是把「谁跟着棋盘抖」从绘制代码里解放出来的关键:
//  管线顺序遍历图层, 遇到 followsShake == true 的连续区段就自动 saveGState +
//  translate, 离开该区段再 restore。于是每个图层只管画自己的东西,
//  不需要在绘制代码里手写 save/restore, 也不会因为漏写而让天气/大字跟着棋盘抖。
//
import AppKit

final class RenderPipeline {
    private(set) var layers: [RenderLayer] = []

    /// 注册一个图层 —— 新增特效唯一的接入点
    func register(_ layer: RenderLayer) { layers.append(layer) }

    /// 任意一层还在动, 主循环就得继续跑 (雨、动画、演员都靠这个)
    var isAnimating: Bool { layers.contains { $0.isAnimating } }

    /// 一行文字描述当前图层栈与活动状态, 便于调试
    var summary: String {
        layers.map { $0.isAnimating ? "\($0.name)*" : $0.name }.joined(separator: " → ")
    }

    func update(_ ctx: RenderContext) {
        for l in layers { l.update(ctx) }
    }

    func draw(_ ctx: RenderContext) {
        var inShakeGroup = false
        for l in layers {
            if l.followsShake != inShakeGroup {
                if l.followsShake {
                    NSGraphicsContext.saveGraphicsState()
                    if ctx.shakeX != 0 { ctx.cg?.translateBy(x: ctx.shakeX, y: 0) }
                    inShakeGroup = true
                } else {
                    NSGraphicsContext.restoreGraphicsState()
                    inShakeGroup = false
                }
            }
            l.draw(ctx)
        }
        if inShakeGroup { NSGraphicsContext.restoreGraphicsState() }
    }
}
