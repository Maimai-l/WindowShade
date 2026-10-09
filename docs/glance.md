# 看一眼

指针停在卷帘条上，卷帘条下面出现一张卡片，按原尺寸显示窗口内容；指针移开，卡片自动收回。
单击卡片才真正展开。这是它和最小化的区别：最小化、切换窗口、切换桌面都要切过去再切回来，
看一眼不必切过去再切回来，看完不用恢复任何东西。

## 入口与行为

- 设置 → **卷帘** → **看一眼**，默认打开。关掉后，单击卷帘条不再弹出内容。
- 指针进入卷帘条就开始准备画面，停够约 0.22 秒才显示；只是路过不显示任何东西。
- 卷帘条不动；卡片显示在它下面、隔 6 点的缝，显示标题栏以下的内容，宽度和位置对齐原窗口；
  超出屏幕可见区域的部分裁掉，上沿不动。卡片和原窗口分得开：一眼看得出这是预览。
- 卡片四个角都用原窗口的圆角：半径从收起时的截图里量（连续曲率，弧线起点按 1.528 倍换算），
  带自己的投影；有画面时不铺底色，不会在角上露出月牙或双层边。
- 被隐藏的 App 临时在原处取消隐藏时，缝和卡片圆角的缺口底下垫一张打开那一刻截的真实背景
  （`FastCapture.composite`），原窗口露不出来；背景截不到就不取消隐藏，只给截图。
- 只有卡片本身算“在画面上”、接单击；缝和投影边距不算。
- 指针从卷帘条移到画面上不会收回；离开两者约 0.16 秒后卷上收回。
- 单击卷帘条：不等计时，马上看一眼。
- 单击画面：真正展开那扇窗。画面留到原窗口回到原处才撤，中间不露出后面的东西。
- 停在卷帘条左侧的红绿灯上不计时：那里另有窗口管理菜单。
- 刚收起的那一下指针还停在卷帘条上：这条先不响应，指针离开一次才恢复悬停。
- 切换 App、换桌面、拖动卷帘条、展开或关闭窗口，都会立刻收回。
- 看一眼不切换当前 App，不抢键盘焦点，不移动、不缩放任何窗口。

## 画面从哪来

macOS 不让别的 App 把窗口画成只剩标题栏，收起时原窗口被藏起来。画面来源取决于
它被藏在哪：

| 原窗口的状态 | 看一眼的画面 |
| --- | --- |
| 挪在屏幕外（Codex 等允许的 App） | 实时画面。指针一进卷帘条就启动实时流，多数时候显示时第一帧已经到了 |
| 整个 App 被隐藏 | 先显示收起时的截图，画面卷下来盖住原处之后，在下面临时取消隐藏、取得实时画面；收回时先藏回去再卷上。只在卷帘条没被拖走、画面能完整盖住原窗口时这样做 |
| 最小化、或上面两种拿不到画面 | 收起时的截图，不加文字说明 |
| 连截图也没有 | 只有卡片的底色和细边，不加文字说明 |

实测（2026-09-24，Mac17,4，macOS 27.0）：

- 屏幕录制能以约 30 帧/秒实时抓取挪到 (-32000, -32000) 的窗口，热启动一条流约
  156ms 首帧。
- 最小化或整体隐藏的窗口，实时流（SCStream）一帧也抓不到；单张画面可以，见下。
- 多数 AppKit 窗口不能用辅助功能挪出屏幕：日常日志里 Safari 窗口被拉回
  (-2097, -1410)，四个停靠点全部失败后退回最小化；历史日志里没有一次成功挪出。
  所以当时的默认收起策略是“单窗口隐藏整个 App，否则最小化”，多数看一眼只能给截图。现在的顺序是：
  满足条件时隐藏整个 App，否则停到屏幕角落，最后才最小化（[design.md](design.md) 第 4 节）。
- 从后台进程调用 `NSRunningApplication.unhide()` 不会让别的 App 显示出来（2 秒内
  窗口不回来）。辅助功能取消隐藏（`kAXHidden = false`）23ms 让窗口回到原处，前台
  App 不变；开流后 104ms 首帧；重新隐藏 13ms，前台仍不变。万一某个 App 取消隐藏后
  切到了前台，看一眼会记下它，之后对它只给截图。
