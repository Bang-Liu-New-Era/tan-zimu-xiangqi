# 生成"走子动画"逐帧预览动图 (GIF)。
# 做法: 把正式源码复制到 /tmp, 注入 XQ_FILM 钩子 + 虚拟时钟 XQ_FILM_T,
#       逐帧离屏渲染一次走子动画 → 合成 GIF。全程不动正式源码。
import os, re, subprocess, glob, shutil, sys

SRC = '/Users/kenttt/Documents/谭子沐象棋/native/XiangqiApp.swift'
SWIFT = '/tmp/XiangqiFilm.swift'
APPDIR = '/tmp/XQFilm.app'
FRAMES = '/tmp/xqfilm'
PY = '/Users/kenttt/.workbuddy/binaries/python/envs/default/bin/python'

# 预览用的着法 (红炮二平五: 70 → 67, 屏幕上是同一横线, 能看清弧线)
FROM, TO = 70, 67


def patch_source():
    s = open(SRC, encoding='utf-8').read()

    # ① 文件级虚拟时钟 (让 draw 能按指定时刻渲染, 用于逐帧定格)
    anchor = 'import CoreText\n'
    assert s.count(anchor) == 1
    s = s.replace(anchor, anchor + '\n// [FILM] 预览渲染用的虚拟时钟; 为 nil 时走真实时间\nvar XQ_FILM_T: Double? = nil\n')

    # ② BoardView: 提供直接启动动画的入口 + 在 draw 里使用虚拟时钟
    anchor = '    func dispRC(_ sq: Int) -> (Int, Int) {'
    assert s.count(anchor) == 1
    film = '''    // [FILM] 直接启动一次走子动画(不经对局流程, 避免 AI 介入)
    func filmStart(_ from: Int, _ to: Int, _ piece: Int, _ start: Double) {
        anim = MoveAnim(from: from, to: to, piece: piece, start: start, fly: 0.26, land: 0.13)
        landRipple = (to, start + 0.26)
        setNeedsDisplay(bounds)
    }
'''
    s = s.replace(anchor, film + anchor)

    # draw 内的 now 换成虚拟时钟 (BoardView.draw 独有的上下文, 保证只替换这一处)
    old = '        let bw = cell * 8, bh = cell * 9\n        let now = CACurrentMediaTime()'
    assert s.count(old) == 1, 'draw 里的 now 定位失败'
    s = s.replace(old, '        let bw = cell * 8, bh = cell * 9\n        let now = XQ_FILM_T ?? CACurrentMediaTime()')

    # ③ 启动钩子: 定格渲染 N 帧
    anchor = '        newGame(side: currentSide, diff: currentDiff)\n'
    assert s.count(anchor) == 1
    hook = '''        newGame(side: currentSide, diff: currentDiff)

        // [测试钩子] XQ_FILM=1: 逐帧定格渲染一次走子动画, 输出 PNG 序列
        if ProcessInfo.processInfo.environment["XQ_FILM"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let dir = "%(frames)s"
                try? FileManager.default.removeItem(atPath: dir)
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                guard let v = self.boardView else { exit(1) }
                // [测量模式] 只保留被移动的棋子, 便于逐帧定位它的真实轨迹
                if ProcessInfo.processInfo.environment["XQ_FILM_BLANK"] != nil {
                    var nb = [Int](repeating: 0, count: 90)
                    nb[%(from)d] = self.board[%(from)d]
                    self.board = nb; v.board = nb
                }
                let t0 = CACurrentMediaTime()
                v.filmStart(%(from)d, %(to)d, self.board[%(from)d], t0)
                // 逐帧: 总时长 0.44s, 30fps
                let fps = 30.0, total = 0.44
                let n = Int(total * fps)
                for i in 0...n {
                    XQ_FILM_T = t0 + Double(i) / fps
                    if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        v.cacheDisplay(in: v.bounds, to: rep)
                        if let d = rep.representation(using: .png, properties: [:]) {
                            try? d.write(to: URL(fileURLWithPath: String(format: "%%@/f%%03d.png", dir, i)))
                        }
                    }
                }
                XQ_FILM_T = nil
                print("FILM_DONE", n + 1)
                exit(0)
            }
        }
''' % {'frames': FRAMES, 'from': FROM, 'to': TO}
    s = s.replace(anchor, hook)
    open(SWIFT, 'w', encoding='utf-8').write(s)
    print('patched ->', SWIFT)


def build_and_run():
    subprocess.run(['/usr/bin/pkill', '-f', 'Contents/MacOS/Xiangqi'], capture_output=True)
    if not os.path.isdir('/Applications/人机中国象棋.app'):
        sys.exit('缺少 /Applications/人机中国象棋.app, 请先 bash native/build_app.sh')
    shutil.rmtree(APPDIR, ignore_errors=True)
    shutil.copytree('/Applications/人机中国象棋.app', APPDIR)
    r = subprocess.run(['swiftc', '-O', SWIFT, '-o', APPDIR + '/Contents/MacOS/Xiangqi',
                        '-framework', 'AppKit', '-framework', 'AVFoundation',
                        '-framework', 'JavaScriptCore'],
                       capture_output=True, text=True)
    if r.returncode != 0:
        print(r.stdout, r.stderr)
        sys.exit('编译失败')
    subprocess.run(['xattr', '-cr', APPDIR], capture_output=True)
    subprocess.run(['codesign', '--force', '--deep', '--sign', '-', APPDIR], capture_output=True)
    r = subprocess.run([APPDIR + '/Contents/MacOS/Xiangqi'], capture_output=True, text=True,
                       env={**os.environ, 'XQ_FILM': '1'}, timeout=60)
    print(r.stdout.strip().splitlines()[-1] if r.stdout.strip() else '(无输出)')


def make_gif(out_path, max_w=760):
    from PIL import Image
    files = sorted(glob.glob(FRAMES + '/f*.png'))
    if not files:
        sys.exit('没有抓到帧')
    im0 = Image.open(files[0]).convert('RGB')
    W, H = im0.size
    # 与 BoardView.layout 一致的棋盘几何, 用来裁到相关区域
    EDGE = 0.30 + 7.0 / 220.0
    cell = min((W - 20) / (8 + 2 * EDGE), (H - 20) / (9 + 2 * EDGE))
    ox = (W - cell * 8) / 2
    oy = (H - cell * 9) / 2

    def png_xy(sq):
        r, c = divmod(sq, 9)
        return ox + cell * (8 - c), H - (oy + cell * (9 - r))    # flipBoard 后的屏幕坐标

    x0, y0 = png_xy(FROM)
    x1, y1 = png_xy(TO)
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    hw, hh = cell * 2.45, cell * 1.55
    box = (max(0, int(cx - hw)), max(0, int(cy - hh)),
           min(W, int(cx + hw)), min(H, int(cy + hh)))

    frames = []
    for f in files:
        im = Image.open(f).convert('RGB').crop(box)
        if im.width > max_w:
            k = max_w / im.width
            im = im.resize((int(im.width * k), int(im.height * k)), Image.LANCZOS)
        frames.append(im)
    # 尾帧多停 0.5s, 方便看清落定姿态
    frames += [frames[-1]] * 12
    dur = int(1000 / 30)
    frames[0].save(out_path, save_all=True, append_images=frames[1:],
                   duration=[dur] * (len(frames) - 12) + [dur * 3] * 12, loop=0, optimize=True)
    print('GIF ->', out_path, f'{len(frames)} 帧')


if __name__ == '__main__':
    patch_source()
    build_and_run()
    out = '/Users/kenttt/Documents/谭子沐象棋/效果预览/走子动画预览.gif'
    make_gif(out)
