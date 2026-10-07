import Cocoa

// 应用内更新：试跑新版（--self-check）要在建 App 之前返回；再读更新日志，记一条启动。见 App/UpdaterLaunch.swift。
if let code = UpdateLaunch.handleEarlyArguments() { exit(code) }
UpdateLaunch.recordLaunch()

let app = NSApplication.shared
let delegate = AppDelegate()
appDelegate = delegate
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
