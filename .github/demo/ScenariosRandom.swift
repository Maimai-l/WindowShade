// 随机操作（docs/test-catalog.md 第 11 节）：对 ProbeApp 的三扇窗口随机收起、展开、看一眼、拖动卷帘条、
// 点卷帘条上的关闭按钮，连续 300 步，每一步后检查不变式。
//
// 种子写进结果（notes.seed）和驱动程序的日志；失败时结果里有种子和到失败为止的操作序列。
// 本地重放：open --env WINDOWSHADE_RANDOM_SEED=<种子> --env WINDOWSHADE_RANDOM_STEPS=<步数> DemoDriver.app --args …
// CI 每次运行用新的种子。发现的失败缩短成几步，写成第 2 至 10 节里的固定场景，再修复。

import AppKit
import ApplicationServices

/// 可重放的伪随机数（SplitMix64）：同一个种子给出同一串操作。
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// 一扇参加随机操作的窗口，以及它此刻应该在的样子。
private struct RandomWindow {
    let title: String
    let slot: Int
    /// 展开时应该在的位置和大小：拖动卷帘条后跟着移动（S2）。
    var frame: CGRect
    var folded = false
    /// 收起时关闭按钮的中心：卷帘条上的关闭按钮和它对齐，拖动后跟着移动。
    var close: CGPoint?

    var titleBar: CGPoint { CGPoint(x: frame.minX + frame.width * 0.72, y: frame.minY + 14) }
}

private enum RandomAction: String, CaseIterable {
    case fold, unfold, glance, drag, close

    /// 权重偏向收起、展开、看一眼、拖动、关闭（第 11 节）。
    var weight: Int {
        switch self {
        case .fold, .unfold: return 3
        case .glance, .drag: return 2
        case .close: return 1
        }
    }

    var needsFolded: Bool { self != .fold }
}

/// 三个互不重叠的位置：看一眼的画面、拖动后的卷帘条都留在自己的格子里，不盖住别的窗口的标题栏。
private let randomSlots = [CGPoint(x: 40, y: 80), CGPoint(x: 440, y: 80), CGPoint(x: 40, y: 380)]
private let randomSize = CGSize(width: 340, height: 220)
/// 拖动卷帘条时离开格子原点最多多远（点）。
private let randomDrift: CGFloat = 30

private func exactWindow(_ probe: Probe, _ title: String) -> AXUIElement? {
    probe.allWindows().first { axString($0, kAXTitleAttribute as String) == title }
}

private func near(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat = 2) -> Bool {
    abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
        && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
}

/// 一次随机操作的运行状态：模型、日志读到哪里、出了什么错。
private final class RandomRun {
    let probe: Probe
    let h: Harness
    var rng: SeededRandom
    var windows: [RandomWindow] = []
    var steps: [String] = []
    var failure: String?
    private var logSeen = 0

    init(probe: Probe, harness: Harness, seed: UInt64) {
        self.probe = probe
        h = harness
        rng = SeededRandom(seed: seed)
    }

    var foldedCount: Int { windows.filter(\.folded).count }

    func fail(_ message: String) {
        if failure == nil { failure = message }
    }

    func raise(_ title: String) async {
        let app = AXUIElementCreateApplication(probe.pid)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        if let window = exactWindow(probe, title) { AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
        await pause(0.3)
    }

    /// 把一扇窗口摆进格子，加进模型。
    func adopt(_ title: String, slot: Int) async -> Bool {
        guard let window = exactWindow(probe, title) else { return false }
        place(window, origin: randomSlots[slot], size: randomSize)
        await pause(0.4)
        guard let frame = axFrame(window) else { return false }
        windows.append(RandomWindow(title: title, slot: slot, frame: frame))
        return true
    }

    func pick() -> (RandomAction, Int)? {
        let unfolded = windows.indices.filter { !windows[$0].folded }
        let folded = windows.indices.filter { windows[$0].folded }
        let choices = RandomAction.allCases.filter { $0.needsFolded ? !folded.isEmpty : !unfolded.isEmpty }
        let total = choices.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return nil }
        var roll = Int.random(in: 0..<total, using: &rng)
        for action in choices {
            if roll < action.weight {
                let pool = action.needsFolded ? folded : unfolded
                return (action, pool[Int.random(in: 0..<pool.count, using: &rng)])
            }
            roll -= action.weight
        }
        return nil
    }

    func perform(_ action: RandomAction, _ index: Int) async {
        switch action {
        case .fold: await fold(index)
        case .unfold: await unfold(index)
        case .glance: await glance(index)
        case .drag: await drag(index)
        case .close: await close(index)
        }
    }

