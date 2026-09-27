//
//  BoardRenderer.swift
//  人机中国象棋 · 棋盘渲染
//
//  纯函数式: 贴图版 (优先) 与程序化版 (无贴图时的回退)。
//
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

enum BoardRenderer {
    /// 贴图版: 程序化石板边框 + 贴图网格面 (贴图网格线与棋盘坐标精确对齐)
    static func drawTextured(_ img: XImage, _ ctx: RenderContext) {
        let cell = ctx.cell, ox = ctx.ox, oy = ctx.oy
        let rim = cell * BOARD_RIM_CELLS
        let k = cell / TEX_CELL_PX
        let tw = img.size.width * k, th = img.size.height * k
        let gx = ox - TEX_INSET_PX * k, gy = oy - TEX_INSET_PX * k      // 贴图原点(网格坐标系)
        let plate = CGRect(x: gx - rim, y: gy - rim, width: tw + 2 * rim, height: th + 2 * rim)
        let rr = rim * 0.35
        // 投影
        xqSaveGState()
        xqSetShadow(blur: cell * 0.25, offsetY: -cell * 0.06, alpha: 0.38)
        XColor(crossRed: 0.62, green: 0.64, blue: 0.52, alpha: 1).setFill()
        XBezierPath(roundedRect: plate, cornerRadius: rr).fill()
        xqRestoreGState()
        // 倒角: 上/左受光, 下/右背光
        let bw = max(1, rim * 0.55)
        xqDefaultLineWidth = bw
        XColor(crossRed: 0.80, green: 0.82, blue: 0.72, alpha: 0.85).setStroke()
        XBezierPath.strokeLine(from: CGPoint(x: plate.minX + bw / 2, y: plate.maxY - bw / 2),
                                to: CGPoint(x: plate.maxX - bw / 2, y: plate.maxY - bw / 2))
        XBezierPath.strokeLine(from: CGPoint(x: plate.minX + bw / 2, y: plate.maxY - bw / 2),
                                to: CGPoint(x: plate.minX + bw / 2, y: plate.minY + bw / 2))
        XColor(crossRed: 0.42, green: 0.44, blue: 0.34, alpha: 0.7).setStroke()
        XBezierPath.strokeLine(from: CGPoint(x: plate.minX + bw / 2, y: plate.minY + bw / 2),
                                to: CGPoint(x: plate.maxX - bw / 2, y: plate.minY + bw / 2))
        XBezierPath.strokeLine(from: CGPoint(x: plate.maxX - bw / 2, y: plate.minY + bw / 2),
                                to: CGPoint(x: plate.maxX - bw / 2, y: plate.maxY - bw / 2))
        // 贴图
        let face = CGRect(x: gx, y: gy, width: tw, height: th)
        xqSaveGState()
        XBezierPath(rect: face).addClip()
        xqSetImageInterpolation(.high)
        if !ctx.scene.flipBoard {   // 我执黑(黑方在下方): 贴图整体旋转 180°
            let c = currentCGContext()
            c?.translateBy(x: face.midX, y: face.midY)
            c?.rotate(by: .pi)
            c?.translateBy(x: -face.midX, y: -face.midY)
        }
        xqDrawImage(img, in: face, alpha: 1)
        xqRestoreGState()
        // 网格外框凹槽
        XColor(crossRed: 0.30, green: 0.32, blue: 0.24, alpha: 0.85).setStroke()
        xqDefaultLineWidth = max(1, cell * 0.018)
        XBezierPath.stroke(face)
    }

