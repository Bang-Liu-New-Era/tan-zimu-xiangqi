//
//  BackgroundEngine.swift
//  人机中国象棋 · 后台线程引擎包装
//
//  本文件由 native/XiangqiApp.swift 拆分而来 (tools/split_xiangqi.py, P1 纯搬运)。
//  拆分过程只做位置搬迁, 未改动任何逻辑。
//
import AppKit
import AVFoundation
import JavaScriptCore
import CoreText

class BackgroundEngine {
    let queue = DispatchQueue(label: "xq.bg")
    var ctx: JSContext?
    func search(board: [Int], turn: String, budget: Int, depth: Int,
                completion: @escaping ([String: Any]?) -> Void) {
        queue.async {
            if self.ctx == nil {
                guard let c = JSContext() else { DispatchQueue.main.async { completion(nil) }; return }
                c.exceptionHandler = { _, e in print("bg JS err:", e?.toString() ?? "?") }
                for f in ["xiangqi", "ai", "coach"] {
                    guard let url = Bundle.main.url(forResource: f, withExtension: "js"),
                          let src = try? String(contentsOf: url, encoding: .utf8) else {
                        DispatchQueue.main.async { completion(nil) }; return
                    }
                    c.evaluateScript(src)
                }
                self.ctx = c
            }
            guard let res = self.ctx?.objectForKeyedSubscript("XiangqiAI")?
                    .objectForKeyedSubscript("search")?
                    .call(withArguments: [board, turn, budget, depth]) else {
                DispatchQueue.main.async { completion(nil) }; return
            }
            guard let from = res.objectForKeyedSubscript("from")?.toNumber()?.intValue,
                  let to = res.objectForKeyedSubscript("to")?.toNumber()?.intValue else {
                DispatchQueue.main.async { completion(nil) }; return
            }
            DispatchQueue.main.async { completion(["from": from, "to": to]) }
        }
    }
}

// MARK: - Pikafish 引擎 (UCI 进程)
