import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut. Uses the Carbon hot key API, which needs no
/// Accessibility permission.
@MainActor
final class GlobalHotKey {
    private struct Handlers {
        var pressed: @MainActor () -> Void
        var released: (@MainActor () -> Void)?
    }

    private var reference: EventHotKeyRef?
    private static var handlers: [UInt32: Handlers] = [:]
    private static var nextID: UInt32 = 1
    private static var isEventHandlerInstalled = false
    private let id: UInt32

    /// Registers `keyCode` with Carbon `modifiers` (for example `optionKey`). `released`, if
    /// given, is called when the key is let go, for push to talk.
    init?(
        keyCode: Int, modifiers: Int, action: @escaping @MainActor () -> Void,
        released: (@MainActor () -> Void)? = nil
    ) {
        Self.installEventHandlerIfNeeded()
        id = Self.nextID
        Self.nextID += 1
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D4F_4D4F), id: id)  // "MOMO"
        let status = RegisterEventHotKey(
            UInt32(keyCode), UInt32(modifiers), hotKeyID, GetApplicationEventTarget(), 0,
            &reference)
        guard status == noErr else { return nil }
        Self.handlers[id] = Handlers(pressed: action, released: released)
    }

    func unregister() {
        if let reference { UnregisterEventHotKey(reference) }
        reference = nil
        Self.handlers[id] = nil
    }

    private static func installEventHandlerIfNeeded() {
        guard !isEventHandlerInstalled else { return }
        isEventHandlerInstalled = true
        var types = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event, EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size,
                    nil, &hotKeyID)
                let id = hotKeyID.id
                let isRelease = GetEventKind(event) == UInt32(kEventHotKeyReleased)
                MainActor.assumeIsolated {
                    guard let handlers = GlobalHotKey.handlers[id] else { return }
                    if isRelease {
                        handlers.released?()
                    } else {
                        handlers.pressed()
                    }
                }
                return noErr
            }, types.count, &types, nil, nil)
    }
}
