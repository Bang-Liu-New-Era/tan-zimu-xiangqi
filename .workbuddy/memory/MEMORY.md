# 谭子沐象棋 项目长期笔记

## 棋子贴图（约定）
- `native/Resources/pieces/`，文件名=棋子编码：红 r1帅 r2仕 r3相 r4马 r5车 r6炮 r7兵；黑 b9将 b10士 b11象 b12马 b13车 b14炮 b15卒。
- 规格：512×512 PNG（RGBA 透明底），棋子直径占画幅 88~92%，严格居中，无外部投影/水印。
- 工具：`tools/prep_pieces.py`（去水印+抠背+裁切+命名）、`tools/enhance_pieces.py`（Otsu 刻字 mask → 红方荧光亮红 / 黑方亮银白，原图备份到 `pieces_orig_<日期>`，全套已执行）。
- 追加棋子用 ImageGen image-to-image（参考 `b14.png` + `input_fidelity=high`），**必须串行调用**（并发会因文件名冲突互相覆盖）。
- 风格：黑石抛光圆盘 + 雕刻字，红方字/环 #9D2933、黑方银灰；基准图 b14.png。
- 渲染：投影在 `Render/PieceRenderer.swift` 的 `drawPieceAt` 用 `setShadow` 画（在棋子变换之前 → 影子不随棋旋转）。参数：offset = 直径 1/16、blur = `cell*0.045`（**不能大**，否则糊成一片）、alpha 0.55。
- App 侧 `BoardView.pieceTexture(_:)` → `Render/PieceTextures.swift`（缺图回退程序化绘制）；显示边长 = 格宽 × 0.84 / PIECE_TEX_RATIO(0.897)。

## 棋盘贴图（约定）
- `native/Resources/boards/board.jpg|png`；网格区必须 8 格宽 × 9 格高；生成参数 CELL=220px、INSET=7px 与原图检测坐标对齐。

## App 图标（约定）
- `native/Resources/AppIcon.icns`，由 `tools/make_appicon.py` 合成；`build_app.sh` 已含"拷图标 + Info.plist `CFBundleIconFile=AppIcon`"，不需单独操作。
- 当前 = 谭子沐照片（人像模式）。裁剪框中心 (664,552) 边长 478（原图 `Resources/iconwork/source.jpg`）。
- 换照片一条命令：`bash native/tools/icon_from_photo.sh <照片>`（Vision 找人脸 → 抠人物 → 按「边长 1.78×脸高、中心在脸中心上方 0.20 脸高」推裁剪框 → 出 icns；`NO_CUT=1` 关人像模式）再 `bash native/build_app.sh`。底层件 `tools/iconvision.swift` + `tools/make_appicon.py`。
- **验证要取 `NSWorkspace.icon(forFile:)` 的解析结果**（getsysicon.swift），只看 icns 在不在不算数。规范：画布 1024、内容区 824、圆角 0.2237×824。

## 构建 / 安装 / 启动（重要）
- 正式版固定 `/Applications/人机中国象棋.app`，bundle id `com.example.xiangqi`；构建一律 `native/build_app.sh`（先杀旧实例 → 输出到 `$TMPDIR/xiangqi-build` → 安装 → 刷新 LaunchServices）。
- **绝不要把 .app 产物放进项目目录**（iCloud 同步会造出 "人机中国象棋 HH-MM-SS.app" 冲突副本 → 同名 bundle id 多份 → 双击没反应）。
- 「双击没反应」排查：`pgrep -fl Xiangqi` → `lsof -p <pid> | grep MacOS` → `lsregister -dump | grep com.example.xiangqi`；一键修复 `bash native/tools/repair_launchservices.sh`。
- 验证窗口真显示：`CGWindowListCopyWindowInfo` 查 owner/title/bounds（screencapture 与 AppleScript GUI 自动化在本机被拒；CGWindowListCreateImage 在 macOS 26 已移除）。
- 支持关窗后点图标恢复（`applicationShouldHandleReopen` + 菜单「窗口 > 显示主窗口 ⌘0」）。

