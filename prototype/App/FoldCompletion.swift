#if canImport(Cocoa)
import Cocoa
#else
import Foundation
#endif

// 需要等收起真正结果的调用方（标题栏三击）在这里登记。只在主线程上修改。
@MainActor extension AppDelegate {
    @discardableResult
    func registerFoldWaiter(id: CGWindowID, completion: @escaping (Bool) -> Void) -> UUID {
        let token = UUID()
        foldWaiters[id, default: [:]][token] = completion
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            self?.settleFoldWaiter(id: id, token: token, success: false)
        }
        return token
    }

    /// 只有这次请求事先拿到的令牌可以绑定到它新建立的状态上。
    func bindFoldWaiters(id: CGWindowID, tokens: [UUID], transaction: UUID) {
        for token in tokens where foldWaiters[id]?[token] != nil {
            guard foldWaiterTransactions[token] == nil else { continue }
            foldWaiterTransactions[token] = transaction
        }
    }

    func settleFoldWaiter(id: CGWindowID, token: UUID, success: Bool) {
        settleFoldWaiters(id: id, tokens: [token], success: success)
    }

    /// 不能只凭窗口号判定成功：完成时必须指明是哪一次事务。
    func settleFoldWaiters(id: CGWindowID, transaction: UUID, success: Bool) {
        let tokens = (foldWaiters[id] ?? [:]).keys.filter { foldWaiterTransactions[$0] == transaction }
        settleFoldWaiters(id: id, tokens: tokens, success: success)
    }

    func cancelFoldWaiters(id: CGWindowID, tokens: [UUID]) {
        settleFoldWaiters(id: id, tokens: tokens, success: false)
    }

    func settleFoldWaiters(id: CGWindowID, tokens: [UUID], success: Bool) {
        guard var waiting = foldWaiters[id] else { return }
        var callbacks: [(callback: (Bool) -> Void, stamp: FoldCallbackStamp?)] = []
        for token in tokens {
            guard let callback = waiting.removeValue(forKey: token) else { continue }
            let transaction = foldWaiterTransactions.removeValue(forKey: token)
            let stamp = success ? transaction.flatMap { foldWaiterDeliveryStamp(id: id, transaction: $0) } : nil
            callbacks.append((callback, stamp))
        }
        foldWaiters[id] = waiting.isEmpty ? nil : waiting
        // 先把这一批全部取出，再回调任何调用方；回调排到主队列上，调用方不会在建立到一半或清理到一半时重入。
        guard !callbacks.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            for delivery in callbacks {
                let fresh: Bool
                if let stamp = delivery.stamp, let owner = self {
                    fresh = owner.foldCallbackIsCurrent(stamp)
                } else { fresh = false }
                delivery.callback(success && fresh)
            }
        }
    }
}
