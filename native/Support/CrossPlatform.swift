//
//  CrossPlatform.swift
//  人机中国象棋 · macOS / iOS 共享代码的跨平台垫片
//
//  ── 为什么需要这一层 ──
//  渲染/规则/引擎层 90% 的代码用的是 CoreGraphics + Foundation, 两个平台都有;
//  只有少量类型名不同 (NSColor/UIColor, NSImage/UIImage, NSBezierPath/UIBezierPath)。
//  与其在每个文件里撒 #if os(iOS), 不如统一换成 XColor / XImage / XBezierPath 这些
//  「跨平台名字」, 平台差异全部收拢到本文件 —— 共享代码保持干净, 平台特定行为只有一处可查。
//
//  ⚠️ 坐标系: iOS 的 UIKit 上下文是 y 向下, 而整套渲染数学按 y 向上写。
//     iOS 的 BoardView 在 draw() 开头把上下文整体翻成 y 向上, 之后所有
//     图层代码与 macOS 完全同构; 只有「画文本」例外 —— 文本在翻转上下文里
//     会倒置, 必须经 xqDraw(at:) / xqDrawCTLine 做局部反翻。
//
#if canImport(AppKit)
import AppKit

public typealias XColor = NSColor
public typealias XImage = NSImage
public typealias XFont = NSFont
public typealias XBezierPath = NSBezierPath

extension NSBezierPath {
    /// 统一圆角构造 (macOS 原生是 xRadius/yRadius 两个参数, iOS 是 cornerRadius 一个)
    convenience init(roundedRect r: CGRect, cornerRadius c: CGFloat) {
        self.init(roundedRect: r, xRadius: c, yRadius: c)
    }
}

#else
import UIKit

public typealias XColor = UIColor
public typealias XImage = UIImage
public typealias XFont = UIFont
public typealias XBezierPath = UIBezierPath

extension UIBezierPath {
    /// macOS 的类方法补齐 (UIBezierPath 只有实例 fill/stroke)
    static func fill(_ rect: CGRect) { UIBezierPath(rect: rect).fill() }
    static func stroke(_ rect: CGRect) { UIBezierPath(rect: rect).stroke() }
    static func strokeLine(from: CGPoint, to: CGPoint) {
        let p = UIBezierPath()
        p.move(to: from); p.addLine(to: to); p.stroke()
    }
    // 注: UIBezierPath 原生就有 init(roundedRect:cornerRadius:), 不要再包一层 —— 会无限递归
}

extension UIView {
    /// NSView.setNeedsDisplay(_ rect:) 的补位 —— 共享代码里到处都是
    /// `boardView.setNeedsDisplay(boardView.bounds)`, iOS 上等价于整视图重画。
    func setNeedsDisplay(_ rect: CGRect) { setNeedsDisplay() }
}
#endif

// MARK: - 颜色 (calibrated* 是 AppKit 专有名字, iOS 换 sRGB 版本即可 —— 棋盘色都是手调的, 视觉无差)

extension XColor {
    convenience init(crossRed r: CGFloat, green g: CGFloat, blue b: CGFloat, alpha a: CGFloat) {
        #if canImport(AppKit)
        self.init(calibratedRed: r, green: g, blue: b, alpha: a)
        #else
        self.init(red: r, green: g, blue: b, alpha: a)
        #endif
    }
    convenience init(crossWhite w: CGFloat, alpha a: CGFloat) {
        #if canImport(AppKit)
        self.init(calibratedWhite: w, alpha: a)
        #else
        self.init(white: w, alpha: a)
        #endif
    }
    convenience init(crossHue h: CGFloat, saturation s: CGFloat, brightness b: CGFloat, alpha a: CGFloat) {
        #if canImport(AppKit)
        self.init(calibratedHue: h, saturation: s, brightness: b, alpha: a)
        #else
        self.init(hue: h, saturation: s, brightness: b, alpha: a)
        #endif
    }
}

// MARK: - 图形上下文

/// 当前 CGContext。macOS 走 NSGraphicsContext.current; iOS 在 draw() 里走 UIGraphicsGetCurrentContext。
func currentCGContext() -> CGContext? {
    #if canImport(AppKit)
    return NSGraphicsContext.current?.cgContext
    #else
    return UIGraphicsGetCurrentContext()
    #endif
}

