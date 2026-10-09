// WindowShade 主文件：全局常量与 AppDelegate 骨架（启动、观察者、生命周期）。
//
// 功能按目录拆分，文件级基础设施也各有归属：
//   App/        收起和展开的流程、鼠标钩子、菜单、设置、看一眼、权限
//   Capture/    截图及其缓存、图像分析
//   Core/       收起相关的值类型和大多不依赖系统的逻辑（状态机、看一眼的指针判断、钩子问答、缩略图几何）
//   Domain/     应用程序配置表与收起计划
//   Overlay/    卷帘条和看一眼的窗口与视图
//   Platform/   移开、放回原窗口，交出焦点，转发红绿灯
//   Private/    SkyLight 私有接口
//   Recovery/   恢复记录与找回屏幕外的窗口
//   Support/    日志、卡顿记录、跨线程包装等基础设施
//   TapHelper/  鼠标钩子进程（单独编译）
//   Window/     辅助功能读写、窗口列表、标题栏外形、坐标换算
//   Vendor/     第三方框架
//
// 编译与运行见 prototype/build.sh（自动收集源文件，签名身份走环境变量）。

import Cocoa
import Carbon.HIToolbox
import ApplicationServices
import ScreenCaptureKit
import QuartzCore
import CoreText
import Darwin
import ServiceManagement

let titleBarHeight: CGFloat = 28
let proxyTitleBarHeight: CGFloat = 34
let quickLookOriginalTitleBarHeight: CGFloat = 38
let standardTitleBarMaxCropHeight: CGFloat = 64
let adobeApplicationFrameChromeHeight: CGFloat = 112
let adobeTabbedDocumentChromeHeight: CGFloat = 84
let adobeFloatingDocumentChromeHeight: CGFloat = 44
// 实测裁切（2026-07，本机截图对照）：通用 112pt 会切进面板内容。
// AE = 细标题栏 + 工具条两排，止于 Project/Effect Controls 面板标签行之前。
// Premiere = 一体化单条标题栏（红绿灯与 Import/Edit/Export 同排），
// 其下的面包屑/侧栏是内容。
let afterEffectsWorkspaceChromeHeight: CGFloat = 56
let premiereWorkspaceChromeHeight: CGFloat = 40
let shadeAppearanceModeDefaultsKey = "ShadeAppearanceMode"
let shadeFloatingOnTopDefaultsKey = "ShadeFloatingOnTop"
let shadeTranslucentDefaultsKey = "ShadeTranslucent"
let shadeTitlebarDoubleClickDefaultsKey = "ShadeTitlebarDoubleClickEnabled"
let shadeSoundEnabledDefaultsKey = "ShadeSoundEnabled"
let shadeFoldSoundDefaultsKey = "ShadeFoldSound"
let shadeUnfoldSoundDefaultsKey = "ShadeUnfoldSound"
let shadeSoundMigrationVersionDefaultsKey = "ShadeSoundMigrationVersion"
let shadeOnboardingShownDefaultsKey = "ShadeOnboardingShown"
let dockMineffectSessionActiveDefaultsKey = "DockMineffectSessionActive"
let dockMineffectHadOriginalDefaultsKey = "DockMineffectHadOriginal"
let dockMineffectOriginalDefaultsKey = "DockMineffectOriginal"
let shadeJournalDefaultsKey = "ShadeJournalEntries"
let shadeDebugWindowDumpDefaultsKey = "ShadeDebugWindowDump"
let shadeJournalMaxAge: TimeInterval = 14 * 24 * 60 * 60
let shadedWindowReconcileInterval: TimeInterval = 5
let journalRescueRetryInterval: TimeInterval = 30
let shadeTranslucentAlpha: CGFloat = 0.82
let axFullScreenAttribute = "AXFullScreen"
/// 一次辅助功能调用最多等多久（秒）。
let axMessagingTimeout: Float = 1.0
// AX 子树遍历预算：限制“顶部控件扫描”（collectTopChromeControlSamples）和
// firstToolbar 在最坏情况下的同步 IPC 数量。复杂窗口（浏览器等）的 AX 树可达
// 数千节点，不限数量地遍历，会让收起和双击判定在忙的应用程序上让主线程长时间等待。
let axTraversalNodeBudget = 150
let axTraversalMaxChildrenPerNode = 40
let hoverPreviewMaxPixelSize = CGSize(width: 720, height: 480)
let menuHoverPreviewMaxSize = NSSize(width: 240, height: 160)
let shadeCaptureTimeoutNanoseconds: UInt64 = 450_000_000
let shadeDefaultFoldSound = "Purr"
let shadeDefaultUnfoldSound = "Pop"
let shadeSoundChoices: [(label: String, name: String)] = [
    ("柔和（Purr）", "Purr"),
    ("低沉（Submarine）", "Submarine"),
    ("轻吹（Blow）", "Blow"),
    ("轻响（Tink）", "Tink"),
    ("清脆（Glass）", "Glass"),
    ("弹响（Pop）", "Pop")
]
/// main.swift 启动时在主线程写一次，之后只读。
nonisolated(unsafe) var appDelegate: AppDelegate?

