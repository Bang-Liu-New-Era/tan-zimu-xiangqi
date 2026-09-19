//
//  PikafishEngine.swift
//  人机中国象棋 · Pikafish UCI 进程引擎
//
//  本文件由 native/XiangqiApp.swift 拆分而来 (tools/split_xiangqi.py, P1 纯搬运)。
//  拆分过程只做位置搬迁, 未改动任何逻辑。
//
import AppKit
import AVFoundation
import JavaScriptCore
import CoreText

class PikafishEngine {
    let path: String
    var process: Process?
    var inHandle: FileHandle?
    var outHandle: FileHandle?
    var readBuffer = ""
    var available = false
    var elo = 2000
    var movetime = 2500
    init?(path: String) {
        self.path = path
        start()
        if !available { return nil }
    }
    func start() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        let outPipe = Pipe(), inPipe = Pipe()
        p.standardOutput = outPipe; p.standardInput = inPipe
        do { try p.run() } catch { return }
        inHandle = inPipe.fileHandleForWriting
        outHandle = outPipe.fileHandleForReading
        process = p
        var got = false
        let grp = DispatchGroup(); grp.enter()
        outHandle?.readabilityHandler = { [weak self] handle in
            guard let self = self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let s = String(data: data, encoding: .utf8) { self.readBuffer += s }
            if self.readBuffer.contains("uciok") { got = true; self.readBuffer = ""; grp.leave() }
        }
        inHandle?.write(Data("uci\n".utf8))
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.5) { if !got { grp.leave() } }
        grp.wait()
        outHandle?.readabilityHandler = nil
        if got {
            let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("pikafish.nnue").path) {
                inHandle?.write(Data("setoption name EvalFile value pikafish.nnue\n".utf8))
            }
            available = true
        }
    }
    func setStrength(elo: Int, movetime: Int) {
        self.elo = elo; self.movetime = movetime
        inHandle?.write(Data("setoption name UCI_LimitStrength value true\n".utf8))
        inHandle?.write(Data("setoption name UCI_Elo value \(elo)\n".utf8))
    }
    func bestMove(fen: String, completion: @escaping (String?) -> Void) {
        guard let inH = inHandle, let outH = outHandle, available else { completion(nil); return }
        var result: String? = nil
        var done = false
        let grp = DispatchGroup(); grp.enter()
        readBuffer = ""
        outH.readabilityHandler = { [weak self] handle in
            guard let self = self else { return }
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if let s = String(data: data, encoding: .utf8) { self.readBuffer += s }
            while let r = self.readBuffer.range(of: "\n") {
                let line = String(self.readBuffer[..<r.lowerBound])
                self.readBuffer.removeSubrange(self.readBuffer.startIndex..<r.upperBound)
                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.hasPrefix("bestmove") {
                    let ps = t.components(separatedBy: " ")
                    if ps.count >= 2 { result = ps[1] }
                    if !done { done = true; grp.leave() }
                }
            }
        }
        inH.write(Data("position fen \(fen)\n".utf8))
        inH.write(Data("go movetime \(movetime)\n".utf8))
        DispatchQueue.global().asyncAfter(deadline: .now() + Double(movetime + 3000) / 1000.0) {
            if !done { done = true; grp.leave() }
        }
        grp.notify(queue: .main) { outH.readabilityHandler = nil; completion(result) }
    }
    func quit() { inHandle?.write(Data("quit\n".utf8)) }
}

// MARK: - 评估条
