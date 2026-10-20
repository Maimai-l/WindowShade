// 窗口标题栏外形：Adobe 工作区识别、标准标题栏裁切高度、外形缓存与解析。

import Cocoa

func adobeChromeProfile(for win: AXUIElement,
                        pid: pid_t,
                        title: String? = nil,
                        size: CGSize? = nil) -> AdobeChromeProfile {
    guard isAdobeApp(pid: pid) else { return .none }

    let bundle = appBundleID(pid: pid).lowercased()
    let appName = appDisplayName(pid: pid).lowercased()
    let windowTitle = (title ?? axTitle(win)).lowercased()
    let subrole = axSubrole(win)?.lowercased() ?? ""
    let size = size ?? axSize(win) ?? .zero
    let hasToolbar = firstToolbar(win) != nil
    let hasDocumentishTitle = windowTitle.contains(".psd") ||
        windowTitle.contains(".psb") ||
        windowTitle.contains(".ai") ||
        windowTitle.contains(".ait") ||
        windowTitle.contains(".indd") ||
        windowTitle.contains(".indl") ||
        windowTitle.contains(".pdf") ||
        windowTitle.contains(".aep") ||
        windowTitle.contains(".aet") ||
        windowTitle.contains(".prproj") ||
        windowTitle.contains(".sesx") ||
        windowTitle.contains(".fla")

    let isProductionWorkspace =
        bundle.contains("aftereffects") ||
        bundle.contains("premiere") ||
        bundle.contains("audition") ||
        bundle.contains("mediaencoder") ||
        bundle.contains("animate") ||
        appName.contains("after effects") ||
        appName.contains("premiere") ||
        appName.contains("audition") ||
        appName.contains("media encoder") ||
        appName.contains("animate")

    let isDesignDocumentApp =
        bundle.contains("photoshop") ||
        bundle.contains("illustrator") ||
        bundle.contains("indesign") ||
        appName.contains("photoshop") ||
        appName.contains("illustrator") ||
        appName.contains("indesign")

    // After Effects、Premiere 的工作区标题总带产品名前缀（“Adobe After Effects 2026 - …”），
    // 独立面板的标题则只有面板名，如“Effect Controls”“Timeline: …”。
    let titleLooksLikeWorkspace = windowTitle.contains("adobe") || windowTitle.contains(appName)

    // Adobe 的面板通常是工作区窗口带出的小浮动窗口，默认不收起，免得和 Adobe 自己的面板布局冲突。
    // After Effects、Premiere 连主工作区的 subrole 都标成 floating（辅助功能树不标准）：
    // After Effects、Premiere、Audition、Media Encoder、Animate 这类影音制作应用程序的工作区窗口
    // （标题带产品名，或带 .aep、.prproj 等工程后缀）不能归为面板，
    // 否则整个应用程序都收不起来（2026-07 实测）。
    if subrole.contains("floating") && !hasDocumentishTitle &&
        !(isProductionWorkspace && titleLooksLikeWorkspace) {
        return AdobeChromeProfile(kind: .floatingPanel,
                                  preservedChromeHeight: titleBarHeight,
                                  hitChromeHeight: titleBarHeight,
                                  canShade: false,
                                  reason: "floating-subrole")
    }
    if !hasDocumentishTitle && size.width > 0 && size.height > 0 &&
        (size.width < 520 || size.height < 260) &&
        (windowTitle.contains("panel") ||
         windowTitle.contains("properties") ||
         windowTitle.contains("effects") ||
         windowTitle.contains("color") ||
         windowTitle.contains("layers") ||
         windowTitle.contains("timeline")) {
        return AdobeChromeProfile(kind: .floatingPanel,
                                  preservedChromeHeight: titleBarHeight,
                                  hitChromeHeight: titleBarHeight,
                                  canShade: false,
                                  reason: "panel-like-title")
    }

    // 主屏或欢迎窗口（标题就是产品名，没有文档和工具栏）：内容紧贴系统标题栏，没有标签条要保留，
    // 按标准标题栏高度裁切。若按 84 点的文档框裁，Photoshop 2026 的主屏会把下面的深色内容条
    // 也裁进卷帘条（2026-07 实测）。文档窗口的标题带文件名或缩放比例，不会误判。
    let titleIsBareProductName = windowTitle.isEmpty || windowTitle == appName
    if titleIsBareProductName && !hasDocumentishTitle && !hasToolbar {
        return AdobeChromeProfile(kind: .tabbedDocumentFrame,
                                  preservedChromeHeight: titleBarHeight,
                                  hitChromeHeight: titleBarHeight,
                                  canShade: true,
                                  reason: "home-screen")
    }

    if isProductionWorkspace {
        // After Effects、Premiere 用实测的裁切高度；其余影音制作应用程序（Audition、Media Encoder、Animate）没有实测，用通用值。
        // 双击判定高度和裁切高度一致：看得见的标题栏部分就是双击收起的范围。
        let isPremiere = bundle.contains("premiere") || appName.contains("premiere")
        let isAfterEffects = bundle.contains("aftereffects") || appName.contains("after effects")
        let base: CGFloat = isPremiere ? premiereWorkspaceChromeHeight
            : (isAfterEffects ? afterEffectsWorkspaceChromeHeight : adobeApplicationFrameChromeHeight)
        let h = min(max(base, titleBarHeight), max(titleBarHeight, size.height))
        return AdobeChromeProfile(kind: .applicationFrame,
                                  preservedChromeHeight: h,
                                  hitChromeHeight: h,
                                  canShade: true,
                                  reason: "production-workspace")
    }

    if isDesignDocumentApp {
        if subrole.contains("standard") && hasDocumentishTitle && !hasToolbar {
            let h = min(max(adobeFloatingDocumentChromeHeight, titleBarHeight), max(titleBarHeight, size.height))
            return AdobeChromeProfile(kind: .floatingDocumentWindow,
                                      preservedChromeHeight: h,
                                      hitChromeHeight: h,
                                      canShade: true,
                                      reason: "floating-document-title")
        }

        let h = min(max(adobeTabbedDocumentChromeHeight, titleBarHeight), max(titleBarHeight, size.height))
        return AdobeChromeProfile(kind: .tabbedDocumentFrame,
                                  preservedChromeHeight: h,
                                  hitChromeHeight: h,
                                  canShade: true,
                                  reason: "design-tabbed-frame")
    }

    let h = min(max(adobeTabbedDocumentChromeHeight, titleBarHeight), max(titleBarHeight, size.height))
    return AdobeChromeProfile(kind: .tabbedDocumentFrame,
                              preservedChromeHeight: h,
                              hitChromeHeight: h,
                              canShade: true,
                              reason: "generic-adobe-frame")
}

