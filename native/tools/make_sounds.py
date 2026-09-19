#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""make_sounds.py — 生成真实感中国象棋音效 + 中文人声播报

替换掉旧版 generate_sounds.py 的正弦/方波"电子音"。
落子声用物理建模(模态合成)方式合成: 短促噪声激励 + 石板/木棋的阻尼共振模态
+ 二次接触 + 小型房间早期反射, 听感接近"棋子拍在石板上"。

产出 (native/Resources/sounds/):
  落子   move_1.wav .. move_4.wav     棋子落板 (4 个随机变体, 避免机械重复)
  拿起   lift_1.wav lift_2.wav        手指提起棋子的轻微木质摩擦
  吃子   capture_1.wav .. capture_3.wav  两段式撞击(被吃子被击开 + 落在棋盘上)
  将军   check_1.wav .. check_3.wav   低沉重击 + 金属余韵
  选子   click.wav                    轻触
  胜/负  win.wav lose.wav             编钟式收尾
  人声   voice_chi.wav / voice_jiangjun.wav / voice_juesha.wav / voice_heqi.wav
         (用 macOS 内置中文语音 Tingting 合成, 再做均衡+房间混响处理)

用法: python3 make_sounds.py
"""
import math
import os
import subprocess
import sys
import tempfile
import wave

import numpy as np

SR = 44100
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.normpath(os.path.join(HERE, "..", "Resources", "sounds"))
TMP = tempfile.mkdtemp(prefix="xqsnd_")


# ---------------------------------------------------------------- 基础滤波
def _biquad(x, b, a):
    y = np.zeros_like(x, dtype=np.float64)
    x1 = x2 = y1 = y2 = 0.0
    for i in range(len(x)):
        v = b[0] * x[i] + b[1] * x1 + b[2] * x2 - a[1] * y1 - a[2] * y2
        y[i] = v
        x2, x1 = x1, x[i]
        y2, y1 = y1, v
    return y


def _coefs(kind, fc, q):
    w = 2 * math.pi * fc / SR
    cw, sw = math.cos(w), math.sin(w)
    al = sw / (2 * q)
    if kind == "lp":
        b = [(1 - cw) / 2, 1 - cw, (1 - cw) / 2]
        a = [1 + al, -2 * cw, 1 - al]
    else:  # hp
        b = [(1 + cw) / 2, -(1 + cw), (1 + cw) / 2]
        a = [1 + al, -2 * cw, 1 - al]
    return [v / a[0] for v in b], [v / a[0] for v in a]


def lp(x, fc, q=0.707):
    b, a = _coefs("lp", min(fc, SR * 0.45), q)
    return _biquad(x, b, a)


def hp(x, fc, q=0.707):
    b, a = _coefs("hp", max(fc, 20.0), q)
    return _biquad(x, b, a)


def fftconv(x, ir):
    n = len(x) + len(ir) - 1
    nfft = 1 << int(math.ceil(math.log2(n)))
    y = np.fft.irfft(np.fft.rfft(x, nfft) * np.fft.rfft(ir, nfft), nfft)[:n]
    return y


# ---------------------------------------------------------------- 房间感
def room_ir(rng, dur=0.20, wet=1.0):
    """小型硬质房间(石室)冲激响应: 早期反射 + 指数衰减尾部。"""
    n = int(SR * dur)
    t = np.arange(n) / SR
    tail = rng.normal(0, 1, n) * np.exp(-t / (dur / 5.5))
    tail = lp(tail, 5200)
    tail *= wet * 0.10
    for d, g in ((0.0045, -0.42), (0.0088, -0.48), (0.0155, -0.55), (0.0242, -0.62)):
        i = int(d * SR)
        if i < n:
            tail[i] += g
    return tail


def add_room(x, rng, wet=0.35, dur=0.20):
    ir = room_ir(rng, dur=dur, wet=wet)
    y = fftconv(x, ir) * 0.55
    out = np.zeros(max(len(x), len(y)))
    out[:len(x)] += x
    out[:len(y)] += y
    return out


def mix_at(buf, sig, off):
    """把 sig 叠加到 buf 的 off 处 (自动截断, 不越界)。"""
    i = max(0, int(off))
    if i >= len(buf):
        return
    seg = sig[:len(buf) - i]
    buf[i:i + len(seg)] += seg


# ---------------------------------------------------------------- 撞击合成
def strike(rng, dur, modes, excite=0.00075, excite_bp=1500, bright=0.55,
           amp=1.0, attack=0.00028):
    """模态合成一次撞击: 噪声瞬态 + 各阶阻尼正弦共振。"""
    n = int(SR * dur)
    t = np.arange(n) / SR
    # 1) 瞬态: 极短噪声脉冲 (接触瞬间的宽带"嗒")
    e = rng.normal(0, 1, n) * np.exp(-t / excite)
    sig = hp(e, excite_bp) * bright
    # 2) 共振模态 (石板 + 木棋的复合体)
    for f, tau, a in modes:
        f = f * (1.0 + rng.uniform(-0.055, 0.055))
        tau = tau * (1.0 + rng.uniform(-0.14, 0.14))
        sig += (a * np.exp(-t / tau)
                * np.sin(2 * math.pi * f * t + rng.uniform(0, 2 * math.pi)))
    # 3) 起振包络, 避免开头的数字爆音
    sig *= 1.0 - np.exp(-t / attack)
    return sig * amp


# 石板上的棋子: 亮、硬、衰减快 (主模态 1~11kHz)
BOARD_MODES = [
    (430, 0.038, 0.30),
    (760, 0.030, 0.26),
    (1180, 0.026, 0.42),
    (2050, 0.019, 0.62),
    (3260, 0.014, 0.50),
    (5150, 0.010, 0.34),
    (7800, 0.007, 0.20),
    (11200, 0.005, 0.12),
]


def place_clack(rng, bright=1.0, amp=1.0, dur=0.17, detune=1.0):
    """一次干脆的落子声。"""
    modes = [(f * detune, tau, a) for (f, tau, a) in BOARD_MODES]
    return strike(rng, dur, modes, bright=0.55 * bright, amp=amp)


def capture_hit(rng):
    """吃子: 第一击(撞开对方棋子, 更硬更亮) + 第二击(被吃子落板, 稍闷更低)。"""
    total = np.zeros(int(SR * 0.42))
    h1 = place_clack(rng, bright=1.35, amp=1.0, dur=0.20, detune=1.06)
    # 第二击: 降低模态 + 更快衰减 = 更闷
    m2 = [(f * 0.72, tau * 0.75, a * 0.9) for (f, tau, a) in BOARD_MODES]
    h2 = strike(rng, 0.22, m2, bright=0.75, amp=0.62)
    h3 = strike(rng, 0.12, [(1500, 0.012, 0.4), (2900, 0.008, 0.3)], bright=0.5, amp=0.22)
    d2 = int(SR * rng.uniform(0.052, 0.068))
    d3 = int(SR * rng.uniform(0.095, 0.125))
    for sig, off in ((h1, 0), (h2, d2), (h3, d3)):
        mix_at(total, sig, off)
    # 棋子被撞开时的轻微摩擦
    ns = int(SR * 0.09)
    tt = np.arange(ns) / SR
    rub = rng.normal(0, 1, ns) * np.exp(-tt / 0.030) * 0.05
    rub = lp(hp(rub, 900), 6500)
    mix_at(total, rub, int(SR * 0.02))
    return total


def lift_sound(rng):
    """提起棋子: 木质轻擦 + 极轻的离板"啵"。"""
    n = int(SR * 0.13)
    t = np.arange(n) / SR
    x = rng.normal(0, 1, n) * np.exp(-t / 0.022) * 0.16
    x = lp(hp(x, 700), 7000)
    for f, tau, a in ((1350, 0.010, 0.30), (2500, 0.007, 0.18), (360, 0.020, 0.14)):
        x += a * np.exp(-t / tau) * np.sin(2 * math.pi * f * t)
    x *= 1 - np.exp(-t / 0.0012)
    return x


def check_strike(rng):
    """将军: 低沉重击 + 一段金属(锣/钟)余韵, 分量足。"""
    dur = 0.95
    n = int(SR * dur)
    t = np.arange(n) / SR
    base = strike(rng, 0.35, [(300, 0.09, 0.55), (620, 0.06, 0.45), (1500, 0.03, 0.35)],
                  bright=0.6, amp=1.0)
    # 非谐金属模态 (编钟/锣的特征)
    bell = np.zeros(n)
    ratios = [0.56, 0.92, 1.19, 1.71, 2.00, 2.74, 3.76]
    gains = [0.55, 0.40, 0.30, 0.22, 0.18, 0.12, 0.07]
    taus = [0.55, 0.42, 0.34, 0.24, 0.18, 0.13, 0.09]
    f0 = 196.0
    for r, g, tau in zip(ratios, gains, taus):
        bell += g * np.exp(-t / tau) * np.sin(2 * math.pi * f0 * r * t + rng.uniform(0, 6.28))
    bell *= 1 - np.exp(-t / 0.004)
    out = np.zeros(n)
    mix_at(out, base, 0)
    out += bell * 0.85
    return out


def bell_note(rng, f, dur, amp=1.0, tau_scale=1.0):
    n = int(SR * dur)
    t = np.arange(n) / SR
    ratios = [0.56, 1.00, 1.19, 1.71, 2.00, 2.74, 3.76, 5.40]
    gains = [0.35, 1.00, 0.60, 0.42, 0.30, 0.20, 0.12, 0.07]
    taus = [0.9, 1.1, 0.7, 0.5, 0.38, 0.28, 0.20, 0.13]
    y = np.zeros(n)
    for r, g, tau in zip(ratios, gains, taus):
        y += g * np.exp(-t / (tau * tau_scale)) * np.sin(2 * math.pi * f * r * t + rng.uniform(0, 6.28))
    y *= 1 - np.exp(-t / 0.005)
    return y * amp


def win_sound(rng):
    n = int(SR * 2.0)
    y = np.zeros(n)
    for f, off, a in ((523.25, 0.00, 0.9), (659.25, 0.16, 0.95), (783.99, 0.32, 1.0), (1046.5, 0.32, 0.5)):
        mix_at(y, bell_note(rng, f, 1.6, amp=a, tau_scale=0.9), off * SR)
    return y


def lose_sound(rng):
    n = int(SR * 1.8)
    y = np.zeros(n)
    for f, off, a in ((392.0, 0.00, 0.9), (311.13, 0.26, 0.85), (233.08, 0.52, 0.9)):
        mix_at(y, bell_note(rng, f, 1.3, amp=a, tau_scale=0.75), off * SR)
    y = lp(y, 3800)
    return y


# ---------------------------------------------------------------- 输出
def master(x, rng, peak=0.86, room=0.32, trim_head=True, fade_out=0.06):
    x = np.asarray(x, dtype=np.float64)
    if room > 0:
        x = add_room(x, rng, wet=room, dur=0.20)
    # 轻微软限幅, 保留冲击力
    x = np.tanh(x * 1.15) / np.tanh(1.15)
    m = np.max(np.abs(x))
    if m > 0:
        x = x / m * peak
    if trim_head:
        thr = 0.004
        idx = np.argmax(np.abs(x) > thr)
        if idx > 8:
            x = x[max(0, idx - 8):]
    n = len(x)
    a = int(SR * 0.0015)
    if a < n:
        x[:a] *= np.linspace(0, 1, a)
    f = int(SR * fade_out)
    if f < n:
        x[-f:] *= np.linspace(1, 0, f)
    return x


def write_wav(path, x):
    d = np.clip(x, -1.0, 1.0)
    data = (d * 32767.0).astype("<i2").tobytes()
    with wave.open(path, "w") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(data)
    print("  %-22s %5.2fs  %6.1f KB" % (os.path.basename(path), len(d) / SR, len(data) / 1024))


# ---------------------------------------------------------------- 人声
VOICE = "Tingting"   # macOS 内置中文(大陆)语音, 唯一可靠的离线中文嗓
VOICE_LINES = [
    ("voice_chi.wav", "吃！", 200),
    ("voice_jiangjun.wav", "将军！", 190),
    ("voice_juesha.wav", "绝杀！", 175),
    ("voice_heqi.wav", "和棋", 175),
]


def render_voice():
    ok = subprocess.run(["which", "say"], capture_output=True).returncode == 0
    if not ok:
        print("  (未找到 say 命令, 跳过人声)")
        return
    for name, text, rate in VOICE_LINES:
        aiff = os.path.join(TMP, name + ".aiff")
        raw = os.path.join(TMP, name + "_raw.wav")
        r = subprocess.run(["say", "-v", VOICE, "-r", str(rate), "-o", aiff, text],
                           capture_output=True)
        if r.returncode != 0 or not os.path.exists(aiff):
            print("  (合成失败:", text, r.stderr.decode()[:80], ")")
            continue
        c = subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEI16@22050", aiff, raw],
                           capture_output=True)
        if c.returncode != 0:
            print("  (转码失败:", text, ")")
            continue
        with wave.open(raw, "rb") as w:
            sr0 = w.getframerate()
            x = np.frombuffer(w.readframes(w.getnframes()), dtype="<i2").astype(np.float64) / 32768.0
        # 升采样到 44.1k
        n1 = int(len(x) * SR / sr0)
        x = np.interp(np.linspace(0, len(x) - 1, n1), np.arange(len(x)), x)
        # 语音处理: 去低频轰鸣 + 轻微去齿音 + 温和压限 + 房间感
        x = hp(x, 120)
        x = lp(x, 11000)
        env = lp(np.abs(x), 40)
        g = np.clip(0.12 / np.maximum(env, 1e-4), 0.35, 2.6) ** 0.45
        x = x * g
        rng = np.random.default_rng(hash(name) % 99991)
        x = master(x, rng, peak=0.82, room=0.24, fade_out=0.08)
        write_wav(os.path.join(OUT, name), x)


# ---------------------------------------------------------------- 主流程
def main():
    os.makedirs(OUT, exist_ok=True)
    old = ["move.wav", "capture.wav", "check.wav", "click.wav", "win.wav", "lose.wav"]
    for f in old:
        p = os.path.join(OUT, f)
        if os.path.exists(p):
            os.remove(p)

    print("== 落子 (4 变体) ==")
    for i in range(4):
        rng = np.random.default_rng(1000 + i)
        write_wav(os.path.join(OUT, "move_%d.wav" % (i + 1)),
                  master(place_clack(rng), rng, peak=0.80, room=0.30))

    print("== 拿起 (2 变体) ==")
    for i in range(2):
        rng = np.random.default_rng(2000 + i)
        write_wav(os.path.join(OUT, "lift_%d.wav" % (i + 1)),
                  master(lift_sound(rng), rng, peak=0.42, room=0.22))

    print("== 吃子 (3 变体) ==")
    for i in range(3):
        rng = np.random.default_rng(3000 + i)
        write_wav(os.path.join(OUT, "capture_%d.wav" % (i + 1)),
                  master(capture_hit(rng), rng, peak=0.90, room=0.34, fade_out=0.10))

    print("== 将军 (3 变体) ==")
    for i in range(3):
        rng = np.random.default_rng(4000 + i)
        write_wav(os.path.join(OUT, "check_%d.wav" % (i + 1)),
                  master(check_strike(rng), rng, peak=0.92, room=0.42, fade_out=0.18))

    print("== 选子 / 胜负 ==")
    rng = np.random.default_rng(5001)
    tick = strike(rng, 0.05, [(2600, 0.006, 0.5), (4200, 0.004, 0.3)], bright=0.5, amp=0.5)
    write_wav(os.path.join(OUT, "click.wav"), master(tick, rng, peak=0.30, room=0.15))

    rng = np.random.default_rng(6001)
    write_wav(os.path.join(OUT, "win.wav"), master(win_sound(rng), rng, peak=0.80, room=0.40, fade_out=0.35))
    rng = np.random.default_rng(6002)
    write_wav(os.path.join(OUT, "lose.wav"), master(lose_sound(rng), rng, peak=0.74, room=0.38, fade_out=0.35))

    print("== 人声 (%s) ==" % VOICE)
    render_voice()
    print("\n完成 ->", OUT)


if __name__ == "__main__":
    main()