- 别的桌面上的窗口也能抓：Safari、备忘录 86ms 拿到当前画面；最小化的窗口仍是 0 帧。
- 最小化、整体隐藏的窗口的单张画面：用一个私有的窗口截图函数（`CGSHWCaptureWindowList`，和 `CGWindowListCreateImage`
  不同，它对最小化的窗口、被隐藏的 App 的窗口也返回画面）。本机 macOS 27.0 实测跨进程约 31–135ms，不出现录屏指示器；
  `CGWindowListCreateImage` 对这两种窗口一律返回空；ScreenCaptureKit 的单张截图也行，但每张都会出现录屏指示器、
  约 80–140ms，还要先列出窗口。没有屏幕录制权限、或这个私有函数不存在时，退回只显示图标的做法。
  拿到的是 App 最后画的那一帧（多数 App 最小化、隐藏后就不再画），所以显示的是那一帧，不加文字说明。

## 收起有多快（与“卡顿”有关）

收起时给窗口截图原来用 ScreenCaptureKit，放在收起途中要 229ms 以上、超时后还会改用简化
标题栏；现在先用 `CGWindowListCreateImage`（见 [performance.md](performance.md) 第 12 条）。
同一进程连续收起的中位数：第一眼看到变化 342 → 147ms、卷帘条出现 499 → 328ms。

收起确认在两次正式检查之间每 30ms 看一次 WindowServer 的实时在屏状态，窗口一离开
屏幕就亮出卷帘条（`FoldVerifier.quickObserve`）。

已有快照时，达到预览触发时机就先显示快照，实时首帧到了再接替，不额外等待。
没有快照且实时流仍在准备时，最多等 250ms；临时取消隐藏仍须先把原窗口完整盖住。

## 代码

| 文件 | 内容 |
| --- | --- |
| `prototype/Core/GlanceIntent.swift` | 指针意图状态机：预热、停留、离开宽限、单击、挡住刚收起的那一条。纯逻辑 |
| `prototype/Overlay/GlancePanel.swift` | 画面面板：卡片（原窗口圆角、投影）、背景垫片、卷下/卷上动画 |
| `prototype/Capture/FastCapture.swift` | 快速截图：整窗与“去掉某些窗口后的屏幕区域” |
| `prototype/App/Glance.swift` | 控制器：悬停跟踪、会话、实时流、几何、展开交接、盖住再取消隐藏 |

接线：`ShadeController.installOverlay` 挂悬停跟踪；`unshadeReturningElement`、
`forceCleanup`、`removeProxyForAction` 撤掉；`peekHoverPreview` 在开关打开时改走看一眼；
前台 App 与桌面切换时收回。看一眼自己取消隐藏期间，`handleAXNotification` 与
`sourceWindowLooksUserVisible` 不把“App 又显示出来”当作用户唤回。

## 验证

```sh
bash tests/run-glance-tests.sh          # 状态机：路过、停留、菜单交接、宽限、切换、单击、撤销
bash tests/run-appkit-tests.sh GlanceLifecycleTests # 会话进出、取消隐藏的所有权、失去目标时收干净
cd prototype && ./build.sh --stage      # 签名隔离构建，不影响日常运行的应用
```

2026-09-24 解锁状态下真机探针的运行结果（Mac17,4，macOS 27.0；探针只操作它自己启动的临时 App）：

```
# --single：整个 App 被隐藏 → 盖住再取消隐藏，实时画面
PASS glance: shown 261ms after the pointer arrived, live picture at 781ms, panel 640x420 under the strip, window unhidden in place fully under cover, frontmost app unchanged
PASS glance: picture keeps updating (30 frames in 1s)
PASS glance: closes 260ms after the pointer leaves; window put away again
PASS glance: click expands in place (window back in 40ms, no gap)

# 默认两扇窗：收起走最小化 → 收起时的截图
PASS glance: shown 259ms after the pointer arrived (snapshot), panel 640x420 under the strip, window still parked, frontmost app unchanged
PASS glance: snapshot labelled as the picture from when it was put away
PASS glance: closes 341ms after the pointer leaves; window put away again
PASS glance: click expands in place (window back in 295ms, no gap)
```

实时那一次在显示期间隔 1.2 秒截了两张屏幕图，临时 App 的计数从 72 走到 101，
原窗口没有从画面和卷帘条之外露出来。“收回”包括 0.16 秒离开宽限和卷上动画。

2026-09-25 整合复检补充：用户主动切回临时显示的 App 时，释放看一眼的隐藏所有权并正常展开，不再把 App 藏回去；关闭后立即回入会重新准备已停流的会话。`bash tests/run-appkit-tests.sh GlanceLifecycleTests` 使用生产控制器和注入的 AX 操作验证这些路径，不操作用户窗口。
