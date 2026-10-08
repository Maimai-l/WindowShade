// 全局快捷键的一个组合：键码加 Carbon 修饰键。负责判断能不能录、怎么显示。

import Carbon.HIToolbox
import Foundation

struct HotKey: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    /// 拒绝明显保留组合与单字母无修饰键绑定。
    static func isReserved(_ hotKey: HotKey) -> Bool {
        let carbonModifiers = hotKey.modifiers
            & UInt32(cmdKey | shiftKey | optionKey | controlKey)
        guard carbonModifiers != 0,
              carbonModifiers != UInt32(shiftKey) else { return true }
        let isCommand = carbonModifiers & UInt32(cmdKey) != 0
        let hasControlOrOption = carbonModifiers & UInt32(controlKey | optionKey) != 0
        // 这是全局热键：只按 Command（或 Command-Shift）的组合几乎都是系统和各应用的保留快捷键
        // （Command-C、Command-V……），录进去会让全系统对应功能失效，因此要求组合里必须
        // 含 Control 或 Option。项目自身的 Control-Command 系列就是这个约定。
        if isCommand, !hasControlOrOption { return true }
        if !isCommand { return false }
        // 与本应用其它快捷键的冲突不在这里写死，由 GlobalShortcutSettings 按当前设置判断。
        let forbidden: Set<UInt32> = [
            UInt32(kVK_ANSI_Q), UInt32(kVK_ANSI_W), UInt32(kVK_Tab),
            UInt32(kVK_Space), UInt32(kVK_ANSI_Comma), UInt32(kVK_ANSI_H)
        ]
        return forbidden.contains(hotKey.keyCode)
    }

    static let controlMask = UInt32(controlKey)
    static let optionMask = UInt32(optionKey)
    static let shiftMask = UInt32(shiftKey)
    static let commandMask = UInt32(cmdKey)

    /// 按键显示成一组键帽：修饰键和方向键这类用 SF Symbols 的名字，其余键用文字。
    enum KeyCap: Equatable {
        case symbol(String)
        case text(String)
    }

    /// 修饰键按系统菜单的顺序：Control、Option、Shift、Command。
    private static let modifierKeys: [(mask: Int, symbol: String, name: String)] = [
        (controlKey, "control", "Control"), (optionKey, "option", "Option"),
        (shiftKey, "shift", "Shift"), (cmdKey, "command", "Command"),
    ]

    /// 按布局翻译出来是控制字符的键：有符号的给符号，名字用于朗读和提示文字。
    private static let specialKeys: [Int: (symbol: String?, name: String)] = [
        kVK_LeftArrow: ("arrow.left", "左箭头"), kVK_RightArrow: ("arrow.right", "右箭头"),
        kVK_UpArrow: ("arrow.up", "上箭头"), kVK_DownArrow: ("arrow.down", "下箭头"),
        kVK_Return: ("return", "Return"), kVK_Delete: ("delete.left", "Delete"),
        kVK_ForwardDelete: ("delete.right", "向前删除"), kVK_Escape: ("escape", "Esc"),
        kVK_Tab: ("arrow.right.to.line", "Tab"), kVK_Space: ("space", "空格"),
        kVK_Home: (nil, "Home"), kVK_End: (nil, "End"),
        kVK_PageUp: (nil, "Page Up"), kVK_PageDown: (nil, "Page Down"),
        kVK_F1: (nil, "F1"), kVK_F2: (nil, "F2"), kVK_F3: (nil, "F3"), kVK_F4: (nil, "F4"),
        kVK_F5: (nil, "F5"), kVK_F6: (nil, "F6"), kVK_F7: (nil, "F7"), kVK_F8: (nil, "F8"),
        kVK_F9: (nil, "F9"), kVK_F10: (nil, "F10"), kVK_F11: (nil, "F11"), kVK_F12: (nil, "F12"),
        kVK_F13: (nil, "F13"), kVK_F14: (nil, "F14"), kVK_F15: (nil, "F15"), kVK_F16: (nil, "F16"),
        kVK_F17: (nil, "F17"), kVK_F18: (nil, "F18"), kVK_F19: (nil, "F19"), kVK_F20: (nil, "F20"),
    ]

    static func modifierCaps(_ modifiers: UInt32) -> [KeyCap] {
        modifierKeys.filter { modifiers & UInt32($0.mask) != 0 }.map { .symbol($0.symbol) }
    }

    static func keyCaps(for hotKey: HotKey) -> [KeyCap] {
        let key: KeyCap = specialKeys[Int(hotKey.keyCode)]?.symbol.map(KeyCap.symbol)
            ?? .text(keyName(for: hotKey.keyCode, shift: hotKey.modifiers & UInt32(shiftKey) != 0))
        return modifierCaps(hotKey.modifiers) + [key]
    }

    /// 写在提示文字里、给读屏念的名字，例如“Control-Command-C”。
    static func displayName(for hotKey: HotKey) -> String {
        (modifierKeys.filter { hotKey.modifiers & UInt32($0.mask) != 0 }.map(\.name)
            + [keyName(for: hotKey.keyCode, shift: hotKey.modifiers & UInt32(shiftKey) != 0)])
            .joined(separator: "-")
    }

    /// 只按修饰键不构成快捷键：录制时应忽略这些键码，等真正的键。
    static func isModifierOnlyKeyCode(_ keyCode: UInt16) -> Bool {
        let modifierKeyCodes: Set<UInt16> = [
            UInt16(kVK_Command), UInt16(kVK_Shift), UInt16(kVK_Option),
            UInt16(kVK_Control), UInt16(kVK_RightCommand), UInt16(kVK_RightShift),
            UInt16(kVK_RightOption), UInt16(kVK_RightControl), UInt16(kVK_CapsLock),
            UInt16(kVK_Function)
        ]
        return modifierKeyCodes.contains(keyCode)
    }

    /// 主键的文字名字。优先用当前输入源的键盘布局翻译键码，避免把键码硬解释成美国键盘字符；
    /// 取不到布局数据时退回内置的 US 名称表。
    static func keyName(for keyCode: UInt32, shift: Bool) -> String {
        if let special = specialKeys[Int(keyCode)] { return special.name }
        if let translated = layoutKeyName(keyCode: keyCode, shift: shift),
           !translated.isEmpty {
            return translated.uppercased()
        }
        return fallbackKeyName(for: keyCode)
    }

    private static func layoutKeyName(keyCode: UInt32, shift: Bool) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layoutPointer = TISGetInputSourceProperty(
                source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let layoutData = Unmanaged<CFData>.fromOpaque(layoutPointer).takeUnretainedValue() as Data
        return layoutData.withUnsafeBytes { raw -> String? in
            guard let layoutBase = raw.baseAddress else { return nil }
            let layout = layoutBase.assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKeyState: UInt32 = 0
            var characters = [UniChar](repeating: 0, count: 8)
            var length = 0
            let modifiers = UInt32(shift ? shiftKey : 0)
            let status = UCKeyTranslate(layout,
                                        UInt16(keyCode),
                                        UInt16(kUCKeyActionDisplay),
                                        modifiers >> 8,
                                        UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                        &deadKeyState,
                                        characters.count,
                                        &length,
                                        &characters)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: characters, count: length)
        }
    }

    private static func fallbackKeyName(for keyCode: UInt32) -> String {
        let map: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
            kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
            kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
            kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
            kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        ]
        return map[Int(keyCode)] ?? "键码 \(keyCode)"
    }
}
