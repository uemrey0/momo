import AppKit

/// Keeps Momo's floating windows out of screenshots, screen recordings and screen sharing
/// when the user wants that (the default).
///
/// Every panel Momo shows over other apps (the notch, the chat panel, bubbles) calls
/// ``register(_:)`` once; the preference then applies to all of them, now and when it changes.
@MainActor
enum CapturePrivacy {
    private static let windows = NSHashTable<NSWindow>.weakObjects()

    /// Whether registered windows are hidden from capture.
    static var hidesWindows = true {
        didSet {
            guard hidesWindows != oldValue else { return }
            for window in windows.allObjects { apply(to: window) }
        }
    }

    /// Starts managing `window`'s sharing type. The window is held weakly.
    static func register(_ window: NSWindow) {
        windows.add(window)
        apply(to: window)
    }

    private static func apply(to window: NSWindow) {
        window.sharingType = hidesWindows ? .none : .readOnly
    }
}
