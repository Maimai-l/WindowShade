// “关于”窗口，照 Ghostty 的样子：图标、名字、一句用途说明、版本 / 构建 / 提交三行和一个 GitHub 按钮。
// 内容由 StandardMenu.swift 的 AboutContent 构造。

import SwiftUI

struct AboutView: View {
    let content: AboutContent

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
            Text("WindowShade")
                .font(.title.bold())
            Text(AboutContent.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Grid(horizontalSpacing: 8, verticalSpacing: 4) {
                ForEach(content.rows, id: \.label) { row in
                    GridRow {
                        Text(row.label)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        Group {
                            if let link = row.link {
                                Link(row.value, destination: link)
                            } else {
                                Text(row.value).textSelection(.enabled)
                            }
                        }
                        .font(.body.monospaced())
                        .gridColumnAlignment(.leading)
                    }
                }
            }
            .padding(.top, 8)
            Button("GitHub") { NSWorkspace.shared.open(AboutContent.repository) }
                .padding(.top, 8)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 24)
        .frame(width: 320)
    }
}

/// 同一时间只开一扇“关于”窗口；再选一次“关于”时把它带到最前面。
@MainActor
final class AboutWindowController {
    static let shared = AboutWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let hosting = NSHostingController(rootView: AboutView(content: .fromBundle()))
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "关于 WindowShade"
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
