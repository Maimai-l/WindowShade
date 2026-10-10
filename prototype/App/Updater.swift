// 应用内更新：Sparkle 的标准流程——检查、下载、校验 EdDSA 签名、替换、重新打开，窗口也用 Sparkle 自带的。
// 发布版的 Info.plist 才有清单地址 SUFeedURL（build.sh --stage 写入）；开发版没有，不启动更新器，
// “检查更新”不可用。其余设置（每天检查、不自动安装、不发送系统信息）都在 Info.plist 的 SU* 键里。

import Cocoa
#if canImport(Sparkle)
import Sparkle
#endif

enum UpdateCopy {
    static let menuTitle = "检查更新…"
    static let settingsGroup = "更新"
    static let autoCheck = "自动检查更新"
    static let autoCheckDetail = "有新版本时提示，不自动安装"
    static let checkButton = "检查更新"
    static func currentVersionRow(_ version: String) -> String { "当前版本 \(version)" }
}

@MainActor
final class UpdaterController: NSObject, NSMenuItemValidation {
    static let shared = UpdaterController()

    /// 清单地址和公钥都有才启动；缺一个，Sparkle 会在每次检查时报错。
    nonisolated static func isConfigured(_ info: [String: Any]) -> Bool {
        (info["SUFeedURL"] as? String).map { !$0.isEmpty } == true
            && (info["SUPublicEDKey"] as? String).map { !$0.isEmpty } == true
    }

    #if canImport(Sparkle)
    private var standard: SPUStandardUpdaterController?
    #endif

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    var isAvailable: Bool {
        #if canImport(Sparkle)
        return standard != nil
        #else
        return false
        #endif
    }

    /// applicationDidFinishLaunching 末尾调用。
    func start() {
        guard Self.isConfigured(Bundle.main.infoDictionary ?? [:]) else {
            wlog("updater: Info.plist has no feed URL or public key; not started")
            return
        }
        #if canImport(Sparkle)
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil,
                                                      userDriverDelegate: nil)
        standard = controller
        wlog("updater: started auto=\(controller.updater.automaticallyChecksForUpdates) interval=\(Int(controller.updater.updateCheckInterval))")
        #endif
    }

    var automaticallyChecks: Bool {
        get {
            #if canImport(Sparkle)
            if let standard { return standard.updater.automaticallyChecksForUpdates }
            #endif
            return false
        }
        set {
            #if canImport(Sparkle)
            standard?.updater.automaticallyChecksForUpdates = newValue
            #endif
        }
    }

    @objc func checkForUpdates(_ sender: Any?) {
        #if canImport(Sparkle)
        standard?.checkForUpdates(sender)
        #endif
    }

    func makeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: UpdateCopy.menuTitle, action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
        return item
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(checkForUpdates(_:)) else { return true }
        #if canImport(Sparkle)
        return standard?.updater.canCheckForUpdates ?? false
        #else
        return false
        #endif
    }
}