    /// 回退版: 纯程序化棋盘 (无贴图时)
    static func drawProcedural(_ ctx: RenderContext) {
        let cell = ctx.cell, ox = ctx.ox, oy = ctx.oy
        let bw = ctx.boardW, bh = ctx.boardH
        XColor(crossRed: 0.96, green: 0.80, blue: 0.55, alpha: 1).setFill()
        XBezierPath(roundedRect: CGRect(x: ox - cell * 0.25, y: oy - cell * 0.25,
                                         width: bw + cell * 0.5, height: bh + cell * 0.5),
                     cornerRadius: 8).fill()
        XColor(crossRed: 0.35, green: 0.22, blue: 0.1, alpha: 1).setStroke()
        xqDefaultLineWidth = 1.2
        for r in 0...9 {
            let y = oy + cell * CGFloat(r)
            XBezierPath.strokeLine(from: CGPoint(x: ox, y: y), to: CGPoint(x: ox + bw, y: y))
        }
        for c in 0...8 {
            let x = ox + cell * CGFloat(c)
            if c == 0 || c == 8 {
                XBezierPath.strokeLine(from: CGPoint(x: x, y: oy), to: CGPoint(x: x, y: oy + bh))
            } else {
                XBezierPath.strokeLine(from: CGPoint(x: x, y: oy), to: CGPoint(x: x, y: oy + cell * 4))
                XBezierPath.strokeLine(from: CGPoint(x: x, y: oy + cell * 5), to: CGPoint(x: x, y: oy + bh))
            }
        }
        func diag(_ r1: Int, _ c1: Int, _ r2: Int, _ c2: Int) {
            let (dr1, dc1) = ctx.dispRC(r1 * 9 + c1), (dr2, dc2) = ctx.dispRC(r2 * 9 + c2)
            XBezierPath.strokeLine(from: CGPoint(x: ox + cell * CGFloat(dc1), y: oy + cell * CGFloat(dr1)),
                                    to: CGPoint(x: ox + cell * CGFloat(dc2), y: oy + cell * CGFloat(dr2)))
        }
        diag(0, 3, 2, 5); diag(0, 5, 2, 3); diag(7, 3, 9, 5); diag(7, 5, 9, 3)
        let rattr: [NSAttributedString.Key: Any] = [
            .font: XFont.systemFont(ofSize: cell * 0.5),
            .foregroundColor: XColor(crossRed: 0.4, green: 0.25, blue: 0.1, alpha: 0.5),
        ]
        // 楚河/漢界 按下方执子方的视角摆放 (红在下→楚河居左; 黑在下→漢界居左)
        let (leftTxt, rightTxt) = ctx.scene.flipBoard ? ("楚 河", "漢 界") : ("漢 界", "楚 河")
        NSAttributedString(string: leftTxt, attributes: rattr)
            .xqDraw(at: CGPoint(x: ox + cell * 1.1, y: oy + cell * 4.3))
        NSAttributedString(string: rightTxt, attributes: rattr)
            .xqDraw(at: CGPoint(x: ox + cell * 5.0, y: oy + cell * 4.3))
    }
}

// MARK: - 图层

/// 棋盘石板层: 有贴图用贴图, 没有则程序化绘制。跟随震屏。
///
/// 石板每帧重画 (圆角石板 + 高斯模糊投影 + 倒角 + 贴图缩放 + 外框), 看起来很贵,
/// 但实测**不该缓存**: 把结果先画进整屏离屏位图再回贴, 位图往返的内存搬运
/// (1458×1504 × 4B ≈ 8.8MB/帧) 比重新绘制还贵 —— 同一份二进制 A/B 实测
/// 0.99ms/帧 (缓存) vs 0.94ms/帧 (直绘), 缓存反而慢 5%; 而且回贴会引入一次
/// 颜色空间转换, 无法做到逐像素相同 (实测 0.2% 像素差 ≤2/255)。
/// 结论: 这个视图尺寸下 CoreGraphics 直绘不是瓶颈 (60fps 预算 16.7ms, 实际约 1ms),
/// 真要再上一个量级的画面, 应该走 GPU (SpriteKit/Metal) 而不是本地缓存。
final class BoardPlateLayer: RenderLayer {
    let name = "board"
    var followsShake: Bool { true }

    /// 棋盘贴图 (Resources/boards/board.jpg|png)。缺失时回退为程序化绘制。
    private lazy var image: XImage? = {
        for ext in ["jpg", "jpeg", "png"] {
            if let u = Bundle.main.url(forResource: "board", withExtension: ext, subdirectory: "boards"),
               let img = xqImage(contentsOf: u), img.size.width > 10 { return img }
            if let u = Bundle.main.url(forResource: "board", withExtension: ext),
               let img = xqImage(contentsOf: u), img.size.width > 10 { return img }
        }
        return nil
    }()

    func draw(_ ctx: RenderContext) {
        if let tex = image { BoardRenderer.drawTextured(tex, ctx) }
        else { BoardRenderer.drawProcedural(ctx) }
    }
}