func framesAlmostEqual(_ a: NSRect, _ b: NSRect, tolerance: CGFloat = 0.5) -> Bool {
    abs(a.minX - b.minX) <= tolerance &&
    abs(a.minY - b.minY) <= tolerance &&
    abs(a.width - b.width) <= tolerance &&
    abs(a.height - b.height) <= tolerance
}

@MainActor
func cgWindowID(for window: NSWindow) -> CGWindowID? {
    let number = window.windowNumber
    guard number > 0, number <= Int(UInt32.max) else { return nil }
    return CGWindowID(UInt32(number))
}

// MARK: - App 主体

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var settingsWindow: SettingsWindow?
    final class PendingTitlebarTripleClick {
        let id: CGWindowID
        let point: CGPoint
        var deadline: Date
        let intent = TitlebarTripleClickIntent()
        var foldTransactionID: UUID?

        init(id: CGWindowID, point: CGPoint, deadline: Date) {
            self.id = id
            self.point = point
            self.deadline = deadline
        }
    }

    struct PendingSpaceReturn {
        let displayID: CGDirectDisplayID
        let sourceSpaceID: UInt64
        let deadline: Date
    }

    // reconcile 需要知道原窗口是否仍存在、是否已最小化，但这些 AX 读取可能被忙的应用程序
    // 阻塞数秒。每个应用程序最多一个在途读取，全局同时最多 4 个；主线程只应用已经返回的结果。
    struct ReconcileAXTarget {
        let id: CGWindowID
        let pid: pid_t
        let element: AXUIElement
        let needsMinimizedState: Bool
        let stamp: FoldCallbackStamp
    }

    struct ReconcileAXSnapshot: Sendable {
        let stamp: FoldCallbackStamp
        var id: CGWindowID { stamp.window }
        let position: CGPoint?
        let size: CGSize?
        let isMinimized: Bool?
    }

    var statusItem: NSStatusItem!
    var statusMenu: NSMenu!
    var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    /// 注册失败（被其他应用占用）的快捷键编号；菜单不再显示这些组合。
    var unavailableHotKeyIDs: Set<UInt32> = []
    var shaded: [CGWindowID: ShadeState] = [:]
    var overlayIDs: Set<CGWindowID> = []      // 我们自己的覆盖层，tap 里要跳过它们
    var arrangedOverlayFrames: [CGWindowID: NSRect] = [:]
    var accessibilityActionTargets: [CGWindowID: ShadedAccessibilityActionTarget] = [:]   // FoldExit/ShadeStrip 扩展跨文件访问
    var isProgrammaticOverlayArrangement = false
    private var scaleMinimizeActive = false           // 临时把最小化动画改成 scale（退出还原用户原设置）
    private var originalDockMinimizeEffect: String?   // nil = 原本没有设置 mineffect
    private var dockMinimizeEffectChanged = false
    // Dock 设置用的后台串行队列：读写 defaults 和 killall Dock 都要同步等子进程，不该占用主线程
    // （启动、菜单切换都走这里）。状态在后台算好、回主线程应用；退出时用 dockWorkQueue.sync
    // 等这些操作做完，再按存盘的会话键恢复，启用和恢复交错进行时结果也正确。
    private let dockWorkQueue = DispatchQueue(label: "WindowShade.dock", qos: .utility)
    private var dockOperationInFlight = false         // 主线程专用：防重复入队启用
    // 截图像素分析（标题栏高度扫描、原标题栏卷帘条的完整性检查、圆角镜像）用的后台队列：纯计算，
    // 4K Retina 全宽的缓冲可达数 MB，放在主线程上会让收起时界面停顿。
    let pixelAnalysisQueue = DispatchQueue(label: "WindowShade.pixels", qos: .userInitiated)
    // 找回屏幕外窗口用的后台队列：逐个应用程序枚举辅助功能窗口、全量扫描停放位置，
    // 遇到忙的应用程序可能要等好几秒，不能放在主线程上。窗口位置统一在主线程写回，
    // 写回前再查一次 shaded 是否为空，避免和正在进行的收起交错。
    let rescueWorkQueue = DispatchQueue(label: "WindowShade.rescue", qos: .utility)
    var isRescuingOffscreenWindows = false
    var isRescueQueued = false
    private var tapSetupTimer: Timer?
    var reconcileTimer: Timer?
    var isReconcilingShadedWindows = false
    var axReadGate = AXReadGate<pid_t, [FoldCallbackStamp]>()
    var reconcileInvalidCounts: [CGWindowID: Int] = [:]
    // 移开原窗口（Platform/WindowHider.swift）。跨进程的 SkyLight 写入是否已确认无效（SIP 限制）：
    // 每试一次都要挪好几处、每处向窗口服务器读一次位置，第一次收起要多花约 0.26 秒。
    // SIP 开着就一直无效，所以记进偏好，系统升级后才重新试。
    let windowHider = WindowHider(control: WindowControlSystem(),
                                  skyLightMoveIneffective: PrivateSLSMemo.isIneffective("offscreen"),
                                  skyLightAlphaIneffective: PrivateSLSMemo.isIneffective("alpha"),
                                  rememberIneffective: { PrivateSLSMemo.markIneffective($0) })
    /// 移开原窗口在这条队列上做；同一时刻只移开一个窗口，和原来在主线程上的顺序一致。
    let windowHideQueue = DispatchQueue(label: "WindowShade.window-hide", qos: .userInteractive)
    /// 展开、转发卷帘条上的按钮、回读原窗口（Platform/WindowRestorer.swift）：辅助功能调用在各应用程序自己的队列上，
    /// 主线程不等其他应用程序（R5）。
    let windowRestorer = WindowRestorer(control: RestoreControlSystem())
    /// 正在后台回读位置、看原窗口是否已被唤回的卷帘条：同一扇窗口同时只读一次，应用程序无响应时不越积越多。
    var pendingVisibilityChecks: Set<CGWindowID> = []
    var restoreVerificationTokens: [CGWindowID: UUID] = [:]
    var restoreFocusTokens: [CGWindowID: UUID] = [:]
    var recoveryJournalOverride: DurableShadeJournal?
    var lastJournalRescueAttempt: Date?
    var focusParkingWindow: NSWindow?
    // 当前唯一在屏幕上的预览视窗（菜单悬停触发），见 presentPreview/hidePreview。
    var activePreview: ActivePreview?
    /// 浅深色切换的 KVO 令牌（系统外观刷新用）。
    var appearanceObservation: NSKeyValueObservation?
    var pendingSpaceReturns: [CGWindowID: PendingSpaceReturn] = [:]
    // 记下菜单里指针停在哪一项：截图要异步等，结果回来时指针已经移开，就不再弹出不相干窗口的预览。
    var menuPreviewHoverID: CGWindowID?
    var menuPreviewAnchor: NSRect?
    var shadeOperationIDs: Set<CGWindowID> = []
    /// 卷帘条已经出现、收起还没走完时收到双击的窗口：收起一完成就展开（见 unshadeFromStrip）。
    var unfoldWhenFolded: Set<CGWindowID> = []
    // 显式窗口状态机：operationStates[id] 缺失即 .normal。
    // capturing/failed 为操作期瞬态，folded/restoring 为会话期状态。
    private var operationStates: [CGWindowID: WindowShadeState] = [:]
    var previewCapturePendingIDs: Set<CGWindowID> = []
    var hoverPreviewSuppressedUntil: [CGWindowID: Date] = [:]
    var statusNoticeWorkItem: DispatchWorkItem?
    var onboardingWindow: NSWindow?
    // 等收起结束的回调（标题栏三击要等收起真正完成）：键是原窗口 ID，值是 token → 回调。
    // 收起是异步的（立即验证 / 延迟验证 / 回滚），只在最终结果出来时回调；
    // token 保证旧请求的结果不会交给新请求。
    var foldWaiters: [CGWindowID: [UUID: (Bool) -> Void]] = [:]
    var foldWaiterTransactions: [UUID: UUID] = [:]
    var foldObserverSerial: UInt = 0
    var foldObserverRoutes: [UInt: FoldObserverRoute] = [:]
    var foldPresentationID = UUID()
    var menuRebuildWorkItem: DispatchWorkItem?
    var suppressMenuRebuilds = false
    var pendingMenuRebuild = false
    var isUpdatingMenuFromDelegate = false
    private var mouseDownMonitor: Any?
    private var titlebarPrefetchInFlight = false
    private var titlebarPrefetchGeneration: UInt64 = 0
    var spaceRefreshWorkItem: DispatchWorkItem?
    /// 上一次看到的显示器，用来分辨“真的换了屏”和“只是菜单栏、Dock 变了”。
    var lastDisplayLayout = DisplayLayout(screens: [])
    private var appNapActivity: NSObjectProtocol?
    var onboardingPermissions: PermissionStatus?
    var onboardingRefreshTimer: Timer?
    var suppressUnshadeSounds = false
    var ownsGlobalInput = true
    var pendingTitlebarTripleClick: PendingTitlebarTripleClick?
    var restorePinTokens: [CGWindowID: UUID] = [:]
    /// 用辅助功能“缩放”过的窗口原来的位置和大小（辅助功能坐标）：再缩放一次放回去。
    var zoomRestoreFrames: [CGWindowID: CGRect] = [:]
    /// 卷帘条最后一次被拖动的令牌：停下 0.3 秒、松开鼠标后，检查它还够不够得着。
    var overlayMoveSettleTokens: [CGWindowID: UUID] = [:]
    var soundEnabled: Bool = {
        if UserDefaults.standard.object(forKey: shadeSoundEnabledDefaultsKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: shadeSoundEnabledDefaultsKey)
    }()
    var foldSoundName: String = {
        UserDefaults.standard.string(forKey: shadeFoldSoundDefaultsKey) ?? shadeDefaultFoldSound
    }()
    var unfoldSoundName: String = {
        UserDefaults.standard.string(forKey: shadeUnfoldSoundDefaultsKey) ?? shadeDefaultUnfoldSound
    }()
    var appearanceMode: ShadeAppearanceMode = {
        let raw = UserDefaults.standard.string(forKey: shadeAppearanceModeDefaultsKey) ?? ""
        let mode = ShadeAppearanceMode(rawValue: raw) ?? .nativeScreenshot
        return mode == .proxyTitleBar ? .proxyTitleBar : .nativeScreenshot
    }()
    var titlebarDoubleClickEnabled: Bool = {
        if UserDefaults.standard.object(forKey: shadeTitlebarDoubleClickDefaultsKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: shadeTitlebarDoubleClickDefaultsKey)
    }()
    var floatingOnTop: Bool = {
        if UserDefaults.standard.object(forKey: shadeFloatingOnTopDefaultsKey) == nil { return true }
        return UserDefaults.standard.bool(forKey: shadeFloatingOnTopDefaultsKey)
    }()
    var translucent: Bool = UserDefaults.standard.bool(forKey: shadeTranslucentDefaultsKey)
    var eventTap: CFMachPort?                          // 供 C 回调重新启用
    var eventTapReenableWorkItem: DispatchWorkItem?
    let offscreen = CGPoint(x: -32000, y: -32000)
    let defaultShadeOptions = ShadeInvocationOptions(forcedAppearanceMode: nil,
                                                             capturePreview: true,
                                                             emitFoldFeedback: true,
                                                             rebuildMenuAfterInstall: true)
    /// 看一眼：指针停在卷帘条上，窗口原样出现，移开就收回。
    lazy var glance = MainActor.assumeIsolated { GlanceController(owner: self) }

    func applicationDidFinishLaunching(_ note: Notification) {
        // 只留一个 WindowShade（docs/test-catalog.md L07）：两个同时运行，会各自拦截双击、各自收起同一扇窗。
        // 在写下任何设置、找回任何窗口之前判断。更新后重新启动时旧的那个可能还在退出，等它最多 2 秒。
        if anotherWindowShadeKeepsRunning() {
            wlog("launch: another WindowShade is running; this one quits pid=\(getpid())")
            exit(0)
        }
        // 新装还是升级：赶在这一次启动写下任何设置之前认一次、存下来（声音迁移每次启动都写，清理收起记录会删键；
        // 见 App/GlobalShortcuts.swift 的 InstallHistory）。
        _ = InstallHistory.settled(in: .standard)
        // 代理应用也要有标准主菜单：文本编辑快捷键与 ⌘W 都靠它的 key equivalent 派发。
        installStandardMainMenu()
        let sessionFormatter = DateFormatter()
        sessionFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        sessionFormatter.locale = Locale(identifier: "en_US_POSIX")
        wlog("=== session start pid=\(getpid()) at \(sessionFormatter.string(from: Date())) ===")
        // 权限状态写进日志：没有权限时的表现（欢迎窗口、简化标题栏）要能和权限对上。
        wlog("permissions: accessibility=\(AXIsProcessTrusted()) screenRecording=\(hasScreenRecordingPermission())")
        // 一直不进入 App Nap：鼠标钩子（在钩子进程里，或钩子进程启动失败时在 WindowShade 自己的线程上）
        // 遇到双击、三击要问主线程；主线程被节流后回答变慢，每次双击都要等满时限才放行
        // （TapDecision.deadline、TapProtocol.deadline）。定时器（如 Reconcile 的定时核对）也会被推迟几十秒。
        appNapActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "WindowShade owns a global event tap; App Nap stalls system-wide mouse input")
        MainThreadStallSentinel.shared.start()
        // 启动序列逐步计时：任何一步超过 100ms 都会记录，用于定位启动期主线程阻塞。
        logIfSlow("launch migrateSounds", threshold: 0.1) { migrateDistractingDefaultSounds() }
        logIfSlow("launch pruneJournal", threshold: 0.1) { pruneShadeJournal(reason: "launch") }
        logIfSlow("launch statusItem", threshold: 0.1) { setupStatusItem() }
        prewarmFastCapture()
        logIfSlow("launch dockEffect", threshold: 0.1) { enableScaleMinimizeEffectForSession() }
        logIfSlow("launch hotKey", threshold: 0.1) { registerHotKey() }
        logIfSlow("launch ensureAX", threshold: 0.1) { _ = ensureAccessibility() }
        // 把本进程所有同步 AX 调用的超时从系统默认 6s 收紧到 axMessagingTimeout。
        // 目标应用程序无响应时，主线程最多等这么久；正常应用程序的 AX 属性读取都在毫秒级，不受影响。
        logIfSlow("launch axTimeout", threshold: 0.1) {
            AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), axMessagingTimeout)
        }
        logIfSlow("launch onboarding", threshold: 0.1) { showPermissionOnboardingIfNeeded(force: false) }
        logIfSlow("launch eventTap", threshold: 0.1) { setupEventTapWhenTrusted() }
        prepareAppIcons()
        FirstUseWarmup.start()
        installStripKeyForwarding()
        setupMouseDownMonitor()
        NSWorkspace.shared.notificationCenter.addObserver(self,
                                                          selector: #selector(appTerminated(_:)),
                                                          name: NSWorkspace.didTerminateApplicationNotification,
                                                          object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self,
                                                          selector: #selector(appUnhidden(_:)),
                                                          name: NSWorkspace.didUnhideApplicationNotification,
                                                          object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self,
                                                          selector: #selector(frontmostApplicationChanged(_:)),
                                                          name: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self,
                                                          selector: #selector(activeSpaceChanged(_:)),
                                                          name: NSWorkspace.activeSpaceDidChangeNotification,
                                                          object: nil)
        lastDisplayLayout = .current()
        NotificationCenter.default.addObserver(self,
                                               selector: #selector(screenParametersChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification,
                                               object: nil)
        // 系统外观开关（减少透明度 / 提高对比度 / 减少动态效果）变化时，
        // 已打开的卷帘条和菜单悬停预览立即跟着刷新。
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(systemAppearanceOptionsChanged(_:)),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil)
        // 强调色与系统颜色变化：刷新自定义表面里用到的语义颜色。
        NotificationCenter.default.addObserver(
            self, selector: #selector(systemAppearanceOptionsChanged(_:)),
            name: NSColor.systemColorsDidChangeNotification, object: nil)
        // 浅深色切换没有公开的 NSApplication 通知：用 KVO 观察 effectiveAppearance，
        // 变化时同样只刷新材质与边线。
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) {
            [weak self] _, _ in
            // AppKit 在修改这个属性的线程上回调；effectiveAppearance 只在主线程改。
            MainActor.assumeIsolated {
                self?.systemAppearanceOptionsChanged(
                    Notification(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification))
            }
        }
        // 应用内更新（App/Updater.swift）：最后启动。
        MainActor.assumeIsolated { UpdaterController.shared.start() }
    }

    /// 辅助功能外观变化：只刷新材质/边线/阴影，不动窗口状态、不触发任何捕获。
    @objc func systemAppearanceOptionsChanged(_ note: Notification) {
        dispatchPrecondition(condition: .onQueue(.main))
        // 外观开关的通知回调也要加标记，卡顿日志里才看得出是它。
        MainThreadActivity.push("system: 外观开关变化")
        defer { MainThreadActivity.pop() }
        let capabilities = SystemAppearanceCapabilities.current
        wlog("appearance: system options changed reduceTransparency="
             + "\(capabilities.reduceTransparency) increaseContrast=\(capabilities.increaseContrast) "
             + "reduceMotion=\(capabilities.reduceMotion)")
        // 卷帘条：全部重画；原标题栏的卷帘条另外刷新边线。
        for state in shaded.values {
            guard let content = state.overlay?.contentView else { continue }
            content.needsDisplay = true
            (content as? TitleStripView)?.applySystemAppearance(capabilities: capabilities)
        }
        // 菜单悬停预览。
        (activePreview?.window.contentView as? SafariStylePreviewView)?
            .applySystemAppearance(capabilities: capabilities)
    }

    /// 安装标准最小主菜单（关于/设置/服务/隐藏/退出 + 编辑 + 窗口）。
    /// 代理应用不显示菜单栏，但文本框与关闭快捷键按系统习惯工作。
    func installStandardMainMenu() {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "WindowShade"
        NSApp.mainMenu = StandardMenu.make(appName: appName,
                                           settingsTarget: self,
                                           settingsAction: #selector(showPreferences),
                                           aboutTarget: self,
                                           aboutAction: #selector(showAboutPanel))
    }

    private func migrateDistractingDefaultSounds() {
        let defaults = UserDefaults.standard
        let migrationVersion = defaults.integer(forKey: shadeSoundMigrationVersionDefaultsKey)
        let retiredFoldSounds = ["Tink", "WindowShadeSoftFold"]
        if let foldSound = defaults.string(forKey: shadeFoldSoundDefaultsKey),
           retiredFoldSounds.contains(foldSound) {
            defaults.set(shadeDefaultFoldSound, forKey: shadeFoldSoundDefaultsKey)
            foldSoundName = shadeDefaultFoldSound
        }
        let retiredUnfoldSounds = ["Bottle", "WindowShadeSoftUnfold"]
        if let unfoldSound = defaults.string(forKey: shadeUnfoldSoundDefaultsKey),
           retiredUnfoldSounds.contains(unfoldSound) {
            defaults.set(shadeDefaultUnfoldSound, forKey: shadeUnfoldSoundDefaultsKey)
            unfoldSoundName = shadeDefaultUnfoldSound
        } else if migrationVersion < 2,
                  defaults.string(forKey: shadeUnfoldSoundDefaultsKey) == "Purr" {
            defaults.set(shadeDefaultUnfoldSound, forKey: shadeUnfoldSoundDefaultsKey)
            unfoldSoundName = shadeDefaultUnfoldSound
        }
        defaults.set(2, forKey: shadeSoundMigrationVersionDefaultsKey)
    }






    /// 每次按下鼠标：可能是双击标题栏的第一下，先在后台取好截图要用的窗口清单。
    private func setupMouseDownMonitor() {
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            // NSEvent 全局 monitor 在主线程回调；连 WindowServer 的标题栏预过滤
            // 也可能很慢。这些准备整体放到后台，连续点击至多留一份工作，过时结果直接丢弃。
            if #available(macOS 14.0, *) {
                self?.scheduleTitlebarPrefetch()
            }
        }
    }

    @available(macOS 14.0, *)
    private func scheduleTitlebarPrefetch() {
        titlebarPrefetchGeneration &+= 1
        guard titlebarDoubleClickEnabled, !titlebarPrefetchInFlight else { return }
        titlebarPrefetchInFlight = true
        let generation = titlebarPrefetchGeneration
        let mouse = NSEvent.mouseLocation
        let point = CGPoint(x: mouse.x, y: coordinateBaselineY() - mouse.y)
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let mayBeTitlebar = pointMayLieInTitlebarBand(point)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.titlebarPrefetchInFlight = false
                guard self.titlebarPrefetchGeneration == generation,
                      self.titlebarDoubleClickEnabled, mayBeTitlebar else { return }
                Task { @MainActor in await ShareableContentCache.shared.prefetch() }
            }
        }
    }










    func configureShadedAccessibility(for overlay: NSWindow, id: CGWindowID,
                                              appName: String, title: String) {
        let displayTitle = descriptiveDisplayTitle(appName: appName, windowTitle: title)
        let label = "已收起的窗口：\(displayTitle)"
        let target = ShadedAccessibilityActionTarget { [weak self] in
            self?.unshade(id) ?? false
        }
        accessibilityActionTargets[id] = target

        let actions = [
            NSAccessibilityCustomAction(name: "展开窗口", target: target,
                                        selector: #selector(ShadedAccessibilityActionTarget.perform(_:)))
        ]
        guard let contentView = overlay.contentView else { return }
        contentView.setAccessibilityElement(true)
        contentView.setAccessibilityRole(NSAccessibility.Role.button)
        contentView.setAccessibilityLabel(label)
        contentView.setAccessibilityValue("已收起")
        contentView.setAccessibilityHelp("展开这个窗口")
        contentView.setAccessibilityCustomActions(actions)
    }

    /// 当前操作的是哪条卷帘条：先看本应用的当前窗口，再看指针下的卷帘条。
    /// ⌃⌘C（toggle）和菜单标题（foldToggleMenuTitle）都用它，菜单里的“收起当前窗口 / 展开当前窗口”
    /// 因此和快捷键的实际行为一致。不读其他应用程序的焦点窗口：忙的应用程序会让每次菜单重建都等到辅助功能超时。
    /// 认不出时返回 nil，菜单显示“收起当前窗口”。
    func currentShadedOverlayID() -> CGWindowID? {
        let activeWindows = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
        for window in activeWindows {
            if let entry = shaded.first(where: { $0.value.overlay === window }) {
                return entry.key
            }
        }

        let mouse = NSEvent.mouseLocation
        let hits = shaded.compactMap { id, state -> (CGWindowID, NSWindow)? in
            guard let overlay = state.overlay,
                  overlay.frame.insetBy(dx: -3, dy: -3).contains(mouse) else { return nil }
            return (id, overlay)
        }
        return hits.max { $0.1.level.rawValue < $1.1.level.rawValue }?.0
    }


@objc func finishOnboarding() {
        dismissOnboarding()
    }

@objc func dismissOnboarding() {
        UserDefaults.standard.set(true, forKey: shadeOnboardingShownDefaultsKey)
        onboardingRefreshTimer?.invalidate()
        onboardingRefreshTimer = nil
        onboardingWindow?.orderOut(nil)
    }




    // 下面这一组只跑 defaults / killall，不读界面状态。Dock 串行队列和退出时的 sync 都直接调用。
    @discardableResult
    nonisolated private func runTool(_ path: String, _ args: [String]) -> Int32? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        do {
            try p.run()
        } catch {
            wlog("tool: failed to run \(path) \(args.joined(separator: " ")) error=\(error)")
            return nil
        }
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            wlog("tool: nonzero status=\(p.terminationStatus) \(path) \(args.joined(separator: " "))")
        }
        return p.terminationStatus
    }

    nonisolated private func readTool(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    nonisolated private func runDefaults(_ args: [String]) { runTool("/usr/bin/defaults", args) }
    nonisolated private func readDefaults(_ args: [String]) -> String? { readTool("/usr/bin/defaults", args) }
    nonisolated private func killDock() { runTool("/usr/bin/killall", ["Dock"]) }   // 让 Dock 重读 mineffect

    nonisolated private func writeDockMinimizeEffect(_ value: String, reason: String) -> Bool {
        for attempt in 1...2 {
            runDefaults(["write", "com.apple.dock", "mineffect", "-string", value])
            let effective = readDefaults(["read", "com.apple.dock", "mineffect"])
            if effective == value {
                wlog("dock: mineffect=\(value) verified reason=\(reason) attempt=\(attempt)")
                return true
            }
            wlog("dock: mineffect verify failed expected=\(value) actual=\(effective ?? "<unset>") reason=\(reason) attempt=\(attempt)")
        }
        return false
    }

    nonisolated private func persistDockMinimizeEffectSession(original: String?) {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: dockMineffectSessionActiveDefaultsKey)
        defaults.set(original != nil, forKey: dockMineffectHadOriginalDefaultsKey)
        if let original {
            defaults.set(original, forKey: dockMineffectOriginalDefaultsKey)
        } else {
            defaults.removeObject(forKey: dockMineffectOriginalDefaultsKey)
        }
    }

    nonisolated private func clearDockMinimizeEffectSession() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: dockMineffectSessionActiveDefaultsKey)
        defaults.removeObject(forKey: dockMineffectHadOriginalDefaultsKey)
        defaults.removeObject(forKey: dockMineffectOriginalDefaultsKey)
    }

    nonisolated private func restoreDockMinimizeEffect(original: String?) {
        if let original {
            runDefaults(["write", "com.apple.dock", "mineffect", "-string", original])
        } else {
            runDefaults(["delete", "com.apple.dock", "mineffect"])
        }
    }

    nonisolated private func recoverStaleDockMinimizeEffectSessionIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: dockMineffectSessionActiveDefaultsKey) else { return }
        let hadOriginal = defaults.bool(forKey: dockMineffectHadOriginalDefaultsKey)
        let original = hadOriginal ? defaults.string(forKey: dockMineffectOriginalDefaultsKey) : nil
        restoreDockMinimizeEffect(original: original)
        clearDockMinimizeEffectSession()
        killDock()
        wlog("dock: recovered stale mineffect session original=\(original ?? "<unset>")")
    }

    private func enableScaleMinimizeEffectForSession() {
        guard !scaleMinimizeActive, !dockOperationInFlight else { return }
        dockOperationInFlight = true
        dockWorkQueue.async { [weak self] in
            guard let self else { return }
            self.recoverStaleDockMinimizeEffectSessionIfNeeded()
            let original = self.readDefaults(["read", "com.apple.dock", "mineffect"])
            let originalWasScale = original == "scale"
            if !originalWasScale {
                self.persistDockMinimizeEffectSession(original: original)
            } else {
                self.clearDockMinimizeEffectSession()
            }
            let verified = self.writeDockMinimizeEffect("scale", reason: "session-start")
            // 即使偏好里已经是 scale，正在运行的 Dock 在重读偏好之前可能仍用“神奇效果”。
            // 这里重启 Dock，让最小化（其他方式都不行时才用的收起方式）的动画和收起的样子一致。
            self.killDock()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.dockOperationInFlight = false
                self.originalDockMinimizeEffect = original
                self.dockMinimizeEffectChanged = verified && !originalWasScale
                self.scaleMinimizeActive = true
            }
        }
    }

    private func restoreDockMinimizeEffect() {
        // 按存盘的会话键恢复，不看实例状态：和进行中的启用在同一个串行队列上按先后执行，
        // 顺序一定是“先启用、后恢复”。
        dockWorkQueue.async { [weak self] in
            guard let self else { return }
            self.recoverStaleDockMinimizeEffectSessionIfNeeded()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.dockOperationInFlight = false
                self.originalDockMinimizeEffect = nil
                self.dockMinimizeEffectChanged = false
                self.scaleMinimizeActive = false
            }
        }
    }


    func currentOperationState(_ id: CGWindowID) -> WindowShadeState {
        operationStates[id] ?? .normal
    }

    // 状态机唯一入口：非法转换拒绝并记日志，避免窗口状态损坏。
    @discardableResult
    func transitionOperationState(id: CGWindowID, to next: WindowShadeState,
                                          reason: String) -> Bool {
        let current = currentOperationState(id)
        guard current.canTransition(to: next) else {
            wlog("state: illegal transition \(current.rawValue) -> \(next.rawValue) id=\(id) reason=\(reason)")
            return false
        }
        operationStates[id] = next
        wlog("state: \(current.rawValue) -> \(next.rawValue) id=\(id) reason=\(reason)")
        if next == .folded, unfoldWhenFolded.remove(id) != nil {
            wlog("strip: unfolding id=\(id) for a double click that came before the fold finished")
            DispatchQueue.main.async { [weak self] in _ = self?.unshade(id) }
        } else if next != .capturing {
            unfoldWhenFolded.remove(id)
        }
        return true
    }


    func applicationWillTerminate(_ note: Notification) {
        restoreAll()
        reconcileTimer?.invalidate()
        reconcileTimer = nil
        if let mouseDownMonitor {
            NSEvent.removeMonitor(mouseDownMonitor)
            self.mouseDownMonitor = nil
        }
        eventTapReenableWorkItem?.cancel()
        eventTapReenableWorkItem = nil
        TapHelperLink.stop()
        // 退出前还原 Dock 偏好：同步等在途子进程排空，再按持久化 session 键
        // 恢复（session 键在改动前写入，异步启用/恢复交错下也正确）。
        dockWorkQueue.sync {
            recoverStaleDockMinimizeEffectSessionIfNeeded()
        }
        scaleMinimizeActive = false
        WindowShadeLogger.shared.flushAndClose()
    }

    @discardableResult
    func ensureAccessibility() -> Bool {
        // kAXTrustedCheckOptionPrompt 的值；系统把那个常量导入成了可变全局变量，并发检查下不能直接读。
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    // MARK: 触发

    @objc func toggleAction() { toggle() }

    @objc func unshadeFromMenu(_ sender: NSMenuItem) {
        guard let n = sender.representedObject as? NSNumber else { return }
        unshade(CGWindowID(n.uint32Value))
    }

    @objc func quit() {
        restoreAll()
        NSApp.terminate(nil)
    }

    // MARK: 双击标题栏（CGEventTap）

    /// 启动时在后台画好正在运行的普通应用程序的图标（见 Support/AppIconCache.swift）。
    func prepareAppIcons() {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            AppIconCache.shared.prepare(pid: app.processIdentifier)
        }
    }

    // 装鼠标钩子需要辅助功能权限；权限可能在启动以后才给，所以每 2 秒查一次，有了再装。
    func setupEventTapWhenTrusted() {
        if setupEventTap() {
            rescueOffscreenWindows(silent: true)
            return
        }
        tapSetupTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
            // 这个计时器是在主线程方法里挂上当前 run loop 的，到点仍在主线程。
            // 计时器本身留在闭包原来的隔离域里停掉，不送进主线程闭包。
            let installed = MainActor.assumeIsolated { () -> Bool in
                guard self?.setupEventTap() == true else { return false }
                self?.rescueOffscreenWindows(silent: true)
                return true
            }
            if installed { t.invalidate() }
        }
    }

    /// 全系统的鼠标钩子装好了：在钩子进程里，或者在 WindowShade 自己这里。
    var hasGlobalTap: Bool { eventTap != nil || TapHelperLink.isRunning }

    /// 先用钩子进程（App/TapHelperLink.swift）：WindowShade 停住、无响应时不挡全系统的点击。
    /// 钩子进程用不了才在自己这里装钩子。
    @discardableResult
    func setupEventTap() -> Bool {
        guard !hasGlobalTap, AXIsProcessTrusted() else { return hasGlobalTap }
        if TapHelperLink.start() { return true }
        return setupInProcessEventTap()
    }

    private func setupInProcessEventTap() -> Bool {
        guard eventTap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: eventTapCallback, userInfo: nil) else { return false }
        eventTap = tap
        mouseDownTapPort = tap
        // 钩子跑在自己的线程上：主线程卡顿时，全系统的单击不用等它（见 eventTapCallback）。
        let thread = Thread {
            let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "WindowShade.mouse-down-tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

}

