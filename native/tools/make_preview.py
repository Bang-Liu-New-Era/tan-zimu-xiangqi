#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""make_preview.py — 生成音效试听台 (单文件 HTML, 音频以 base64 内嵌, 可离线打开)"""
import base64
import os

HERE = os.path.dirname(os.path.abspath(__file__))
SND = os.path.normpath(os.path.join(HERE, "..", "Resources", "sounds"))
OUT = os.path.normpath(os.path.join(HERE, "..", "..", "音效试听台.html"))

GROUPS = [
    ("落子（石板撞击）", "棋子落在石板上的清脆「啪」声，每次随机换变体并微调音高，不会机械重复。",
     [("move_1", "落子 A"), ("move_2", "落子 B"), ("move_3", "落子 C"), ("move_4", "落子 D"),
      ("lift_1", "提子（离板）"), ("lift_2", "提子 B")]),
    ("吃子（两声连击）", "被吃掉的棋子被撞开、再落到棋盘上的两段式撞击，比落子更闷更重。",
     [("capture_1", "吃子 A"), ("capture_2", "吃子 B"), ("capture_3", "吃子 C")]),
    ("将军（编钟余韵）", "低沉重击 + 非谐金属余韵，分量足。",
     [("check_1", "将军 A"), ("check_2", "将军 B"), ("check_3", "将军 C")]),
    ("人声播报", "macOS 中文语音合成的短促播报，做过均衡与房间处理。",
     [("voice_chi", "「吃」"), ("voice_jiangjun", "「将军」"),
      ("voice_juesha", "「绝杀」"), ("voice_heqi", "「和棋」")]),
    ("选子 / 胜负", "轻触选中棋子；对局结束的编钟收尾音。",
     [("click", "选中"), ("win", "胜"), ("lose", "负")]),
]

SCENES = [
    ("普通走子", ["lift_1", "move_2"]),
    ("吃子 + 喊「吃」", ["lift_1", "capture_1", "voice_chi"]),
    ("将军 + 喊「将军」", ["lift_1", "move_3", "check_1", "voice_jiangjun"]),
    ("绝杀", ["lift_1", "capture_2", "win", "voice_juesha"]),
]


def b64(name):
    p = os.path.join(SND, name + ".wav")
    with open(p, "rb") as f:
        return base64.b64encode(f.read()).decode()


def main():
    data = {}
    for _, _, items in GROUPS:
        for n, _ in items:
            data[n] = b64(n)
    for _, seq in SCENES:
        for n in seq:
            data.setdefault(n, b64(n))

    blocks = []
    for title, desc, items in GROUPS:
        btns = "".join(
            f'<button class="snd" data-k="{n}"><span class="dot"></span>{lab}'
            f'<span class="dur">{os.path.getsize(os.path.join(SND, n + ".wav")) / 1024:.0f}K</span></button>'
            for n, lab in items)
        blocks.append(f'<section><h2>{title}</h2><p class="desc">{desc}</p><div class="row">{btns}</div></section>')

    scenes = "".join(
        f'<button class="scene" data-seq="{",".join(seq)}">{lab}</button>' for lab, seq in SCENES)

    payload = "{" + ",".join(f'"{k}":"data:audio/wav;base64,{v}"' for k, v in data.items()) + "}"

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
  <p class="sub">落子/吃子为物理建模合成（石板撞击 + 阻尼共振 + 房间反射），每类含多个变体；人声由 macOS 中文语音合成后再做均衡与混响处理。</p>
  <section class="scenes"><h2>场景连播</h2>
    <p class="desc">按下后按真实对局顺序依次播放，感受衔接是否自然。</p>
    <div class="row">{scenes}</div>
    <p class="tip">提示：连播时人声会稍晚于撞击声出现（约 0.15～0.5 秒），这是刻意留出的“落子—报招”节奏。</p>
  </section>
  {"".join(blocks)}
</div>
<script>
const SND = {payload};
let cur = null, timer = [];
function stopAll() {{
  if (cur) {{ cur.pause(); cur.currentTime = 0; cur = null; }}
  document.querySelectorAll('button.playing').forEach(b => b.classList.remove('playing'));
  timer.forEach(t => clearTimeout(t)); timer = [];
}}
function playOne(k, btn, delay) {{
  const run = () => {{
    const a = new Audio(SND[k]);
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
    const gaps = {{ lift_1:0.30, move_2:0.30, move_3:0.30, capture_1:0.55, capture_2:0.55,
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
