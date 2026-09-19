// pxdiff.swift — 两张 PNG 的逐像素比对 (回归验证用)
// 用法: swift pxdiff.swift a.png b.png [--tolerance N]
// 输出: 完全相同 / 差异像素数 / 最大通道差 / 平均通道差 / 差异包围盒
import AppKit
import Foundation

func load(_ p: String) -> (w: Int, h: Int, px: [UInt8])? {
    guard let img = NSImage(contentsOfFile: p),
          let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    let w = rep.pixelsWide, h = rep.pixelsHigh
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    guard let cg = rep.cgImage else { return nil }
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    return (w, h, buf)
}

let a = CommandLine.arguments
guard a.count >= 3 else { print("用法: pxdiff a.png b.png [--tolerance N]"); exit(2) }
let tol = a.count >= 5 && a[3] == "--tolerance" ? (Int(a[4]) ?? 0) : 0

guard let A = load(a[1]) else { print("无法读取 \(a[1])"); exit(2) }
guard let B = load(a[2]) else { print("无法读取 \(a[2])"); exit(2) }

let nameA = (a[1] as NSString).lastPathComponent
let nameB = (a[2] as NSString).lastPathComponent

if A.w != B.w || A.h != B.h {
    print("✗ 尺寸不同: \(nameA) \(A.w)×\(A.h)  vs  \(nameB) \(B.w)×\(B.h)")
    exit(1)
}

var diffCount = 0, maxDelta = 0, sumDelta = 0
var minX = A.w, minY = A.h, maxX = -1, maxY = -1
for y in 0..<A.h {
    for x in 0..<A.w {
        let i = (y * A.w + x) * 4
        var d = 0
        for c in 0..<4 {
            let v = abs(Int(A.px[i + c]) - Int(B.px[i + c]))
            if v > d { d = v }
        }
        sumDelta += d
        if d > tol {
            diffCount += 1
            if d > maxDelta { maxDelta = d }
            if x < minX { minX = x }; if x > maxX { maxX = x }
            if y < minY { minY = y }; if y > maxY { maxY = y }
        }
    }
}
let total = A.w * A.h
let pct = Double(diffCount) / Double(total) * 100
let mean = Double(sumDelta) / Double(total)

if diffCount == 0 {
    print("✓ 逐像素完全相同  \(nameA) == \(nameB)  (\(A.w)×\(A.h), 容差 \(tol))")
    exit(0)
}
print("差异  \(nameA) vs \(nameB)")
print("  尺寸        \(A.w)×\(A.h)")
print("  差异像素    \(diffCount) / \(total)  (\(String(format: "%.4f", pct))%)")
print("  最大通道差  \(maxDelta)")
print("  平均通道差  \(String(format: "%.6f", mean))")
print("  差异包围盒  x \(minX)…\(maxX)  y \(minY)…\(maxY)")
exit(diffCount > 0 && tol == 0 ? 1 : 0)
