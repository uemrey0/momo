import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut. Uses the Carbon hot key API, which needs no
/// Accessibility permission.
@MainActor
final class GlobalHotKey {
    private var reference: EventHotKeyRef?
    private static var handlers: [UInt32: @MainActor () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var isEventHandlerInstalled = false
    private let id: UInt32

    /// Registers `keyCode` with Carbon `modifiers` (for example `optionKey`).
    init?(keyCode: Int, modifiers: Int, action: @escaping @MainActor () -> Void) {
        Self.installEventHandlerIfNeeded()
        id = Self.nextID
        Self.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D4F_4D4F), id: id)  // "MOMO"
        let status = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0,
            &reference)
        guard status == noErr else { return nil }
        Self.handlers[id] = action
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        Self.handlers[id] = nil
    }

    private static func installEventHandlerIfNeeded() {
        guard !isEventHandlerInstalled else { return }
        isEventHandlerInstalled = true
        var type = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size,
                    nil, &hotKeyID)
                let id = hotKeyID.id
                MainActor.assumeIsolated { GlobalHotKey.handlers[id]?() }
                return noErr
            }, 1, &type, nil, nil)
    }
}
