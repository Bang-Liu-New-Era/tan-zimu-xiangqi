# 生成"选中抬起 / 上一步蓝点"视觉验证用的测试源码（只动 /tmp 副本，不碰正式源码）
import io, sys
SRC = '/Users/kenttt/Documents/谭子沐象棋/native/XiangqiApp.swift'
DST = '/tmp/XiangqiLiftTest.swift'
s = open(SRC, encoding='utf-8').read()

anchor = '        newGame(side: currentSide, diff: currentDiff)\n'
hook = '''        newGame(side: currentSide, diff: currentDiff)

        // [测试钩子] XQ_SCENE=none|lift|dot|both : none = 干净棋盘(作测量基准), 其余构造对应场景
        if let scene = ProcessInfo.processInfo.environment["XQ_SCENE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.40) {
                if scene == "none" {
                    // 什么都不做: 干净的棋盘, 用作投影测量的基准帧
                } else if scene == "lift" {
                    self.select(70)                       // 选中红炮 → 离板抬起 + 倾斜
                } else if scene == "dot" {
                    var nb = self.board                   // 手动走一步(不触发 AI): 炮二平五
                    nb[67] = nb[70]; nb[70] = 0
                    self.board = nb; self.boardView.board = nb
                    self.boardView.lastMove = (70, 67)
                    self.boardView.setNeedsDisplay(self.boardView.bounds)
                } else if scene == "fly" {
                    // 真实走子路径: 先选中(抬起)再落子 → 抬起状态必须被正确重置
                    self.select(70)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) {
                        self.performMove(from: 70, to: 67, mover: RED, byHuman: true)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.05) {
                        let diag = "appSel=\(String(describing: self.selected)) viewSel=\(String(describing: self.boardView.selected)) lastMove=\(String(describing: self.boardView.lastMove)) b70=\(self.board[70]) b67=\(self.board[67]) turn=\(self.turn)"
                        try? diag.write(toFile: "/tmp/fly_diag.txt", atomically: true, encoding: .utf8)
                    }
                } else if scene == "both" {
                    var nb = self.board
                    nb[67] = nb[70]; nb[70] = 0
                    self.board = nb; self.boardView.board = nb
                    self.boardView.lastMove = (70, 67)     // 起点蓝点停在 70
                    self.select(88)                        // 同时选中红马 → 抬起
                    self.boardView.setNeedsDisplay(self.boardView.bounds)
                }
                print("[scene]", scene, "liftT setup done")
            }
        }
'''
assert s.count(anchor) == 1, s.count(anchor)
s = s.replace(anchor, hook)

# 把快照延迟从 1.0s 放宽到 2.2s, 避开启动期主线程阻塞导致的时序假象
key = 'if let sp = ProcessInfo.processInfo.environment["XQ_SNAPSHOT"] {\n            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {'
assert s.count(key) == 1, s.count(key)
s = s.replace(key, 'if let sp = ProcessInfo.processInfo.environment["XQ_SNAPSHOT"] {\n            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) {')

open(DST, 'w', encoding='utf-8').write(s)
print('written', DST)