func standardTitleBarCropHeight(of win: AXUIElement,
                                winTop: CGFloat,
                                winSize: CGSize,
                                trafficPaddedHeight: CGFloat? = nil) -> CGFloat {
    let padded = trafficPaddedHeight ?? trafficLightPaddedHeight(of: win, winTop: winTop) ?? titleBarHeight
    return min(max(titleBarHeight, padded), min(winSize.height, standardTitleBarMaxCropHeight))
}

func windowLooksToolbarlessStandardTitleBar(_ win: AXUIElement,
                                            winTop: CGFloat,
                                            winSize: CGSize,
                                            pid: pid_t,
                                            hasToolbar: Bool? = nil,
                                            trafficLightHeight precomputedTrafficH: CGFloat? = nil,
                                            adobeProfile: AdobeChromeProfile? = nil,
                                            trafficLights: ProxyTrafficLightConfiguration? = nil) -> Bool {
    let hasToolbar = hasToolbar ?? (firstToolbar(win) != nil)
    guard !hasToolbar else { return false }
    guard !needsControlPaddedChrome(pid: pid) else { return false }

    let adobeProfile = adobeProfile ?? adobeChromeProfile(for: win, pid: pid, size: winSize)
    guard adobeProfile.kind == .none else { return false }

    let trafficLights = trafficLights ?? proxyTrafficLightConfiguration(of: win, pid: pid)
    guard trafficLights.style != .quickLook else { return false }

    guard let trafficH = precomputedTrafficH ?? trafficLightHeight(of: win, winTop: winTop),
          trafficH > 0,
          trafficH <= 40 else { return false }
    return true
}

// 收起和双击判定共用的标题栏外形缓存：短时间内反复收起、反复双击同一扇窗口，
// 都要重复一批耗时的辅助功能调用（找工具栏、量红绿灯高度、深度 6 的控件扫描）。
// 双击判定量出的命中高度另存一份（hitHeights），收起时的外形解析直接拿来用。
// 窗口号、辅助功能元素、窗口尺寸任一变了就重新计算。
// entries 只在持有 lock 时读写，可以从任意线程调用；收起时在后台队列解析。
// 自己的窗口要读 AppKit 的几何信息，由调用方先在主线程用 localChromeHeight(id:pid:) 取好再传进来。
final class ChromeProfileCache: @unchecked Sendable {
    static let shared = ChromeProfileCache()
    private let lock = NSLock()

    /// 只在主线程调用：WindowShade 自己的窗口用 AppKit 给出的标题栏高度，其他应用程序返回 nil。
    static func localChromeHeight(id: CGWindowID, pid: pid_t) -> CGFloat? {
        localWindowChromeHeight(id: id, pid: pid)
    }

    private struct Entry {
        let element: AXUIElement
        let profile: WindowChromeProfile
        let size: CGSize
        let resolvedAt: CFAbsoluteTime
    }

