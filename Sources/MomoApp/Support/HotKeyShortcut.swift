import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A key combination for a global hot key: a virtual key code and Carbon modifiers.
struct HotKeyShortcut: Codable, Hashable, Sendable {
    /// The virtual key code, for example `kVK_Space`.
    var keyCode: Int
    /// Carbon modifier flags (`cmdKey`, `optionKey`, `shiftKey`, `controlKey`).
    var modifiers: Int

    init(keyCode: Int, modifiers: Int) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.modifierMask
    }

    /// The combination of a key press, ignoring Caps Lock and the function key flag.
    init(event: NSEvent) {
        let flags = event.modifierFlags
        var modifiers = 0
        if flags.contains(.control) { modifiers |= controlKey }
        if flags.contains(.option) { modifiers |= optionKey }
        if flags.contains(.shift) { modifiers |= shiftKey }
        if flags.contains(.command) { modifiers |= cmdKey }
        self.init(keyCode: Int(event.keyCode), modifiers: modifiers)
    }

    private static let modifierMask = controlKey | optionKey | shiftKey | cmdKey

    var hasControl: Bool { modifiers & controlKey != 0 }
    var hasOption: Bool { modifiers & optionKey != 0 }
    var hasShift: Bool { modifiers & shiftKey != 0 }
    var hasCommand: Bool { modifiers & cmdKey != 0 }

    var isFunctionKey: Bool { Self.functionKeys.contains(keyCode) }

    /// The modifiers in the order macOS menus show them, for example "⌥⇧".
    var modifierSymbols: String {
        (hasControl ? "⌃" : "") + (hasOption ? "⌥" : "") + (hasShift ? "⇧" : "")
            + (hasCommand ? "⌘" : "")
    }

    /// How menus would show the shortcut, for example "⌥Space" or "⌃⌘K".
    var displayString: String { modifierSymbols + keyName }

    /// The key's name: a fixed name or symbol for special keys, otherwise the character the
    /// current keyboard layout types.
    var keyName: String {
        if keyCode == kVK_Space { return L("Space", comment: "Key name") }
        if let symbol = Self.specialKeyNames[keyCode] { return symbol }
        if let index = Self.functionKeys.firstIndex(of: keyCode) { return "F\(index + 1)" }
        return Self.layoutCharacter(for: keyCode)?.uppercased()
            ?? String(format: L("Key %lld", comment: "Unknown key name"), keyCode)
    }

    // MARK: - SwiftUI

    /// The shortcut for a SwiftUI menu item, or `nil` when it has no key equivalent there.
    var keyboardShortcut: KeyboardShortcut? {
        guard let key = keyEquivalent else { return nil }
        var flags: SwiftUI.EventModifiers = []
        if hasControl { flags.insert(.control) }
        if hasOption { flags.insert(.option) }
        if hasShift { flags.insert(.shift) }
        if hasCommand { flags.insert(.command) }
        return KeyboardShortcut(key, modifiers: flags)
    }

    private var keyEquivalent: KeyEquivalent? {
        switch keyCode {
        case kVK_Space: return .space
        case kVK_Return: return .return
        case kVK_Tab: return .tab
        case kVK_Delete: return .delete
        case kVK_ForwardDelete: return .deleteForward
        case kVK_Escape: return .escape
        case kVK_LeftArrow: return .leftArrow
        case kVK_RightArrow: return .rightArrow
        case kVK_UpArrow: return .upArrow
        case kVK_DownArrow: return .downArrow
        case kVK_Home: return .home
        case kVK_End: return .end
        case kVK_PageUp: return .pageUp
        case kVK_PageDown: return .pageDown
        default: break
        }
        if let index = Self.functionKeys.firstIndex(of: keyCode),
            let scalar = UnicodeScalar(NSF1FunctionKey + index)
        {
            return KeyEquivalent(Character(scalar))
        }
        // Keypad keys type the same characters as the main keys, so a menu can't tell them
        // apart.
        guard !Self.keypadKeys.contains(keyCode), Self.specialKeyNames[keyCode] == nil,
            let text = Self.layoutCharacter(for: keyCode)?.lowercased(), text.count == 1,
            let character = text.first
        else { return nil }
        return KeyEquivalent(character)
    }

    // MARK: - Key names

    private static let functionKeys = [
        kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
        kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
    ]

    private static let keypadKeys: Set<Int> = [
        kVK_ANSI_KeypadDecimal, kVK_ANSI_KeypadMultiply, kVK_ANSI_KeypadPlus,
        kVK_ANSI_KeypadClear, kVK_ANSI_KeypadDivide, kVK_ANSI_KeypadEnter, kVK_ANSI_KeypadMinus,
        kVK_ANSI_KeypadEquals, kVK_ANSI_Keypad0, kVK_ANSI_Keypad1, kVK_ANSI_Keypad2,
        kVK_ANSI_Keypad3, kVK_ANSI_Keypad4, kVK_ANSI_Keypad5, kVK_ANSI_Keypad6, kVK_ANSI_Keypad7,
        kVK_ANSI_Keypad8, kVK_ANSI_Keypad9,
    ]

    /// Keys that type nothing visible, named with the symbols macOS menus use.
    private static let specialKeyNames: [Int: String] = [
        kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞",
        kVK_PageDown: "⇟", kVK_ANSI_KeypadClear: "⌧",
    ]

    /// What `keyCode` types without modifiers on the current keyboard layout, or on the last
    /// Latin layout when the current input source has no layout (some input methods).
    private static func layoutCharacter(for keyCode: Int) -> String? {
        let sources = [
            TISCopyCurrentKeyboardLayoutInputSource(),
            TISCopyCurrentASCIICapableKeyboardLayoutInputSource(),
        ]
        for case let source? in sources.map({ $0?.takeRetainedValue() }) {
            guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
            else { continue }
            let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
            guard let bytes = CFDataGetBytePtr(data) else { continue }
            let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
            var deadKeyState: UInt32 = 0
            var characters = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count,
                &length, &characters)
            guard status == noErr, length > 0 else { continue }
            let text = String(utf16CodeUnits: characters, count: length)
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            if !text.isEmpty { return text }
        }
        return nil
    }
}

