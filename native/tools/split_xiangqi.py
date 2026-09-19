#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""split_xiangqi.py — 把单文件 XiangqiApp.swift 按顶层声明切成多文件骨架 (P1 纯搬运)。

设计要点
--------
切分是 **按源码行号连续分段** 的: 每个目标文件拿到的是一段(或多段)连续行区间,
拼起来必须与原文一字不差。因此本脚本同时是 **执行器** 和 **验证器**:

    python3 tools/split_xiangqi.py --plan      # 打印切分计划(不落盘)
    python3 tools/split_xiangqi.py --write     # 执行切分, 并写 manifest
    python3 tools/split_xiangqi.py --verify    # 按 manifest 重新拼接, 与原文逐字节比对

--verify 通过 = "纯搬运, 未改一行逻辑" 的硬证据。
"""

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
NATIVE = os.path.dirname(HERE)
# 切分完成后 native/XiangqiApp.swift 就不再存在, 原始文件归档到 tools/archive/ 下
# (扩展名 .orig 而不是 .swift, 免得被 build_app.sh 的 find 扫进去造成符号重复)。
SRC_CANDIDATES = [
    os.path.join(NATIVE, "XiangqiApp.swift"),
    os.path.join(HERE, "archive", "XiangqiApp.swift.orig"),
]
MANIFEST = os.path.join(HERE, "split_manifest.json")

# 原文 1-7 行是文件头注释 + import, 由每个新文件各自生成, 不参与分段。
HEADER_LINES = 7

# (起始行, 目标文件, 该段说明) —— 起始行按原文顶层声明/注释块的行号, 必须递增。
ANCHORS = [
    (8,    "Core/Constants.swift",              "全局常量 / Difficulty / 坐标工具 / JS 取值转换"),
    (58,   "Core/Engine/EngineBridge.swift",    "内置 JS 引擎桥 (JavaScriptCore)"),
    (109,  "Core/Engine/BackgroundEngine.swift","后台线程引擎包装"),
    (142,  "Core/Engine/PikafishEngine.swift",  "Pikafish UCI 进程引擎"),
    (224,  "UI/EvalBarView.swift",              "形势评估条"),
    (245,  "UI/CoachPanel.swift",               "教学侧栏"),
    (288,  "UI/BoardView.swift",                "棋盘视图 (待 P1b 再按职责细分)"),
    (1138, "FX/Trajectory.swift",               "轨迹引擎: Ease + Trajectory"),
    (1219, "Core/Rng.swift",                    "确定性随机数发生器"),
    (1230, "FX/CrackForge.swift",               "裂痕: Crack + CrackForge"),
    (1282, "FX/WeatherLayer.swift",             "天气: RainDrop / Splash / Weather"),
    (1463, "FX/ActorLayer.swift",               "屏幕演员: SpriteSheet / ActorAssets / HorseArt / Actor"),
    (1599, "UI/Sim/SimMove.swift",              "模拟模式: 走子记录"),
    (1612, "UI/Sim/SimPanel.swift",             "模拟模式: 控制面板"),
    (1720, "UI/Sim/SimOverlayView.swift",       "模拟模式: 暗黑遮罩"),
    (1747, "App/AppDelegate.swift",             "应用委托 (待 P1b 再按职责细分)"),
    (2442, "Audio/SoundEngine.swift",           "音效引擎"),
    (2534, "UI/ToolbarIDs.swift",               "工具栏标识符"),
    (2546, "App/main.swift",                    "程序入口 (顶层语句只能在这一个文件里)"),
    (2556, "UI/MenuBuilder.swift",              "主菜单构建"),
]

FILE_HEADER = """//
//  {name}
//  人机中国象棋 · {desc}
//
//  本文件由 native/XiangqiApp.swift 拆分而来 (tools/split_xiangqi.py, P1 纯搬运)。
//  拆分过程只做位置搬迁, 未改动任何逻辑。
//
import AppKit
import AVFoundation
import JavaScriptCore
import CoreText

