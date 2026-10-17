// 备用池：窗口用完不销毁，放在这里下次直接拿来用（依据见 prototype/Overlay/SpareWindowPool.swift 开头的注释）。

final class FakeWindow {
    let serial: Int
    init(serial: Int) { self.serial = serial }
}

@main
struct SpareWindowPoolTests {
    @MainActor static func main() {
        var suite = TestSuite("spare-window-pool")
        var made = 0
        let pool = SpareWindowPool<FakeWindow>(capacity: 1) { made += 1; return FakeWindow(serial: made) }

        suite.section("W1", "启动后先建好一个，第一次打开“看一眼”时不新建（A33-Safari）")
        pool.prepare()
        suite.expect(made == 1 && pool.spareCount == 1, "prepare() makes one spare window")
        let first = pool.take()
        suite.expect(!first.isNew && made == 1, "the first take() uses the spare window instead of making one")

        suite.section("W2", "用完放回，下一次拿回同一个")
        suite.expect(pool.giveBack(first.window), "the window goes back to the pool")
        let second = pool.take()
        suite.expect(!second.isNew && second.window === first.window && made == 1, "the next take() reuses it")

        suite.section("W3", "没有备用的时候才新建；池里满了不再收；同一扇窗口不收两次")
        let third = pool.take()
        suite.expect(third.isNew && made == 2, "with no spare left, take() makes a new window")
        suite.expect(pool.giveBack(second.window), "one window fits")
        suite.expect(!pool.giveBack(third.window), "a second one is refused at capacity 1, so the caller closes it")
        suite.expect(pool.giveBack(second.window) && pool.spareCount == 1,
                     "giving back a window already in the pool keeps it once and does not ask the caller to close it")
        pool.prepare()
        suite.expect(made == 2, "prepare() does nothing while a spare is waiting")

        suite.finish()
    }
}
