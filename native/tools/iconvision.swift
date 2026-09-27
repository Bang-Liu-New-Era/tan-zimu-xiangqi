// iconvision.swift — 给「照片换 App 图标」流程做视觉定位与抠图。
//
// 输出两部分:
//   ① 抠图 PNG (Vision 前景分割, 保留主人物, 背景透明)
//   ② 人脸框写进一个文本文件, 形如 "x y w h" (左上角为原点的像素坐标)
//
// 用法: iconvision <照片> <抠图输出.png> <人脸框输出.txt>
//
// 为什么用人脸框而不是目测: 目测的裁剪框在不同照片上会偏, 而"脸高 × 1.78、中心在脸上方 0.2 脸高"
// 这条比例在多数半身人像照上都成立, 由人脸框推裁剪框才稳。
import Foundation
import Vision
import AppKit

let args = CommandLine.arguments
guard args.count >= 4 else { print("usage: iconvision <photo> <cut.png> <face.txt>"); exit(2) }
let srcPath = args[1], cutPath = args[2], facePath = args[3]

guard let img = NSImage(contentsOfFile: srcPath),
      let tiff = img.tiffRepresentation,
      let bmp = NSBitmapImageRep(data: tiff),
      let cg = bmp.cgImage else { print("load fail: \(srcPath)"); exit(1) }
let W = CGFloat(cg.width), H = CGFloat(cg.height)
let handler = VNImageRequestHandler(cgImage: cg, options: [:])

// ① 人脸
let faceReq = VNDetectFaceRectanglesRequest()
try? handler.perform([faceReq])
guard let face = faceReq.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) else {
    print("no face found"); exit(1)
}
let fb = face.boundingBox
let fx = fb.minX * W
let fy = (1 - fb.maxY) * H          // 转成左上原点
let fw = fb.width * W
let fh = fb.height * H
try! "\(Int(fx)) \(Int(fy)) \(Int(fw)) \(Int(fh))".write(toFile: facePath, atomically: true, encoding: .utf8)
print(String(format: "face: x=%.0f y=%.0f w=%.0f h=%.0f  (conf %.2f)", fx, fy, fw, fh, face.confidence))

// ② 抠图 (人像模式要用它把背景与主体分开)
let maskReq = VNGenerateForegroundInstanceMaskRequest()
do {
    try handler.perform([maskReq])
    guard let r = maskReq.results?.first else { print("no foreground mask"); exit(1) }
    let masked = try r.generateMaskedImage(ofInstances: r.allInstances, from: handler,
                                           croppedToInstancesExtent: false)
    let ci = CIImage(cvPixelBuffer: masked)
    guard let outCG = CIContext().createCGImage(ci, from: ci.extent) else { print("ci fail"); exit(1) }
    let rep = NSBitmapImageRep(cgImage: outCG)
    guard let data = rep.representation(using: .png, properties: [:]) else { print("png fail"); exit(1) }
    try data.write(to: URL(fileURLWithPath: cutPath))
    print("cutout: \(cutPath)  instances=\(r.allInstances.count)")
} catch {
    print("mask error: \(error)"); exit(1)
}
