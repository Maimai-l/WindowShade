// 看一眼（docs/test-catalog.md 第 5 节）。D08（没有屏幕录制权限）在权限场景组里跑。

import AppKit
import ApplicationServices

/// 指针停在卷帘条上，等画面卡片出现。
func hoverForGlance(_ folded: Folded, _ seconds: Double = 1.2) async -> Bool {
    await glide(to: folded.titleBar, duration: 0.3)
    return await eventually(seconds) { glanceVisible(over: folded.frame) }
}

let glanceScenarios: [Scenario] = [
    Scenario(id: "D01", title: "指针停在卷帘条上：画面在原处出现", options: []) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        h.expect(await hoverForGlance(folded), "D01: the glance did not open after resting on the strip")
    },
    Scenario(id: "D02", title: "指针快速划过卷帘条：不打开", options: []) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        await glide(to: CGPoint(x: folded.titleBar.x, y: folded.titleBar.y + 120), duration: 0.2)
        await glide(to: CGPoint(x: folded.titleBar.x, y: folded.titleBar.y - 60), duration: 0.08)
        await pause(1)
        h.expect(!glanceVisible(over: folded.frame), "D02: passing over the strip opened the glance")
    },
    Scenario(id: "D03", title: "画面打开后指针移开：画面收回，窗口仍收起", options: []) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        guard await hoverForGlance(folded) else { h.result.violations.append("D03: the glance did not open"); return }
        await glide(to: h.neutral, duration: 0.3)
        h.expect(await eventually(1.5) { !glanceVisible(over: folded.frame) }, "D03: the glance stayed after the pointer left")
        h.expect(stripFrames().count == 1, "D03: the window unfolded when the glance closed")
    },
    Scenario(id: "D04", title: "按住卷帘条不放：不打开画面", options: []) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        await glide(to: folded.titleBar, duration: 0.3)
        post(.leftMouseDown, at: folded.titleBar)
        await pause(1.2)
        h.expect(!glanceVisible(over: folded.frame), "D04: the glance opened while the mouse button was held")
        post(.leftMouseUp, at: folded.titleBar)
        await glide(to: h.neutral, duration: 0.2)
    },
    Scenario(id: "D05", title: "单击卷帘条：打开画面", options: []) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        await click(folded.titleBar)
        h.expect(await eventually(1.5) { glanceVisible(over: folded.frame) }, "D05: a click did not open the glance")
        await glide(to: h.neutral, duration: 0.3)
    },
    Scenario(id: "D06", title: "画面开着时双击卷帘条：展开", options: []) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        guard await hoverForGlance(folded) else { h.result.violations.append("D06: the glance did not open"); return }
        await doubleClick(at: folded.titleBar)
        await glide(to: h.neutral, duration: 0.2)
        await expectRestored(probe, folded.frame, h, within: 4)
        await expectNoStrip(h, within: 2)
        h.expect(!glanceVisible(over: folded.frame) || probe.window() != nil, "D06: the glance card stayed over the window")
    },
    Scenario(id: "D07", title: "应用程序被隐藏时看一眼：移开后仍然隐藏", options: []) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        let hiddenBefore = NSRunningApplication(processIdentifier: probe.pid)?.isHidden ?? false
        guard await hoverForGlance(folded) else { h.result.violations.append("D07: the glance did not open"); return }
        await glide(to: h.neutral, duration: 0.3)
        await pause(1.5)
        let hiddenAfter = NSRunningApplication(processIdentifier: probe.pid)?.isHidden ?? false
        h.expect(hiddenAfter == hiddenBefore, "D07: the glance changed whether the app is hidden (\(hiddenBefore) → \(hiddenAfter))")
        h.expect(stripFrames().count == 1, "D07: the window unfolded")
    },
    Scenario(id: "D09", title: "画面开着时应用程序退出：画面和卷帘条都移除", options: []) { probe, h in
        guard let folded = await foldProbe(probe, h) else { return }
        guard await hoverForGlance(folded) else { h.result.violations.append("D09: the glance did not open"); return }
        probe.send("quit")
        await glide(to: h.neutral, duration: 0.3)
        h.expect(await eventually(4) { !glanceVisible(over: folded.frame) }, "D09: the glance stayed after the app quit")
        await expectNoStrip(h, within: 4)
    },
    Scenario(id: "D10", title: "窗口贴着屏幕右上角：画面完整显示在屏幕内", options: []) { probe, h in
        let screen = CGDisplayBounds(CGMainDisplayID())
        guard let window = probe.window(),
              let folded = await fold(window, at: CGPoint(x: screen.maxX - probeSize.width, y: 30), size: probeSize, h) else { return }
        guard await hoverForGlance(folded), let pid = windowShadePID() else {
            h.result.violations.append("D10: the glance did not open"); return
        }
        let cards = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
            .compactMap { info -> CGRect? in
                guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                      let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: bounds), rect.height > 100 else { return nil }
                return rect
            }
        h.expect(cards.allSatisfy { screen.insetBy(dx: -1, dy: -1).contains($0) }, "D10: the glance card leaves the screen (\(cards))")
        await glide(to: h.neutral, duration: 0.3)
    },
    Scenario(id: "D11", title: "关掉“看一眼”：停留不打开", options: [], changesSettings: true) { probe, h in
        _ = await relaunchWindowShade([["GlanceEnabled", "-bool", "false"]])
        NSRunningApplication(processIdentifier: probe.pid)?.activate()
        guard let folded = await foldProbe(probe, h) else { return }
        h.expect(!(await hoverForGlance(folded, 1.5)), "D11: the glance opened while turned off")
        await glide(to: h.neutral, duration: 0.3)
    },
    Scenario(id: "D12", title: "指针依次划过挨着的两条卷帘条：至多一个画面", options: ["--windows=2", "--size=360,220"]) { probe, h in
        let frames = await foldAll(probe, h)
        guard frames.count == 2, let pid = windowShadePID() else { return }
        var most = 0
        let points = frames.map { CGPoint(x: $0.minX + $0.width * 0.5, y: $0.minY + 14) }
        for point in points + points.reversed() {
            await glide(to: point, duration: 0.4)
            for _ in 0..<6 {
                let cards = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
                    .filter { info in
                        guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
                              let bounds = info[kCGWindowBounds as String] as? NSDictionary,
                              let rect = CGRect(dictionaryRepresentation: bounds) else { return false }
                        return rect.height > 100
                    }
                most = max(most, cards.count)
                await pause(0.1)
            }
        }
        h.expect(most <= 1, "D12: \(most) glance cards were open at once")
        await glide(to: h.neutral, duration: 0.3)
        await pause(1)
        _ = await pressWindowShadeMenu("全部展开")
    },
]
