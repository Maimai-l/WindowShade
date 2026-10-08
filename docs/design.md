# WindowShade 设计

这份文件从功能需求出发，重新规定 WindowShade 该怎么搭。现有代码按这里的结构逐步改写；
改写期间，两者不一致时以这里为准，差异在“迁移”一节里逐项记账。

## 1. 现在的代码为什么难改

不是某一处写错，是结构上没有人管过整体：

- **几十轮接力，每轮只往上加。** 147 次提交里，功能是一轮一轮加上去的（合盖动画、手势、置顶、
  跨桌面、Dock 窗口列表……后来又整块删掉）。每轮修自己碰到的问题，没有回头收拾结构。
- **所有状态挂在一个对象上。** `AppDelegate` 有 106 个成员变量，22 个文件都是它的扩展。
  任何地方都能改任何状态，改一处很难知道会碰到哪里。
- **收起是一个 514 行的函数**（`ShadeController.shade()`），里面再套一个安装闭包。
  截图、裁剪、选样子、写恢复记录、藏窗口、交接焦点、显示卷帘条全在里面，先后顺序靠注释维持。
  收起时的闪烁和“整扇窗先没了”都是这个顺序没对上。
- **每次出事加一条补丁，补丁不收拢。** 截图有三条路，藏窗口有五级退路，外加 Space 归属兜底、
  定时核对（reconcile）、延迟验证重试、回调身份戳……每条都对应一次事故，但没有一个地方能
  一眼看出“收起到底分几步、每步可能怎么失败”。
- **比例失衡。** 约 2.2 万行 Swift 里，应用内更新（含看护进程、备份、换回）占 3,800 行，
  比收起 / 展开核心（3,200 行）还多。
- **App 特判一半在策略表里，一半散在外面。** `Compatibility/Policies.swift` 管了 10 种 App，
  另有约 40 处按 bundle ID、名字判断的代码散在收起、截图、外框解析里。

## 2. 功能需求

只保留卷帘本身。编号后面的 P0 / P1 / P2 是取舍顺序：P0 必须有；P1 保留但可以晚一点重写；
P2 建议砍，等你拍板。

### 2.1 收起与展开（P0）

| 编号 | 需求 | 验收 |
|---|---|---|
| F1 | 双击任意窗口的标题栏，窗口收成一条卷帘条，停在原处；`⌃⌘C` 同样 | 双击到窗口主体消失 ≤ 250ms；全程没有空帧、没有别的窗口先盖上来 |
| F2 | 双击卷帘条、`⌃⌘C`、`⌃⌘1…9`、菜单里点它，窗口回到原位、原大小，拿到焦点 | 位置和大小与收起前一致；全程没有空帧 |
| F3 | 收起和展开都不播系统动画（不缩进 Dock） | 录屏里看不到最小化动画 |
| F4 | 收起时焦点交给后面那扇窗，菜单栏跟着变 | 收起后按键不落到藏起来的窗口上 |
| F5 | 三击标题栏仍是系统原来的双击动作（缩放或最小化） | 按系统设置执行 |

### 2.2 卷帘条（P0）

| 编号 | 需求 |
|---|---|
| S1 | 卷帘条就是原标题栏的截图，和原窗口对齐、圆角一致 |
| S2 | 拖动卷帘条可以挪位置；展开时窗口出现在新位置 |
| S3 | 卷帘条上的红绿灯作用在真窗口上（关闭、最小化、全屏） |
| S4 | 卷帘条在最前面时，`⌘W` `⌘M` `⌘H` `⌘Q` `⌘N` 交给背后的 App；`⌘Q` 先把窗口放回来 |
| S5 | 没有屏幕录制权限、或截图不像标题栏时，用统一样式的标题栏代替 |

### 2.3 看一眼（P0）

| 编号 | 需求 | 验收 |
|---|---|---|
| G1 | 指针在卷帘条上停 0.25 秒，下面挂出原尺寸的窗口画面；移开收回 | 只是路过不出现 |
| G2 | 画面尽量是实时的；拿不到就用收起时的截图，并写明 | — |
| G3 | 单击卡片或双击卷帘条：真正展开，卡片留到真窗口回到原位才撤 | 没有空帧，没有录屏胶囊 |
| G4 | 看一眼不切换当前 App、不移动任何窗口 | — |

### 2.4 收起后的样子（P1）

