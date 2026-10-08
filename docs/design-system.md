# WindowShade 设计系统

> 2026-09-29 定稿。这份文件规定四件事：界面怎么贴合硬件，各个表面取哪些数值，各个表面怎么动，
> 怎样才算做到了 Apple 的水准。面向用户的文字一律按 [copy-guide.md](copy-guide.md) 写。
>
> 怎么扩充、和稿对不上的账，见 [design-grammar.md](design-grammar.md)。这份文件仍只管数值；文法不改这里的数字。
>
> 2026-10：合盖效果、收起动画、标题栏手势与提示浮窗、置顶预览、带到每张桌面、窗口浏览已经从 App 里拿掉。
> 第 5 节里它们那几条（5.1、5.2）已删；第 4、6 节里提到这些表面的数值和进度只作记录，不再对应代码。

**数值标注**

| 标注 | 含义 |
|---|---|
| **[Apple]** | Apple 官方页面、HIG 或 WWDC 讲座原文写明的 |
| **[图稿]** | 从 Apple Design Resources 的 Product Bezels（M5 Air、M5 Pro、Neo）量出来的。授权素材只能用来测量，图片和 PSB 不进仓库 |
| **[系统]** | 本机 Mac17,4（MacBook Air 15″ M5，macOS 27）用只读脚本读到的系统数据，没有对过实物，不写成“实测” |
| **[推断]** | 由其它数值推出来的 |
| **[现值]** | 代码里现在写着的，文件和行号相对 `prototype/` |
| **[自定]** | WindowShade 自己定的，不是 Apple 的数字 |
| **[改值 §6-n]** | 目标值和现值不同，要按 §6 第 n 条单独改、单独验收 |

**单位与换算**

- px 指**面板物理像素**，pt 指**当前显示模式下的 Cocoa 点**。硬件数值一律按 px 存，用的时候再换成 pt，代码里不写死点数。
- 换算只用 `pxPerPt = 原生面板像素宽 ÷ screen.frame.width`，**不要用 `backingScaleFactor`**。本机默认模式 1710×1107 时 pxPerPt = 2880/1710 = 1.684，`backingScaleFactor` 却是 2；只有 2× 模式（1440×932）两者才相等。
- 原生面板宽这样取：`CGDisplayCopyAllDisplayModes(id, [kCGDisplayShowDuplicateLowResolutionModes: true])`，找 `ioFlags` 带 native 标志（`0x2000000`）的那个模式，读它的 `pixelWidth`。**当前模式的 `CGDisplayModeGetPixelWidth` 给的是帧缓冲宽（本机 3420），不是面板宽（2880）**，不能拿来换算 [系统]。

---

## 1. Apple 的价值观与 Liquid Glass 初衷

压缩成六条设计原则。它们和 §2 的九条一起用：九条讲“怎么做得像 Apple”，这六条讲“做什么、不做什么”。
§5 的每个组件都有一行“价值观”，写明它怎么满足这六条；满足不了的，写进 §6 当差距。

| # | 原则 | 出处 | 在 WindowShade 里 |
|---|---|---|---|
| V1 | **一眼就熟悉。** 更有表现力，但不丢掉用户已经熟悉的东西 | Apple Newsroom 2025-06-09（新设计发布稿）；Adopting Liquid Glass | Mac 已经有的做法优先。新东西长得像系统的一部分，不另起窗口。从 iPad、Windows 搬来的行为不当默认（§8）。不借用 Apple 的功能名和口号（Apple 商标准则） |
| V2 | **内容优先。** 界面退后，让内容突出 | WWDC25 219；HIG Materials | 内容层（窗口画面、缩略图）不加材质。顺利时不说话。浮层用完就走，停稳后不压在内容上 |
| V3 | **玻璃只在控件层，不叠玻璃。** 玻璃是浮在内容上的导航和控件那一层 | WWDC25 219；HIG Materials | 分两层：浮层用系统玻璃、内容层不加材质（§4.2）。浮层里再分块，用填充、透明度、分隔线，不再套一层玻璃 |
| V4 | **用系统玻璃，不自己仿。** 光学质感和流动感说的是系统材质本身 | Adopting Liquid Glass；WWDC25 310 | macOS 26+ 用 `NSGlassEffectView` / `NSGlassEffectContainerView`，14/15 用 `NSVisualEffectView`。不手画高光、折射和灰色“玻璃” |
| V5 | **无障碍从第一行开始。** 为所有人设计，不是事后补 | apple.com/accessibility；HIG Accessibility；HIG Gestures | 每个表面都处理减少动态效果、减少透明度、增强对比度，并有 VoiceOver 名称（§4.9）。每个手势都有菜单或快捷键可以代替。少造新手势。状态不只靠颜色区分 |
| V6 | **Apple 式文案。** 清楚、能少就少、少说“我们” | HIG Writing；Apple Style Guide；copy-guide.md | 一个东西一个名字。组合键符号 ⌃⌘⌥ 第一次出现时说明是哪个键。按设备描述手势（触控板说“两指”）。不替 Apple 的硬件下定义 |

