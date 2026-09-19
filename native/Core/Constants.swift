//
//  Constants.swift
//  人机中国象棋 · 全局常量 / Difficulty / 坐标工具 / JS 取值转换
//
//  本文件由 native/XiangqiApp.swift 拆分而来 (tools/split_xiangqi.py, P1 纯搬运)。
//  拆分过程只做位置搬迁, 未改动任何逻辑。
//
import AppKit
import AVFoundation
import JavaScriptCore
import CoreText


// MARK: - 常量
let RED = "r"
let BLACK = "b"
let PIECE_CHARS: [Int: String] = [
    1: "帅", 2: "仕", 3: "相", 4: "马", 5: "车", 6: "炮", 7: "兵",
    9: "将", 10: "士", 11: "象", 12: "马", 13: "车", 14: "炮", 15: "卒",
]

struct Difficulty {
    let id: String
    let label: String
    let embeddedBudget: Int   // 内置引擎时间预算(ms)
    let pikaMovetime: Int      // Pikafish 思考时间(ms)
    let pikaElo: Int          // Pikafish 限制强度
}
let DIFFICULTIES = [
    Difficulty(id: "easy",   label: "入门", embeddedBudget: 350,  pikaMovetime: 250,  pikaElo: 1000),
    Difficulty(id: "medium", label: "进阶", embeddedBudget: 1000, pikaMovetime: 900,  pikaElo: 1500),
    Difficulty(id: "hard",   label: "高手", embeddedBudget: 2000, pikaMovetime: 2500, pikaElo: 2000),
]

func rc(_ i: Int) -> (Int, Int) { (i / 9, i % 9) }
func opp(_ c: String) -> String { c == RED ? BLACK : RED }

// 棋盘贴图几何: 贴图内每格 220px, 最外网格线距贴图边缘 7px, 程序化石板边框宽 0.30 格
let TEX_CELL_PX: CGFloat = 220
let TEX_INSET_PX: CGFloat = 7
let BOARD_RIM_CELLS: CGFloat = 0.30
let BOARD_EDGE_CELLS: CGFloat = BOARD_RIM_CELLS + TEX_INSET_PX / TEX_CELL_PX

// 棋子贴图几何: 贴图是正方形, 棋子直径占画幅 PIECE_TEX_RATIO, 显示直径 = 0.84 格
let PIECE_TEX_RATIO: CGFloat = 0.897
let PIECE_TEX_SPAN: CGFloat = 0.84 / PIECE_TEX_RATIO

// MARK: - JS 转换辅助
func boardFromJS(_ v: JSValue?) -> [Int] {
    guard let arr = v?.toArray() else { return [] }
    return arr.compactMap { ($0 as? NSNumber)?.intValue }
}
func movesFromJS(_ v: JSValue?) -> [[String: Any]] {
    guard let arr = v?.toArray() else { return [] }
    return arr.compactMap { $0 as? [String: Any] }
}
func dictFromJS(_ v: JSValue?) -> [String: Any]? {
    guard let d = v?.toDictionary() else { return nil }
    return d as? [String: Any]
}

// MARK: - 引擎桥 (JavaScriptCore)
