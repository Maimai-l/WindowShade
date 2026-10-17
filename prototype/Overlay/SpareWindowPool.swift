// 备用池：窗口用完不销毁，放在这里下次直接拿来用。
//
// 新建窗口要在主线程上等窗口服务器回话，窗口服务器正忙时可能要等 1 秒以上（2026-10-17 CI 场景 A33-Safari，
// 33232d9：主线程停了 1,113 毫秒）。所以用完的窗口放回这里，启动后先建好一个。
// 只管放和取，不碰 AppKit：make 由调用方给出。

@MainActor
final class SpareWindowPool<Window: AnyObject> {
    private var spare: [Window] = []
    private let capacity: Int
    private let make: () -> Window

    init(capacity: Int, make: @escaping () -> Window) {
        self.capacity = capacity
        self.make = make
    }

    /// 有备用的就拿备用的，没有才新建。第二个值表示这扇窗口是不是新建的。
    func take() -> (window: Window, isNew: Bool) {
        if let window = spare.popLast() { return (window, false) }
        return (make(), true)
    }

    /// 用完放回。这扇窗口已经在池里时什么也不做，返回 true；池里已经满了时不收，返回 false，由调用方关掉。
    @discardableResult
    func giveBack(_ window: Window) -> Bool {
        if spare.contains(where: { $0 === window }) { return true }
        guard spare.count < capacity else { return false }
        spare.append(window)
        return true
    }

    /// 没有备用的时候先建好一个。
    func prepare() {
        if spare.isEmpty { spare.append(make()) }
    }

    var spareCount: Int { spare.count }
}
