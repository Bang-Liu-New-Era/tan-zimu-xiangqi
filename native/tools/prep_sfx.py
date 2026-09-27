#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
prep_sfx.py — 把外部音效素材规范化为本项目 App 可直接使用的格式。

为什么需要它
------------
外部素材（AI 生成、素材库下载、自己录的）几乎都不满足 App 的约定：
  · 采样率/位深/声道不一致  → 播放时音量与音色会漂, 变调后更明显
  · 开头有一段空白          → 每次走子都先"静默一下", 手感发迟
  · 电平五花八门            → 有的震耳有的听不见, 混在一起忽大忽小
  · 开头/结尾被硬切          → 播放时"咔"一声
  · 尾部低电平底噪          → 叠在别的音效上变成沙沙声
本脚本一次性把这些都修掉, 输出严格符合约定:
  **44100 Hz / 16 bit / 单声道 PCM WAV**

用法
----
  # 单文件: 输出到 sounds/ 下的指定名字
  python3 tools/prep_sfx.py 素材.wav --out ../Resources/sounds --name move_1

  # 只试跑, 打印分析结果不写文件
  python3 tools/prep_sfx.py 素材.wav --dry-run

  # 批量: 目录里所有音频依次处理 (用文件名做输出名)
  python3 tools/prep_sfx.py 素材目录/ --out ../Resources/sounds --batch

  # 手动指定参数
  python3 tools/prep_sfx.py 素材.wav --name capture_1 --peak -1.0 --gate -52 --fade-out 15

参数说明
--------
  --peak   dBFS      归一化目标峰值, 默认 -1.0 (留 1dB 余量, 不削波)
  --sr     Hz        目标采样率, 默认 44100
  --trim   auto|none 自动裁掉首尾无声段, 默认 auto
  --gate   dBFS      静音门限, 低于它的样本视为无声 (默认 -45)
  --fade-in  ms      开头淡入, 默认 1.5 (消除爆音; 撞击类别超过 2ms, 会削掉瞬态)
  --fade-out ms      结尾淡出, 默认 12 (自然收尾, 不留硬切)
  --tail   ms        有声段之后再保留多少 ms 尾巴, 默认 20
