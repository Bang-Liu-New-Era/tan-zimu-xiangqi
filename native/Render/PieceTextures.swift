//
//  PieceTextures.swift
//  人机中国象棋 · 棋子贴图仓库
//
//  贴图资源不该由视图持有 —— 它是"资源", 不是"状态"。
//  抽成独立仓库后, 任何图层/渲染器都能直接取用, 不必绕回 BoardView。
//
import AppKit

enum PieceTextures {
    /// 棋子贴图 (Resources/pieces/<编码>.png, 例 r1.png 红帅 / b14.png 黑炮)。
    /// 任一棋子缺图时该子回退为程序化绘制, 不影响其他棋子。
    private static var cache: [Int: NSImage] = [:]
    private static var miss: Set<Int> = []

    static func image(_ p: Int) -> NSImage? {
        if let hit = cache[p] { return hit }
        if miss.contains(p) { return nil }
        let code = p <= 7 ? "r\(p)" : "b\(p)"
        for sub in ["pieces", nil] as [String?] {
            for ext in ["png", "jpg"] {
                if let u = Bundle.main.url(forResource: code, withExtension: ext, subdirectory: sub),
                   let img = NSImage(contentsOf: u), img.size.width > 10 {
                    cache[p] = img
                    return img
                }
            }
        }
        // 注意: 字典值为 Optional 时赋 nil 是「删除键」, 判"缺素材"必须另用 Set 记录
        miss.insert(p)
        return nil
    }
}