| 编号 | 需求 |
|---|---|
| A1 | 三种样子：跟原来一样（截图）/ 统一标题栏 / 缩略图 |
| A2 | 透明度滑块；“浮在其他窗口上面”开关 |
| A3 | 音效开关，收起和展开各选一个声音 |
| A4 | `⌃⌘0` 整理卷帘条：排成一排，再按放回原位（缩略图排到屏幕下边） |

### 2.5 菜单栏与设置（P1）

| 编号 | 需求 |
|---|---|
| M1 | 菜单栏：收起或展开当前窗口、已收起的窗口（前 9 个带 `⌃⌘1…9`）、全部展开、设置、退出 |
| M2 | 设置四页：卷帘、快捷键、权限与启动、高级 |
| M3 | 快捷键可以录、可以清；新装的一个都不占，升级上来的保留原来的 |
| M4 | 首次打开的欢迎窗口：放进“应用程序”、两项授权 |

### 2.6 可靠性（P0）

| 编号 | 需求 |
|---|---|
| R1 | WindowShade 崩溃、被强退或电脑断电，重启后藏起来的窗口都能找回 |
| R2 | 用户从 Dock、`⌘Tab`、调度中心把窗口叫回来时，卷帘条自动撤掉 |
| R3 | 窗口被关闭、App 退出时，卷帘条跟着清掉 |
| R4 | 切换桌面、插拔显示器后，卷帘条仍在原窗口所在的桌面和屏幕上，拿得到 |
| R5 | 别的 App 卡住时，WindowShade 不跟着卡（任何一次跨 App 调用都不在主线程上等） |

### 2.7 建议砍（P2，待定）

| 功能 | 理由 |
|---|---|
| 专注当前 App（外观选“统一标题栏”时 `⌃⌘0` 的另一种行为，963 行里的大半） | 和“收起一扇窗”不是一件事，交互复杂 |
| 应用内更新的看护进程、备份与换回（约 3,000 行） | 换成 Sparkle 的标准流程：下载、校验签名、替换、重启 |
| 关掉看一眼时，单击卷帘条弹出的小缩略图（1.0.14 的旧行为） | 看一眼已经覆盖 |

## 3. 平台约束

设计里每一条“为什么要这样”都来自下面这些 macOS 的限制。这是事实，不是选择：

| 限制 | 后果 |
|---|---|
| 别的 App 的窗口不能被可靠地缩成只剩标题栏 | 收起只能“把真窗口藏起来，在原处摆一张标题栏截图” |
| 系统不让别人的窗口整个离开屏幕，至少留几像素在屏上 | 藏窗口用“停到屏幕角上、只留 1 像素”（`CornerParking`） |
| 系统完整性保护开着时，跨进程的 SkyLight 窗口改动会被悄悄忽略 | 私有接口只在确认有效的机器上用；无效的结果按系统版本记住，不再每次启动重试 |
| 最小化一定有缩进 Dock 的动画 | 最小化是最后的退路 |
| 隐藏整个 App 会把焦点和桌面一起带走 | 只有这扇是 App 唯一的窗口、且当前桌面有别的窗口可以接焦点时才用 |
| 截图要屏幕录制权限；用流抓一扇窗时系统会在它的红绿灯上画紫色胶囊 | 没权限退成统一标题栏；真窗口回来之前先停流 |
| 辅助功能调用是同步的跨进程请求，对方卡住要等到超时（已收紧到 2 秒） | 所有辅助功能读写放到后台队列，主线程只等结果 |
| 卷帘条要等主线程这一轮跑完才上屏，别的 App 挪窗口却是立刻生效的 | 卷帘条要当场画好、提交、等一帧，再动真窗口 |
| 第一次窗口截图要热身（实测可达 0.7 秒） | 启动后在后台先截一张 |

## 4. 架构

### 4.1 分层

```text
App 层      AppDelegate（只做接线）、菜单栏、设置、欢迎窗口
功能层      FoldEngine · UnfoldEngine · Glance · Thumbnail · Arrange
领域层      ShadeStore · ShadeRecord · FoldPlanner · AppProfiles · Journal     ← 纯逻辑，可单测
平台层      Accessibility · WindowServer · Capture · Stream · SkyLight · Spaces  ← 唯一碰系统接口的地方
```

规则：

1. **只有平台层碰系统接口**（AX、CGWindow、ScreenCaptureKit、SkyLight）。上层拿到的是值
   （`WindowFacts`、`CGImage`、成功 / 失败），不是 `AXUIElement`。