"""
import argparse
import os
import subprocess
import sys
import tempfile
import wave

import numpy as np

SR_DEFAULT = 44100
PEAK_DEFAULT = -1.0
GATE_DEFAULT = -45.0

AUDIO_EXT = {".wav", ".aif", ".aiff", ".mp3", ".m4a", ".aac", ".caf", ".flac", ".ogg", ".mp4"}


# ---------------------------------------------------------------- 读写

def db(x: float) -> float:
    return 20 * np.log10(max(float(x), 1e-12))


def read_wav(path: str):
    """读 PCM WAV → (float64 单声道数据, 采样率)。非 PCM/非 WAV 先经 afconvert 转一道。"""
    try:
        with wave.open(path, "rb") as w:
            sw, sr, ch = w.getsampwidth(), w.getframerate(), w.getnchannels()
            if sw != 2:
                raise ValueError("not 16-bit PCM")
            raw = w.readframes(w.getnframes())
    except Exception:
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
            tmp_path = tmp.name
        # afconvert 读一切, 统一转成 48k 立体声 16bit PCM 中间格式
        subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@48000",
                        path, tmp_path], check=True, capture_output=True)
        with wave.open(tmp_path, "rb") as w:
            sr, ch = w.getframerate(), w.getnchannels()
            raw = w.readframes(w.getnframes())
        os.unlink(tmp_path)
    a = np.frombuffer(raw, dtype="<i2").astype(np.float64) / 32768.0
    if ch > 1:
        a = a.reshape(-1, ch).mean(axis=1)      # 下混单声道
    return a, sr


def write_wav(path: str, x: np.ndarray, sr: int) -> None:
    """写 44100/16bit/mono PCM WAV。写入前做硬限幅保险, 保证绝不溢出。"""
    y = np.clip(x, -1.0, 1.0)
    data = np.round(y * 32767.0).astype("<i2").tobytes()
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(sr)
        w.writeframes(data)


# ---------------------------------------------------------------- 信号处理

def resample(x: np.ndarray, sr_in: int, sr_out: int) -> np.ndarray:
    """多相重采样。先用 gcd 化简, 再补零到能整除, 最后带低通回到原长度。"""
    if sr_in == sr_out:
        return x
    from math import gcd
    from scipy.signal import resample_poly
    g = gcd(int(sr_in), int(sr_out))
    up, down = int(sr_out) // g, int(sr_in) // g
    y = resample_poly(x, up, down)
    n = int(round(len(x) * sr_out / sr_in))
    if len(y) > n:
        y = y[:n]
    elif len(y) < n:
        y = np.pad(y, (0, n - len(y)))
    return y


def trim_ends(x: np.ndarray, sr: int, gate_db: float, tail_ms: float):
    """裁掉首尾无声段。返回 (裁剪后信号, 起点样本, 终点样本)。"""
    th = 10 ** (gate_db / 20.0)
    idx = np.where(np.abs(x) > th)[0]
    if len(idx) == 0:
        return x, 0, len(x)
    start = int(idx[0])
    end = int(idx[-1]) + int(sr * tail_ms / 1000.0)
    end = min(end, len(x))
    return x[start:end], start, end


def gate_tail(x: np.ndarray, sr: int, gate_db: float, fade_out_ms: float) -> np.ndarray:
    """尾部去底噪: 从后往前找有声段结束点, 之后淡出到零, 避免留下低电平沙沙声。"""
    th = 10 ** (gate_db / 20.0)
    win = max(1, int(sr * 0.005))                 # 5ms 滑动窗
    n = len(x)
    if n <= win:
        return x
    # 从尾部往回扫 5ms 窗的峰值, 找最后一个"确实有声"的窗
    last = 0
    for i in range(n - win, 0, -win):
        if np.max(np.abs(x[i:i + win])) > th:
            last = i + win
            break
    if last >= n:
        return x
    out = x.copy()
    fade = max(2, int(sr * fade_out_ms / 1000.0))
    stop = min(n, last + fade)
    if stop > last:                                # last → stop 线性淡出
        k = np.linspace(1.0, 0.0, stop - last, endpoint=False)
        out[last:stop] *= k
    out[stop:] = 0.0
    return out


def apply_fades(x: np.ndarray, sr: int, fade_in_ms: float, fade_out_ms: float) -> np.ndarray:
    """首尾淡入淡出, 消除硬切造成的爆音。"""
    out = x.copy()
    fi = int(sr * fade_in_ms / 1000.0)
    if fi > 0 and fi < len(out):
        out[:fi] *= np.linspace(0.0, 1.0, fi)
    fo = int(sr * fade_out_ms / 1000.0)
    if fo > 0 and fo < len(out):
        out[-fo:] *= np.linspace(1.0, 0.0, fo)
    return out


# ---------------------------------------------------------------- 主流程

def process(src: str, dst: str, args) -> dict:
    x, sr_in = read_wav(src)
    info = {"src": os.path.basename(src), "dst": os.path.basename(dst),
            "sr_in": sr_in, "dur_in": len(x) / sr_in * 1000, "peak_in": db(np.max(np.abs(x)))}

    if args.trim == "auto":
        x, cut, _ = trim_ends(x, sr_in, args.gate, args.tail)
        info["lead_ms"] = cut / sr_in * 1000        # 被裁掉的开头空白
    else:
        info["lead_ms"] = 0.0

    x = resample(x, sr_in, args.sr)
    x = gate_tail(x, args.sr, args.gate, args.fade_out)
    x = apply_fades(x, args.sr, args.fade_in, args.fade_out)

    peak = np.max(np.abs(x)) if len(x) else 0.0
    if peak > 0:
        x = x * (10 ** (args.peak / 20.0) / peak)

    info.update(dur_out=len(x) / args.sr * 1000,
                peak_out=db(np.max(np.abs(x))) if len(x) else -120,
                rms_out=db(np.sqrt(np.mean(x ** 2))) if len(x) else -120)
    if not args.dry_run:
        os.makedirs(os.path.dirname(os.path.abspath(dst)), exist_ok=True)
        write_wav(dst, x, args.sr)
    return info


def report(info: dict, src: str, args) -> None:
    print(f"  {info['src']}")
    print(f"    输入  {info['sr_in']}Hz  {info['dur_in']:.0f}ms  峰值 {info['peak_in']:+.1f} dBFS")
    print(f"    输出  {args.sr}Hz 16bit mono  {info['dur_out']:.0f}ms  峰值 {info['peak_out']:+.1f} dBFS  "
          f"RMS {info['rms_out']:+.1f} dBFS")
    warn = "  ← 开头空白, 会造成手感延迟" if info["lead_ms"] > 15 else ""
    print(f"    处理  裁掉开头 {info['lead_ms']:.0f}ms{warn} | 门限 {args.gate:g}dBFS | "
          f"淡入 {args.fade_in:g}ms 淡出 {args.fade_out:g}ms")


def main() -> int:
    ap = argparse.ArgumentParser(description="把外部音效规范化为 44100/16bit/mono WAV")
    ap.add_argument("input", help="输入文件或目录")
    ap.add_argument("--out", default=".", help="输出目录")
    ap.add_argument("--name", help="输出文件名(不含扩展名); 省略则沿用输入文件名")
    ap.add_argument("--batch", action="store_true", help="输入是目录时逐个处理")
    ap.add_argument("--peak", type=float, default=PEAK_DEFAULT, help="目标峰值 dBFS (默认 -1.0)")
    ap.add_argument("--sr", type=int, default=SR_DEFAULT, help="目标采样率 (默认 44100)")
    ap.add_argument("--trim", choices=["auto", "none"], default="auto", help="是否裁掉首尾无声段")
    ap.add_argument("--gate", type=float, default=GATE_DEFAULT, help="静音门限 dBFS (默认 -45)")
    ap.add_argument("--fade-in", type=float, default=1.5, help="开头淡入 ms (默认 1.5)")
    ap.add_argument("--fade-out", type=float, default=12.0, help="结尾淡出 ms (默认 12)")
    ap.add_argument("--tail", type=float, default=20.0, help="有声段后保留的尾巴 ms (默认 20)")
    ap.add_argument("--dry-run", action="store_true", help="只分析不写文件")
    args = ap.parse_args()

    src = os.path.abspath(args.input)
    if os.path.isdir(src):
        if not args.batch:
            print("输入是目录, 请加 --batch", file=sys.stderr)
            return 2
        files = sorted(f for f in os.listdir(src)
                       if os.path.splitext(f)[1].lower() in AUDIO_EXT)
        if not files:
            print("目录里没有可识别的音频文件", file=sys.stderr)
            return 2
    else:
        files = [os.path.basename(src)]
        src = os.path.dirname(src)

    for f in files:
        stem = os.path.splitext(f)[0]
        name = (args.name if (args.name and not args.batch) else stem)
        dst = os.path.join(os.path.abspath(args.out), name + ".wav")
        # 批量模式下跳过已经符合规格且非本次输入的文件由调用方决定, 这里不擅自跳过
        try:
            info = process(os.path.join(src, f), dst, args)
        except Exception as e:                       # 单个文件失败不中断整批
            print(f"  ✗ {f}: {e}", file=sys.stderr)
            continue
        report(info, src, args)
        if not args.dry_run:
            print(f"    → {dst}  ({os.path.getsize(dst) / 1024:.0f}K)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
