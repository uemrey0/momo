import AppKit
import SwiftUI

/// Shows the Settings window.
///
/// Momo is a menu bar app without a Dock icon. SwiftUI's `Settings` scene can't be opened
/// from AppKit code on macOS 14 and later (the old `showSettingsWindow:` action is ignored),
/// and windows of accessory apps don't reliably come to the front. So Settings lives in its
/// own window, and Momo briefly becomes a regular app while it is open.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        guard let model else { return }
        let window = self.window ?? makeWindow(model: model)
        self.window = window
        ForegroundPresence.enter(window)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func close() {
        window?.close()
    }

    private func makeWindow(model: AppModel) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = L("Momo Settings")
        window.toolbarStyle = .unified
        let content = NSHostingController(rootView: SettingsView(model: model))
        content.sceneBridgingOptions = [.toolbars, .title]
        window.contentViewController = content
        window.setContentSize(NSSize(width: 820, height: 600))
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("MomoSettings")
        window.delegate = self
        return window
    }

    func windowWillClose(_ notification: Notification) {
        guard let window else { return }
        ForegroundPresence.leave(window)
    }
}

/// Makes Momo a regular app (Dock icon, app switcher) while any of its normal windows is
/// open, so they can come to the front, and returns it to a menu bar app afterwards.
@MainActor
enum ForegroundPresence {
    private static var windows: Set<ObjectIdentifier> = []

    static func enter(_ window: NSWindow) {
        windows.insert(ObjectIdentifier(window))
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate()
    }

    static func leave(_ window: NSWindow) {
        windows.remove(ObjectIdentifier(window))
        guard windows.isEmpty else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}
