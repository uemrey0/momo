import Foundation
import Observation

/// Decides how often the character redraws.
///
/// Momo draws at the display's full rate while something moves, and drops to
/// ``restingInterval`` once the engine has been resting for ``settleDelay``. Low Power Mode
/// caps the full rate at ``lowPowerInterval``.
public struct FramePacing: Sendable, Equatable {
    /// The time between frames while Momo rests, in seconds.
    public static let restingInterval = 1.0 / 15
    /// The shortest time between frames in Low Power Mode, in seconds.
    public static let lowPowerInterval = 1.0 / 30
    /// How long the engine has to rest before the frame rate drops, in seconds, so short
    /// pauses between movements keep the full rate.
    public static let settleDelay = 0.3

    /// Whether frames are drawn at the resting rate.
    public private(set) var isSlow = false
    private var restingSince: Double?

    public init() {}

    /// Records whether the engine rested in the frame drawn at `time`, in seconds.
    public mutating func record(isResting: Bool, at time: Double) {
        guard isResting else {
            wake()
            return
        }
        let since = restingSince ?? time
        restingSince = since
        if time - since >= Self.settleDelay { isSlow = true }
    }

    /// Returns to the full frame rate at once, for example when the user clicks Momo.
    public mutating func wake() {
        restingSince = nil
        isSlow = false
    }

    /// The shortest time between frames, or `nil` for the display's full rate.
    public static func minimumInterval(isSlow: Bool, isLowPowerModeEnabled: Bool) -> Double? {
        if isSlow { return restingInterval }
        return isLowPowerModeEnabled ? lowPowerInterval : nil
    }
}

/// Holds a view's ``FramePacing`` and publishes its decision, so the view can change its
/// schedule without redrawing for every recorded frame.
@MainActor
@Observable
final class FramePacer {
    private(set) var isSlow = false
    @ObservationIgnored private var pacing = FramePacing()

    var minimumInterval: Double? {
        FramePacing.minimumInterval(
            isSlow: isSlow, isLowPowerModeEnabled: LowPowerMode.shared.isEnabled)
    }

    /// Called while a frame is drawn. The decision is published after drawing, because
    /// changing view state in the middle of drawing isn't allowed.
    func record(isResting: Bool, at time: Double) {
        pacing.record(isResting: isResting, at: time)
        let decision = pacing.isSlow
        guard decision != isSlow else { return }
        Task { @MainActor [weak self] in
            guard let self, self.pacing.isSlow == decision else { return }
            self.isSlow = decision
        }
    }

    func wake() {
        pacing.wake()
        isSlow = false
    }
}

/// Follows the system's Low Power Mode.
@MainActor
@Observable
final class LowPowerMode {
    static let shared = LowPowerMode()

    private(set) var isEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
        }
    }
}
