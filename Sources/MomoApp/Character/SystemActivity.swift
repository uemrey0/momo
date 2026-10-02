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

/// Reads the system idle time at most once per ``interval`` and counts up from the last
/// reading in between, so the character doesn't query the system on every frame.
///
/// The interval stays under a second: Momo wakes up when the idle time drops below one second,
/// and a fresh reading taken less than a second after the user comes back always does.
struct IdleTimeSampler {
    /// The longest time between two readings, in seconds.
    var interval = 0.75
    private var reading: (value: Double, takenAt: Double)?

    /// The idle time at `now` (a monotonic clock in seconds), calling `read` when the last
    /// reading is too old.
    mutating func idleSeconds(now: Double, read: () -> Double) -> Double {
        if let reading, now >= reading.takenAt, now - reading.takenAt < interval {
            return reading.value + (now - reading.takenAt)
        }
        let value = read()
        reading = (value, now)
        return value
    }
}
