// 收起 / 展开的音效。
//
// 为什么单独用一个播放器：音频设备闲置后，`NSSound.play()` 会在**调用线程上**同步启动设备，
// 耗时 250–500 毫秒（2026-10-01 实测：冷启动 496 毫秒，设备已启动时 0 毫秒）。
// 在主线程上播放，每次收起、展开都会让主线程停住半秒。
//
// 所以固定在这条串行队列上播放，主线程立即返回；并在收起、展开开始前静音播放一次，提前启动设备。
// 设备由整个进程共用，提前启动一次，之后的音效都能立即播放。

import AppKit

/// 不是 `@MainActor`：cache 只在这条串行队列上读写，plays 和 lastMilliseconds 由 lock 保护，
/// 这是 `@unchecked Sendable` 的依据。所以主线程、手势队列都能直接调用它，不用等它播完。
final class ShadeSoundPlayer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.windowshade.sounds", qos: .userInitiated)
    private var cache: [String: NSSound] = [:]
    private let lock = NSLock()
    private var plays = 0
    private var lastMilliseconds = 0

    /// 播放音量。默认 1；测试把它设成 0，走同一条路径但不出声。
    var volume: Float = 1

    /// 诊断 / 测试用：后台真正播了几次、最后一次在队列上花了多久。
    var stats: (plays: Int, lastMilliseconds: Int) {
        lock.lock(); defer { lock.unlock() }
        return (plays, lastMilliseconds)
    }

    /// 真正要听到的那一次：排队播，不在主线程等设备起来。
    func play(_ name: String) {
        queue.async { [self] in
            guard let sound = sound(name) else { return }
            sound.stop()
            sound.volume = volume
            let started = CFAbsoluteTimeGetCurrent()
            sound.play()
            // 设备冷启动时会在这里花 250–500 毫秒：记一行日志，说明这段时间花在后台队列上，不在主线程。
            let elapsedMilliseconds = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
            lock.lock(); plays += 1; lastMilliseconds = elapsedMilliseconds; lock.unlock()
            if elapsedMilliseconds >= 50 {
                wlog("perf: sound \(name) play \(elapsedMilliseconds)ms on the sound queue (audio device cold start)")
            }
        }
    }

    /// 静音播放一次，提前启动音频设备。用的是另一个 NSSound 实例，不影响要播放的那个实例的音量。
    func prewarm(_ name: String) {
        queue.async {
            guard let warm = NSSound(named: NSSound.Name(name)) else { return }
            warm.volume = 0
            warm.play()
        }
    }

    /// 系统提示音。`NSSound.beep()` 和播放一样会在调用线程上拉设备，所以也放到这条队列上。
    func beep() {
        queue.async { NSSound.beep() }
    }

    private func sound(_ name: String) -> NSSound? {
        if let cached = cache[name] { return cached }
        guard let made = NSSound(named: NSSound.Name(name)) else { return nil }
        cache[name] = made
        return made
    }
}

/// 全局共用一个，音效队列和缓存也共用（主线程、手势队列都直接调用它）。
let shadeSounds = ShadeSoundPlayer()
