//
//  EngineBridge.swift
//  人机中国象棋 · 内置 JS 引擎桥 (JavaScriptCore)
//
//  本文件由 native/XiangqiApp.swift 拆分而来 (tools/split_xiangqi.py, P1 纯搬运)。
//  拆分过程只做位置搬迁, 未改动任何逻辑。
//
import AppKit
import AVFoundation
import JavaScriptCore
import CoreText

class EngineBridge {
    let ctx: JSContext
    init?() {
        guard let c = JSContext() else { return nil }
        c.exceptionHandler = { _, e in print("JS error:", e?.toString() ?? "?") }
        for f in ["xiangqi", "ai", "coach"] {
            guard let url = Bundle.main.url(forResource: f, withExtension: "js"),
                  let src = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            c.evaluateScript(src)
        }
        ctx = c
    }
    func call(_ path: [String], _ args: [Any]) -> JSValue? {
        var ref: JSValue? = ctx.globalObject
        for p in path { ref = ref?.objectForKeyedSubscript(p) }
        return ref?.call(withArguments: args)
    }
    func initialBoard() -> [Int] { boardFromJS(call(["Xiangqi", "initialBoard"], [])) }
    func legalMoves(_ b: [Int], _ color: String) -> [[String: Any]] {
        movesFromJS(call(["Xiangqi", "generateLegalMoves"], [b, color]))
    }
    func applyMove(_ b: [Int], _ m: [String: Any]) -> [Int]? {
        guard let r = call(["Xiangqi", "applyMove"], [b, m]) else { return nil }
        let a = boardFromJS(r); return a.isEmpty ? nil : a
    }
    func isInCheck(_ b: [Int], _ color: String) -> Bool {
        call(["Xiangqi", "isInCheck"], [b, color])?.toBool() ?? false
    }
    func boardToFen(_ b: [Int], _ color: String) -> String {
        call(["Xiangqi", "boardToFen"], [b, color])?.toString() ?? ""
    }
    func moveToNotation(_ b: [Int], _ m: [String: Any], _ color: String) -> String {
        call(["Xiangqi", "moveToNotation"], [b, m, color])?.toString() ?? ""
    }
    // coach
    func coachEvaluate(_ b: [Int]) -> Int {
        call(["Xiangqi", "coach", "evaluate"], [b])?.toNumber()?.intValue ?? 0
    }
    func coachHint(_ b: [Int], _ c: String, _ budget: Int) -> [String: Any]? {
        dictFromJS(call(["Xiangqi", "coach", "hint"], [b, c, budget]))
    }
    func coachThreats(_ b: [Int], _ c: String) -> (inCheck: Bool, pieces: [[String: Any]]) {
        guard let d = dictFromJS(call(["Xiangqi", "coach", "threats"], [b, c])) else { return (false, []) }
        return (d["inCheck"] as? Bool ?? false, d["pieces"] as? [[String: Any]] ?? [])
    }
    func coachCommentary(before: [Int], move: [String: Any], after: [Int], mover: String, ply: Int) -> [String: Any]? {
        dictFromJS(call(["Xiangqi", "coach", "commentary"], [before, move, after, mover, ply]))
    }
}

// MARK: - 后台搜索 (独立 JSContext, 不阻塞主线程)
