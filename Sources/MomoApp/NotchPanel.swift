import AppKit
import SwiftUI

/// A transparent, borderless panel that sits above the menu bar at the top centre of the
/// screen.
///
/// It never becomes key or main, so it never steals focus, and it appears on every Space and
/// next to full-screen apps. The owner toggles `ignoresMouseEvents` so that only the
/// character's body catches clicks.
final class NotchPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .mainMenu + 3
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Allows the panel to overlap the menu bar, which AppKit would otherwise prevent.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// A hosting view that accepts the first click, so poking Momo works without first
/// activating the app.
final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
