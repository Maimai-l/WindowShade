// 访达快速查看面板显示的文件：按面板写出的文件名找访达里选中的那一项，文件引用换成路径（场景 A32）。
import Foundation

@main
struct QuickLookSourceTests {
    static func main() {
        var t = TestSuite("QuickLookSource")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ql-source-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("A32 preview.txt")
        try! "x".write(to: file, atomically: true, encoding: .utf8)
        // 访达给的是文件引用网址（file:///.file/id=…），不是路径。
        let reference = (file as NSURL).fileReferenceURL()! as URL
        let other = folder.appendingPathComponent("other.txt")
        try! "y".write(to: other, atomically: true, encoding: .utf8)

        t.section("Q1", "面板写出的文件名对上访达里选中的一项")
        let found = quickLookSourceURL(previewName: "A32 preview.txt",
                                       selected: [SelectedFinderItem(name: "A32 preview.txt", url: reference)])
        t.expect(found?.standardizedFileURL.resolvingSymlinksInPath().path == file.standardizedFileURL.resolvingSymlinksInPath().path,
                 "文件引用换成了路径：\(found?.path ?? "nil")")
        t.expect(found.map { !$0.path.hasPrefix("/.file/") } ?? false, "得到的是路径，不是文件引用")
        t.expect(quickLookSourceURL(previewName: " A32 preview.txt\n",
                                    selected: [SelectedFinderItem(name: "A32 preview.txt", url: file)]) != nil,
                 "文件名前后的空白不算")
        t.expect(quickLookSourceURL(previewName: "A32 preview.txt",
                                    selected: [SelectedFinderItem(name: "other.txt", url: other),
                                               SelectedFinderItem(name: "A32 preview.txt", url: reference)]) != nil,
                 "选中了好几项时取名字对上的那一项")

        t.section("Q2", "对不上就不给，宁可不收起")
        t.expect(quickLookSourceURL(previewName: "A32 preview.txt",
                                    selected: [SelectedFinderItem(name: "other.txt", url: other)]) == nil,
                 "选中的是别的文件")
        t.expect(quickLookSourceURL(previewName: "A32 preview.txt", selected: []) == nil, "访达里什么也没选中")
        t.expect(quickLookSourceURL(previewName: "", selected: [SelectedFinderItem(name: "", url: file)]) == nil,
                 "面板没写出文件名")
        t.expect(quickLookSourceURL(previewName: "A32 preview.txt",
                                    selected: [SelectedFinderItem(name: "A32 preview.txt", url: file),
                                               SelectedFinderItem(name: "A32 preview.txt", url: reference)]) == nil,
                 "两扇窗口各选中一个同名文件，分不清")
        t.expect(quickLookSourceURL(previewName: "A32 preview.txt",
                                    selected: [SelectedFinderItem(name: "A32 preview.txt",
                                                                  url: URL(string: "https://example.com/A32%20preview.txt")!)]) == nil,
                 "不是本机文件")
        let gone = folder.appendingPathComponent("gone.txt")
        t.expect(quickLookSourceURL(previewName: "gone.txt", selected: [SelectedFinderItem(name: "gone.txt", url: gone)]) == nil,
                 "文件已经不在了")
        t.finish()
    }
}