2. **领域层不碰 AppKit、不碰时间、不碰线程。** 时间由调用方传入，所有判断能在单元测试里跑。
3. **状态只有一个主人。** 所有收起的窗口都在 `ShadeStore` 里，只能通过它的方法改；
   菜单、看一眼、整理订阅它的变化，不自己存副本。
4. **`AppDelegate` 不放状态。** 它只在启动时把各部件接起来。

### 4.2 一条收起记录

```swift
struct ShadeRecord {
    let windowID: CGWindowID
    let pid: pid_t
    let appProfile: AppProfile.ID
    var frame: CGRect              // 收起前的位置和大小（展开回这里；拖动卷帘条会改它）
    var space: SpaceID?
    var display: DisplayID?
    var look: Look                 // .screenshot / .titleBar / .thumbnail
    var hiddenBy: HideMethod       // .appHidden / .cornerParked / .skyLightOffscreen / .minimized …
    var phase: Phase               // .folding / .folded / .unfolding（非法转换直接拒绝）
    var transaction: UUID          // 异步回调回来时拿它对身份，对不上就丢掉
}
```

现在散在 `ShadeState`、`foldWaiters`、`foldWaiterTransactions`、`restoreVerificationTokens`、
`arrangedOverlayFrames`、`hoverPreviewSuppressedUntil` 等十几个字典里的东西，都收进这一条记录
或 `ShadeStore` 的方法里。

### 4.3 App 适配：一张表

```swift
struct AppProfile {
    let id: ID
    let match: [Match]              // bundle ID（首选）、名字（兜底）
    let hideOrder: [HideMethod]     // 按顺序试，前一种不行换下一种
    let allowAppHide: Bool
    let chromeHeight: ChromeRule    // .accessibility / .standard / .fixed(51.5) / .scanPixels
    let nativeShade: Bool           // 便笺：交给系统自己的收起
    let stripResizable: Bool
    let note: String                // 为什么要这样（哪次实测、什么现象）
}
```

- 现在 `Policies.swift` 的 10 种 App 加上散在外面的约 40 处判断，全部变成这张表里的行。
  收起、截图、外框解析的代码里不再出现任何 bundle ID。
- 加一个 App 的适配 = 加一行表 + 在录屏矩阵里加这个 App（见第 6 节）。
- 默认行适用于所有没列出来的 App：按辅助功能读标题栏高度，读不准就扫像素；藏法依次是
  隐藏整个 App（条件满足时）→ 停到角上 → 最小化。

### 4.4 收起：固定的步骤

`FoldPlanner` 是纯函数：输入窗口的事实、App 的那一行表和用户设置，输出一份计划。
`FoldEngine` 照计划一步步执行，每步计时、每步可能的失败都写清楚。

```text
                                  主线程？  预算     失败了怎么办
1 认出目标窗口（标题栏命中）        否       ≤ 30ms   不收起
2 读事实：位置、大小、标题栏高度、   否       ≤ 40ms   读不到的项用默认值
  这个 App 有几扇窗、在哪个桌面
3 出计划（纯逻辑）                  否        < 1ms   —
4 截图并裁出标题栏                  否       ≤ 80ms   退成统一标题栏
5 写恢复记录（落盘）                否       ≤ 10ms   不收起，提示一次
6 显示卷帘条：当场画好、提交、等一帧  是       ≤ 25ms   —
7 藏真窗口：按计划的顺序试            否       ≤ 60ms   试下一种；都不行就撤卷帘条、删记录
8 交接焦点（卷帘条这时先浮一层）       否       ≤ 40ms   不交接
9 收尾：音效、刷新菜单、挂上看一眼     是       不计入   —
```

- 从双击到窗口主体消失的预算是 1 到 7 步相加，约 250ms。现在实测 430ms 到 1.2 秒。
- 第 6 步必须在第 7 步之前，第 8 步必须在第 6 步之后：这两条写在 `FoldPlanner` 的输出里，
  有单元测试守着，不再靠注释。
- 第 7 步之后的核对（窗口真的不见了吗）在后台做；核对失败按 `hideOrder` 换下一种，
  卷帘条保持不动。

### 4.5 展开：固定的步骤

```text
1 看一眼开着就停流（卡片留着最后一帧）
2 真窗口挪回记录里的位置和大小
3 核对它真的回来了（在屏上、位置对）
4 撤卡片和卷帘条（同一帧）
5 焦点给它
6 删恢复记录
```

