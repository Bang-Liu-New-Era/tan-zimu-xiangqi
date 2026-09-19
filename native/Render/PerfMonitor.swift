//
//  PerfMonitor.swift
//  人机中国象棋 · 帧耗时探针
//
//  只在 XQ_PERF=1 时启用, 正常使用完全不介入 (零开销, 连 CA 调用都不多一次)。
//  每累计 N 帧打印一次「平均 / 最慢」的单帧绘制耗时 —— 用来给优化定量, 而不是靠感觉。
//
import Foundation
import QuartzCore

enum PerfMonitor {
    static let enabled = ProcessInfo.processInfo.environment["XQ_PERF"] != nil
    private static let windowSize = 120

    private static var sum: Double = 0
    private static var peak: Double = 0
    private static var count: Int = 0
    private static var start = CACurrentMediaTime()

    /// 在 BoardView.draw 前后调用, 记录一次绘制耗时 (秒)
    static func record(_ seconds: Double) {
        guard enabled else { return }
        sum += seconds
        if seconds > peak { peak = seconds }
        count += 1
        guard count >= windowSize else { return }
        let avgMs = sum / Double(count) * 1000
        let peakMs = peak * 1000
        let elapsed = CACurrentMediaTime() - start
        let fps = elapsed > 0 ? Double(count) / elapsed : 0
        FileHandle.standardError.write(
            String(format: "[perf] %d 帧  平均 %.2fms  最慢 %.2fms  实测 %.1f fps\n",
                   count, avgMs, peakMs, fps).data(using: .utf8)!)
        sum = 0; peak = 0; count = 0; start = CACurrentMediaTime()
    }
}
