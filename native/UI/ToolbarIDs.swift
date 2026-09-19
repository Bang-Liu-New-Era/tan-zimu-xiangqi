//
//  ToolbarIDs.swift
//  人机中国象棋 · 工具栏标识符
//
//  本文件由 native/XiangqiApp.swift 拆分而来 (tools/split_xiangqi.py, P1 纯搬运)。
//  拆分过程只做位置搬迁, 未改动任何逻辑。
//
import AppKit
import AVFoundation
import JavaScriptCore
import CoreText

extension NSToolbarItem.Identifier {
    static let newGame = NSToolbarItem.Identifier("xq.newGame")
    static let undo = NSToolbarItem.Identifier("xq.undo")
    static let resign = NSToolbarItem.Identifier("xq.resign")
    static let hint = NSToolbarItem.Identifier("xq.hint")
    static let simulate = NSToolbarItem.Identifier("xq.simulate")
    static let sound = NSToolbarItem.Identifier("xq.sound")
    static let side = NSToolbarItem.Identifier("xq.side")
    static let difficulty = NSToolbarItem.Identifier("xq.difficulty")
    static let engine = NSToolbarItem.Identifier("xq.engine")
    static let flex = NSToolbarItem.Identifier("xq.flex")
}