另外两条照旧：画面只在本机处理，不上传；常驻不耗电，不轮询、不截图。

---

## 2. 原则

参考案例来自 Chan Karunamuni 个人网站列出的作品：iPhone X 手势界面（2017，fall2017 801）、Designing Fluid Interfaces（WWDC18 803）、
灵动岛（2022）、Design dynamic Live Activities（WWDC23 10194）、iOS 18 手电筒（2024）、Liquid Glass（WWDC25 219）。
WWDC25 356、WWDC23 10158 和 HIG 是其他讲者或文档给的补充来源。共同点归成下面九条。

| # | 原则 | 出处 | 在 WindowShade 里 |
|---|---|---|---|
| 1 | **同心。** 子半径 = 父半径 − 边距；没有父容器时用兜底的固定半径；矮条用胶囊 | 356 | 容器里的内容和容器同心。靠近屏幕角落的表面不改半径，只做包含测试、挪位置（§4.1 规则 2） |
| 2 | **空间一致。** 从哪里出去就从哪里回来 | 803 | 窗口在原处收起，也在原处展开。提示浮窗出现在手势发生的窗口旁边 |
| 3 | **跟手、随时可打断、中途可以改方向。** 过程中持续反馈；判断停顿看手指的加速度尖峰，不用计时器 | 803；fall2017 801 | 标题栏上的每个手势，过程中都要动。弹簧叠加播放，换目标时位置和速度连续。松手时按投影落点决定去向，不在一开始锁死方向 |
| 4 | **用弹簧描述动效，不用时长。** 默认 100% 阻尼；只有动作本身带动量，或者回弹本身是提示时才回弹 | 803（点按没有动量用 100% 阻尼；锁屏手电筒按钮的回弹是提示）；WWDC23 10158；HIG Motion | 所有动效引用 §4.6 的弹簧令牌。HIG Motion 说用触控板时效果更收敛，所以 Mac 上回弹上限定为 0.2，小元素确认 `pop` 0.25 [自定] |
| 5 | **顺着手势方向提示，轻输入、放大输出。** 用减速率把松手速度投影成落点，再找最近的目标 | 803（投影 = v/1000 · r/(1−r)） | 标题栏手势松手时按投影落点（r=0.99），甩一下标题栏也用投影落点。过程中的形变朝最终状态长 |
| 6 | **画结果，不画参数。** 防误触靠更有意的动作加回弹提示，不弹确认框 | iOS 18 手电筒；803 | 提示浮窗的终点图标画松手后的样子。越过阈值时终点弹一下，告诉用户“松手就成” |
| 7 | **材质分层。** 玻璃只用在浮在内容上的控件层；不叠玻璃；着色只给主要操作 | 219；HIG Materials | 见 V3 与 §4.2 |
| 8 | **少说话，先演示再用文字。** 文字只讲会反复用到的手势，讲一次 | 803 | 提示浮窗只说松手会做什么；顺利时不说话 |
| 9 | **动效、触感、声音是同一种性格；辅助设置自动跟随。** | 803；219；HIG Playing haptics | 越过阈值给 `.alignment`（[现值]，见 §4.8），手势不加声音。三项辅助设置每个表面都有对应处理（§4.9） |

**拿这些原则检查新东西**：
- 它是另起一个窗口吗？刚换到 Mac 的人一眼认得出它吗？
- 它的形状是从父容器推出来的，还是写死的？
- 手势做到一半松手或改方向，会发生什么？
- 减少动态效果、减少透明度、增强对比度打开时，它长什么样？VoiceOver 怎么念？

---

## 3. 硬件形状

### 3.1 事实

**天圆地方。** 五款机型（Neo、Air 13/15、Pro 14/16）都是顶部两个圆角、底部两个直角。底角的缺角面积：五张 PNG（含全部配色）和 Air 的 2× 内嵌图稿都是 0；Pro 的 2× 内嵌图稿有极小的缺角，换成原生 Pro 14 约 0.6、Pro 16 约 2.1 px²，仍按直角处理 [图稿]。
规格页脚注写的是 “rounded corners at the top” [Apple]。本机 `bezelPath` 的两个底角是直线，WindowServer 的 `SLSDisplayGetCornerRadii` 也是“两个 0、两个非 0” [系统]。

