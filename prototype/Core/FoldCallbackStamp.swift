import Foundation
import CoreFoundation

/// 一次收起在异步回调里的身份。回调回来时拿它和当前状态比，对不上就丢掉，
/// 防止过期的 AX 通知或读取结果改动已经变了的收起状态。
struct FoldCallbackStamp: Equatable, Sendable {
    let window: UInt32
    let pid: Int32
    let transaction: UUID
    let hide: String
    let presentation: UUID
    let capturedAt: TimeInterval

    func accepts(current: Self, now: TimeInterval, maximumAge: TimeInterval = 2) -> Bool {
        guard capturedAt.isFinite, current.capturedAt.isFinite, now.isFinite,
              maximumAge.isFinite, maximumAge > 0, now >= capturedAt,
              now - capturedAt < maximumAge, current.capturedAt <= now,
              current.window == window, current.pid == pid,
              current.transaction == transaction, current.hide == hide,
              current.presentation == presentation else { return false }
        return true
    }
}

/// AX 观察器的 refcon 只放一个不复用的整数，从不当成对象解引用。
struct FoldObserverRoute: Equatable, Sendable {
    let window: UInt32
    let pid: Int32
    let transaction: UUID
}

/// AX 布尔属性必须是真正的 CFBoolean；nil、数字、字符串都算不知道。
func observedAXBoolean(_ raw: CFTypeRef?) -> Bool? {
    guard let raw, CFGetTypeID(raw) == CFBooleanGetTypeID() else { return nil }
    return CFEqual(raw, kCFBooleanTrue)
}
