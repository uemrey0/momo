import Carbon.HIToolbox
import Foundation
import Testing

@testable import MomoApp

@MainActor
@Suite("Shortcuts")
struct ShortcutTests {
    @Test("display strings list modifiers in menu order before the key")
    func displayStrings() {
        #expect(ShortcutAction.openPanel.defaultShortcut.displayString == "⌥Space")
        #expect(ShortcutAction.talk.defaultShortcut.displayString == "⌥⇧Space")
        let all = HotKeyShortcut(
            keyCode: kVK_Return, modifiers: cmdKey | shiftKey | optionKey | controlKey)
        #expect(all.displayString == "⌃⌥⇧⌘↩")
        #expect(HotKeyShortcut(keyCode: kVK_F5, modifiers: 0).displayString == "F5")
        #expect(HotKeyShortcut(keyCode: kVK_F13, modifiers: cmdKey).displayString == "⌘F13")
        #expect(HotKeyShortcut(keyCode: kVK_LeftArrow, modifiers: controlKey).displayString == "⌃←")
    }

    @Test("letter keys are named by the keyboard layout")
    func letterKeys() {
        let name = HotKeyShortcut(keyCode: kVK_ANSI_K, modifiers: cmdKey).keyName
        #expect(!name.isEmpty)
        #expect(name == name.uppercased())
    }

    @Test("only the four modifier flags are kept")
    func modifierMask() {
        let shortcut = HotKeyShortcut(keyCode: kVK_Space, modifiers: optionKey | alphaLock)
        #expect(shortcut.modifiers == optionKey)
    }

    @Test("a shortcut needs ⌃, ⌥ or ⌘ unless it is an F-key")
    func needsModifier() {
        let settings = ShortcutSettings()
        func problem(_ keyCode: Int, _ modifiers: Int) -> ShortcutProblem? {
            settings.problem(
                with: HotKeyShortcut(keyCode: keyCode, modifiers: modifiers), for: .openPanel)
        }
        #expect(problem(kVK_ANSI_K, 0) == .needsModifier)
        #expect(problem(kVK_ANSI_K, shiftKey) == .needsModifier)
        #expect(problem(kVK_Space, shiftKey) == .needsModifier)
        #expect(problem(kVK_ANSI_K, controlKey) == nil)
        #expect(problem(kVK_ANSI_K, optionKey | shiftKey) == nil)
        #expect(problem(kVK_ANSI_K, cmdKey) == nil)
        #expect(problem(kVK_F6, 0) == nil)
        #expect(problem(kVK_F6, shiftKey) == nil)
    }

    @Test("both actions can't share a combination")
    func duplicates() {
        var settings = ShortcutSettings()
        let talk = ShortcutAction.talk.defaultShortcut
        #expect(settings.problem(with: talk, for: .openPanel) == .usedBy(.talk))
        #expect(
            settings.problem(with: ShortcutAction.openPanel.defaultShortcut, for: .talk)
                == .usedBy(.openPanel))
        // An action may keep its own combination.
        #expect(settings.problem(with: talk, for: .talk) == nil)
        // A cleared shortcut frees its combination.
        settings.talk = nil
        #expect(settings.problem(with: talk, for: .openPanel) == nil)
    }

    @Test("missing shortcuts decode as the defaults")
    func decodesDefaults() throws {
        let old = try JSONDecoder().decode(
            Preferences.self, from: Data(#"{"speaksReplies":true}"#.utf8))
        #expect(old.shortcuts == ShortcutSettings())
        #expect(old.shortcuts.openPanel == ShortcutAction.openPanel.defaultShortcut)
        #expect(old.shortcuts.talk == ShortcutAction.talk.defaultShortcut)

        let partial = try JSONDecoder().decode(
            ShortcutSettings.self, from: Data(#"{"talk":{"keyCode":96,"modifiers":0}}"#.utf8))
        #expect(partial.openPanel == ShortcutAction.openPanel.defaultShortcut)
        #expect(partial.talk == HotKeyShortcut(keyCode: kVK_F5, modifiers: 0))

        let broken = try JSONDecoder().decode(
            ShortcutSettings.self, from: Data(#"{"openPanel":"⌥Space"}"#.utf8))
        #expect(broken.openPanel == ShortcutAction.openPanel.defaultShortcut)
    }

    @Test("cleared and custom shortcuts survive a round trip")
    func roundTrip() throws {
        var preferences = Preferences()
        preferences.shortcuts.openPanel = HotKeyShortcut(
            keyCode: kVK_ANSI_M, modifiers: controlKey | optionKey)
        preferences.shortcuts.talk = nil
        let data = try JSONEncoder().encode(preferences)
        let decoded = try JSONDecoder().decode(Preferences.self, from: data)
        #expect(decoded.shortcuts == preferences.shortcuts)
        #expect(decoded.shortcuts.talk == nil)
    }

    @Test("the menu item follows the shortcut when a menu can show it")
    func menuShortcut() {
        let open = ShortcutAction.openPanel.defaultShortcut.keyboardShortcut
        #expect(open?.key == .space)
        #expect(open?.modifiers == .option)
        let keypad = HotKeyShortcut(keyCode: kVK_ANSI_Keypad1, modifiers: cmdKey)
        #expect(keypad.keyboardShortcut == nil)
    }
}