    private func fold(_ index: Int) async {
        let title = windows[index].title
        await raise(title)
        let close = exactWindow(probe, title).flatMap(closeButtonCenter)
        let before = stripFrames().count
        await glide(to: windows[index].titleBar, duration: 0.25)
        await pause(0.15)
        await doubleClick(at: windows[index].titleBar)
        guard await eventually(4, { stripFrames().count == before + 1 }) else {
            fail("fold \(title): no new strip within 4 s (strips \(before) → \(stripFrames().count))")
            return
        }
        windows[index].folded = true
        windows[index].close = close
        await pause(0.5)
        await glide(to: h.neutral, duration: 0.2)
    }

    private func unfold(_ index: Int) async {
        let title = windows[index].title
        let before = stripFrames().count
        await glide(to: windows[index].titleBar, duration: 0.25)
        await doubleClick(at: windows[index].titleBar)
        guard await eventually(4, { stripFrames().count == before - 1 }) else {
            fail("unfold \(title): the strip is still there after 4 s (strips \(before) → \(stripFrames().count))")
            return
        }
        windows[index].folded = false
        await pause(0.3)
        await glide(to: h.neutral, duration: 0.2)
    }

    private func glance(_ index: Int) async {
        await glide(to: windows[index].titleBar, duration: 0.25)
        await pause(1.2)
        await glide(to: h.neutral, duration: 0.25)
        // 等画面收回，免得它盖住下一步要点的地方。
        if !(await eventually(3, { !glanceVisible(over: windows[index].frame) })) {
            fail("glance \(windows[index].title): the picture is still on screen 3 s after the pointer left")
        }
    }

    private func drag(_ index: Int) async {
        let window = windows[index]
        let offset = CGPoint(x: window.frame.minX - randomSlots[window.slot].x, y: window.frame.minY - randomSlots[window.slot].y)
        func delta(_ current: CGFloat) -> CGFloat {
            let low = max(-25, -randomDrift - current), high = min(25, randomDrift - current)
            var value = CGFloat(Int.random(in: Int(low)...Int(high), using: &rng))
            // 至少挪 10 点，才是拖动而不是单击（单击会打开看一眼）。
            if abs(value) < 10 { value = current > 0 ? -12 : 12 }
            return value
        }
        let dx = delta(offset.x), dy = delta(offset.y)
        let start = window.titleBar
        await drag(from: start, to: CGPoint(x: start.x + dx, y: start.y + dy))
        await glide(to: h.neutral, duration: 0.2)
        let target = window.frame.offsetBy(dx: dx, dy: dy)
        var moved: CGRect?
        if !(await eventually(2, {
            moved = stripFrames().first { abs($0.minX - target.minX) <= 6 && abs($0.minY - target.minY) <= 6 }
            return moved != nil
        })) {
            fail("drag \(window.title) by (\(Int(dx)),\(Int(dy))): no strip near (\(Int(target.minX)),\(Int(target.minY))); strips \(stripFrames())")
            return
        }
        // 窗口展开时回到卷帘条所在的地方（S2）。系统拖动窗口时卷帘条和指针会差两三点，
        // 所以按卷帘条实际停下的位置记，不按指针移动的距离推算（种子 2875042576 第 129 步：差了 3 点）。
        guard let moved else { return }
        let actual = CGPoint(x: moved.minX - window.frame.minX, y: moved.minY - window.frame.minY)
        windows[index].frame = window.frame.offsetBy(dx: actual.x, dy: actual.y)
        windows[index].close = window.close.map { CGPoint(x: $0.x + actual.x, y: $0.y + actual.y) }
    }