**屏幕顶角**是连续曲率曲线，不是圆弧：
- Air 和 Pro 比 `.continuous` 更方（超椭圆指数 n≈3.0–4.3），Neo 的 n≈2.5，基本就是 `.continuous` [图稿]。
- 各机型换成物理尺寸，等效圆半径都约 4 mm [图稿]。
- **可以用 `.continuous` 画。** 五款机型、两份独立渲染上，`.continuous` 的最大偏差都 ≤0.5 px。要到 ≤0.2 px 才需要超椭圆。
- 本机 `bezelPath` 的顶角和图稿边界点相比，内部最大偏差左上 0.32 px、右上 0.51 px，45° 内缩 9.97 对 9.76 px。图稿对 `.continuous` 的最大偏差是 0.29–0.32 px，所以 `.continuous` 离 `bezelPath` 的上界约 0.85 px（右上 0.51 + 0.32，三角不等式，未直接拟合）。
- 顶角几乎总在菜单栏下面，贴顶角的工作优先级低。

**系统给的和不给的**：
- 屏幕圆角没有公开 API。
- `NSViewCornerConfiguration`、`NSView.effectiveCornerRadii` 在 SDK 头文件里标的是 `API_AVAILABLE(macos(27.0))`，只处理窗口和容器的圆角，不描述屏幕形状 [系统，SDK 头文件]。
- 画连续角路径要自己生成：`NSBezierPath` 的圆角矩形是圆弧，`NSGlassEffectView.cornerRadius` 只有一个统一值。

**配件准则**（ADG R31，404 页）里没有 Mac 屏幕几何。能借用的只有术语：显示玻璃分成 active area（显示区）和 non-active area（边框）（p.229–231）。

### 3.2 机型表

表的键是**内建屏 + 原生面板像素尺寸**，五款互不相同。面板相同的旧代机型（例如 M2–M4 的 Air）共用同一行 [推断]。

**屏幕开口与顶角**（px；括号内是 2× 模式下的 pt）

| 面板 px / ppi | 机型 | 默认模式（pxPerPt） | 2× 模式 | 顶角 `.continuous` r | 最大偏差 | 45° 内缩 d45 | 等效圆 R | 底角 | 来源 |
|---|---|---|---|---|---|---|---|---|---|
| 2408×1506 / 219 | MacBook Neo（Mac17,5） | 1408×881（1.710）[三方，未核实] | 1204×753 | 33.6（16.8） | ≤0.25 | 9.8（4.9） | 34.0±0.5 | 直角 | 图稿（只有 PNG 一份） |
| 2560×1664 / 224 | Air 13″ M2–M5 | 1470×956（1.741）[三方] | 1280×832 | 34.8±0.3（17.4） | ≤0.46 | 10.0（5.0） | 35.1±0.4 | 直角 | 图稿 ×2 |
| 2880×1864 / 224 | Air 15″ M2–M5 | 1710×1107（1.684）[系统] | 1440×932 | 34.1±0.3（17.1） | ≤0.38 | 9.7（4.9）；`bezelPath` 9.97 | 34.4±0.4 | 直角 | 图稿 ×2；系统 |
| 3024×1964 / 254 | Pro 14″ 2021–2026 | 1512×982（2.0）[三方] | 1512×982 | 39.7±0.8（19.9） | ≤0.47 | 11.4（5.7） | 40.1±0.8 | 直角 | 图稿 ×2 |
| 3456×2234 / 254 | Pro 16″ 2021–2026 | 1728×1117（2.0）[常见值，未核实] | 1728×1117 | 40.3±0.3（20.1） | ≤0.46 | 11.5（5.75） | 40.6±0.3 | 直角 | 图稿 ×2 |

- 分辨率、ppi、“rounded corners at the top”来自 Apple 规格页 [Apple]；其余是 [图稿]。
- 2× 内嵌图稿的数值已按“原生宽 ÷ 内部开口宽”换回原生 px 再平均。

**本机（Air 15″）换算成 pt**

| 项 | 1710×1107（默认） | 1440×932（2×） | 来源 |
|---|---|---|---|
| 顶角 `.continuous` r | 20.2 | 17.1 | 图稿 |
| 顶角 d45 | 5.8（`bezelPath` 5.9） | 4.9 | 图稿；系统 |
| 菜单栏 | 34 | — | 系统 |

### 3.3 不确定度