/// 记住本机的跨进程 SkyLight 改动无效（SIP 开着）。按系统版本记：升级系统后重新试一次。
enum PrivateSLSMemo {
    private static func key(_ kind: String) -> String { "PrivateSLS.ineffective.\(kind)" }
    private static var systemVersion: String { ProcessInfo.processInfo.operatingSystemVersionString }

    static func isIneffective(_ kind: String) -> Bool {
        UserDefaults.standard.string(forKey: key(kind)) == systemVersion
    }

    /// 写偏好要和 cfprefsd 同步往返，CI 上实测在主线程上等过 446 毫秒：放到后台写，下次启动才读。
    static func markIneffective(_ kind: String) {
        let version = systemVersion
        let defaultsKey = key(kind)
        DispatchQueue.global(qos: .utility).async { UserDefaults.standard.set(version, forKey: defaultsKey) }
    }
}

extension AppDelegate {
    /// 启动一秒后在后台截 1 像素：截图接口第一次调用要先加载（实测可达 0.7 秒），
    /// 不提前做，这段时间就会算到第一次收起上。
    func prewarmFastCapture() {
        guard hasScreenRecordingPermission() else { return }
        let selfPID = ProcessInfo.processInfo.processIdentifier
        pixelAnalysisQueue.asyncAfter(deadline: .now() + 1) {
            var startedAt = CFAbsoluteTimeGetCurrent()
            let ok = FastCapture.warmUp()
            wlog("capture: prewarm \(ok ? "ok" : "no image") \(Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000))ms")
            // 只在 CI 录像时打开（record.sh 设置）：CI 虚拟机上同一窗口的第一次整窗截图要 0.6–1.7 秒，
            // 真实的 Mac 上只要几十毫秒（2026-10-08 实测 45 毫秒，docs/testing.md 第 5 节）。启动时先对最前面的
            // 窗口整窗截一次，让录像里的收起耗时和真实的 Mac 一致。
            guard UserDefaults.standard.bool(forKey: "WindowShadePrewarmFullCapture") else { return }
            let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] ?? []
            guard let window = windows.first(where: { info in
                      (info[kCGWindowLayer as String] as? Int) == 0
                          && (info[kCGWindowOwnerPID as String] as? pid_t) != selfPID
                  }),
                  let number = window[kCGWindowNumber as String] as? NSNumber else { return }
            startedAt = CFAbsoluteTimeGetCurrent()
            let full = FastCapture.window(CGWindowID(number.uint32Value))
            wlog("capture: CI full-capture prewarm window=\(number) owner=\(window[kCGWindowOwnerName as String] as? String ?? "?") \(full == nil ? "empty" : "ok") \(Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000))ms")
        }
    }

}

/// 除了自己，还有别的 WindowShade 进程在运行，并且 2 秒内没有退出。
private func anotherWindowShadeKeepsRunning() -> Bool {
    guard let bundleID = Bundle.main.bundleIdentifier else { return false }
    let selfPID = ProcessInfo.processInfo.processIdentifier
    for _ in 0..<20 {
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != selfPID && !$0.isTerminated }
        if others.isEmpty { return false }
        Thread.sleep(forTimeInterval: 0.1)
    }
    return true
}
