# iPhone 真机安装指引（人机中国象棋 · iOS 版）

工程位置：`native/ios/XiangqiIOS.xcodeproj`（双击打开即可，无需 XcodeGen / CocoaPods 等任何第三方工具）

## 一、准备（一次性，约 3 分钟）

1. **装 Xcode**：App Store 安装 Xcode 26（首次打开会自动装组件，等它跑完）。
2. **登录 Apple ID**：Xcode 菜单 `Xcode → Settings…（设置）→ Accounts（帐户）→ +`，输入你的 Apple ID（免费的就行，**不需要**付费开发者账号）。
3. **数据线连接**：用 Lightning / USB-C 线把 iPhone 连到 Mac，手机上点「信任此电脑」。

## 二、安装到手机（每次约 1 分钟）

1. 双击打开 `native/ios/XiangqiIOS.xcodeproj`。
2. 左侧点中蓝色的 **XiangqiIOS** 项目 → 中间选 **TARGETS → XiangqiIOS → Signing & Capabilities（签名与能力）**：
   - 勾选 **Automatically manage signing（自动管理签名）**
   - **Team** 下拉选择你刚才登录的 Apple ID（显示为 "你的姓名 (Personal Team)"）
3. Xcode 顶部左侧设备选择器，选你连线的 iPhone（不要选模拟器）。
4. 按 **⌘R**（Run）。第一次会编译 + 签名，稍等。
5. 首次安装后手机上直接点图标会提示「不受信任的开发者」：
   手机 `设置 → 通用 → VPN与设备管理 → Apple Development: 你的账号 → 信任`。
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
- **手机选不到（设备列表灰的）**：手机解锁后再插线；确认 Xcode → Settings → Components 里 iOS 平台已装。
- **改了音效/棋子图不生效**：资源走的是目录引用，删掉手机上的 App 重新 ⌘R 即可（Xcode 偶尔缓存资源）。
- **只想到模拟器玩（不用手机）**：终端跑 `cd native && bash ios/build_ios_sim.sh`，免签名免 Xcode 工程。
