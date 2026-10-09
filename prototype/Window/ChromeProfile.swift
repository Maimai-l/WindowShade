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

// 收起和双击判定共用的标题栏外形缓存：短时间内反复收起同一扇窗口，或者双击的第一下和第二下，
// 都要重复一批耗时的辅助功能调用（找工具栏、量红绿灯高度、深度 6 的控件扫描）。
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

    private var entries: [CGWindowID: Entry] = [:]
    private let ttl: TimeInterval = 2.0
    private let sizeTolerance: CGFloat = 0.5
    private let maxEntries = 64

    /// 只在主线程调用。
    func profile(id: CGWindowID, win: AXUIElement, pos: CGPoint, size: CGSize,
                 pid: pid_t, title: String) -> WindowChromeProfile {
        profile(id: id, win: win, pos: pos, size: size, pid: pid, title: title,
                localChromeHeight: localWindowChromeHeight(id: id, pid: pid))
    }

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

    // 并发预取：外形解析只有只读的辅助功能调用（找工具栏、红绿灯位置、标题栏高度），各窗口互不相干；
    // 实测每个约 70 毫秒，批量收起时最慢的就是这一段。先并发算好，再在 lock 里一次写入 entries。
    // 要在主线程调用：开头先取 AppKit 的几何信息。
    @discardableResult
    func prewarm(
        _ requests: [(id: CGWindowID, win: AXUIElement, pos: CGPoint,
                      size: CGSize, pid: pid_t, title: String)]
    ) -> [CGWindowID: WindowChromeProfile] {
        guard requests.count > 1 else { return [:] }
        // 各次写入都在 resultsLock 里；编译器看不见这把锁。
        nonisolated(unsafe) var resolved = [WindowChromeProfile?](repeating: nil, count: requests.count)
        // 进入并发的辅助功能读取之前，先在主线程取好 AppKit 的几何信息。
        let localHeights = requests.map { localWindowChromeHeight(id: $0.id, pid: $0.pid) }
        // 只保护 resolved；写 entries 要用 self.lock，才和其他线程读 entries 互斥。
        let resultsLock = NSLock()
        DispatchQueue.concurrentPerform(iterations: requests.count) { index in
            let request = requests[index]
            let profile = resolveWindowChromeProfileUncached(
                win: request.win, id: request.id, pos: request.pos,
                size: request.size, pid: request.pid, title: request.title,
                localChromeHeight: localHeights[index])
            resultsLock.lock()
            resolved[index] = profile
            resultsLock.unlock()
        }
        let now = CFAbsoluteTimeGetCurrent()
        var warmed: [CGWindowID: WindowChromeProfile] = [:]
        self.lock.lock()
        defer { self.lock.unlock() }
        for (index, request) in requests.enumerated() {
            guard let profile = resolved[index] else { continue }
            entries[request.id] = Entry(element: request.win, profile: profile,
                                        size: request.size, resolvedAt: now)
            warmed[request.id] = profile
        }
        pruneIfNeeded()
        return warmed
    }

    // 双击判定只需要标题栏命中高度：外形缓存新鲜时直接返回，第二下点击不必再做一次完整的外形解析。
    func cachedHitBarHeight(id: CGWindowID, win: AXUIElement, size: CGSize) -> CGFloat? {
        lock.withLock {
            guard let entry = entries[id], isFresh(entry, id: id, win: win, size: size) else { return nil }
            return entry.profile.hitBarHeight
        }
    }

    private func isFresh(_ entry: Entry, id: CGWindowID, win: AXUIElement, size: CGSize) -> Bool {
        CFAbsoluteTimeGetCurrent() - entry.resolvedAt < ttl
            && CFEqual(win, entry.element)
            && abs(size.width - entry.size.width) <= sizeTolerance
            && abs(size.height - entry.size.height) <= sizeTolerance
    }

    /// 调用方持有 lock。
    private func pruneIfNeeded() {
        guard entries.count > maxEntries else { return }
        let now = CFAbsoluteTimeGetCurrent()
        // 先按 TTL 清掉过期项；仍超限（短时间大量不同窗口）就丢最旧的一个。
        entries = entries.filter { now - $0.value.resolvedAt < ttl }
        while entries.count > maxEntries {
            guard let oldest = entries.min(by: { $0.value.resolvedAt < $1.value.resolvedAt }) else { break }
            entries.removeValue(forKey: oldest.key)
        }
    }
}

func resolveWindowChromeProfile(win: AXUIElement, id: CGWindowID,
                                pos: CGPoint,
                                size: CGSize,
                                pid: pid_t,
                                title: String) -> WindowChromeProfile {
    ChromeProfileCache.shared.profile(id: id, win: win, pos: pos, size: size, pid: pid, title: title)
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
                               hitBarHeight: hitBarH)
}