- **顶角**：半径 ±0.3–0.8 px，主要来自 Apple 两份渲染之间的差异，Pro 14 最大（1.5 px）。d45 ±0.2 px，是最稳的描述量，验收用它。超椭圆的 R 和 n 会互相补偿，单独看都不稳。
- **延伸长度没有唯一定义**：连续曲线的尾段和直边相差 <0.1 px。`bezelPath` 给顶角延伸 65 px，图稿按拟合给 52 px。所以**存曲线或 `.continuous` 的 r，不存延伸量**。
- **`.continuous` 是不是同一条曲线**：图稿拟合用的是 iOS 7 的连续角曲线。macOS 上 `CALayer.cornerCurve = .continuous` 与 SwiftUI `RoundedRectangle(style: .continuous)` 是否同一条，可以离线验证，不用跑 App：
  - `CALayer.cornerCurveExpansionFactor(.continuous)` 应读到 1.5287；
  - 把两者的路径渲染进同一个 `CGContext` 比较。
- **`SLSDisplayGetCornerRadii`**：内建屏返回 `0, 0, 21.05, 21.05`，Studio Display 四个都是 0 [系统]。
  - 这是 WindowServer 独立给出的“天圆地方”信号。
  - 单位不确定：按当前模式的 pt 算，21.05 × 1.684 = 35.4 px，接近等效圆 R；按 2× 的 pt 算，21.05 × 2 = 42.1 px，接近 65 ÷ 1.5287 = 42.5 px [推断]。
  - 函数签名是猜的，随产品发布有崩溃风险。只放在探针里做诊断和交叉校验，不进产品。

### 3.4 特殊情况

- **缩放模式**：只影响 pxPerPt，物理形状不变。只有 2× 模式能逐像素对齐（表里的 2× 列）；其它模式只要求抗锯齿带 ≤1 px。
- **“避开刘海”模式**（1440×900、1710×1068 等）：顶部一条带熄灭，MBA 64 px [系统]，MBP 74 px [推断，1964−1890]。顶角延伸约 65 px，和熄灭带差不多高，可见区的角实际就是直角。
- **MacBook Neo**：天圆地方，摄像头在一圈均匀的边框里。Apple 规格页确认 2408×1506、219 ppi、IPS、顶部圆角。顶角可以直接用 `.continuous` r=33.6 px。
- **外接屏**：
  - Studio Display 的 `bezelPath` 就是 `frame`，四角直角；`SLSDisplayGetCornerRadii` 四个 0 [系统]。
  - 本机外接屏的 `visibleFrame == frame`，`_revealedMenuBarHeight` 是 0，也就是这块屏上根本没有菜单栏（推测“显示器具有单独的空间”关着）。所以菜单栏高保持 `max(24, 实测)`，**不**改成 30，也不调私有的 `SLSGetDisplayMenubarHeight`。
  - Sidecar（iPad）和 AirPlay 屏实物是圆角，但拿不到数据，按直角处理（等于现状）。
- **旋转**：内建屏正常不能旋转；万一 `CGDisplayRotation ≠ 0`，按四角直角处理。

---

## 4. 设计令牌

动效令牌在 `Core/FlickMotion.swift` 的 `MotionSpring`（App 里叫 `Motion.Spring`），形状令牌在 `Overlay/SystemAppearance.swift` 的 `SystemCornerRadius`。各表面只引用令牌，不写魔法数。

**改值规则**：令牌先填**现值**，第一轮（§6-5）只把现值收进令牌，参数逐字不变。目标值和现值不同的，一律标 **[改值 §6-n]**，汇总在 §4.10，一条一条改、一条一条验收。不能笼统地说“只收拢，不改值”。

### 4.1 圆角

**硬件（单位 pt，按 §3 的机型表）**

| 令牌 | 含义 | 本机 1710 / 1440 |
|---|---|---|
| `hw.screenTop` | 屏幕顶角，`.continuous` r | 20.2 / 17.1 |
| `hw.screenBottom` | 屏幕底角 | 0 / 0 |

**系统（固定值）**

| 令牌 | 值 | 用在 | 来源 |
|---|---|---|---|
| `system.window` | 13 | 只有标题栏的窗口级表面：浮窗、卷帘条、预览面板 | [现值]，实测 macOS 27 标准窗口 |
| `system.card` | 12 | 内容卡片、设置分组 | [现值] |
| `system.item` | 8 | 窗口浏览里的卡片、行；缩略图 | [现值] |
| `system.control` | 6 | 自绘小按钮、chip | [现值] |
| `capsule` | 高 ÷ 2 | 矮条：胶囊按钮 | WWDC25 356 |

带工具栏的窗口圆角更大；macOS 27 上从 `effectiveCornerRadii` 读，不写死。