/// What a global shortcut does.
enum ShortcutAction: String, CaseIterable, Identifiable, Sendable {
    /// Open or close the chat panel.
    case openPanel
    /// Talk to Momo; with push to talk, hold to speak and let go to send.
    case talk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openPanel: L("Open Momo")
        case .talk: L("Talk to Momo")
        }
    }

    var defaultShortcut: HotKeyShortcut {
        switch self {
        case .openPanel: HotKeyShortcut(keyCode: kVK_Space, modifiers: optionKey)
        case .talk: HotKeyShortcut(keyCode: kVK_Space, modifiers: optionKey | shiftKey)
        }
    }
}

/// Why a recorded shortcut can't be used.
enum ShortcutProblem: Equatable {
    /// Only ⇧ or no modifier, on a key that isn't an F-key.
    case needsModifier
    /// The other action already has this combination.
    case usedBy(ShortcutAction)

    var message: String {
        switch self {
        case .needsModifier:
            L("Add ⌃, ⌥ or ⌘ to the shortcut, or use an F-key.")
        case .usedBy(let action):
            String(format: L("“%@” already uses this shortcut."), action.title)
        }
    }
}

/// The global shortcuts. `nil` means the action has no shortcut.
struct ShortcutSettings: Codable, Equatable {
    var openPanel: HotKeyShortcut? = ShortcutAction.openPanel.defaultShortcut
    var talk: HotKeyShortcut? = ShortcutAction.talk.defaultShortcut

    init() {}

    subscript(action: ShortcutAction) -> HotKeyShortcut? {
        get {
            switch action {
            case .openPanel: openPanel
            case .talk: talk
            }
        }
        set {
            switch action {
            case .openPanel: openPanel = newValue
            case .talk: talk = newValue
            }
        }
    }

    /// Why `shortcut` can't be used for `action`, or `nil` when it can.
    func problem(with shortcut: HotKeyShortcut, for action: ShortcutAction) -> ShortcutProblem? {
        let hasModifier = shortcut.hasControl || shortcut.hasOption || shortcut.hasCommand
        if !hasModifier && !shortcut.isFunctionKey { return .needsModifier }
        if let other = ShortcutAction.allCases.first(where: {
            $0 != action && self[$0] == shortcut
        }) {
            return .usedBy(other)
        }
        return nil
    }

    // A missing key keeps the default; an explicit `null` is a shortcut the user cleared.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys, _ fallback: HotKeyShortcut) -> HotKeyShortcut? {
            guard container.contains(key) else { return fallback }
            if (try? container.decodeNil(forKey: key)) == true { return nil }
            return (try? container.decode(HotKeyShortcut.self, forKey: key)) ?? fallback
        }
        openPanel = value(.openPanel, ShortcutAction.openPanel.defaultShortcut)
        talk = value(.talk, ShortcutAction.talk.defaultShortcut)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(openPanel, forKey: .openPanel)
        try container.encode(talk, forKey: .talk)
    }

    private enum CodingKeys: String, CodingKey {
        case openPanel
        case talk
    }
}
