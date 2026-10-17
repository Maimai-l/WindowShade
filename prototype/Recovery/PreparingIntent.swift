// WindowShade 在收起途中退出、恢复记录停在“准备”这一步时，重新启动后怎样处理那扇窗口。
//
// 只看窗口位置还在屏幕上不够：隐藏应用程序、最小化窗口的请求可能在 WindowShade 退出前已经发出，
// 应用程序在它退出之后才执行。依据：2026-10-17 CI 场景 L03，kill -9 之后测试应用程序才隐藏，
// WindowShade 重新启动时当作窗口完好，删掉了记录，应用程序一直隐藏着。

enum PreparingIntentOutcome: Equatable {
    /// 窗口完好，删掉记录即可。
    case intact
    /// 应用程序已隐藏：取消隐藏，再放回原处。窗口同时已最小化时，放回时一并解除最小化（Rescue.swift）。
    case unhideApp
    /// 窗口已最小化：解除最小化，再放回原处。
    case unminimize
    /// 窗口在屏幕外：放回原处。
    case moveBack
}

func preparingIntentOutcome(windowOnScreen: Bool, appHidden: Bool, minimized: Bool) -> PreparingIntentOutcome {
    if appHidden { return .unhideApp }
    if minimized { return .unminimize }
    return windowOnScreen ? .intact : .moveBack
}
