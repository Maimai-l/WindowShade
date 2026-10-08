// 快捷键：新装的不占、升级的照旧，录制规则和菜单上的按键。
// 纯逻辑，用单独的偏好域，不碰用户的设置、不碰任何窗口。
import Carbon.HIToolbox
import Cocoa

@main
struct QuietDefaultsTests {
    static var failures = 0
    static func expect(_ condition: Bool, _ message: String) {
        if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message)") }
    }

    static let controlCommand = UInt32(controlKey | cmdKey)
    static func ctrlCmd(_ code: Int) -> HotKey { HotKey(keyCode: UInt32(code), modifiers: controlCommand) }

    /// 在一个新的偏好域里跑一段，跑完删掉；prepare 先写好“以前的版本留下的”键。
    static func withDefaults(_ prepare: (UserDefaults) -> Void = { _ in }, _ body: (UserDefaults) -> Void) {
        let suite = "WindowShade.QuietDefaultsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let saved = GlobalShortcutSettings.defaults
        GlobalShortcutSettings.defaults = defaults
        defer {
            defaults.removePersistentDomain(forName: suite)
            GlobalShortcutSettings.defaults = saved
        }
        prepare(defaults)
        body(defaults)
    }

    static let shipped: [GlobalShortcut: HotKey] = [
        .toggleShade: ctrlCmd(kVK_ANSI_C), .arrange: ctrlCmd(kVK_ANSI_0),
    ]

    static func main() {
        installHistory()
        shortcuts()
        identifiers()
        hotKeyPolicy()
        menuKeyEquivalents()
        print(failures == 0 ? "all quiet-defaults tests passed" : "\(failures) quiet-defaults test(s) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: 新装还是升级

    /// 事件分派靠 hotKeyID（`EventTap` 按它找动作），编号重了会把快捷键指到别的动作上；
    /// 名字空着则设置页和冲突提示里会是一片空白。两样都没有别的地方会挡。
    static func identifiers() {
        var seen: [UInt32: GlobalShortcut] = [:]
        for shortcut in GlobalShortcut.allCases {
            expect(!shortcut.title.isEmpty, "\(shortcut) 在设置里没有名字")
            if let other = seen[shortcut.hotKeyID] {
                expect(false, "\(shortcut) 和 \(other) 共用热键编号 \(shortcut.hotKeyID)")
            }
            seen[shortcut.hotKeyID] = shortcut
        }
        expect(seen.count == GlobalShortcut.allCases.count,
               "每个动作有自己的热键编号（\(seen.count) / \(GlobalShortcut.allCases.count)）")
    }

    static func installHistory() {
        withDefaults { defaults in
            // 启动第一步就认：这时新装的偏好里什么都没有。
            expect(InstallHistory.detect(in: defaults) == .fresh, "a brand-new install (nothing written yet) is fresh")
            expect(InstallHistory.settled(in: defaults) == .fresh, "settling a fresh install says fresh")
            // 认过之后，这一次启动写下声音迁移版本号、欢迎窗口关了写下“看过了”、答了来处：还是新装，下一次启动也不变。
            defaults.set(2, forKey: "ShadeSoundMigrationVersion")
            defaults.set(true, forKey: "ShadeOnboardingShown")
            defaults.set("windows", forKey: "SwitcherOrigin")
            expect(InstallHistory.settled(in: defaults) == .fresh, "once settled, what this launch writes does not turn it into an upgrade")
        }
        // 1.0.15 用过、欢迎窗口点红色按钮关掉、从没改过设置、升级时没有收着的窗口：只剩每次启动都写的那个键。
        withDefaults({ $0.set(2, forKey: "ShadeSoundMigrationVersion") }) { defaults in
            expect(InstallHistory.settled(in: defaults) == .shipped,
                   "a Mac with only the sound-migration key every earlier launch wrote is an upgrade")
        }
        withDefaults({ $0.set(1, forKey: "ShadeSoundMigrationVersion") }) { defaults in
            expect(InstallHistory.detect(in: defaults) == .shipped, "an older sound-migration value counts too")
        }
        withDefaults({ $0.set(true, forKey: "ShadeOnboardingShown") }) { defaults in
            expect(InstallHistory.settled(in: defaults) == .shipped, "a Mac that saw the welcome window before is an upgrade")
            expect(defaults.integer(forKey: InstallHistory.defaultsKey) == InstallHistory.shipped.rawValue, "the answer is stored")
        }
        withDefaults({ $0.set([Int](), forKey: "GlobalShortcut.carry") }) { defaults in
            expect(InstallHistory.detect(in: defaults) == .shipped, "someone who only ever changed a shortcut is an upgrade")
        }
        withDefaults({ $0.set([["id": 1]], forKey: "ShadeJournalEntries") }) { defaults in
            expect(InstallHistory.detect(in: defaults) == .shipped, "someone with collapsed windows on record is an upgrade")
        }
        withDefaults({
            $0.set(true, forKey: "ShadeOnboardingShown")
            $0.set(true, forKey: InstallHistory.previewMarker)
        }) { defaults in
            expect(InstallHistory.detect(in: defaults) == .preview, "a Mac that ran the 1.0.16 preview is recognised as such")
        }
        withDefaults({ $0.set(99, forKey: InstallHistory.defaultsKey) }) { defaults in
            expect(InstallHistory.settled(in: defaults) == .fresh, "a value from a later version reads as fresh")
        }
    }

    // MARK: ⌃⌘ 快捷键

    static func shortcuts() {
        withDefaults { _ in
            expect(GlobalShortcut.allCases.allSatisfy { GlobalShortcutSettings.hotKey(for: $0) == nil },
                   "a new install occupies no shortcut at all")
            expect(!GlobalShortcutSettings.numberedExpandEnabled, "a new install does not take ⌃⌘1…9 either")
            expect(GlobalShortcutSettings.isAllDefault, "nothing recorded yet counts as the defaults")
            let ctrlCmd3 = ctrlCmd(kVK_ANSI_3)
            expect(GlobalShortcutSettings.conflictName(for: ctrlCmd3, excluding: .toggleShade) == nil,
                   "⌃⌘3 is free to record on a new install")

            // 自己录一个，照常生效；清掉就是没有；再录回同一个也不占别人的。
            GlobalShortcutSettings.setHotKey(ctrlCmd(kVK_ANSI_C), for: .toggleShade)
            expect(GlobalShortcutSettings.hotKey(for: .toggleShade) == ctrlCmd(kVK_ANSI_C) && !GlobalShortcutSettings.isAllDefault,
                   "recording ⌃⌘C on a new install works and counts as a change")
            expect(GlobalShortcutSettings.conflictName(for: ctrlCmd(kVK_ANSI_C), excluding: .arrange) == GlobalShortcut.toggleShade.title,
                   "a recorded combination is reported as taken")
            GlobalShortcutSettings.setHotKey(nil, for: .toggleShade)
            expect(GlobalShortcutSettings.hotKey(for: .toggleShade) == nil && GlobalShortcutSettings.isAllDefault,
                   "clearing it on a new install goes back to the default: nothing")
            GlobalShortcutSettings.numberedExpandEnabled = true
            expect(GlobalShortcutSettings.numberedExpandEnabled && !GlobalShortcutSettings.isAllDefault,
                   "⌃⌘1…9 can be switched on in Settings")
            GlobalShortcutSettings.setHotKey(ctrlCmd(kVK_ANSI_N), for: .arrange)
            GlobalShortcutSettings.resetAll()
            expect(GlobalShortcut.allCases.allSatisfy { GlobalShortcutSettings.hotKey(for: $0) == nil }
                    && !GlobalShortcutSettings.numberedExpandEnabled && GlobalShortcutSettings.isAllDefault,
                   "restore defaults on a new install clears everything again")
        }

        withDefaults({ $0.set(true, forKey: "ShadeOnboardingShown") }) { defaults in
            let kept = GlobalShortcut.allCases.allSatisfy { GlobalShortcutSettings.hotKey(for: $0) == shipped[$0] }
            expect(kept, "an upgrade from 1.0.15 keeps exactly its ⌃⌘C / ⌃⌘0 and nothing new")
            expect(GlobalShortcutSettings.numberedExpandEnabled, "an upgrade keeps ⌃⌘1…9")
            expect(GlobalShortcutSettings.isAllDefault, "an untouched upgrade still counts as the defaults (restore button stays off)")
            expect(defaults.object(forKey: "GlobalShortcut.toggleShade") == nil, "nothing is copied into the per-shortcut settings")
            // 他关掉一个、改掉一个：照他的；恢复默认回到他原来的那一套，而不是清空。
            GlobalShortcutSettings.setHotKey(nil, for: .arrange)
            GlobalShortcutSettings.setHotKey(ctrlCmd(kVK_ANSI_K), for: .toggleShade)
            GlobalShortcutSettings.numberedExpandEnabled = false
            expect(GlobalShortcutSettings.hotKey(for: .arrange) == nil && GlobalShortcutSettings.hotKey(for: .toggleShade) == ctrlCmd(kVK_ANSI_K)
                    && !GlobalShortcutSettings.numberedExpandEnabled,
                   "an upgrade can still clear or re-record its shortcuts")
            GlobalShortcutSettings.resetAll()
            expect(GlobalShortcut.allCases.allSatisfy { GlobalShortcutSettings.hotKey(for: $0) == shipped[$0] }
                    && GlobalShortcutSettings.numberedExpandEnabled,
                   "restore defaults on an upgrade brings back the combinations it shipped with")
        }

        // 1.0.15 时关掉过 ⌃⌘1…9、清掉过一个：升级后照旧关着。
        withDefaults({
            $0.set(false, forKey: GlobalShortcutSettings.numberedExpandKey)
            $0.set([Int](), forKey: "GlobalShortcut.arrange")
        }) { _ in
            expect(!GlobalShortcutSettings.numberedExpandEnabled && GlobalShortcutSettings.hotKey(for: .arrange) == nil
                    && GlobalShortcutSettings.hotKey(for: .toggleShade) == shipped[.toggleShade],
                   "what an upgrade had switched off stays off, the rest keep working")
        }

        // 1.0.16 测试版多占的那几个组合属于已经拿掉的动作：留下的两个照 1.0.15。
        withDefaults({ $0.set(true, forKey: InstallHistory.previewMarker) }) { _ in
            expect(GlobalShortcut.allCases.allSatisfy { GlobalShortcutSettings.hotKey(for: $0) == shipped[$0] },
                   "a Mac that ran the 1.0.16 preview keeps ⌃⌘C / ⌃⌘0")
        }
    }

    // MARK: 录制规则

    static func hotKeyPolicy() {
        func hotKey(_ keyCode: Int, _ modifiers: Int) -> HotKey {
            HotKey(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))
        }
        expect(HotKey.isReserved(hotKey(kVK_ANSI_Q, cmdKey)), "⌘Q is rejected as a reserved shortcut")
        expect(HotKey.isReserved(hotKey(kVK_ANSI_K, 0)), "unmodified single letters are rejected")
        expect(HotKey.isReserved(hotKey(kVK_ANSI_K, shiftKey)), "shift-only shortcuts are rejected")
        expect(HotKey.isReserved(hotKey(kVK_ANSI_K, cmdKey)),
               "plain ⌘ combinations are rejected (they collide with app shortcuts)")
        expect(HotKey.isReserved(hotKey(kVK_ANSI_K, cmdKey | shiftKey)), "⌘⇧ combinations are rejected as well")
        expect(!HotKey.isReserved(hotKey(kVK_ANSI_K, cmdKey | optionKey)), "a deliberate combination is accepted")
        expect(!HotKey.isReserved(hotKey(kVK_ANSI_K, controlKey)), "control combinations are accepted")
        let name = HotKey.displayName(for: hotKey(kVK_ANSI_K, cmdKey | shiftKey))
        expect(name.contains("⌘") && name.contains("⇧") && !name.isEmpty,
               "display name renders modifier glyphs and a layout key name")
        expect(HotKey.isModifierOnlyKeyCode(UInt16(kVK_Command)) && HotKey.isModifierOnlyKeyCode(UInt16(kVK_RightOption)),
               "modifier-only presses are not recorded as shortcuts")
        expect(!HotKey.isModifierOnlyKeyCode(UInt16(kVK_ANSI_K)), "a real key can be recorded")
        expect(!HotKey.isReserved(hotKey(kVK_ANSI_C, cmdKey | controlKey)),
               "the app's own ⌃⌘ combinations can be re-recorded; clashes are checked per setting")
    }

    static func menuKeyEquivalents() {
        let menu = GlobalShortcutSettings.menuKeyEquivalent(for: ctrlCmd(kVK_ANSI_C))
        expect(menu?.modifiers == [.control, .command] && menu?.key.count == 1 && menu?.key == menu?.key.lowercased(),
               "menu items show a lower-case key so AppKit does not add a phantom ⇧")
        let f5 = ctrlCmd(kVK_F5)
        let f5Name = HotKey.displayName(for: f5)
        expect(GlobalShortcutSettings.menuKeyEquivalent(for: f5) == nil || f5Name.drop { "⌃⌥⇧⌘".contains($0) }.count == 1,
               "keys whose name is not one character are not squeezed into a menu key (\(f5Name))")
    }
}
