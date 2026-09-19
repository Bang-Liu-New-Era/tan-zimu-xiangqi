#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# 【已废弃】旧版音效生成器: 用正弦/方波合成"电子音"(move.wav / capture.wav / ...)。
# 已被 tools/make_sounds.py 取代 —— 新版用物理建模合成真实石板撞击声 + 中文人声播报。
# 保留此文件仅为兼容旧引用, 运行它会直接转调新版脚本。
import os
import runpy

print("[deprecated] generate_sounds.py 已废弃, 转调 tools/make_sounds.py")
runpy.run_path(os.path.join(os.path.dirname(os.path.abspath(__file__)), "tools", "make_sounds.py"),
               run_name="__main__")
