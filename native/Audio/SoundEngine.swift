//
//  SoundEngine.swift
//  人机中国象棋 · 音效引擎
//
//  本文件由 native/XiangqiApp.swift 拆分而来 (tools/split_xiangqi.py, P1 纯搬运)。
//  拆分过程只做位置搬迁, 未改动任何逻辑。
//
import AppKit
import AVFoundation
import JavaScriptCore
import CoreText

final class SoundEngine {
    static let shared = SoundEngine()

    var sfxOn = true
    var voiceOn = true
    var sfxVolume: Float = 1.0

    /// 每类音效的变体文件 (随机取一个)
    private static let groups: [String: [String]] = [
        "move":    ["move_1", "move_2", "move_3", "move_4"],
        "lift":    ["lift_1", "lift_2"],
        "capture": ["capture_1", "capture_2", "capture_3"],
        "check":   ["check_1", "check_2", "check_3"],
        "click":   ["click"],
        "win":     ["win"],
        "lose":    ["lose"],
    ]
    private static let voiceFiles: [String: String] = [
        "chi": "voice_chi", "jiangjun": "voice_jiangjun",
        "juesha": "voice_juesha", "heqi": "voice_heqi",
    ]
    /// 每类的音量微调 (落子要清脆但不吵, 吃子强调, 将军厚重)
    private static let gains: [String: Float] = [
        "move": 0.85, "lift": 0.45, "capture": 1.0, "check": 0.95,
        "click": 0.5, "win": 0.85, "lose": 0.85,
    ]

    private var pools: [String: [AVAudioPlayer]] = [:]
    private var cursor: [String: Int] = [:]
    private var voicePlayer: AVAudioPlayer?
    private var lastVoiceTime: Double = 0

    /// 启动时预载, 避免第一次走子时卡顿
    func preload() {
        for (_, files) in SoundEngine.groups { for f in files { _ = players(f) } }
        for (_, f) in SoundEngine.voiceFiles { _ = voice(f) }
    }

    private func url(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "wav", subdirectory: "sounds")
    }

    /// 每个文件建 3 个播放器轮转, 保证快速连续触发时互不打断
    private func players(_ name: String) -> [AVAudioPlayer] {
        if let p = pools[name] { return p }
        guard let u = url(name) else { pools[name] = []; return [] }
        var list: [AVAudioPlayer] = []
        for _ in 0..<3 {
            if let p = try? AVAudioPlayer(contentsOf: u) {
                p.prepareToPlay(); p.enableRate = true; list.append(p)
            }
        }
        pools[name] = list
        return list
    }

    private func voice(_ name: String) -> AVAudioPlayer? {
        if let p = voicePlayer, p.url?.lastPathComponent == name + ".wav" { return p }
        guard let u = url(name), let p = try? AVAudioPlayer(contentsOf: u) else { return nil }
        p.prepareToPlay(); voicePlayer = p
        return p
    }

    /// 播放一类音效 (自动随机变体 + 音高微扰)
    func play(_ key: String, volume: Float = 1.0, jitter: Double = 0.05) {
        guard sfxOn, let files = SoundEngine.groups[key], let name = files.randomElement() else { return }
        let list = players(name)
        guard !list.isEmpty else { return }
        let i = (cursor[name] ?? 0) % list.count
        cursor[name] = i + 1
        let p = list[i]
        p.stop(); p.currentTime = 0
        p.rate = Float(1.0 + Double.random(in: -jitter...jitter))
        p.volume = min(1.0, volume * (SoundEngine.gains[key] ?? 1.0) * sfxVolume)
        p.play()
    }

    /// 人声播报。delay 用于让撞击声先落, 再出人声, 听感更自然。
    func speak(_ key: String, delay: Double = 0.0, volume: Float = 1.0) {
        guard voiceOn, let f = SoundEngine.voiceFiles[key] else { return }
        let fire = { [weak self] in
            guard let self = self, self.voiceOn, let p = self.voice(f) else { return }
            p.stop(); p.currentTime = 0; p.volume = min(1.0, volume); p.play()
            self.lastVoiceTime = CACurrentMediaTime()
        }
        if delay > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: fire) } else { fire() }
    }

    func stopVoice() { voicePlayer?.stop() }
}

// MARK: - 工具栏标识符