    private func drag(from start: CGPoint, to end: CGPoint) async {
        await glide(to: start, duration: 0.25)
        await pause(0.15)
        post(.leftMouseDown, at: start)
        for step in 1...12 {
            let t = Double(step) / 12
            post(.leftMouseDragged, at: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t))
            await pause(0.02)
        }
        post(.leftMouseUp, at: end)
        pointer = end
        await pause(0.4)
    }

    private func close(_ index: Int) async {
        let window = windows[index]
        guard let button = window.close else {
            fail("close \(window.title): no close button position recorded when it folded")
            return
        }
        let closedBefore = probe.count("closed")
        let stripsBefore = stripFrames().count
        await click(button)
        await glide(to: h.neutral, duration: 0.2)
        guard await eventually(4, { probe.count("closed") == closedBefore + 1 }) else {
            fail("close \(window.title): the window did not close within 4 s")
            return
        }
        if !(await eventually(3, { stripFrames().count == stripsBefore - 1 })) {
            fail("close \(window.title): the strip is still there 3 s after the window closed")
            return
        }
        windows.remove(at: index)
        // 补一扇新窗口放进空出来的格子，保持三扇。
        let newBefore = probe.count("new-window")
        probe.send("new-window")
        guard await eventually(4, { probe.count("new-window") == newBefore + 1 }),
              let title = probe.events().last(where: { $0["event"] as? String == "new-window" })?["title"] as? String else {
            fail("close \(window.title): ProbeApp did not open a replacement window")
            return
        }
        if !(await adopt(title, slot: window.slot)) { fail("close \(window.title): cannot place the replacement \(title)") }
    }

    /// 每一步之后：卷帘条数和模型一致，展开着的窗口都在应该在的地方，日志里没有新的 I5、I6，没有合成输入。
    func check() async {
        let expected = foldedCount
        if !(await eventually(3, { stripFrames().count == expected })) {
            fail("expected \(expected) strips, found \(stripFrames().count): \(stripFrames())")
            return
        }
        for window in windows where !window.folded {
            var last: CGRect?
            let back = await eventually(3) {
                last = exactWindow(probe, window.title).flatMap(axFrame)
                return last.map { near($0, window.frame) } ?? false
            }
            if !back {
                fail("I1: \(window.title) is at \(last.map { "\($0)" } ?? "unknown"), expected \(window.frame)")
                return
            }
        }
        let lines = h.logLines()
        if lines.count > logSeen {
            if let violation = Harness.logViolations(Array(lines[logSeen...])).first { fail(violation) }
            logSeen = lines.count
        }
        if let violation = Harness.inputViolations(h.audit.takeSynthetic()).first { fail(violation) }
    }
}

let randomScenarios: [Scenario] = [
    Scenario(id: "Q01", title: "随机操作：收起、展开、看一眼、拖动、关闭，每步后检查不变式",
             options: ["--windows=3", "--size=340,220"], group: "random", timeLimit: 2400) { probe, h in
        let environment = ProcessInfo.processInfo.environment
        let seed = environment["WINDOWSHADE_RANDOM_SEED"].flatMap { UInt64($0) } ?? UInt64.random(in: 1...UInt64(UInt32.max))
        let stepCount = environment["WINDOWSHADE_RANDOM_STEPS"].flatMap { Int($0) } ?? 300
        log("scenario Q01: seed \(seed), \(stepCount) steps")
        h.result.notes["seed"] = String(seed)
        // 文本编辑的窗口和格子重叠：先隐藏，跑完再显示。
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit")
        others.forEach { _ = $0.hide() }
        defer { others.forEach { _ = $0.unhide() } }
        await pause(0.8)

        let run = RandomRun(probe: probe, harness: h, seed: seed)
        let titles = probe.allWindows().map { axString($0, kAXTitleAttribute as String) }.sorted()
        for (slot, title) in titles.prefix(randomSlots.count).enumerated() {
            if !(await run.adopt(title, slot: slot)) {
                h.result.violations.append("setup: cannot place \(title)")
                return
            }
        }
        guard run.windows.count == randomSlots.count else {
            h.result.violations.append("setup: ProbeApp has \(run.windows.count) windows, expected \(randomSlots.count)")
            return
        }

        var done = 0
        for step in 1...stepCount {
            guard let picked = run.pick() else { break }
            let (action, index) = picked
            let entry = "\(step) \(action.rawValue) \(run.windows[index].title)"
            run.steps.append(entry)
            await run.perform(action, index)
            if run.failure == nil { await run.check() }
            if run.failure == nil, step % 10 == 0 { await h.probeInput() }
            if run.failure != nil { break }
            done = step
        }
        h.result.notes["steps"] = Array(run.steps.suffix(60))
        h.result.notes["stepsDone"] = done
        if let failure = run.failure {
            h.result.violations.append("Q01 seed \(seed), step \(run.steps.last ?? "?"): \(failure)")
            h.diagnose(probe)
            log("scenario Q01: failed at step \(run.steps.last ?? "?") (seed \(seed))")
            return
        }
        // 收尾：全部展开，每扇窗口都回到模型里的位置（I1）。
        for index in run.windows.indices where run.windows[index].folded {
            await run.perform(.unfold, index)
        }
        await run.check()
        if let failure = run.failure {
            h.result.violations.append("Q01 seed \(seed), final unfold: \(failure)")
        }
        log("scenario Q01: \(done) steps done (seed \(seed))")
    },
]
