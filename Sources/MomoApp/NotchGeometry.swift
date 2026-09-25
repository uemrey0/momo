import AppKit
import MomoFace

/// Describes the notch of a screen and where the character panel goes.
struct NotchGeometry: Equatable {
    /// The screen's frame in global coordinates.
    let screenFrame: NSRect
    /// Width of the hardware notch, or zero on screens without one.
    let notchWidth: CGFloat
    /// Height of the hardware notch, or zero on screens without one.
    let notchHeight: CGFloat

    var hasNotch: Bool { notchHeight > 0 }

    init(screen: NSScreen) {
        screenFrame = screen.frame
        if screen.safeAreaInsets.top > 0,
            let left = screen.auxiliaryTopLeftArea,
            let right = screen.auxiliaryTopRightArea
        {
            notchWidth = screen.frame.width - left.width - right.width
            notchHeight = screen.safeAreaInsets.top
        } else {
            notchWidth = 0
            notchHeight = 0
        }
    }

    /// Prefers a screen with a notch (the built-in display), then the main screen.
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    /// The character layout for this screen.
    var layout: FaceLayout {
        FaceLayout(topInset: notchHeight, capWidth: notchWidth)
    }

    /// The panel frame, flush with the top edge and centred horizontally.
    func panelFrame(for layout: FaceLayout) -> NSRect {
        let size = layout.canvasSize
        return NSRect(
            x: screenFrame.midX - size.width / 2, y: screenFrame.maxY - size.height,
            width: size.width, height: size.height)
    }
}