    private struct HitEntry {
        let element: AXUIElement
        let height: CGFloat
        let size: CGSize
        let resolvedAt: CFAbsoluteTime
    }

    private var entries: [CGWindowID: Entry] = [:]
    private var hitHeights: [CGWindowID: HitEntry] = [:]
    private let ttl: TimeInterval = 2.0
    private let sizeTolerance: CGFloat = 0.5
    private let maxEntries = 64

    /// 任意线程：localChromeHeight 由调用方在主线程取好。
    func profile(id: CGWindowID, win: AXUIElement, pos: CGPoint, size: CGSize,
                 pid: pid_t, title: String, localChromeHeight: CGFloat?) -> WindowChromeProfile {
        if let cached = lock.withLock({ entries[id].flatMap { isFresh($0, id: id, win: win, size: size) ? $0.profile : nil } }) {
            return cached
        }
        let resolved = resolveWindowChromeProfileUncached(win: win, id: id, pos: pos,
                                                          size: size, pid: pid, title: title,
                                                          localChromeHeight: localChromeHeight)
        lock.withLock {
            entries[id] = Entry(element: win, profile: resolved, size: size,
                                resolvedAt: CFAbsoluteTimeGetCurrent())
            pruneIfNeeded()
        }
        return resolved
    }

    // 双击判定只需要标题栏命中高度：外形缓存或上一次量过的命中高度还新鲜时直接返回，不必再量。
    func cachedHitBarHeight(id: CGWindowID, win: AXUIElement, size: CGSize) -> CGFloat? {
        lock.withLock {
            if let entry = entries[id], isFresh(entry, id: id, win: win, size: size) {
                return entry.profile.hitBarHeight
            }
            guard let hit = hitHeights[id],
                  isFresh(element: hit.element, size: hit.size, resolvedAt: hit.resolvedAt,
                          win: win, currentSize: size) else { return nil }
            return hit.height
        }
    }

    /// 存下双击判定当场量出的命中高度，新鲜度的规则和外形缓存相同。
    func storeHitBarHeight(_ height: CGFloat, id: CGWindowID, win: AXUIElement, size: CGSize) {
        lock.withLock {
            hitHeights[id] = HitEntry(element: win, height: height, size: size,
                                      resolvedAt: CFAbsoluteTimeGetCurrent())
            pruneIfNeeded()
        }
    }

    private func isFresh(_ entry: Entry, id: CGWindowID, win: AXUIElement, size: CGSize) -> Bool {
        isFresh(element: entry.element, size: entry.size, resolvedAt: entry.resolvedAt, win: win, currentSize: size)
    }

    private func isFresh(element: AXUIElement, size: CGSize, resolvedAt: CFAbsoluteTime,
                         win: AXUIElement, currentSize: CGSize) -> Bool {
        CFAbsoluteTimeGetCurrent() - resolvedAt < ttl
            && CFEqual(win, element)
            && abs(currentSize.width - size.width) <= sizeTolerance
            && abs(currentSize.height - size.height) <= sizeTolerance
    }

    /// 调用方持有 lock。先按 TTL 清掉过期项；仍超限（短时间大量不同窗口）就丢最旧的。
    private func pruneIfNeeded() {
        let now = CFAbsoluteTimeGetCurrent()
        if entries.count > maxEntries {
            entries = entries.filter { now - $0.value.resolvedAt < ttl }
            while entries.count > maxEntries {
                guard let oldest = entries.min(by: { $0.value.resolvedAt < $1.value.resolvedAt }) else { break }
                entries.removeValue(forKey: oldest.key)
            }
        }
        if hitHeights.count > maxEntries {
            hitHeights = hitHeights.filter { now - $0.value.resolvedAt < ttl }
            while hitHeights.count > maxEntries {
                guard let oldest = hitHeights.min(by: { $0.value.resolvedAt < $1.value.resolvedAt }) else { break }
                hitHeights.removeValue(forKey: oldest.key)
            }
        }
    }
}

/// 窗口有没有标题栏：有系统的关闭、最小化或缩放按钮（应用程序把按钮藏起来的也算），或有工具栏。
/// Adobe、微信这类自己画标题栏的应用程序读不到按钮和工具栏，也算有标题栏。
/// 没有标题栏的窗口（录屏工具的浮动面板、Gemini 的悬浮输入框）顶部是内容，双击交给应用程序，不收起。
func windowHasTitleBar(_ win: AXUIElement, pid: pid_t) -> Bool {
    let buttons = [kAXCloseButtonAttribute, kAXMinimizeButtonAttribute, kAXZoomButtonAttribute] as [String]
    if buttons.contains(where: { axButtonElement(win, $0) != nil }) { return true }
    if isAdobeApp(pid: pid) || fixedNonstandardChromeHeight(pid: pid) != nil { return true }
    return firstToolbar(win) != nil
}

