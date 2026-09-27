#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""make_preview.py — 生成音效试听台 (单文件 HTML, 音频以 base64 内嵌, 可离线打开)"""
import base64
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SND = os.path.normpath(os.path.join(HERE, "..", "Resources", "sounds"))
OUT = os.path.normpath(os.path.join(HERE, "..", "..", "音效试听台.html"))

# 每组的类别键 —— 用来套用与 Audio/SoundEngine.swift 完全一致的分类增益,
# 这样试听台里听到的比例就是 App 里实际播放的比例。
GROUPS = [
    ("move", "落子（外部素材）", "由 AI 生成的短促闷响，经 prep_sfx.py 规范化（裁掉 173ms 起始空白、归一化到 -1 dBFS）。",
     [("move_1", "落子"), ("lift_1", "提子（离板）"), ("lift_2", "提子 B")]),
    ("capture", "吃子（两声连击）", "被吃掉的棋子被撞开、再落到棋盘上的两段式撞击，比落子更闷更重。",
     [("capture_1", "吃子 A"), ("capture_2", "吃子 B"), ("capture_3", "吃子 C")]),
    ("check", "将军（编钟余韵）", "低沉重击 + 非谐金属余韵，分量足。",
     [("check_1", "将军 A"), ("check_2", "将军 B"), ("check_3", "将军 C")]),
    ("voice", "人声播报", "macOS 中文语音合成的短促播报，做过均衡与房间处理。",
     [("voice_chi", "「吃」"), ("voice_jiangjun", "「将军」"),
      ("voice_juesha", "「绝杀」"), ("voice_heqi", "「和棋」")]),
    ("click", "选子 / 胜负", "轻触选中棋子；对局结束的编钟收尾音。",
     [("click", "选中"), ("win", "胜"), ("lose", "负")]),
]

# 与 SoundEngine.gains 一一对应; 未列出的类别按 1.0
GAINS = {"move": 0.85, "lift": 0.45, "capture": 1.0, "check": 0.95,
         "click": 0.5, "win": 0.85, "lose": 0.85}

# 单文件 → 增益 (同组共用一个键; lift/win/lose 单独指定)
FILE_GROUP = {}

SCENES = [
    ("普通走子", ["lift_1", "move_1"]),
    ("吃子 + 喊「吃」", ["lift_1", "capture_1", "voice_chi"]),
    ("将军 + 喊「将军」", ["lift_1", "move_1", "check_1", "voice_jiangjun"]),
    ("绝杀", ["lift_1", "capture_2", "win", "voice_juesha"]),
]


def b64(name):
    p = os.path.join(SND, name + ".wav")
    with open(p, "rb") as f:
        return base64.b64encode(f.read()).decode()


def build_file_gain():
    """把 '文件 → 增益' 展开出来: 组内所有文件共用组键, 特例 (lift/win/lose) 单独覆盖。"""
    g = {}
    for key, _, _, items in GROUPS:
        if key == "voice":
            for n, _ in items:
                g[n] = 1.0
            continue
        for n, _ in items:
            if n in GAINS:                       # lift_1 / click / win / lose 等自带键
                g[n] = GAINS[n]
            elif key == "move" and n.startswith("lift"):
                g[n] = GAINS["lift"]
            else:
                g[n] = GAINS.get(key, 1.0)
    g["lift_2"] = GAINS["lift"]
    return g


