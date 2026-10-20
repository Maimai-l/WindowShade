// 把别的应用程序的窗口移到另一个桌面的办法之一（需求 S6），moveOtherAppWindow 第二个试它。
// SLSMoveWindowsToManagedSpace 从 macOS 14.5 起移不了别的应用程序的窗口；兼容编号的办法从 macOS 15 起要关闭系统完整性保护才能用。
// SkyLight 里有一个内部函数 SLSPerformAsynchronousBridgedWindowManagementOperation，
// 交给它一个 SLSBridgedMoveWindowsToManagedSpaceOperation 对象，系统完整性保护开着时也能移
// （窗口管理工具 yabai 从 2026-05-08 发布的 7.1.25 版起这样做）。
// 这个函数是内部链接的，dlsym 找不到，要在已载入的 SkyLight 映像里逐条读符号表。

import Darwin
import Foundation
import MachO

enum BridgedSpaceMove {
    private typealias PerformFunction = @convention(c) (UnsafeRawPointer) -> Int64
    private typealias AllocFunction = @convention(c) (UnsafeRawPointer, Selector) -> UnsafeRawPointer?
    private typealias InitFunction = @convention(c) (UnsafeRawPointer, Selector, UnsafeRawPointer, UInt64) -> UnsafeRawPointer?
    private typealias ReleaseFunction = @convention(c) (UnsafeRawPointer, Selector) -> Void

    private static let skyLightPath = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
    private static let performSymbol =
        "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperationP47SLSAsynchronousBridgedWindowManagementOperation"

    private static let initializerName = "initWithWindows:spaceID:"

    /// 第一次用到时查一次类、它的初始化方法和函数地址；有一样找不到就为 nil，调用方改用别的办法。
    private static let perform: PerformFunction? = {
        guard let cls = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation"), canInitialize(cls),
              let address = findLocalSymbol(image: skyLightPath, name: performSymbol) else { return nil }
        return unsafeBitCast(address, to: PerformFunction.self)
    }()

    /// 这个类的实例是否响应 initWithWindows:spaceID:，而且这个方法正好两个参数（连同 self 和 _cmd 共四个）。
    /// 下面用 objc_msgSend 直接发这条消息：以后的 macOS 去掉这个方法而保留类时，发出去会抛出“unrecognized selector”，
    /// WindowShade 崩溃；参数个数变了时，会按错的调用约定调用。
    static func canInitialize(_ cls: AnyClass) -> Bool {
        guard let method = class_getInstanceMethod(cls, NSSelectorFromString(initializerName)) else { return false }
        return method_getNumberOfArguments(method) == 4
    }

    static var isAvailable: Bool { perform != nil }

    /// 提交移动请求，返回 true 只说明请求已经交出去。SkyLight 的那个内部函数是异步的：返回时窗口不一定已经换了桌面，由调用方核对。
    @discardableResult
    static func move(windows: [UInt32], toSpace sid: UInt64) -> Bool {
        guard let perform,
              let cls = NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation"),
              let msgSend = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend") else { return false }
        // initWithWindows:spaceID: 的参数里有 UInt64，用不了 perform(_:with:)，所以把 objc_msgSend 当 C 函数调用；alloc 得到的对象要在这里 release。
        let alloc = unsafeBitCast(msgSend, to: AllocFunction.self)
        let initialize = unsafeBitCast(msgSend, to: InitFunction.self)
        let release = unsafeBitCast(msgSend, to: ReleaseFunction.self)
        let list = windows.map { NSNumber(value: $0) } as CFArray
        let classPointer = UnsafeRawPointer(Unmanaged.passUnretained(cls as AnyObject).toOpaque())
        guard let allocated = alloc(classPointer, NSSelectorFromString("alloc")),
              let operation = initialize(allocated, NSSelectorFromString(initializerName),
                                         UnsafeRawPointer(Unmanaged.passUnretained(list).toOpaque()), sid)
        else { return false }
        _ = perform(operation)
        release(operation, NSSelectorFromString("release"))
        withExtendedLifetime(list) {}
        return true
    }

    /// 在已载入的映像里按名字找符号（包括不导出的内部符号），返回加上映像载入偏移（slide）之后的地址。
    static func findLocalSymbol(image path: String, name: String) -> UnsafeRawPointer? {
        // 有的系统版本里映像名是带 Versions/A 的完整路径，有的是框架目录下的短路径。
        let paths = [path, path.replacingOccurrences(of: "/Versions/A/", with: "/")]
        for index in 0..<_dyld_image_count() {
            guard let imageName = _dyld_get_image_name(index), paths.contains(String(cString: imageName)),
                  let header = _dyld_get_image_header(index) else { continue }
            let slide = _dyld_get_image_vmaddr_slide(index)
            return findSymbol(header: header, slide: slide, name: name)
        }
        return nil
    }

    private static func findSymbol(header: UnsafePointer<mach_header>, slide: Int, name: String) -> UnsafeRawPointer? {
        guard header.pointee.magic == MH_MAGIC_64 else { return nil }
        var linkedit: segment_command_64?
        var symtab: symtab_command?
        var command = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<header.pointee.ncmds {
            let load = command.load(as: load_command.self)
            if load.cmd == UInt32(LC_SEGMENT_64) {
                let segment = command.load(as: segment_command_64.self)
                let segname = withUnsafeBytes(of: segment.segname) { raw in
                    String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                }
                if segname == "__LINKEDIT" { linkedit = segment }
            } else if load.cmd == UInt32(LC_SYMTAB) {
                symtab = command.load(as: symtab_command.self)
            }
            command = command.advanced(by: Int(load.cmdsize))
        }
        guard let linkedit, let symtab else { return nil }
        let base = Int(linkedit.vmaddr) - Int(linkedit.fileoff) + slide
        guard let strings = UnsafePointer<CChar>(bitPattern: base + Int(symtab.stroff)),
              let symbols = UnsafePointer<nlist_64>(bitPattern: base + Int(symtab.symoff)) else { return nil }
        let target = Array(name.utf8CString)
        for i in 0..<Int(symtab.nsyms) {
            let entry = symbols[i]
            guard entry.n_value != 0 else { continue }
            let candidate = strings.advanced(by: Int(entry.n_un.n_strx))
            if strcmp(candidate, target) == 0 {
                return UnsafeRawPointer(bitPattern: Int(entry.n_value) + slide)
            }
        }
        return nil
    }
}