private func localWindowChromeHeight(id: CGWindowID, pid: pid_t) -> CGFloat? {
    dispatchPrecondition(condition: .onQueue(.main))
    // 上面已经要求当前队列是主队列。
    return MainActor.assumeIsolated {
        guard pid == ProcessInfo.processInfo.processIdentifier,
              let window = NSApp.windows.first(where: { $0.windowNumber == Int(id) }),
              window.styleMask.contains(.titled) else { return nil }
        // 辅助功能可能读不到我们自己窗口的工具栏和红绿灯；AppKit 给出的内容区边界是准的，统一工具栏也算在内。
        let content = window.convertToScreen(window.contentLayoutRect)
        return max(0, window.frame.maxY - content.maxY)
    }
}

private func resolveWindowChromeProfileUncached(win: AXUIElement,
                                                id: CGWindowID,
                                                pos: CGPoint,
                                                size: CGSize,
                                                pid: pid_t,
                                                title: String,
                                                localChromeHeight: CGFloat? = nil) -> WindowChromeProfile {
    let hasToolbar = firstToolbar(win) != nil
    let trafficH = trafficLightHeight(of: win, winTop: pos.y)
    let adobeProfile = adobeChromeProfile(for: win, pid: pid, title: title, size: size)
    let trafficLights = proxyTrafficLightConfiguration(of: win, pid: pid)
    let preciseChrome = needsControlPaddedChrome(pid: pid)
    let toolbarlessStandardTitleBar = windowLooksToolbarlessStandardTitleBar(
        win,
        winTop: pos.y,
        winSize: size,
        pid: pid,
        hasToolbar: hasToolbar,
        trafficLightHeight: trafficH,
        adobeProfile: adobeProfile,
        trafficLights: trafficLights
    )
    let standardTitleBarOnly = localChromeHeight == nil &&
        (usesStandardTitleBarOnly(pid: pid) || toolbarlessStandardTitleBar)
    let hasContentBelowTitleBar = !standardTitleBarOnly && size.width > 0 &&
        hasContentControlsBelowTitleBar(win, winTop: pos.y, winSize: size, titleBarBottom: trafficH)
    let standardCropH = standardTitleBarCropHeight(of: win, winTop: pos.y, winSize: size)
    let axBarH = localChromeHeight ?? (standardTitleBarOnly
        ? standardCropH
        : chromeHeight(of: win, winTop: pos.y, winSize: size, pid: pid))
    let hitBarH = localChromeHeight ?? (standardTitleBarOnly
        ? standardCropH
        : titlebarHitHeight(of: win, id: id, winTop: pos.y, winSize: size, pid: pid))

    // 其余窗口的卷帘条下沿在截图里找。下面几种不找：有原生工具栏的、配置表里只裁标准标题栏的、Adobe 的、快速查看的窗口，
    // 辅助功能读到的高度够用；配置表里有固定高度的应用程序（微信这类）和 WindowShade 自己的窗口，已经知道高度。
    // 没有原生工具栏、红绿灯在标准位置的窗口也找。网页或跨平台框架自己画的顶栏（网易云音乐、Texpile），红绿灯也在标准位置；
    // 只按红绿灯裁，会裁到约 28 点，丢掉顶栏的下半截。
    let pixelBoundary = !hasToolbar && !usesStandardTitleBarOnly(pid: pid) && !preciseChrome && localChromeHeight == nil
        && adobeProfile.kind == .none && trafficLights.style != .quickLook
    var topControls: [ClosedRange<CGFloat>] = []
    if pixelBoundary {
        var samples: [TopChromeControlSample] = []
        var budget = axTraversalNodeBudget
        collectTopChromeControlSamples(win, winTop: pos.y, winSize: size, ignoredFrames: standardTrafficButtonFrames(of: win),
                                       scanLimit: 140, nodeBudget: &budget, into: &samples)
        topControls = samples.map { $0.minTop...max($0.minTop, $0.maxBottom) }
    }
    return WindowChromeProfile(hasToolbar: hasToolbar,
                               trafficLightHeight: trafficH,
                               adobeProfile: adobeProfile,
                               trafficLights: trafficLights,
                               preciseChrome: preciseChrome,
                               toolbarlessStandardTitleBar: toolbarlessStandardTitleBar,
                               standardTitleBarOnly: standardTitleBarOnly,
                               hasContentBelowTitleBar: hasContentBelowTitleBar,
                               standardCropHeight: standardCropH,
                               axBarHeight: axBarH,
                               hitBarHeight: hitBarH,
                               pixelBoundary: pixelBoundary,
                               topControls: topControls,
                               trafficLightBottom: standardTrafficButtonFrames(of: win).map { $0.maxY - pos.y }.max())
}
