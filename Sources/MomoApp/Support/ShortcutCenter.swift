import AppKit
import Carbon.HIToolbox
import Observation

/// Registers the global shortcuts from the settings, keeps them in step when they change, and
/// records new ones for the shortcut recorders in Settings.
@MainActor
@Observable
final class ShortcutCenter {
    private struct Handlers {
        var pressed: @MainActor () -> Void
        var released: (@MainActor () -> Void)?
    }

    /// Actions whose shortcut couldn't be registered, usually because another app has it.
    private(set) var failedActions: Set<ShortcutAction> = []
    /// The action whose recorder is waiting for a key press, if any.
    private(set) var recordingAction: ShortcutAction?
    /// Why the last recorded combination was turned down, per action.
    private(set) var rejections: [ShortcutAction: ShortcutProblem] = [:]

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var handlers: [ShortcutAction: Handlers] = [:]
    @ObservationIgnored private var hotKeys: [ShortcutAction: GlobalHotKey] = [:]
    @ObservationIgnored private var registered: [ShortcutAction: HotKeyShortcut] = [:]
    @ObservationIgnored private var keyMonitor: Any?

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Sets what `action`'s shortcut does. `released`, if given, is called when the key is let
    /// go, for push to talk.
    func setHandler(
        for action: ShortcutAction, pressed: @escaping @MainActor () -> Void,
        released: (@MainActor () -> Void)? = nil
    ) {
        handlers[action] = Handlers(pressed: pressed, released: released)
    }

    /// The shortcut `action` has in the settings, or `nil` when it has none.
    func shortcut(for action: ShortcutAction) -> HotKeyShortcut? {
        settings.preferences.shortcuts[action]
    }

    /// Registers the shortcuts from the settings, replacing those that changed. Shortcuts that
    /// failed before are tried again. While a recorder listens, none are registered, so the
    /// recorder sees the keys.
    func apply() {
        var wanted: [ShortcutAction: HotKeyShortcut] = [:]
        if recordingAction == nil {
            for action in ShortcutAction.allCases {
                wanted[action] = settings.preferences.shortcuts[action]
            }
        }
        // Let go of every changed shortcut first, so two actions can swap combinations.
        for action in ShortcutAction.allCases where registered[action] != wanted[action] {
            hotKeys[action]?.unregister()
            hotKeys[action] = nil
            registered[action] = nil
        }
        var failed: Set<ShortcutAction> = []
        for action in ShortcutAction.allCases {
            guard let shortcut = wanted[action], registered[action] == nil else { continue }
            let hotKey = GlobalHotKey(
                keyCode: shortcut.keyCode, modifiers: shortcut.modifiers,
                action: { [weak self] in self?.handlers[action]?.pressed() },
                released: { [weak self] in self?.handlers[action]?.released?() })
            if let hotKey {
                hotKeys[action] = hotKey
                registered[action] = shortcut
            } else {
                failed.insert(action)
            }
        }
        // While recording nothing is registered, so earlier failures still stand.
        if recordingAction == nil, failed != failedActions { failedActions = failed }
    }

    /// Gives `action` a new shortcut, or none, and registers it. Returns why `shortcut` was
    /// turned down instead, leaving the setting unchanged.
    @discardableResult
    func set(_ shortcut: HotKeyShortcut?, for action: ShortcutAction) -> ShortcutProblem? {
        if let shortcut,
            let problem = settings.preferences.shortcuts.problem(with: shortcut, for: action)
        {
            rejections[action] = problem
            return problem
        }
        rejections[action] = nil
        settings.preferences.shortcuts[action] = shortcut
        apply()
        return nil
    }

    // MARK: - Recording

    /// Waits for `action`'s new shortcut: the next key press with a valid combination is
    /// saved. Esc cancels; Delete clears the shortcut.
    func startRecording(_ action: ShortcutAction) {
        stopRecording()
        recordingAction = action
        rejections[action] = nil
        apply()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.record(event) }
            return nil
        }
    }

    func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        guard let action = recordingAction else { return }
        rejections[action] = nil
        recordingAction = nil
        apply()
    }

    private func record(_ event: NSEvent) {
        guard let action = recordingAction else { return }
        let shortcut = HotKeyShortcut(event: event)
        switch shortcut.keyCode {
        case kVK_Escape where shortcut.modifiers == 0:
            stopRecording()
        case kVK_Delete where shortcut.modifiers == 0,
            kVK_ForwardDelete where shortcut.modifiers == 0:
            settings.preferences.shortcuts[action] = nil
            stopRecording()
        default:
            // A turned-down combination keeps the recorder listening, so the user can try
            // another one right away.
            if let problem = settings.preferences.shortcuts.problem(with: shortcut, for: action) {
                rejections[action] = problem
                return
            }
            settings.preferences.shortcuts[action] = shortcut
            stopRecording()
        }
    }
}