## Git / GitHub 同步（约定）
- 远端 `https://github.com/Bang-Liu-New-Era/tan-zimu-xiangqi`（SSH）。一键：项目根 `bash sync.sh`（add -A → 有改动才 commit → push → 比对 HEAD 与 ls-remote，失败自动重试一次）。
- 本机 `github.com:443`(HTTPS) 被阻断，`api.github.com` / `github.com:22` / `ssh.github.com:443` 通 → `~/.ssh/config` 把 github.com 指到 `HostName ssh.github.com / Port 443`。`gh` CLI 装不上（沙箱禁写 /opt/homebrew），一律用系统 `git` + `curl`。
- GitHub 已停用密码认证，**不要索要密码**；公钥由用户自己贴到网页。
- 沙箱下 commit/push 可能被权限拦截，重跑像"已无改动"——用 `git log` / `git status --porcelain` 复核，别误判。

## 音效（约定）
- `native/Resources/sounds/`，**一律 44100Hz / 16bit / mono PCM WAV**。命名：move_1、lift_1..2、capture_1..3、check_1..3、click、win、lose、voice_chi / voice_jiangjun / voice_juesha / voice_heqi。
- **落子 = 外部素材**（用户给的 AI `chess_move.wav`：原 48kHz 立体声、峰值 −9.5dBFS、**开头 173ms 空白**）→ `prep_sfx.py` 规范化成 78ms / −1dBFS 单声道 `move_1.wav`，故落子只有 1 个变体。旧合成变体在 `tools/archive/sounds_synth_move/`。
- `tools/prep_sfx.py`（**外部素材一律先过它**）：下混 → 裁首尾 → 重采样 → 尾部门限 → 淡入淡出 → 归一化。默认 `--gate -50 --tail 25 --fade-in 1.5 --fade-out 12`；**撞击类淡入别超 2ms**（削瞬态）。支持 `--dry-run` / `--batch`。
- `tools/make_sounds.py`（物理建模；人声用 `say -v Tingting` + afconvert + numpy）。**默认不再合成落子**（要加 `--with-move`）。别用旧的 `generate_sounds.py`（已改转调外壳）。
- 试听台 `tools/make_preview.py` → 根目录 `音效试听台.html`（base64 内嵌，可离线）。**按 SoundEngine.gains 套音量**，改增益要两处同步。
- App：`Audio/SoundEngine.swift` 单例；变体随机 + 播放 rate ±5%；`play(_:)` 音效、`speak(_:delay:)` 人声（刻意延后于撞击）。新增音效 = 加文件 + 在 SoundEngine 的 groups/voiceFiles/gains 与 make_preview 的 GROUPS 登记。
- macOS 离线中文语音只有 **Tingting** 可用（Eddy/Flo/Rocko/Sandy 用 `say -o` 只出 16ms 静音）。

## 棋子交互视觉（约定）
- **选中抬起**：中心上移 **0.44 格** + 放大 1.10 + 旋转 15°（必须 > 棋子半径 0.42，否则投影被自己盖住）。驱动 `liftT/liftSq/liftPiece`，`selected.didSet → kick() → tick()` 带 dt 推进 0.14s，静止停 timer。
- 抬起子绘制必须 `drawPieceAt(..., castShadow: false)`（否则移开后露出黑斑）。**选中不额外画高亮**（无填充圆、无描边环——环贴投影外缘会被读成"投影的边框"）。
- **抬起投影**（`Render/PieceLayer.swift`）：纯黑，峰值 alpha **0.54**，径向渐变 6 档（stops [0,.28,.52,.72,.88,1] / decay [1,.95,.83,.62,.32,0]），**无描边**；半径 `cell*0.42*0.894*(1+0.10*lift)*1.02`（0.894=√0.80 即面积 −20%），y 压缩 0.94，中心下移 0.055 格。
- **投影测量的可靠方法**：不能拿"有选中/无选中"两帧差分（落点提示点会污染）。把 `let a = 0.54*lift` 改成 `0.0*lift` 编第二个二进制，两帧相减得纯投影。棋子直径取设计值（可见 0.84 格、抬起 ×1.10），别用行扫描量（格线会连通）。
- **上一步标记**：只画起点小圆点（直径 = 棋子直径 1/10 = `cell*0.084`）+ 蓝色径向光晕；**没有横线和箭头**。

