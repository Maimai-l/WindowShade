// 恢复记录（Recovery Journal）：收起状态的持久化、匹配与生命周期标记。
// 数据层为 AppDelegate 扩展方法；找回屏幕外窗口的流程在 Recovery/Rescue.swift。
//
// 崩溃后也能找回：任何可能让窗口长时间看不见的操作之前，调用方先写一条 stage=preparing 的恢复记录
// （recordShadeRecoveryIntent）；隐藏成功并验证后，再改成 stage=folded（recordShadeJournal）。
// 这样即使进程在“已隐藏、记录还没更新”时被结束，重启后仍能按这条记录找回窗口。

import Cocoa

extension AppDelegate {
    func shadeJournalEntries() -> [[String: Any]] {
        do { if let entries = try (recoveryJournalOverride ?? .application).load() { return entries } }
        catch { wlog("journal: disk read failed; using preference recovery copy: \(error)") }
        if recoveryJournalOverride != nil { return [] }
        return UserDefaults.standard.array(forKey: shadeJournalDefaultsKey) as? [[String: Any]] ?? []
    }

    @discardableResult
    func saveShadeJournalEntries(_ entries: [[String: Any]]) -> Bool {
        do { try (recoveryJournalOverride ?? .application).save(entries) }
        catch { wlog("journal: durable write failed: \(error)"); return false }
        if recoveryJournalOverride != nil { return true }
        if entries.isEmpty {
            UserDefaults.standard.removeObject(forKey: shadeJournalDefaultsKey)
        } else {
            UserDefaults.standard.set(entries, forKey: shadeJournalDefaultsKey)
        }
        return true
    }

    nonisolated func journalNumber(_ entry: [String: Any], _ key: String) -> Double? {
        if let n = entry[key] as? NSNumber { return n.doubleValue }
        if let d = entry[key] as? Double { return d }
        if let i = entry[key] as? Int { return Double(i) }
        return nil
    }

    nonisolated func journalString(_ entry: [String: Any], _ key: String) -> String {
        entry[key] as? String ?? ""
    }

    nonisolated func journalID(_ entry: [String: Any]) -> CGWindowID? {
        // 读回的值不可信：不截断、不强行改到有效范围，也不触发崩溃。
        if let value = entry["id"] as? NSNumber,
           CFGetTypeID(value) == CFBooleanGetTypeID() { return nil }
        guard let raw = journalNumber(entry, "id"),
              let exact = CGWindowID(exactly: raw), exact != 0 else { return nil }
        return exact
    }

    func pruneShadeJournal(reason: String) {
        let now = Date().timeIntervalSince1970
        let entries = shadeJournalEntries()
        let filtered = entries.filter { entry in
            guard journalID(entry) != nil else { return false }
            let created = journalNumber(entry, "createdAt") ?? journalNumber(entry, "updatedAt") ?? now
            return now - created <= shadeJournalMaxAge
        }
        if filtered.count != entries.count {
            saveShadeJournalEntries(filtered)
            wlog("journal: pruned \(entries.count - filtered.count) stale entries reason=\(reason)")
        }
    }

    func recordShadeJournal(id: CGWindowID, win: AXUIElement, hide: HideMethod,
                                    pid: pid_t, bundleID: String, appName: String,
                                    title: String, originalPosition: CGPoint,
                                    originalSize: CGSize, mode: ShadeAppearanceMode,
                                    policy: ShadePolicy, planReason: String,
                                    stage: ShadeLifecycleStage,
                                    sourceDisplayID: CGDirectDisplayID?,
                                    sourceSpaceID: UInt64?) {
        // 自己的窗口和已关掉的快速查看窗口不需要恢复记录；最小化、隐藏整个应用程序的仍然要记。
        guard hide != .quickLookClosed && hide != .ownWindowOrderedOut else {
            clearShadeJournal(id: id)
            return
        }
        // D21：新写入不再存窗口标题。参数仍留给旧调用方；旧档里已有的 title 继续可读。
        _ = title

        // 收起的正常结果：调用方在隐藏前已经写了一条 preparing 记录；这里改写同一条记录的
        // 隐藏方式和停放位置，保留 createdAt，14 天过期仍从第一次写入算起。
        let parked = cgWindowInfo(id)
            .flatMap { cgWindowBounds($0) }
            .map { CGPoint(x: $0.minX, y: $0.minY) }
            ?? axPosition(win)
            ?? offscreen
        let now = Date().timeIntervalSince1970
        var entries = shadeJournalEntries().filter { journalID($0) != id }
        let existingCreatedAt = shadeJournalEntries().first { journalID($0) == id }
            .flatMap { journalNumber($0, "createdAt") }
        var entry: [String: Any] = [
            "schemaVersion": 3,
            "id": Int(id),
            "pid": Int(pid),
            "bundleID": bundleID,
            "appName": appName,
            "hide": hide.rawValue,
            "mode": mode.rawValue,
            "policy": policy.logDescription,
            "planReason": planReason,
            "stage": stage.rawValue,
            "state": stage.rawValue,
            "originalX": Double(originalPosition.x),
            "originalY": Double(originalPosition.y),
            "originalWidth": Double(originalSize.width),
            "originalHeight": Double(originalSize.height),
            "parkedX": Double(parked.x),
            "parkedY": Double(parked.y),
            "originalAlpha": Double(windowHider.originalAlpha(id: id) ?? 1),
            "createdAt": existingCreatedAt ?? now,
            "updatedAt": now
        ]
        if let displayID = sourceDisplayID { entry["displayID"] = Double(displayID) }
        if let spaceID = sourceSpaceID { entry["spaceID"] = Double(spaceID) }
        entries.append(journalEntryWithoutTitle(entry))
        saveShadeJournalEntries(entries)
        wlog("journal: record \(hide.rawValue) id=\(id) app=\(appName) parked=(\(Int(parked.x)),\(Int(parked.y)))")
    }

