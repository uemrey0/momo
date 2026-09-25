import CoreGraphics

/// Reads how long the user has been away from the keyboard, mouse and trackpad.
///
/// This uses the session-wide idle timer, which needs no special permission and reveals
/// nothing about what the user typed.
enum SystemActivity {
    /// `kCGAnyInputEventType`: matches every kind of input event.
    private static let anyInputEvent = CGEventType(rawValue: ~0) ?? .mouseMoved

    /// Seconds since the last user input.
    static func idleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInputEvent)
    }
}
