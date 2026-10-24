// 需求：S6（docs/testing.md 第 3.2 节）。按住卷帘条切换桌面时，用 SkyLight 的内部类把原窗口移过去（Private/BridgedSpaceMove.swift）。
// 缺陷回归（2026-10-20 代码审查发现）：只查了类和内部函数在不在，没查类是否还响应 initWithWindows:spaceID:。
// 以后的 macOS 去掉这个方法而保留类时，照样发这条消息会抛出“unrecognized selector”，WindowShade 崩溃。
// 用运行时新建的类代替 SkyLight 的类，不移动任何窗口。

import Foundation
import ObjectiveC

@main
struct BridgedSpaceMoveTests {
    /// 新建一个 NSObject 的子类；types 不为 nil 时给它加上 initWithWindows:spaceID:，类型编码用 types。
    static func makeClass(_ name: String, initializerTypes types: String?) -> AnyClass {
        guard let cls = objc_allocateClassPair(NSObject.self, name, 0) else {
            preconditionFailure("Cannot make class \(name)")
        }
        if let types {
            let body: @convention(block) (AnyObject) -> AnyObject = { $0 }
            let added = class_addMethod(cls, NSSelectorFromString("initWithWindows:spaceID:"),
                                        imp_implementationWithBlock(body), types)
            precondition(added, "Cannot add the initializer to \(name)")
        }
        objc_registerClassPair(cls)
        return cls
    }

    static func main() {
        var t = TestSuite("bridged-space-move")

        t.section("S6", "类还在、却不响应 initWithWindows:spaceID: 时不用这个办法，不发消息")
        t.expect(!BridgedSpaceMove.canInitialize(makeClass("WSTestMoveOperationWithoutInitializer", initializerTypes: nil)),
                 "a class without initWithWindows:spaceID: is not used")
        t.expect(!BridgedSpaceMove.canInitialize(NSObject.self), "NSObject does not answer initWithWindows:spaceID:")

        t.section("S6", "初始化方法的参数个数变了时不用这个办法")
        t.expect(!BridgedSpaceMove.canInitialize(makeClass("WSTestMoveOperationOneArgument", initializerTypes: "@24@0:8@16")),
                 "an initializer with a different number of arguments is not used")

        t.section("S6", "和现在的 SkyLight 一样有这个方法、两个参数时照常使用")
        t.expect(BridgedSpaceMove.canInitialize(makeClass("WSTestMoveOperation", initializerTypes: "@32@0:8@16Q24")),
                 "a class with initWithWindows:spaceID: taking a window list and a space ID is used")

        t.finish()
    }
}