/// 对应 NSGraphicsContext.saveGraphicsState() (iOS 没有这个类, 直接存 CG 状态)
func xqSaveGState() { currentCGContext()?.saveGState() }
func xqRestoreGState() { currentCGContext()?.restoreGState() }

/// 对应 NSGraphicsContext.current?.imageInterpolation = .high
func xqSetImageInterpolation(_ q: CGInterpolationQuality) {
    #if canImport(AppKit)
    NSGraphicsContext.current?.imageInterpolation = .high
    #else
    currentCGContext()?.interpolationQuality = q
    #endif
}

/// 画布默认线宽。macOS 是 NSBezierPath.defaultLineWidth(全局量, 不随图形状态存取);
/// iOS 是 CGContext.lineWidth(随 save/restore 存取)。共享代码都是在描线前临时设, 语义差异无碍。
var xqDefaultLineWidth: CGFloat {
    get {
        #if canImport(AppKit)
        return NSBezierPath.defaultLineWidth
        #else
        return _xqDefaultLineWidth
        #endif
    }
    set {
        #if canImport(AppKit)
        NSBezierPath.defaultLineWidth = newValue
        #else
        _xqDefaultLineWidth = newValue
        currentCGContext()?.setLineWidth(newValue)
        #endif
    }
}
#if canImport(UIKit)
private var _xqDefaultLineWidth: CGFloat = 1
#endif
/// 石板投影: macOS 用 NSShadow().set() 影响后续填充; iOS 用 CGContext.setShadow。
/// offsetY 为负 = 影子在下方 (两个平台在 y 向上坐标系里语义一致)。
func xqSetShadow(blur: CGFloat, offsetY: CGFloat, alpha: CGFloat) {
    #if canImport(AppKit)
    let sh = NSShadow()
    sh.shadowBlurRadius = blur
    sh.shadowOffset = CGSize(width: 0, height: offsetY)
    sh.shadowColor = NSColor(calibratedWhite: 0, alpha: alpha)
    sh.set()
    #else
    if let cg = currentCGContext() {
        let space = CGColorSpaceCreateDeviceRGB()
        let col = CGColor(colorSpace: space, components: [0, 0, 0, alpha])
        cg.setShadow(offset: CGSize(width: 0, height: offsetY), blur: blur, color: col)
    }
    #endif
}

// MARK: - 图片

/// 从 Bundle 资源加载图片 (NSImage(contentsOf:) / UIImage(contentsOfFile:))
func xqImage(contentsOf u: URL) -> XImage? {
    #if canImport(AppKit)
    return NSImage(contentsOf: u)
    #else
    return UIImage(contentsOfFile: u.path)
    #endif
}

/// 画图片: 在「y 向上」的坐标系里把图片正向画进 rect。
/// macOS: NSImage.draw(in:from:operation:fraction:)。
/// iOS: UIImage.draw 自带 UIKit 翻转, 在我们手动翻成 y 向上的上下文里会倒置,
///       所以改走 CGImage 直绘 (它严格遵循 CTM, 与 macOS 行为一致)。
func xqDrawImage(_ img: XImage, in rect: CGRect, alpha: CGFloat = 1) {
    #if canImport(AppKit)
    img.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
    #else
    if let cg = currentCGContext(), let gi = img.cgImage {
        cg.draw(gi, in: rect)
    }
    #endif
}

// MARK: - 文本 (翻转上下文里的文本必须局部反翻, 否则字是倒的)

extension NSAttributedString {
    /// 在 y 向上坐标系里以 p 为「文本盒左上角」绘制单行文本。
    func xqDraw(at p: CGPoint) {
        #if canImport(AppKit)
        draw(at: p)
        #else
        if let cg = currentCGContext() {
            cg.saveGState()
            cg.translateBy(x: p.x, y: p.y)
            cg.scaleBy(x: 1, y: -1)          // 局部翻回 y 向下, UIKit 的文本绘制才是正的
            draw(at: .zero)
            cg.restoreGState()
        }
        #endif
    }
}
