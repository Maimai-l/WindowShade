// 欢迎使用 WindowShade：首次打开时出现，设置的“高级”页里随时能再打开。
// 一页：两项授权、标题和一句说明。关窗口也算看过，下次不再自动弹出。

import AppKit
import SwiftUI

enum WelcomeCopy {
    static let title = "欢迎使用 WindowShade"
    static let lede = "两项都允许后就可以开始使用。"
    static let standardAccount = "允许这两项时，要输入管理员的用户名和密码。"
    static let later = "稍后再说"
    static let start = "开始使用"

    static var all: [String] { [title, lede, standardAccount, later, start] }

    /// 当前用户在 admin 组（gid 80）里。
    static func isAdminUser() -> Bool {
        var groups = [gid_t](repeating: 0, count: 64)
        let count = getgroups(Int32(groups.count), &groups)
        guard count > 0 else { return false }
        return groups.prefix(Int(count)).contains(80)
    }
}

@MainActor
struct WelcomeContent: View {
    static let size = CGSize(width: 520, height: 400)

    @ObservedObject var status: PermissionStatus
    let isAdmin: Bool
    let onFinish: () -> Void
    let onLater: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section { PermissionRows(status: status) }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(height: 156)

            VStack(alignment: .leading, spacing: 8) {
                Text(WelcomeCopy.title)
                    .font(.title.weight(.semibold))
                Text(isAdmin ? WelcomeCopy.lede : WelcomeCopy.lede + "\n" + WelcomeCopy.standardAccount)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20)

            Spacer(minLength: 16)

            HStack {
                Spacer()
                // 没授权时显示“稍后再说”；两项都授权后才能点“开始使用”。
                if !status.allGranted {
                    Button(WelcomeCopy.later, action: onLater)
                }
                Button(WelcomeCopy.start, action: onFinish)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!status.allGranted)
            }
            .controlSize(.large)
            .padding(20)
        }
        .padding(.top, 28)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
