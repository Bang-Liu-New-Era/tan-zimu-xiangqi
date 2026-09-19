# 谭子沐象棋 项目长期笔记

## 棋子贴图规格（约定）
- 目录 native/Resources/pieces/，文件名 = 棋子编码：红 r1帅 r2仕 r3相 r4马 r5车 r6炮 r7兵；黑 b9将 b10士 b11象 b12马 b13车 b14炮 b15卒
- 格式 512×512 PNG（RGBA，透明背景），棋子直径占画幅 88~92%，严格居中，不带外部投影/水印
- 批处理脚本 native/tools/prep_pieces.py（输入目录/单图，自动去水印+抠背+裁切+命名）
- 刻字提亮脚本 native/tools/enhance_pieces.py（Otsu 分离刻字 mask → HSV 提亮：红方荧光亮红、黑方亮银白 + 柔光；自动备份原图到 pieces_orig_<日期>）。当前全套已执行提亮。
- 棋子投影在渲染层做（XiangqiApp.swift drawPieceAt：CGContext.setShadow + fillEllipse，在棋子变换之前绘制，故影子不随棋子旋转）。参数约定：offset = 棋子直径的 1/16（-(r*2)/16，r=cell*0.42）、blur = cell*0.045、alpha 0.55。**blur 不能大**，否则影子糊成一片看不见。
- **全套 14 个已生成并接入 App（2026-09-19）**。风格 = 黑石抛光圆盘 + 雕刻字：红方字/装饰环为绛红 #9D2933，黑方为银灰。风格基准图为 b14.png。
- 追加棋子时用 ImageGen image-to-image（参考图 b14.png + input_fidelity=high）保持风格，**必须串行调用**（并发会因文件名冲突互相覆盖）。
- App 侧：XiangqiApp.swift 的 BoardView.pieceTexture(_:) 负责加载（缺图自动回退程序化绘制）；显示边长 = 格宽 × 0.84 / PIECE_TEX_RATIO(0.897)。

## 棋盘贴图规格（约定）
- native/Resources/boards/board.jpg|png；网格区必须 8 格宽 × 9 格高；生成参数 CELL=220px、INSET=7px 与原图检测坐标对齐

## 构建 / 安装 / 启动（重要约定）
- 正式版固定装在 `/Applications/人机中国象棋.app`，bundle id `com.example.xiangqi`；构建一律走 `native/build_app.sh`（会先杀掉运行中的旧实例，输出到 `$TMPDIR/xiangqi-build`，安装后刷新 LaunchServices 注册）。
- **绝不要把 .app 构建产物放进项目目录**：项目在 iCloud 同步的「文稿」下，会产生 "人机中国象棋 HH-MM-SS.app" 冲突副本；同名 bundle id 多份副本 → 双击 App 没反应（系统激活的是废纸篓里的僵尸实例）。
- 排查「双击没反应」：`pgrep -fl Xiangqi` → `lsof -p <pid> | grep MacOS` 看真实二进制路径 → `lsregister -dump | grep com.example.xiangqi` 看注册了哪些路径。一键修复：`bash native/tools/repair_launchservices.sh`。
- 验证窗口是否真的显示：用 `CGWindowListCopyWindowInfo` 查 owner/title/bounds（不需要录屏权限）。screencapture 与 AppleScript GUI 自动化在本机被权限拒绝；CGWindowListCreateImage 在 macOS 26 已移除。
- App 已支持关窗后再点图标恢复窗口（applicationShouldHandleReopen + 菜单「窗口 > 显示主窗口 ⌘0」）。

## 音效规格（约定）
- 目录 native/Resources/sounds/（全部 44100Hz / 16bit / mono WAV）。命名：move_1..4、lift_1..2、capture_1..3、check_1..3、click、win、lose、voice_chi / voice_jiangjun / voice_juesha / voice_heqi。
- 生成脚本 native/tools/make_sounds.py（物理建模合成：噪声瞬态 + 阻尼共振模态 + 房间反射；人声用 `say -v Tingting` 渲染后 afconvert + numpy 处理）。**不要再用正弦/方波时代的 native/generate_sounds.py（已改为转调外壳）**。
- 试听台生成脚本 native/tools/make_preview.py → 工作区根目录 `音效试听台.html`（音频 base64 内嵌，单文件可离线打开）。
- App 侧：XiangqiApp.swift 的 SoundEngine 单例；每类多变体随机 + 播放时 rate 随机 ±5%；playSound(key) 播音效，speak(key, delay:) 播人声（刻意延后于撞击声）。新增音效只需加文件 + 在 SoundEngine.groups / voiceFiles / gains 登记。
- macOS 离线中文语音：只有 Tingting 可用；Eddy/Flo/Rocko/Sandy 等 eloquence 语音用 `say -o` 只产出 16ms 静音。

## 棋子交互视觉（约定）
- **选中抬起**：点选棋子后该子离板（中心上移 **0.44 格** + 放大 1.10 + 旋转 15°），棋盘原位留柔影。驱动在 BoardView 的 `liftT/liftSq/liftPiece`，由 `selected` 的 didSet → `kick()` → `tick()` 带 dt 推进（0.14s），静止自动停 timer。
  - 抬升必须 > 棋子半径（0.42 格），否则棋子会把自己在棋盘上的投影全遮住。