    // 收起前的恢复记录：在窗口可能被移到屏幕外或设成透明之前写盘，崩溃后据此找回。
    // 隐藏成功后由 recordShadeJournal 改成 folded。
    func recordShadeRecoveryIntent(id: CGWindowID, pid: pid_t, bundleID: String,
                                   appName: String, title: String,
                                   originalPosition: CGPoint, originalSize: CGSize,
                                   sourceDisplayID: CGDirectDisplayID?,
                                   sourceSpaceID: UInt64?) -> Bool {
        restoreVerificationTokens.removeValue(forKey: id)
        _ = title
        let now = Date().timeIntervalSince1970
        var entries = shadeJournalEntries().filter { journalID($0) != id }
        var entry: [String: Any] = [
            "schemaVersion": 3,
            "id": Int(id),
            "pid": Int(pid),
            "bundleID": bundleID,
            "appName": appName,
            "hide": HideMethod.none.rawValue,
            "stage": ShadeLifecycleStage.preparing.rawValue,
            "state": ShadeLifecycleStage.preparing.rawValue,
            "originalX": Double(originalPosition.x),
            "originalY": Double(originalPosition.y),
            "originalWidth": Double(originalSize.width),
            "originalHeight": Double(originalSize.height),
            "createdAt": now,
            "updatedAt": now
        ]
        if let displayID = sourceDisplayID { entry["displayID"] = Double(displayID) }
        if let spaceID = sourceSpaceID { entry["spaceID"] = Double(spaceID) }
        entries.append(journalEntryWithoutTitle(entry))
        guard saveShadeJournalEntries(entries) else { return false }
        wlog("journal: intent id=\(id) app=\(appName) preparing")
        return true
    }

    func updateShadeJournal(id: CGWindowID, reason: String,
                                    _ mutate: (inout [String: Any]) -> Void) {
        var entries = shadeJournalEntries()
        guard let index = entries.firstIndex(where: { journalID($0) == id }) else { return }
        var entry = entries[index]
        mutate(&entry)
        entry["updatedAt"] = Date().timeIntervalSince1970
        entry["lastReason"] = reason
        entries[index] = journalEntryWithoutTitle(entry)
        saveShadeJournalEntries(entries)
    }

    func markShadeJournalStage(id: CGWindowID, _ stage: ShadeLifecycleStage,
                                       reason: String) {
        updateShadeJournal(id: id, reason: reason) { entry in
            entry["stage"] = stage.rawValue
            entry["state"] = stage.rawValue
        }
    }

    func markShadeLifecycle(id: CGWindowID, _ stage: ShadeLifecycleStage,
                                    reason: String) {
        if var state = shaded[id] {
            if state.lifecycleStage == stage {
                markShadeJournalStage(id: id, stage, reason: reason)
                return
            }
            let oldStage = state.lifecycleStage
            state.lifecycleStage = stage
            shaded[id] = state
            wlog("lifecycle: id=\(id) \(oldStage.rawValue) -> \(stage.rawValue) reason=\(reason)")
        } else {
            wlog("lifecycle: id=\(id) -> \(stage.rawValue) reason=\(reason)")
        }
        markShadeJournalStage(id: id, stage, reason: reason)
    }
    func clearShadeJournal(id: CGWindowID) {
        let entries = shadeJournalEntries()
        let filtered = entries.filter { journalID($0) != id }
        if filtered.count != entries.count {
            guard saveShadeJournalEntries(filtered) else { return }
            wlog("journal: clear id=\(id)")
        }
    }

    func syncRestoreJournal(id: CGWindowID, fromOverlayFrame frame: NSRect,
                                    restoredSize: CGSize? = nil) {
        var entries = shadeJournalEntries()
        guard let index = entries.firstIndex(where: { journalID($0) == id }) else { return }

        let pos = axPosition(fromCocoaFrame: frame)
        var entry = entries[index]
        entry["originalX"] = Double(pos.x)
        entry["originalY"] = Double(pos.y)
        if let restoredSize {
            entry["originalWidth"] = Double(restoredSize.width)
            entry["originalHeight"] = Double(restoredSize.height)
        }
        entry["updatedAt"] = Date().timeIntervalSince1970
        entries[index] = entry
        saveShadeJournalEntries(entries)
        wlog("journal: sync id=\(id) restore=(\(Int(pos.x)),\(Int(pos.y)))")
    }

    nonisolated func journalMatches(_ entry: [String: Any], app: NSRunningApplication,
                                win: AXUIElement) -> Bool {
        guard Int(app.processIdentifier) == Int(journalNumber(entry, "pid") ?? -1) else { return false }
        if let created=journalNumber(entry,"createdAt"), let launched=app.launchDate?.timeIntervalSince1970, created<launched-1 { return false }
        let expectedBundle = journalString(entry, "bundleID")
        if !expectedBundle.isEmpty, app.bundleIdentifier != expectedBundle { return false }

        // 标题不能证明是同一扇窗口：两个文档或标签页可能同名。找回之前，创建记录的进程和 CGWindowID 都必须一致。
        if let expectedID = journalID(entry), let currentID = windowID(of: win), expectedID == currentID {
            return true
        }
        return false
    }
}

/// 新的恢复记录不写窗口标题；旧档里已有的标题读的时候仍可取到。
private func journalEntryWithoutTitle(_ entry: [String: Any]) -> [String: Any] {
    var copy = entry
    copy.removeValue(forKey: "title")
    return copy
}
