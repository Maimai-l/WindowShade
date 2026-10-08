import Cocoa

/// 原窗口是否已经回到记录的位置。在应用程序自己的队列上执行（辅助功能调用可能等到超时），不改输入和焦点。
func observeRestoredWindow(_ window: WindowHandle, id: CGWindowID, pid: pid_t, expected: CGRect,
                           control: RestoreControl) -> RestoreObservation {
  guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return .closed }
  let original = unsafeDowncast(window.element, to: AXUIElement.self)
  let element = unsafeDowncast(control.resolve(window, id: id, pid: pid).element, to: AXUIElement.self)
  guard let info = cgWindowInfo(id), (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid else {
    var role: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(original, kAXRoleAttribute as CFString, &role)
    return error == .invalidUIElement ? .closed : .pending
  }
  guard windowID(of: element) == id,
    !app.isHidden, !axBoolAttribute(element, kAXMinimizedAttribute as String),
    (info[kCGWindowIsOnscreen as String] as? Bool) == true,
    ((info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
    let bounds = cgWindowBounds(info), let size = axSize(element),
    let actual = axPosition(element)
  else { return .pending }
  let ax = CGRect(origin: actual, size: size)
  let tolerates: (CGRect) -> Bool = { frame in
    abs(frame.minX - expected.minX) <= 2 && abs(frame.minY - expected.minY) <= 2
      && abs(frame.width - expected.width) <= 2 && abs(frame.height - expected.height) <= 2
  }
  return tolerates(ax) && tolerates(bounds) ? .visible : .pending
}

/// Journal acknowledgement after the original window is back.
extension AppDelegate {
  func verifyRestoredWindow(
    _ state: ShadeState, to position: CGPoint, completion: ((Bool) -> Void)?
  ) {
    let id = state.sourceWindowID
    let token = UUID()
    restoreVerificationTokens[id] = token
    markShadeJournalStage(id: id, .restoring, reason: "awaiting-restore-verification")
    // Keep the last durable position current even when the strip was dragged.
    updateShadeJournal(id: id, reason: "restore-target") { entry in
      let safe = safeRestorePosition(for: state, desired: position)
      entry["originalX"] = Double(safe.x)
      entry["originalY"] = Double(safe.y)
    }
    let window = WindowHandle(ax: state.element)
    let pid = state.pid
    let expected = CGRect(origin: safeRestorePosition(for: state, desired: position), size: state.originalSize)
    let restorer = windowRestorer
    RestoreVerifier(
      now: CACurrentMediaTime,
      schedule: { delay, action in runOnMainQueue(after: delay, action) }, isCurrent: { [weak self] in self?.restoreVerificationTokens[id] == token },
      observe: { reply in
        let answer = HandOff(reply)
        restorer.run(pid: pid, {
          observeRestoredWindow(window, id: id, pid: pid, expected: expected, control: restorer.control)
        }, then: { result in MainActor.assumeIsolated { answer.value(result) } })
      },
      acknowledge: { [weak self] in self?.clearShadeJournal(id: id) },
      completion: { [weak self] success in
        self?.restoreVerificationTokens.removeValue(forKey: id)
        completion?(success)
        if !success {
          wlog(
            "restore: window not visible; recovery record kept unless it was closed id=\(id)"
          )
        }
      }
    ).start()
  }
}
