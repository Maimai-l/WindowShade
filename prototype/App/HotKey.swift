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
        // 这是全局热键：纯 ⌘（或 ⌘⇧）组合几乎都是系统/各应用的保留快捷键
        // （⌘C/⌘V/⌘A…），录进去会让全系统对应功能失效，因此要求组合里必须
        // 含 Control 或 Option。项目自身的 ⌃⌘ 系列就是这个约定。
        if isCommand, !hasControlOrOption { return true }
        if !isCommand { return false }
        // 与本应用其它快捷键的冲突不在这里写死，由 GlobalShortcutSettings 按当前设置判断。
        let forbidden: Set<UInt32> = [
            UInt32(kVK_ANSI_Q), UInt32(kVK_ANSI_W), UInt32(kVK_Tab),
            UInt32(kVK_Space), UInt32(kVK_ANSI_Comma), UInt32(kVK_ANSI_H)
        ]
        return forbidden.contains(hotKey.keyCode)
    }

    static func displayName(for hotKey: HotKey) -> String {
        var text = ""
        if hotKey.modifiers & UInt32(controlKey) != 0 { text += "⌃" }
        if hotKey.modifiers & UInt32(optionKey) != 0 { text += "⌥" }
        if hotKey.modifiers & UInt32(shiftKey) != 0 { text += "⇧" }
        if hotKey.modifiers & UInt32(cmdKey) != 0 { text += "⌘" }
        text += keyName(for: hotKey.keyCode,
                        shift: hotKey.modifiers & UInt32(shiftKey) != 0)
        return text
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

    /// 优先用当前输入源的键盘布局翻译键码，避免把键码硬解释成美国键盘字符；
    /// 取不到布局数据时退回内置的 US 名称表。
    private static func keyName(for keyCode: UInt32, shift: Bool) -> String {
        // 方向键、回车这类键按布局翻译出来是控制字符，直接给符号。
        let special: [Int: String] = [
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Return: "↩", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "esc",
            kVK_Tab: "⇥", kVK_Space: "空格", kVK_Home: "↖", kVK_End: "↘",
            kVK_PageUp: "⇞", kVK_PageDown: "⇟"
        ]
        if let name = special[Int(keyCode)] { return name }
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
            kVK_Space: "空格", kVK_Tab: "⇥", kVK_Return: "↩", kVK_Escape: "esc"
        ]
        return map[Int(keyCode)] ?? "键码 \(keyCode)"
    }
}