"""


def read_source():
    for c in SRC_CANDIDATES:
        if os.path.isfile(c):
            with open(c, "r", encoding="utf-8") as f:
                return f.read().split("\n")
    sys.exit("找不到源文件, 试过:\n  " + "\n  ".join(SRC_CANDIDATES))


def brace_depths(lines):
    """逐行计算「进入该行之前」的花括号深度。

    只认代码里的 {}, 跳过 // 行注释、/* */ 块注释、字符串字面量(含转义)。
    这是切分点的安全闸: 锚点必须落在深度 0 的行上, 否则说明切到了某个声明的
    肚子中间 —— 文件能拼回原样, 但语义已被劈开 (上一次 main.swift 切走
    extension 的收尾大括号就是这个错)。
    """
    depths = []
    depth = 0
    in_block_comment = False
    for raw in lines:
        depths.append(depth)
        i, n = 0, len(raw)
        in_str = False
        while i < n:
            ch = raw[i]
            nxt = raw[i + 1] if i + 1 < n else ""
            if in_block_comment:
                if ch == "*" and nxt == "/":
                    in_block_comment = False
                    i += 2
                    continue
                i += 1
                continue
            if in_str:
                if ch == "\\":
                    i += 2
                    continue
                if ch == '"':
                    in_str = False
                i += 1
                continue
            if ch == "/" and nxt == "/":
                break                      # 行注释, 本行剩余部分忽略
            if ch == "/" and nxt == "*":
                in_block_comment = True
                i += 2
                continue
            if ch == '"':
                in_str = True
                i += 1
                continue
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
            i += 1
    return depths


def check_boundaries(lines, anchors):
    """每个锚点行必须是「深度 0」的整行声明起点。"""
    depths = brace_depths(lines)
    bad = []
    for start, path, _desc in anchors:
        d = depths[start - 1]
        if d != 0:
            bad.append((start, path, d))
    if bad:
        print("✗ 锚点落在声明内部 (花括号深度非 0), 切分会把某段声明劈成两半:")
        for start, path, d in bad:
            print("    第 %d 行  深度 %d  ->  %s" % (start, d, path))
            print("      原文: %s" % lines[start - 1].rstrip()[:90])
            # 往后找最近的深度 0 行, 给出建议锚点
            for k in range(start + 1, min(len(lines), start + 200) + 1):
                if depths[k - 1] == 0:
                    print("      建议锚点改到深度 0 的下一行: %d  (%s)"
                          % (k, lines[k - 1].rstrip()[:70] or "(空行)"))
                    break
        return False
    print("✓ 全部 %d 个锚点都落在深度 0 的声明边界上" % len(anchors))
    return True


def build_regions(lines):
    """把 ANCHORS 转成连续行区间列表。返回 [(path, desc, start, end)] (end 为开区间)。"""
    regions = []
    for i, (start, path, desc) in enumerate(ANCHORS):
        end = ANCHORS[i + 1][0] if i + 1 < len(ANCHORS) else len(lines) + 1
        regions.append((path, desc, start, end))
    # 合法性检查
    prev = HEADER_LINES
    for path, desc, start, end in regions:
        if start <= prev:
            sys.exit("锚点行号未严格递增: %s @%d (上一段结束于 %d)" % (path, start, prev))
        if end <= start:
            sys.exit("空区间: %s @%d..%d" % (path, start, end))
        prev = start
    return regions


def group_by_file(regions):
    """同一目标文件的多段合并。Swift 里同文件内声明顺序无关, 但保持原顺序更好读。"""
    order, chunk = [], {}
    for path, desc, start, end in regions:
        if path not in chunk:
            order.append(path)
            chunk[path] = {"desc": desc, "ranges": []}
        chunk[path]["ranges"].append([start, end])
    return order, chunk


def do_plan(lines, regions):
    order, chunk = group_by_file(regions)
    total = 0
    print("源: %s  (%d 行)" % (SRC_CANDIDATES[0] if os.path.isfile(SRC_CANDIDATES[0])
                              else SRC_CANDIDATES[1], len(lines)))
    print("头 %d 行(注释+import) 由每个新文件各自生成, 不参与分段。\n" % HEADER_LINES)
    print("%-38s %8s %s" % ("目标文件", "行数", "原文行区间"))
    print("-" * 96)
    for path in order:
        info = chunk[path]
        n = sum(e - s for s, e in info["ranges"])
        total += n
        rng = ", ".join("%d-%d" % (s, e - 1) for s, e in info["ranges"])
        print("%-38s %8d %s" % (path, n, rng))
    print("-" * 96)
    print("%-38s %8d" % ("合计 (%d 个文件)" % len(order), total))
    print("\n期望行数: %d  实际: %d  %s"
          % (len(lines) - HEADER_LINES, total,
             "✓ 无遗漏无重叠" if total == len(lines) - HEADER_LINES else "✗ 不匹配!"))


def do_write(lines, regions):
    order, chunk = group_by_file(regions)
    written = []
    for path in order:
        info = chunk[path]
        parts = []
        for start, end in info["ranges"]:
            parts.append("\n".join(lines[start - 1:end - 1]))
        body = "\n".join(parts)
        text = FILE_HEADER.format(name=os.path.basename(path), desc=info["desc"]) + body
        if not text.endswith("\n"):
            text += "\n"
        full = os.path.join(NATIVE, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as f:
            f.write(text)
        written.append(path)
        print("  ✓ %-38s %6d 字节" % (path, len(text.encode("utf-8"))))

    man = {
        "source": "XiangqiApp.swift",
        "headerLines": HEADER_LINES,
        "files": [{"path": p, "desc": chunk[p]["desc"], "ranges": chunk[p]["ranges"]}
                  for p in order],
    }
    with open(MANIFEST, "w", encoding="utf-8") as f:
        json.dump(man, f, ensure_ascii=False, indent=2)
    print("\n已写 %d 个文件, manifest -> %s" % (len(written), MANIFEST))


def do_verify(lines):
    """按 manifest 把新文件的正文重新拼回来, 与原文逐字节比对。"""
    if not os.path.isfile(MANIFEST):
        sys.exit("缺少 manifest, 先跑 --write")
    with open(MANIFEST, "r", encoding="utf-8") as f:
        man = json.load(f)

    pieces = []
    for entry in man["files"]:
        path = os.path.join(NATIVE, entry["path"])
        if not os.path.isfile(path):
            sys.exit("✗ 缺少文件: %s" % entry["path"])
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
        body = strip_header(text)
        # 按 ranges 反向切出各段, 逐段与原文对应行比对 —— 这样能直接指出哪一段被改动了
        cursor = 0
        for start, end in entry["ranges"]:
            want = "\n".join(lines[start - 1:end - 1])
            got = body[cursor:cursor + len(want)]
            if got != want:
                print("✗ 内容被改动: %s  (原文 %d-%d 行)" % (entry["path"], start, end - 1))
                for i, (a, b) in enumerate(zip(want.split("\n"), got.split("\n"))):
                    if a != b:
                        print("    首个差异在第 %d 行:" % (start + i))
                        print("      原文: %r" % a)
                        print("      新文: %r" % b)
                        break
                else:
                    print("    (长度不同: 原文 %d 字符 / 新文 %d 字符)" % (len(want), len(got)))
                return 1
            cursor += len(want)
        pieces.append("".join(body))

    if len(pieces) != len(man["files"]):
        sys.exit("✗ 文件数不符")

    # 每一段已逐行比对通过 => 纯搬运成立。再核对总行数没有丢失。
    expect = "\n".join(lines[HEADER_LINES:])
    covered = 0
    for entry in man["files"]:
        covered += sum(e - s for s, e in entry["ranges"])
    got_lines = covered

    print("✓ 全部 %d 个文件的 %d 个分段均与原文逐行一致"
          % (len(man["files"]), sum(len(e["ranges"]) for e in man["files"])))
    print("  覆盖原文 %d 行 / 原文总行 %d (头 %d 行由各文件头替代)"
          % (got_lines, len(lines), HEADER_LINES))
    if got_lines != len(lines) - HEADER_LINES:
        print("✗ 行数不匹配, 可能有段落遗漏")
        return 1
    print("  => 纯搬运验证通过: 未改动任何一行逻辑")
    return 0


# 生成的文件头占几行 —— 固定值, 按模板算出来。
# 注意: 不能用「跳过开头所有 // 与空行」来裁头, 正文自身可能也以
# `// MARK:` 注释开头, 那样会把正文吃掉。
PREFIX_LINES = FILE_HEADER.format(name="x", desc="y").count("\n")


def strip_header(text):
    """去掉生成的文件头 (固定行数), 返回正文。"""
    return "\n".join(text.split("\n")[PREFIX_LINES:])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", action="store_true", help="只打印计划")
    ap.add_argument("--write", action="store_true", help="执行切分")
    ap.add_argument("--verify", action="store_true", help="校验纯搬运")
    a = ap.parse_args()

    lines = read_source()
    if not (a.plan or a.write or a.verify):
        ap.print_help()
        return 0

    if a.plan:
        if not check_boundaries(lines, ANCHORS):
            return 1
        do_plan(lines, build_regions(lines))
        return 0
    if a.write:
        if not check_boundaries(lines, ANCHORS):
            return 1
        do_write(lines, build_regions(lines))
        return 0
    if a.verify:
        return do_verify(lines)
    return 0


if __name__ == "__main__":
    sys.exit(main())