- 抬起子绘制时必须 `drawPieceAt(..., castShadow: false)`，否则 setShadow 那套"黑圆被棋子盖住"的写法会在棋子移开后露出黑斑。
- **选中不额外画高亮**（既无填充圆也无描边环）——环贴着投影外缘会被看成"投影的边框"。选中反馈只靠"抬起"。
- **抬起投影规格**：纯黑 `NSColor(calibratedWhite: 0.0)`，峰值 alpha = **0.45**，径向渐变 6 档平滑收敛到 0（stops `[0,.28,.52,.72,.88,1]` / decay `[1,.95,.83,.62,.32,0]`），**无描边**。半径 `rShadow = cell*0.42*(1.0+0.10*lift)*1.02`（= 棋子可见半径，实测可视宽 0.924 格 = 抬起后棋子直径），y 压缩 0.94，中心下移 0.055 格。实测暗化 22.8%（相对同行棋盘基线）；经验：深灰在带纹理的浅色棋盘上存在感弱，降 white 收效有限（0.25→0 只多暗约 19/255），提 alpha 才是关键。
- **投影测量的可靠方法**：不能用"有选中 vs 无选中"两帧差分（选中会画合法落点提示点，污染结果）。正确做法：把源码 `let a = 0.45 * lift` 改成 `let a = 0.0 * lift` 编出第二个二进制，两张快照相减得纯投影。棋子直径直接取设计值（可见直径 0.84 格，抬起 ×1.10），别用阈值行扫描去量（格线会连通成一片）。
- **上一步标记**：只在 lastMove 的起点画小圆点（直径 = 棋子直径的 1/10 = cell*0.084）+ 蓝色径向渐变光晕；**没有横线和箭头**。

## 走子动画（约定）
- **不需要任何外部引擎**：BoardView 已有 60fps 重绘循环（`tick()` + Timer），动画 = 每帧算位置再画（CoreGraphics）。Godot/Cocos2d-x/Phaser 等对 2D 棋盘属过度设计。
- `MoveAnim`（from/to/piece/start/fly/land）；fly=0.26s + land=0.13s。飞行段用 smoothstep 缓入缓出 + 抛物线抬升 `cell*0.30*4u(1-u)` + `1+0.13*arc` 缩放 + `14°*sin(πu)` 旋转；落地段用阻尼振荡压扁回弹 `amp=0.13*e^(-4.2v)cos(6.2v)`。
- 飞行中棋子的投影由 `drawFlightShadow` 单独画（固定在正下方棋盘位置、越高越淡越散），**飞行棋子的 castShadow 必须为 false**。落地另有 `landRipple` 扩散细环（长于 anim，tick 的 active 判定要单独计入）。
- 预览动图生成脚本 native/tools/make_move_film.py（注入虚拟时钟 `XQ_FILM_T` 逐帧定格渲染 → GIF，输出到 效果预览/走子动画预览.gif）。

## 渲染与验证手段
- XQ_SNAPSHOT=/path.png 环境变量：启动时离屏渲染棋盘快照（正常使用无影响）。注意 `open` 不透传环境变量，须直接执行 Contents/MacOS/Xiangqi。快照延迟默认 1.0s，抓帧验证请留足余量（改到 2.2s），否则启动期主线程阻塞会让动画完成时刻落在快照之后，产生"状态残留"的时序假象。
- App 内 `print()` 不会落到重定向的 stdout（被 kill 时缓冲丢失）；诊断信息写文件（`try? "".write(toFile:...)`）。
- 修改渲染代码后，复制 XiangqiApp.swift 到 /tmp 注入钩子做回归验证，不动正式源码。可用钩子：XQ_SIDE=b（切执黑）、XQ_SCENE=lift|dot|both|fly（选中抬起/起点蓝点/同框/真实走子路径）、**XQ_FX=crack|crack_mid|drizzle|rain|storm|horse|paths**（预置特效场景，逗号可组合）、XQ_SNAP_DELAY（快照延迟秒）。全部由 `XiangqiApp.swift` 内的 env 分支实现，正常使用无影响。
- 出图流水线：`/tmp/xq_shots.sh`（逐场景启动 App → 等 PNG → kill）+ `/tmp/crop.swift in.png out.png x y w h`（CGImage.cropping，**左上角为原点**）+ `sips -Z N` 放大看细节。

## 特效模块（约定，2026-09-19 深夜）
- 分层 z 序（顶→底）：L8 全屏提示 / L7 演员(马) / L6 天气(雨) / L5 瞬时特效 / L4 棋子与走子 / L3 标记 / L2 伤痕贴花(裂痕) / L1 棋盘。震屏变换只包住 L1~L5，演员与雨在变换之外。
- **四种生命周期**：瞬时(FX，用完即弃) / 永久(Crack，只在开新局或菜单清除时删) / 常驻(Weather，靠 active 判定维持 60fps) / 一次性(Actor，按绝对时间取帧)。加新特效先想清属于哪一类。
- **轨迹** `Trajectory`：形状只输出「法向侧偏 + 离板抬升」两个标量（单位=格），推进节奏交给 `Ease`；采样后再乘 cell。加新轨迹形状 = 在 `shapeScalars(_:)` 里加一个 case，不要动采样/绘制代码。
- **裂痕** `CrackForge.forge(sq:born:seed:power:)` 用 `SeededRNG` 确定性生成，`branches` 存相对格中心的点集；绘制三层(缝隙暗带→深色主缝→断口亮边)+中心焦痕，按 `e × 总段数` 截断做生长动画。车/炮/马 power 依次 1.0/0.92/0.80。
- **模拟推演不留痕**：`animateMove(..., scar: Bool = true)`，simPlay 传 `scar: false`。
- **演员素材**：`native/Resources/actors/<名>/run_NN.png`，文件名排序即帧序，16fps；缺目录自动退回 `HorseArt` 程序化剪影。换动物 = 复制目录改名 + 改 `runHorse()` 里的 `load("horse")`。规范见该目录 README.md。
- 菜单「特技」控制全部特效，选择存 UserDefaults(`xq.fxShape/fxEase/fxWeather/fxCrack`)，启动时 `applyFX()` 恢复。