### 4.6 定时核对

只做两件事，间隔 1 秒，只在有收起的窗口时运行：

- 真窗口自己回来了（被 Dock、`⌘Tab` 叫回）→ 撤卷帘条，删记录（R2）。
- 真窗口没了（关了、App 退了）→ 撤卷帘条，删记录（R3）。

其余“兜底”（Space 归属回切、显示器变化重排）改成响应系统通知，不靠轮询。

### 4.7 恢复记录

- 藏窗口之前落盘（第 5 步），展开核对通过之后删除。
- 启动第一步读记录：记录里有、窗口还藏着的，全部放回原位（R1）。
- 记录格式和现在的 `Journal` 兼容，升级上来的人不丢窗口。

### 4.8 线程

- 主线程只做 AppKit：建窗口、改层级、画卷帘条、菜单。
- 辅助功能、窗口截图、像素分析都在一条串行后台队列上；同一个 App 的辅助功能请求排队，
  不同 App 互不阻塞（现在的 `AXReadGate` 保留）。
- 主线程单次阻塞超过 16ms 记一行日志（现在的卡顿哨兵保留）。

## 5. 文件结构

```text
prototype/
  App/          AppDelegate.swift · MenuBar.swift · Settings/ · Welcome.swift · Shortcuts.swift
  Features/     FoldEngine.swift · UnfoldEngine.swift · Glance/ · Thumbnail/ · Arrange.swift
  Domain/       ShadeStore.swift · ShadeRecord.swift · FoldPlanner.swift · AppProfiles.swift · Journal.swift
  Platform/     Accessibility.swift · WindowServer.swift · Capture.swift · Stream.swift
                SkyLight.swift · Spaces.swift · CornerParking.swift
  UI/           StripWindow.swift · GlanceCard.swift · SystemAppearance.swift
  Update/       Sparkle 接口一层
```

单个文件不超过 400 行，单个函数不超过 60 行。

## 6. 怎么验证

改写的每一步都用同一套关卡，不靠“看起来对”：

1. **单元测试**：`FoldPlanner`、`AppProfiles` 匹配、`ShadeStore` 状态转换、`GlanceIntent`、
   恢复记录读写。
2. **录屏矩阵**：CI 在 macOS 虚拟机上对每个 App 录一段“收起 → 看一眼 → 展开”：
   文本编辑、访达、Safari、计算器、系统设置、备忘录。
3. **逐帧检查**（录屏之后自动跑，不过就算 CI 失败）：
   - 没有空帧：标题栏位置从“窗口”直接变成“卷帘条”，中间没有桌面或别的窗口；
   - 没有紫色录屏胶囊；
   - 展开后位置和大小与收起前一致。
4. **时延**：从日志里读每一步的耗时，超出第 4.4 节的预算就标出来。

## 7. 迁移

不推倒重写：现在的代码在 CI 录屏里是能用的。按下面的顺序一块一块换，每块换完都过第 6 节的关卡，
行为不变才换下一块。

| 步 | 做什么 | 换掉的东西 |
|---|---|---|
| 1 | 建 `Domain/`：`ShadeRecord`、`ShadeStore`、`FoldPlanner`、`AppProfiles` 表，配单元测试 | `ShadeModels.swift`、`Policies.swift`、散落的 App 判断 |
| 2 | 建 `Platform/`：把 AX、截图、SkyLight、停角落从各处收进来，全部异步 | `AXWindow.swift`、`FastCapture.swift`、`SkyLightBridge.swift` 等 |
| 3 | `FoldEngine` 按 4.4 的步骤重写收起 | `ShadeController.shade()`、`FoldTransaction.swift` 的大半 |
| 4 | `UnfoldEngine` 按 4.5 重写展开 | `FoldExit.swift` |
| 5 | 定时核对按 4.6 收窄 | `Reconcile.swift`、`OverlayPresentation.swift` 的兜底 |
| 6 | `AppDelegate` 只留接线，状态全部搬进 `ShadeStore` | `WindowShade.swift` 的 106 个成员变量 |
| 7 | P2 的砍不砍，按你的决定处理；更新换成 Sparkle 标准流程 | `Updater*.swift`、`Watchdog/` |
| 8 | 录屏矩阵加到 6 个 App，逐帧检查设成 CI 关卡 | — |

做完以后，旧文件全部删除，`DEVELOPMENT.md` 的模块结构照第 5 节重写。