## 走子动画 + 震屏（约定）
- **不需要外部引擎**：BoardView 自带 60fps `tick()` + Timer，动画=每帧算位置再画（CoreGraphics）。
- `MoveAnim` 由 `FX/MoveAnimator.swift` 编排，飞行段在 `Render/PieceLayer.swift` 画。
- **默认轨迹 = `Shape.slam`「重锤(发力)」**（不走抛物线）：fly 0.20s / land 0.16s / hop 0.22 格 / `impact 1.9`；抬升 `hop*sin(π*u^0.62)`（u≈0.33 到顶后俯冲）+ 默认 `Ease.easeIn`。`amp = 0.13*impact*e^(-4.2v)*cos(6.2v)`。
- 飞行投影由 `flightShadow` 单独画（固定正下方、越高越淡越散），**飞行棋 castShadow 必须 false**；落地另有 `landRipple` 扩散环（长于 anim，tick 的 active 判定要单独计入）。
- **震屏**：`ctx.shakeX = sin(now*40)*shakeAmp`，RenderPipeline 只对 `followsShake` 层 `translateBy(x: shakeX)`（横向抖，顶层 UI 不抖）。MoveAnimator 在落地时设幅值：普通落子 3 / 吃子 6 / 吃子砸裂 6.5 px，持续到 `landT+0.10~0.20s`。
  - **全局系数 `BoardView.shakeScale`（当前 0.5）**：三个数值都乘它。**调震感只改这一处**。实测 0.5 → 1.5/3.0/3.25 px。
- 预览动图：`tools/make_move_film.py`（注入虚拟时钟 `XQ_FILM_T` 定格渲染 → GIF，输出 `效果预览/走子动画预览.gif`）。

## 架构分层（约定）
- 目录：`Core/`(局面与规则) `Render/`(图层与绘制) `FX/`(特效) `UI/`(BoardView 壳+菜单) `App/`(AppDelegate+main.swift) `Audio/` `Support/`(跨平台垫片)。
- **每种视觉元素 = 一个 `RenderLayer`**（`name`/`followsShake`/`isAnimating`/`update`/`draw`），在 `BoardView.buildPipeline()` 注册一行即可，绘制顺序=注册顺序。图层只读 `RenderContext`（now/cell/ox/oy/flip/cg/shakeX/`dispRC`/`center`），**不直接读 BoardView**。
- `Render/LayerCache.swift` 离屏缓存已被实测**证伪并删除**（直绘 0.94ms vs 缓存 0.99ms）——**不要再试离屏缓存**。

## 渲染与验证手段
- `XQ_SNAPSHOT=/path.png` 离屏出图（`open` 不透传环境变量，须直接跑 `Contents/MacOS/Xiangqi`）；延迟默认 1.0s，抓帧建议 ≥1.2s（改到 2.2s 更稳），否则主线程阻塞会造成"状态残留"的时序假象。
- App 内 `print()` 不落 stdout（kill 时缓冲丢失）→ 诊断写文件。
- 调试钩子（`App/AppDelegate.swift` 的 env 分支，正常使用无影响）：`XQ_SIDE=b`、`XQ_SNAPSHOT`、`XQ_SNAP_DELAY`、`XQ_FX=crack|crack_mid|paths`（`XQ_CRACKS=N` 指定裂纹数）、`XQ_SCENE=lift|fly`、`XQ_PERF=1`。
- 出图流水线：`/tmp/xq_shots.sh` + `/tmp/crop.swift in out x y w h`（**左上角为原点**）+ `sips -Z N` 放大。
- 回归：`bash tools/regress.sh compare /tmp/xqbase /tmp/xqnew`（clear/paths/crack 三场景 strict 逐像素=0，crackmid 松容差）。**改视觉后基线必须重拍并说明意图**。
- **量化参数改动**：A/B 双二进制（改系数→两次 swiftc）+ 运行期探针；别靠快照抓帧（`sin(now*40)` 相位随机）。
- **测单帧绘制耗时**：给 /tmp 副本注入 `XQ_BENCH=N`（`boardView.display()` 连续 N 次取平均写日志），配 `XQ_CRACKS=40` 满负荷。**探针必须等窗口布局完成（`asyncAfter`）**，否则 display() 空转、量到 0.0026ms 这种假数。比 `tools/perf.sh` 可靠（静止场景定时器会停，采不到样本）。
- **判定亮边/暗边方向**：在 /tmp 副本把其它层 alpha 归零，分别导出"只有槽底""只有亮边"，与 clear 相减做红青叠加（`/tmp/composite.swift`）。
- **怀疑"改了代码画面没变"**：① Read 对**同名图片**会误报"未变"→ 用带时间戳的文件名；② 决定性测试=把参数改成夸张值→编译→比快照 md5；③ 只验生成端逻辑：`FX/CrackForge.swift` + `Core/Rng.swift` + main.swift 一起 swiftc 成命令行程序 dump。

