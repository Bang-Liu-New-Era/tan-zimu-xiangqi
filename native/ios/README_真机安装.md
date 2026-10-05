# iPhone 真机安装指引（人机中国象棋 · iOS 版）

工程位置：`native/ios/XiangqiIOS.xcodeproj`（双击打开即可，无需 XcodeGen / CocoaPods 等任何第三方工具）

## 一、准备（一次性，约 3 分钟）

1. **装 Xcode**：App Store 安装 Xcode 26（首次打开会自动装组件，等它跑完）。
2. **登录 Apple ID**：Xcode 菜单 `Xcode → Settings…（设置）→ Accounts（帐户）→ +`，输入你的 Apple ID（免费的就行，**不需要**付费开发者账号）。
3. **数据线连接**：iPhone 17 Pro 是 **USB-C 口**，用一根**支持数据传输**的 C-to-C 线连到 Mac（原装或认证线；纯充电线会认不到设备）。手机弹「要信任此电脑吗？」→ 点**信任**，并输入锁屏密码。（手机保持**解锁**状态，锁屏时 Xcode 常认不到。）

## 二、安装到手机（每次约 1 分钟）

1. 双击打开 `native/ios/XiangqiIOS.xcodeproj`。
2. 左侧点中蓝色的 **XiangqiIOS** 项目 → 中间选 **TARGETS → XiangqiIOS → Signing & Capabilities（签名与能力）**：
   - 勾选 **Automatically manage signing（自动管理签名）**
   - **Team** 下拉选择你刚才登录的 Apple ID（显示为 "你的姓名 (Personal Team)"）
3. Xcode 顶部左侧设备选择器，选你连线的 iPhone（不要选模拟器）。
4. 按 **⌘R**（Run）。第一次会编译 + 签名；顶部会显示 "Preparing iPhone for development…"，等它跑完（一次性，1~3 分钟）。
5. **首次安装后手机上必须做两件事，缺一不可：**
   - **① 开发者模式**（iOS 16 以后强制要求，自签名 App 不开这个装了也打不开）：
     `设置 → 隐私与安全性 → 开发者模式` → 打开 → **重启手机** → 重启后解锁时弹窗点「打开」。
     ⚠️ 这个开关只有在手机**连过 Xcode 之后**才会出现在设置里。如果第一次 ⌘R 后 Xcode 提示 "Developer Mode disabled"，就是去这里开，开完重启再按一次 ⌘R。
   - **② 信任开发者**：
     `设置 → 通用 → VPN 与设备管理 → Apple Development: 你的账号 → 信任`。
6. 回到桌面点图标即可玩。棋子交互、走子动画、裂痕特效、音效与教学侧栏全部可用（教学侧栏在竖屏下半屏 / 横屏右侧）。

## 三、免费签名的限制（务必知道）

| 事项 | 说明 |
|---|---|
| 有效期 | 免费 Apple ID 签名 **7 天过期**，过期后 App 打不开 |
| 续期 | 手机插线，Xcode 里再按一次 ⌘R 即可再续 7 天（数据不会丢） |
| 设备数 | 免费 ID 最多同时 3 台设备 |
| 想长期用 | 需 Apple Developer Program（688 元/年），可上 TestFlight / App Store，签名 1 年有效 |

## 四、这个工程和 macOS 版的关系

- `src/`、`../Core`、`../Render`、`../FX`、`../Audio`、`../Support`、`../UI` 都是**同步文件夹（蓝色共享目录）**——直接引用 `native/` 下的源码，没有复制副本。
- 也就是说：**改任何一份源码，Mac 版和 iPhone 版同时生效**。
- 只有 `App/AppDelegate.swift + main.swift`（macOS 壳）和 `src/`（iOS 壳）各管各的。
- 资源（棋盘/棋子/音效/引擎 JS/图标）也是直接引用 `native/Resources/` 和 `engine/` 原目录。
- 改完代码在 Xcode 里直接 ⌘R 就会重新编译安装，无需其它操作。

## 五、常见问题

- **点 Run 提示签名错误**：检查 Team 是否选了 Personal Team；若提示 bundle id `com.tanzimu.xiangqi.ios` 已被注册（极少见），把它改成 `com.你的名字.xiangqi`（在 TARGET → General → Bundle Identifier 里改）。
- **手机选不到（设备列表灰的）**：手机解锁后再插线；换一根能传数据的 C-to-C 线；确认 Xcode → Settings → Components 里 iOS 平台已装。
- **装上了但点图标打不开 / 图标是灰的**：99% 是**没开开发者模式**，按第二节第 5 步①处理；或忘了在「VPN 与设备管理」里点信任。
- **改了音效/棋子图不生效**：资源走的是目录引用，删掉手机上的 App 重新 ⌘R 即可（Xcode 偶尔缓存资源）。
- **只想到模拟器玩（不用手机）**：终端跑 `cd native && bash ios/build_ios_sim.sh`，免签名免 Xcode 工程。