**派生规则**：
1. **同心（容器内）。** 子半径 = 外层半径 − 边距，最小 4。
2. **靠近屏幕角落（包含测试）。**
   - 只在 `visibleFrame` 伸到屏幕顶边时才可能碰到（自动隐藏菜单栏、全屏空间）。
   - 判据：拿表面的实际轮廓和屏幕轮廓（§3 的顶角）做包含测试，同时避开刘海所在的那一列（`safeAreaInsets`）。不要用“离两条边都不到 6 pt”这种只看 45° 的判据：贴着顶边的东西，离侧边三十多点以内都可能被切（离侧边 10 pt 处，屏幕边向内切约 2.9 pt）。
   - 不通过时**只挪位置，不改半径**。“屏幕角半径 − 边距”要求两边边距相等，现有表面基本都不满足（卷帘架是 10 和 8）。
   - 屏幕底角是直角，下半部的角落一律用自身令牌。
3. **胶囊只给矮条。** 高度会变的形状用固定半径，不在“胶囊”和“圆角矩形”之间来回跳。

### 4.2 材质

| 层 | 用在 | macOS 26+ | macOS 14/15 | 减少透明度 | 增强对比度 |
|---|---|---|---|---|---|
| **浮层** | 手势提示浮窗、窗口浏览面板 | `NSGlassEffectView`，style `.regular`；内容放进 `contentView`，不把玻璃当兄弟视图垫在后面；彼此靠近的几块放进 `NSGlassEffectContainerView` | `NSVisualEffectView`：提示浮窗 `.hudWindow`，面板 `.popover` | 不透明的 `windowBackgroundColor` | 不透明底上的边线加粗到 1 pt、用 `labelColor`（窗口浏览：WindowBrowserMaterial.swift；提示浮窗：GestureHUD.swift）；用玻璃时不另加边（现值） |
| **内容层** | 窗口画面、缩略图、看一眼的卡片 | 不加材质 | 同左 | — | — |

使用规则：
- **不叠玻璃**（HIG Materials；WWDC25 219）。浮层里再分块，用填充、透明度、分隔线。
- **不用 Clear 玻璃**，一律 Regular。
- **着色**只给主要操作和“已对准”，用 `controlAccentColor`。
- **交互发光**：`effectIsInteractive` 只在 macOS 27 有 [系统，SDK 头文件]。给被按住或拖动的小片玻璃用。
- **显隐**：AppKit 没有 Liquid Glass 的“显形”API，淡入淡出要短，不让玻璃停在半透明状态。
- **外观**：深浅色和辅助设置都要**持续监听**（`NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`、`effectiveAppearance` 变化），不能只在挂上时取一次。
- **不自己仿**（V4）：自绘的灰色“玻璃”、手画高光、合盖和倾斜效果都属于仿造或装饰。合盖效果默认关，其余在 §6-8 逐个过。

### 4.3 颜色

只用系统语义色，不写 RGB。

| 令牌 | 值 | 用在 | 来源 |
|---|---|---|---|
| `accent` | `controlAccentColor` | 主要操作；提示浮窗越过阈值的终点 | [现值] |
| `destructive` | `systemRed` | 只给退出 App、关掉这类不可撤销的操作 | — |
| `label.*` | `labelColor` / `secondaryLabelColor` / `tertiaryLabelColor` | 浮层里的文字 | — |

### 4.4 字体

一律用系统字体（SF Pro），数字用等宽数字。

| 令牌 | 值 | 用在 | 来源 |
|---|---|---|---|
| `panel.*` | 沿用 `WindowBrowserTypography`：正文跟随系统字号，次要文字 = 正文 − 2，不小于 10 | 窗口浏览、设置 | [现值] |
| `welcome.*` | 标题 24、导语 14 | 欢迎窗口 | [现值] |

### 4.5 间距

| 令牌 | 值 | 用在 | 来源 |
|---|---|---|---|
| `inset.panel` | 12 | 窗口浏览面板内边距 | [现值] |
| `margin.edgeHug` | 8 | 贴边的东西：提示浮窗的夹边、卷帘架离顶 | [现值] |

### 4.6 动效（弹簧）

两个参数：`response`（秒）和阻尼比 ζ。SwiftUI 的 `bounce = 1 − ζ`（ζ ≤ 1）。换成弹簧：mass 1，stiffness `(2π/response)²`，damping `4πζ/response`（WWDC23 10158）。

| 令牌 | response / ζ（bounce） | 带初速度 | 何时用 | 状态 |
|---|---|---|---|---|
| `calm` | 0.34 / 1.0（0） | 否 | 没有动量的变化：悬停、收回、换状态 | [现值] |
| `settle` | 0.38 / 1.0（0） | 尺寸变化不带 | 尺寸变化（甩一下标题栏后的窗口尺寸、收起时的替身） | [现值] |
| `glide` | 0.42 / 0.88（0.12） | 必须 | 甩一下标题栏后的窗口滑行位置 | [现值] |
| `pop` | 0.30 / 0.75（0.25） | 否 | 只给小元素的确认：提示浮窗的终点图标 | [现值]，ζ 由 0.6 改来（§6-10） |
| `reduced` | 0.30 / 1.0（窗口滑行） | **否** | 减少动态效果时替换以上全部；挪位置改为原处淡出、目标处淡入 | [现值] |