## 特效模块（约定）
- z 序（底→顶）= buildPipeline 注册顺序：棋盘石板 → 永久裂痕 → 标记 → 棋子与走子 → 涟漪/爆点 → 调试轨迹 → 全屏提示。震屏只包 `followsShake` 层（当前前 6 层）。
- **四种生命周期**：瞬时(FX) / 永久(Crack，开新局或菜单清除才删) / 常驻(靠 active 判定维持 60fps) / 一次性(按绝对时间取帧)。加特效先归好类。
- **轨迹** `Trajectory`（FX/Trajectory.swift）：形状只输出「法向侧偏 + 离板抬升」（单位=格），节奏交给 `Ease`，采样后乘 cell。加形状 = 在 `shapeScalars(_:)` 加 case。预置 7 形状 + 7 缓动，默认 slam + easeIn。
- **裂痕 = 碎裂石板 H**（2026-09-27 定稿：用户从 F/G/H/I 候选中选 H「碎裂·细碎」；`CrackForge.forge(sq:born:seed:power:)` 用 `SeededRNG` 确定性生成，`maxDecals = 60`）。
  - 配方：碎区 **56% 棋子面积**、**8 块**、缝 **0.034 格**、spread 1.60、发丝裂 11、颗粒密度 520。`power` 只调线宽/深浅（车 1.0 / 炮 0.92 / 马 0.80 / 其他 0.72，由 MoveAnimator 传）。
  - 几何四条铁律：① 撒 `pieces×3.8` 个种子做**功率图**（加权 Voronoi，权重随机才有大小块）；② 只取**离冲击点最近的一撮**当碎区，凑目标面积；③ 缝只在**碎块与碎块之间**产生（与"没碎的邻居"那条边不缩）——**碎区轮廓必须由碎块的边自己拼出来**；④ 收完按**面积加权重心**拉回冲击点。
  - 收块两条规则缺一不可：硬上界 80% 棋子面积；同时"离目标更远就停"（只有这样才落在 46%~80% 中间）。
  - 渲染（`CrackLayer.drawShatter`）：缝 = **未缩块 − 内缩块** nonzero 一次填充；块面只做**逐块明暗差**（`cellShade`），**不整体提亮**；亮唇只给正对光的边且乘 `|法线·光线|^1.7`、又窄又淡；颗粒只撒块内（撒缝里会被盖掉）。`branches` 里只剩**块内发丝裂**，走坡口画法但 `thin` 模式（3 层，省 4 次填充）。
  - **三个不要回退的坑**：① 不许"先画圆再裁碎块"（轮廓成圆弧+坡口闭合=贴上去的圆标签）；② 不许碎块整体提亮（亮补丁=贴片）；③ 不许沿轮廓一圈均匀亮唇（=玻璃碎片）。断口主体读数永远是"暗"。
  - 性能实测（400 次重绘取平均）：空盘 0.275ms / 40 道 **2.72ms**（上一版辐射裂纹 2.08ms）→ 占 60fps 预算约 16%。
  - 发丝裂沿用坡口那套：`aoBands`(3 圈 0.050/0.078/0.105) / `wallBand`(shift −0.34) / `coreBands`(0.58/0.42) / `litBand`(shift +0.36)。两条铁律：受光的是**背对光源那侧**的壁（deboss：光从左上来→亮边在下边）；亮边宽度乘 `|cross(方向,光线)|^0.6`。每"层"合成一条 CGPath 一次 fill（nonzero 取并集，**要求多边形都逆时针**，`Ribbon.flip` 构造时测绕向）。
  - **已废弃的实现**（不要回退）：从中心放射的"星芒/枯枝"裂纹（方向累积式生长）、"描边 + 偏移亮边"的伪刻痕。
