# 人机中国象棋对战（谭子沐象棋）

一个**纯前端 + 轻量本地服务器**的人机中国象棋游戏。电脑棋力由内置的开源风格棋力引擎提供，**每一步思考时间严格限制在 3 秒以内**（默认难度约 1.8 秒）。

## 如何运行

```bash
cd 谭子沐象棋
node server.js
```

然后浏览器打开 **http://localhost:3000** 即可对弈。
（无需安装任何依赖，Node 自带模块即可运行；Node 22 已验证。）

> 如果你不想用命令行，也可以直接用 `python3 -m http.server 3000` 之类任意静态服务器托管本项目根目录，但 `server.js` 已经把路由、MIME 都处理好，推荐用它。

## 功能

- **人机对战**：你执红或执黑，电脑自动应招。
- **反应时间 ≤ 3 秒**：电脑每步思考受硬时间预算约束（见下）。
- **难度选择**：入门（约 0.4s）/ 进阶（约 1.0s）/ 高手（约 1.8s）。
- **悔棋**：一键退回你上一步之前（自动连退电脑应着）。
- **认输 / 新对局**。
- **中文棋谱**：自动记录每一步（如 `炮八平五`、`马八进七`）。
- **计时**：分别统计红方、黑方用时。
- **终局判定**：将死、困毙、三次重复局面判和。

## 教学版（原生 macOS 程序）⭐

不想开浏览器、想要更丰富的界面与教学功能？项目内置一个**真正的 macOS 原生 App**（Swift + WebKit 封装，双击即运行，**无需联网、无需 Node**）：

- **原生外壳**：独立 `.app`、原生菜单与工具栏（新对局 / 悔棋 / 认输 / 提示 / 先手 / 难度 / 教学开关），原生音效。
- **教学助手面板**：
  - 💡 **提示**：一键给出当前最优着法及简要理由（高亮发光显示）。
  - ⚠️ **威胁**：实时标出你（或对方）正被攻击、可能被吃的子（棋盘上红色脉冲圈 + 文字说明）。
  - 📝 **着法讲解**：每步自动生成中文讲解（开局命名如「当头炮」、是否将军、战术如「双将 / 捉双 / 马后炮」）。
  - 🎯 **走子质量点评**：你走完一步后，对比 AI 最优解，给出「好棋 / 略亏 / 败着」反馈。
  - 📊 **局势评估条**：红黑优劣势实时可视化。
- **更多 UI 特效**：吃子粒子爆发 + 红环「吃」字、被将时屏幕震动 + 红闪、提示落子发光、上一步箭头高亮。

### 构建与运行

```bash
cd 谭子沐象棋/native
bash build_app.sh
# 生成的 App 在: native/build/人机中国象棋.app
open "native/build/人机中国象棋.app"   # 或直接双击
```

> 构建仅需 Xcode 命令行工具（本机已具备 swiftc + AppKit/WebKit），**不下载任何依赖**。
> 教学逻辑来自 `engine/coach.js`；界面与特效在 `native/Resources/`，原生外壳在 `native/XiangqiApp.swift`。

## 关于“开源棋力模型”

本项目优先评估了 GitHub 上最强的开源象棋引擎 **Pikafish**（`official-pikafish/Pikafish`，Stockfish 衍生、UCI 协议）以及经典引擎 **ElephantEye（象眼）**。

但当前构建环境通过代理访问外网，单条下载连接被限制在约 120 秒，而 Pikafish 的 NNUE 权重文件约 49 MB、ElephantEye 源码也超过该上限，**无法在本环境内下载/编译原生二进制**。

因此，本项目内置了一个**自研的高强度 JavaScript 棋力引擎**（`engine/` 目录），它实现了：

- 完整的中国象棋规则（马腿、象眼、过河兵、九宫、将帅对面等）；
- 负极大值搜索（Negamax）+ Alpha-Beta 剪枝；
- 迭代加深（iterative deepening）+ **硬时间预算**（保证每步 ≤ 预算）；
- 静态搜索（quiescence）消除水平线效应；
- 置换表（transposition table）+ MVV-LVA 走法排序；
- 简单开局库与局面评估（子力 + 位置）。

该引擎在普通笔记本上即可在 ~1.8 秒内达到业余中高级水平，且**天然满足“每步 ≤ 3 秒”**。

### 可选：接入原生开源引擎（Pikafish / ElephantEye）

如果网络允许，你可以下载原生引擎二进制并让本项目直接调用它（更强的棋力）：

1. 下载 Pikafish 二进制及其 `pikafish.nnue` 权重（见 https://github.com/official-pikafish/Pikafish/releases ）。
2. 设置环境变量后启动服务器：
   ```bash
   ENGINE_PATH=/绝对路径/pikafish ENGINE_PROTOCOL=uci node server.js
   ```
3. 浏览器访问 **http://localhost:3000/?useEngine=1** 即走原生引擎。

> 注：该路径为实验性，坐标约定（`ucciToIndex` / `indexToUcci`）可能需按所用引擎微调；若使用 ElephantEye 需自行适配 UCCI 协议。

## 时间控制如何保证 ≤ 3 秒

- 浏览器端用一个 **Web Worker** 后台线程运行搜索，主线程界面不卡顿，并能实时显示思考计时。
- 搜索循环采用**迭代加深**：先搜浅层，再逐层加深；每次进入节点都检查已用时间，一旦超过预算立即中止，并采用“上一完整层”的最佳着法。
- 默认最高难度预算 1800ms，加上通信开销后仍稳定低于 3000ms。
- 服务端若走原生引擎，则通过 `go movetime <ms>`（UCI）或 `go time <ms>`（UCCI）再次兜底。

## 文件结构

```
谭子沐象棋/
├── server.js            # 零依赖静态服务器 + 可选原生引擎接入
├── package.json
├── test.js              # 规则/AI 单元测试（node test.js）
├── engine/
│   ├── xiangqi.js       # 规则引擎 + 中文记谱（浏览器/Node 通用）
│   ├── ai.js            # 搜索引擎（alpha-beta / 迭代加深 / 时间预算）
│   └── coach.js         # 教学模块（提示/威胁/讲解/战术/评估/点评）
├── public/              # 浏览器版界面（server.js 托管）
│   ├── index.html
│   ├── style.css
│   ├── app.js
│   └── worker.js
└── native/              # 原生 macOS 教学版（.app）
    ├── XiangqiApp.swift # Swift 原生外壳（窗口/工具栏/菜单/WebView/音效桥）
    ├── build_app.sh     # 编译 + 打包脚本
    ├── generate_sounds.py # 生成原生音效 WAV
    └── Resources/       # 界面与资源（index.html/style.css/app.js/sounds）
```

## 测试

```bash
node test.js
```

会校验：开局合法着法数、将帅对面规则、每步耗时 ≤ 3 秒、自对弈全程合法且能正常终局。