`calm` 现在没有调用点。`MotionSpring` 里还留着 `expand`、`bloom`、`catchDrop`、`flyOut`、`pull` 和 `reducedNotch`，产品里也已经没有调用点；对照测试 `tests/MotionTokensTests.swift` 仍逐项比对它们。

规则：
- **上限**：Mac 上 bounce ≤ 0.2，`pop` ≤ 0.25 [自定]。超过 0.4 对界面来说就夸张了（10158）。
- **打断**：一律叠加播放。换目标时用当时的速度作初速度，位置和速度都连续；不同属性可以各自在不同时刻结束（10158）。
- **不等停稳**：后续动作不等 `settlingDuration`，它和感知时长不是一回事（10158）。
- **位移不用贝塞尔曲线描述。**

### 4.7 时序

| 令牌 | 值 | 性质 |
|---|---|---|
| `fade.hud` | 0.12 s | [现值] GestureHUD.swift |

### 4.8 触感

| 时刻 | 反馈 | 性质 |
|---|---|---|
| 越过阈值（已对准） | `.alignment` | [现值] App/TrackpadGestures.swift；HIG 里 alignment 就是“对齐”，合适 |
| 声音 | 手势不加 | [自定] |

### 4.9 辅助设置

每个表面都要有下面几项，缺哪项就是 §6 的差距。

| 设置 | 处理 |
|---|---|
| 减少动态效果 | 用 `reduced` 弹簧，不带速度，不飞行；示范动画停在最能说明问题的那一帧（HIG Motion） |
| 减少透明度 | 浮层改为不透明 |
| 增强对比度 | 浮层的不透明底加 1 pt `labelColor` 边（§4.2） |
| VoiceOver | 每个可操作的东西有名字；手势执行后播报动作名 |
| 键盘 | 每个手势都有菜单项或快捷键可以代替 |
| 不只靠颜色 | “已对准”同时改边线粗细或图标，不只换颜色 |

### 4.10 改值清单

| 令牌或数值 | 原值 | 目标 | 条目 |
|---|---|---|---|
| `pop` | ζ 0.6 | ζ 0.75，已落 | §6-10 |
| 提示浮窗不透明底的边（增强对比度） | `separatorColor` 1 pt | `labelColor` 1 pt，和窗口浏览一致，已落 | §6-11 |

---

### 4.11 符号（SF Symbols）

Aaron 2026-10-03：“整个 app 多用 SF Symbols，不要大段大段文字。”规则见 copy-guide 第 7 条。下表的符号名都在这台 Mac 上用
`NSImage(systemSymbolName:)` 核对过（`trackpad` 不存在，用 `rectangle.and.hand.point.up.left`）。设置行的符号放在系统设置那样的圆角色块里，
用 hierarchical 渲染。

| 概念 | 符号 |
| --- | --- |
| 收起窗口 / 展开窗口 | `rectangle.compress.vertical` / `rectangle.expand.vertical` |
| 看一眼 | `eye` |
| 置顶 / 取消置顶 | `pin` / `pin.slash` |
| 左半屏 / 右半屏 / 铺满 / 排列 | `rectangle.lefthalf.inset.filled` / `rectangle.righthalf.inset.filled` / `rectangle.inset.filled` / `rectangle.split.2x1` |
| 网格 | `rectangle.split.3x3` |
| 调度中心 / 窗口浏览 | `rectangle.3.group` / `rectangle.on.rectangle` |
| 快捷键 | `command` |
| 权限与启动 | `lock.shield` |
| 更多说明 | `info.circle` |

## 5. 组件

每个组件写五项：结构、令牌、状态与动效、贴合硬件、价值观。

### 5.3 看一眼、卷帘条

- **看一眼的卡片**（Overlay/GlancePanel.swift）：内容层，不加材质；圆角 = 源窗口实测圆角（App/Glance.swift）；阴影沿卡片路径画。有画面时不加底和边，代码注释写明原因：窗口画面自带边缘，多一层会在角上露出月牙；只有拿不到画面时才有底色和细边（GlancePanel.swift）。
- **卷帘条**：`SystemCornerRadius.surfaceRadius(forHeight:)`，不超过高度的一半。
- **价值观**：V1 收起窗口是 WindowShade 的来历，用的是 Mac 标题栏的样子（“跟原来一样 / 统一标题栏”）。V2 看一眼移开就收回。V5 看一眼拿不到实时画面时显示收起时的截图，卡片上不加文字说明。