- **模拟推演不留痕**：`animateMove(..., scar: Bool = true)`，simPlay 传 `false`。
- 菜单「特技」控制特效，选择存 UserDefaults(`xq.fxShape/fxEase/fxCrack`)，启动 `applyFX()` 恢复。
- **已删除（2026-09-25 用户要求）**：下雨/天气 `FX/WeatherLayer.swift`、马跑过 `FX/ActorLayer.swift` + `Resources/actors/`、菜单天气与马、`fxWeather`。别按旧文档找这些文件。

## 走棋引擎（约定）
- 规则引擎 = `engine/xiangqi.js`（ai.js/coach.js 复用它），走子生成 `generateLegalMoves`、攻击判定 `isAttacked`。
- **2026-10-05 修复两个 bug 并与权威 xqwlight 对拍到完全一致**（perft 44/1920/79666 + depth-2 divide 44 根着法全同）：
  ① `isAttacked` 马腿方向（腿 = `ar - dr/2`，[dr,dc] 是目标→马偏移，别写 +）；② 补了象的攻击检测（田字+象眼+不过河）。
  炮**无炮架不能吃**——直线扫描第一个子是炮时不 return（当炮架）。
- isAttacked 在「target 是空格/攻击方己子」上会多报，但将军判定 target 恒为王格，不受影响；对拍须排除这些格。
- **引擎有多处副本，改引擎必须全同步**：`engine/*.js`（源头）、`native/Resources/*.js`（死副本）、
  `象棋单机版.html` 内嵌 `<script id="libs-xq">`/`libs-ai` 段。build_app.sh 与 iOS 工程都直接引用 engine/ 原目录 ✓。
- perft 基准（权威 xqwlight 实测）：44 / 1920 / 79666。对拍脚本在 /tmp/test_horse_leg.js 等（会话级，丢了可按日志重建）。

## iOS 移植（约定）
- 目录：源码 `native/ios/src/`（AppIOS / BoardViewIOS / CoachPanelIOS / GameViewController / Diag）；真机工程 `native/ios/XiangqiIOS.xcodeproj`（手写 pbxproj，objectVersion 77）；说明 `native/ios/README_真机安装.md`；模拟器一键 `cd native && bash ios/build_ios_sim.sh`。
- **工程结构铁律**：源码用**同步组**（`src`、`../Core|Render|FX|Audio|Support|UI`，改一份双端生效）；**资源必须用经典蓝色文件夹引用**（`../Resources/sounds|pieces|boards` + `../../engine/*.js`）——同步组的子目录是"组"，资源会被**平铺拷到包根**。
- `../App/main.swift` 只列进工程、**不进 iOS 编译**（避免与 `@main` 冲突）；`../App/AppDelegate.swift` 用经典引用进 Sources（全文件 `#if canImport(AppKit)` 守卫，iOS 下编译为空）。
- **图标不用 Asset Catalog**：本机 actool 报 `No simulator runtime version from ["23E254a"] ... iphonesimulator SDK 23F81a`（Xcode 26.6 SDK 与已装 iOS 26.5 runtime 错配）。改用 `ios/icon/*.png` 拷包根 + Info.plist `CFBundleIcons`/`CFBundleIcons~ipad`。
- 命令行验证（免签）：`cd native/ios && xcodebuild -project XiangqiIOS.xcodeproj -target XiangqiIOS -destination 'generic/platform=iOS' -configuration Release CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO SYMROOT=$TMPDIR/xiangqi-xcode-build OBJROOT=$TMPDIR/xiangqi-xcode-build/obj build`（`-target` 会忽略模拟器 destination）。
- 通用做法见技能 `~/.workbuddy/skills/xcode-project-cli/SKILL.md`。
- 真机：免费 Apple ID 签名 7 天有效，到期重按 ⌘R 续期；`bundle id = com.tanzimu.xiangqi.ios`。
