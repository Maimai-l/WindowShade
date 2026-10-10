// 访达快速查看面板显示的是哪个文件（场景 A32）。面板窗口自己不给 AXDocument、AXURL、AXFilename，
// 只在子元素里用文字写出文件名；访达窗口里被选中的那一项带 AXFilename 和文件引用网址
// （file:///.file/id=…）。两者名字相同，就取那一项，把文件引用换成路径。只读辅助功能，不替用户按键（R6）。

import Foundation

/// 访达窗口里一项被选中的条目：辅助功能给的文件名和网址。
struct SelectedFinderItem: Sendable {
    let name: String
    let url: URL
}

/// 面板显示的文件名对上的那个选中项，换成路径网址；文件不在了、对不上、名字有重复时返回 nil。
func quickLookSourceURL(previewName: String, selected: [SelectedFinderItem]) -> URL? {
    let name = previewName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return nil }
    let matches = selected.filter { $0.name == name }
    // 两扇访达窗口各选中了一个同名文件：分不清面板显示的是哪一个，宁可不收起。
    guard matches.count == 1, let match = matches.first, match.url.isFileURL else { return nil }
    let path = (match.url as NSURL).filePathURL ?? match.url
    guard path.lastPathComponent == name, FileManager.default.fileExists(atPath: path.path) else { return nil }
    return path
}