### 5.4 欢迎窗口（App/Welcome.swift）

- **结构**：一页两项授权（辅助功能、屏幕录制）。从“下载”等地方直接打开时，授权之前多一步“放进‘应用程序’文件夹”。
- **内容**：按钮只用“开始使用”，没授权时旁边给“稍后再说”。
- **动效**：放进“应用程序”那一步，按下去时图标朝文件夹滑过去、变小、变淡；减少动态效果时只变淡。
- **价值观**：V2 只问真正要用的两项授权，手势留给用的时候。V5 每一行旁边有一句话，VoiceOver 能读到。V6 标题说用户得到什么，不列功能。

### 5.5 App 图标（assets/app-icon/WindowShade.icns，build.sh）

- 现在的图标画死了圆角、阴影和高光，照搬了窗口和红绿灯。
- 按 HIG App Icons 重做：用 Icon Composer 分层，不自带高光和阴影，不照搬界面控件，让系统给出浅色、深色、着色、透明几种外观。
- **价值观**：V1 放在 Dock 和访达里要像一个 Mac App。V4 高光和折射交给系统。

### 5.6 官网与宣传片（App 以外）

- 舞台天圆地方；画出来的 Mac 按一台参照机型的真实比例画（例如 MacBook Air 15″：刘海占屏宽 10.8%，高宽比 0.18）。比例数字只写在代码注释里；页面和图片的替代文字最多写“按 15 英寸 MacBook Air 的比例画”（copy-guide 第 1、5 条：几何和比例数字不进用户文字）。
- **价值观**：V1 画出来的 Mac 要和用户手里的一样。V6 宣传语不替 Apple 的硬件下定义，不模仿 Apple 的口号，候选由 Aaron 挑。

---

## 6. 与现状的差距

按影响从大到小排。每一条都写明帕累托守卫：做不到守卫，就不合入。编号沿用定稿时的编号，做完或随功能拿掉的条目不再列出。

### 落代码进度（2026-09-30）

已经落到产品里的：

- **§6-10**：`pop` 阻尼比 0.6 → 0.75（`Overlay/GestureHUD.swift`）。
- **§6-11 增强对比度**：提示浮窗的边从 `separatorColor` 改成 `labelColor`，和窗口浏览一致。
- **§6-17 注释更正**：GestureHUD 不再叫「胶囊」（写明固定圆角 24）；橡皮筋的 c = 0.55 不再写成「Apple 的」。
- **§6-5 动效令牌收拢**（2026-10-01）：§4.6 那张表收进 `Core/FlickMotion.swift` 的 `MotionSpring`
  （App 里叫 `Motion.Spring`，别名），窗口滑行、提示浮窗的调用点改成引用令牌，
  参数逐字不变；对照测试 `tests/MotionTokensTests.swift` + `tests/run-motion-tokens-tests.sh` 逐项比对。
  令牌放在 Core 是因为只编译 `FlickMotion.swift` 的单测也要能用（放在 App 层曾让 9 个 runner 编不过）。

仍未做：§6-8 玻璃审计、§6-15 包含测试探针、§6-16 App 图标（要 Aaron 认概念）。

**5. 动效令牌收拢（第一轮只搬现值）**
- 改什么：把窗口滑行、提示浮窗的参数改成引用令牌。
- 文件：App/Motion.swift；Core/FlickMotion.swift；Overlay/GestureHUD.swift。
- 守卫：每个调用点的 response、ζ、初速度和改之前逐字相等（写一条对照测试）。改值另走 §6-10。

**8. 玻璃用量逐个过一遍（V3、V4）**
- 改什么：列出所有玻璃和自绘材质，检查“只在控件层”“不叠玻璃”“不自己仿”；合盖 / 倾斜效果默认关。
- 文件：用 `NSGlassEffectView` 的有 Overlay/SystemAppearance.swift、Overlay/GestureHUD.swift、WindowBrowser/WindowBrowserMaterial.swift、WindowBrowser/WindowBrowserContentView.swift；合盖和倾斜在 Effects/（FoldRenderer.swift、LidAngleSource.swift、DuoController.swift）。
- 守卫：只删叠层和仿造，不删功能；设置里还能打开合盖效果。

**10. 改值清单（§4.10）**
- 改什么：`pop` ζ 0.6 → 0.75。
- 文件：Overlay/GestureHUD.swift。
- 守卫：单独提交，单独对比手感。

**11. 增强对比度**
- 改什么：提示浮窗不透明底的边从 `separatorColor` 改成 `labelColor`，和窗口浏览一致。
- 文件：Overlay/GestureHUD.swift。
- 守卫：设置关着时像素不变。

