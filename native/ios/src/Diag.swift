//
//  Diag.swift  (临时诊断, 验证完即删)
//
#if canImport(UIKit)
import UIKit

func diag(_ s: String) {
    guard ProcessInfo.processInfo.environment["XQ_IOS_TEST"] != nil else { return }
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let url = dir.appendingPathComponent("diag.log")
    let line = "\(Date().timeIntervalSince1970) \(s)\n"
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
    } else {
        try? Data(line.utf8).write(to: url)
    }
}
#endif