def main():
    data = {}
    for _, _, _, items in GROUPS:
        for n, _ in items:
            data[n] = b64(n)
    for _, seq in SCENES:
        for n in seq:
            data.setdefault(n, b64(n))

    blocks = []
    for _, title, desc, items in GROUPS:
        btns = "".join(
            f'<button class="snd" data-k="{n}"><span class="dot"></span>{lab}'
            f'<span class="dur">{os.path.getsize(os.path.join(SND, n + ".wav")) / 1024:.0f}K</span></button>'
            for n, lab in items)
        blocks.append(f'<section><h2>{title}</h2><p class="desc">{desc}</p><div class="row">{btns}</div></section>')

    scenes = "".join(
        f'<button class="scene" data-seq="{",".join(seq)}">{lab}</button>' for lab, seq in SCENES)

    payload = "{" + ",".join(f'"{k}":"data:audio/wav;base64,{v}"' for k, v in data.items()) + "}"
    gains_js = "{" + ",".join(f'"{k}":{v}' for k, v in build_file_gain().items()) + "}"

    html = f"""<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>象棋音效试听台</title>
<style>
  :root {{ --bg:#f5f6f8; --card:#ffffff; --line:#e3e6ea; --tx:#1c1f23; --dim:#6b7280;
          --accent:#9D2933; --accent2:#b8342f; }}
  * {{ box-sizing:border-box; }}
  body {{ margin:0; padding:32px 20px 64px; background:var(--bg); color:var(--tx);
         font:15px/1.7 -apple-system,"PingFang SC","Helvetica Neue",sans-serif; }}
  .wrap {{ max-width:880px; margin:0 auto; }}
  h1 {{ font-size:26px; margin:0 0 6px; letter-spacing:.5px; }}
  .sub {{ color:var(--dim); margin:0 0 28px; font-size:13.5px; }}
  section {{ background:var(--card); border:1px solid var(--line); border-radius:14px;
             padding:18px 20px 20px; margin-bottom:16px; box-shadow:0 1px 2px rgba(0,0,0,.04); }}
  h2 {{ font-size:16px; margin:0 0 4px; }}
  h2::before {{ content:""; display:inline-block; width:4px; height:15px; background:var(--accent);
                border-radius:2px; margin-right:8px; vertical-align:-2px; }}
  .desc {{ color:var(--dim); font-size:13px; margin:0 0 14px; }}
  .row {{ display:flex; flex-wrap:wrap; gap:10px; }}
  button {{ font:inherit; cursor:pointer; border-radius:10px; border:1px solid var(--line);
            background:#fbfbfc; color:var(--tx); padding:9px 15px; display:inline-flex;
            align-items:center; gap:8px; transition:.15s; }}
  button:hover {{ border-color:#c9ced6; background:#fff; transform:translateY(-1px); }}
  button:active {{ transform:translateY(0); }}
  .dot {{ width:8px; height:8px; border-radius:50%; background:#c7ccd3; transition:.15s; }}
  button.playing {{ border-color:var(--accent); background:#fdf3f3; color:var(--accent); }}
  button.playing .dot {{ background:var(--accent); box-shadow:0 0 0 4px rgba(157,41,51,.15); }}
  .dur {{ color:#9aa1ab; font-size:11px; }}
  .scenes {{ background:linear-gradient(180deg,#fff,#fcfbfb); border-color:#eadadd; }}
  .scene {{ background:var(--accent); color:#fff; border-color:var(--accent); font-weight:500; }}
  .scene:hover {{ background:var(--accent2); border-color:var(--accent2); }}
  .tip {{ color:var(--dim); font-size:12.5px; margin-top:12px; }}
</style></head>
<body><div class="wrap">
  <h1>人机中国象棋 · 音效试听台</h1>
  <p class="sub">落子为外部素材（已用 prep_sfx.py 规范化）；吃子、将军为物理建模合成（石板撞击 + 阻尼共振 + 房间反射），含多个变体；人声由 macOS 中文语音合成后再做均衡与混响处理。试听台不套用 App 内的分类增益，音量以文件自身电平为准。</p>
  <section class="scenes"><h2>场景连播</h2>
    <p class="desc">按下后按真实对局顺序依次播放，感受衔接是否自然。</p>
    <div class="row">{scenes}</div>
    <p class="tip">提示：连播时人声会稍晚于撞击声出现（约 0.15～0.5 秒），这是刻意留出的“落子—报招”节奏。</p>
  </section>
  {"".join(blocks)}
</div>
<script>
const SND = {payload};
const GAIN = {gains_js};
let cur = null, timer = [];
function stopAll() {{
  if (cur) {{ cur.pause(); cur.currentTime = 0; cur = null; }}
  document.querySelectorAll('button.playing').forEach(b => b.classList.remove('playing'));
  timer.forEach(t => clearTimeout(t)); timer = [];
}}
function playOne(k, btn, delay) {{
  const run = () => {{
    const a = new Audio(SND[k]);
    a.volume = Math.min(1, GAIN[k] === undefined ? 1 : GAIN[k]);   // 与 App 内的分类增益一致
    if (btn) btn.classList.add('playing');
    a.onended = () => {{ if (btn) btn.classList.remove('playing'); }};
    cur = a; a.play();
  }};
  if (delay) timer.push(setTimeout(run, delay * 1000)); else run();
}}
document.querySelectorAll('button.snd').forEach(b => {{
  b.onclick = () => {{ stopAll(); playOne(b.dataset.k, b, 0); setTimeout(() => b.classList.remove('playing'), 2500); }};
}});
document.querySelectorAll('button.scene').forEach(b => {{
  b.onclick = () => {{
    stopAll();
    const seq = b.dataset.seq.split(',');
    let t = 0;
    const gaps = {{ lift_1:0.30, move_1:0.30, capture_1:0.55, capture_2:0.55,
                    voice_chi:0.45, voice_jiangjun:0.60, check_1:0.55, voice_juesha:0.60, win:0.55 }};
    seq.forEach(n => {{ playOne(n, null, t); t += (gaps[n] || 0.5); }});
    b.classList.add('playing'); setTimeout(() => b.classList.remove('playing'), t * 1000 + 900);
  }};
}});
</script></body></html>"""

    with open(OUT, "w", encoding="utf-8") as f:
        f.write(html)
    print("试听台 ->", OUT, "(%.1f MB)" % (os.path.getsize(OUT) / 1048576))


if __name__ == "__main__":
    main()