**15. 贴角的表面：包含测试探针**
- 改什么：写一个几何断言探针，覆盖带到每张桌面的卷帘条、提示浮窗、悬停预览、专注时的卷帘架；只修真正不通过的，只挪位置。
- 文件：Core/CarryShelfLayout.swift；Overlay/GestureHUD.swift；App/HoverPreview.swift；App/FocusSession.swift。
- 守卫：菜单栏显示时（绝大多数情况）位置和半径逐一不变。按现有边距估算，卷帘架、提示浮窗在本机都不会被切。

**16. App 图标**
- 改什么：按 HIG App Icons 用 Icon Composer 分层重做。
- 文件：assets/app-icon/WindowShade.icns；prototype/build.sh。
- 守卫：旧系统（14/15）上仍有图标。

**17. 注释更正**
- 改什么：GestureHUD 的“胶囊”注释删掉，写明固定圆角 24；橡皮筋 c=0.55 不写成“Apple 的”（Core/FlickMotion.swift）。
- 守卫：只改注释。

**18. 官网与宣传片**
- 改什么：天圆地方，按参照机型的真实比例画（§5.6）。
- 文件：site/；promo/。
- 守卫：单独处理，不和 App 改动一起发。

---

## 7. 验收

**7.1 包含测试**
- §6-15 的各表面在“自动隐藏菜单栏”下都在屏幕轮廓内，并避开刘海那一列。
- 自动隐藏菜单栏时亲眼看四个角。

**7.2 辅助设置与文案**
- 每个改过的表面，在减少动态效果、减少透明度、增强对比度下各看一次，VoiceOver 读一遍。
- 新增和改动的用户可见字符串按 copy-guide 的自检四问过一遍；内部叫法不出现在界面上。

**7.3 能耗**
- 没有新增定时器。

---

## 8. 已定（Aaron，2026-09-29）

1. 搬来的行为逐项定：⌃⌘ 默认快捷键全部不占（老用户保留正在用的）；主动推销类的提示删掉。

---

## 9. 出处

**Apple 讲座**
- WWDC18 803 Designing Fluid Interfaces：https://developer.apple.com/videos/play/wwdc2018/803/
- Designing for iPhone X（fall2017 801）：https://developer.apple.com/videos/play/fall2017/801/
- WWDC23 10158 Animate with springs：https://developer.apple.com/videos/play/wwdc2023/10158/
- WWDC23 10194 Design dynamic Live Activities：https://developer.apple.com/videos/play/wwdc2023/10194/
- WWDC25 219 Meet Liquid Glass：https://developer.apple.com/videos/play/wwdc2025/219/
- WWDC25 356 Get to know the new design system：https://developer.apple.com/videos/play/wwdc2025/356/
- WWDC25 310 Build an AppKit app with the new design：https://developer.apple.com/videos/play/wwdc2025/310/

**HIG 与开发者文档**
- Materials：https://developer.apple.com/design/human-interface-guidelines/materials
- Motion：https://developer.apple.com/design/human-interface-guidelines/motion
- Playing haptics：https://developer.apple.com/design/human-interface-guidelines/playing-haptics
- Live Activities：https://developer.apple.com/design/human-interface-guidelines/live-activities
- Layout：https://developer.apple.com/design/human-interface-guidelines/layout
- Accessibility：https://developer.apple.com/design/human-interface-guidelines/accessibility
- Gestures：https://developer.apple.com/design/human-interface-guidelines/gestures
- Writing：https://developer.apple.com/design/human-interface-guidelines/writing
- App icons：https://developer.apple.com/design/human-interface-guidelines/app-icons
- Adopting Liquid Glass：https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
- Design Resources（Product Bezels）：https://developer.apple.com/design/resources/
- Accessory Design Guidelines R31 与尺寸图：https://developer.apple.com/accessories/dimensional-drawings/

**Apple 规格与新闻**
- MacBook Air 规格：https://www.apple.com/macbook-air/specs/ ；MacBook Air 15″ M5：https://support.apple.com/en-us/126321
- MacBook Pro 规格：https://www.apple.com/macbook-pro/specs/
- MacBook Neo 规格：https://www.apple.com/macbook-neo/specs/ ；https://support.apple.com/en-us/126322
- 新设计发布稿（2025-06）：https://www.apple.com/newsroom/2025/06/apple-introduces-a-delightful-and-elegant-new-software-design/
- iPhone 14 Pro 发布稿（灵动岛，2022-09-07）：https://www.apple.com/newsroom/2022/09/apple-debuts-iphone-14-pro-and-iphone-14-pro-max/
- 无障碍：https://www.apple.com/accessibility/
