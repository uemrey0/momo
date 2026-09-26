import Foundation

/// A short, one-shot behaviour with its own timeline.
public enum FaceAction: String, CaseIterable, Sendable, Identifiable {
    /// Glances left, then right, then back.
    case lookAround
    /// A big yawn with a stretch.
    case yawn
    /// Hums a little tune with closed, happy eyes.
    case hum
    /// Stretches up, then squashes down.
    case stretch
    /// Winks with the right eye.
    case wink
    /// Hides in the notch for a moment, then pops back out.
    case peek
    /// A quick side-to-side wiggle.
    case wiggle
    /// A ticklish reaction to being poked.
    case giggle

    public var id: String { rawValue }

    /// Actions that can play on their own while Momo is idle.
    public static let idlePool: [FaceAction] = [
        .lookAround, .yawn, .hum, .stretch, .wink, .peek, .wiggle,
    ]

    /// How long the action lasts, in seconds.
    public var duration: Double {
        switch self {
        case .lookAround: 2.6
        case .yawn: 2.4
        case .hum: 3.2
        case .stretch: 1.7
        case .wink: 0.9
        case .peek: 2.3
        case .wiggle: 1.4
        case .giggle: 0.9
        }
    }

    /// Whether Momo keeps following the cursor during the action.
    public var tracksPointer: Bool {
        self != .peek
    }

    /// Particles the action emits, and how often.
    var emission: (kind: ParticleKind, interval: Double)? {
        self == .hum ? (.note, 0.45) : nil
    }

    /// Writes the action's targets for time `t` (seconds since it started) into `pose`.
    func apply(at t: Double, to pose: inout FacePose) {
        switch self {
        case .lookAround:
            pose[.gazeX] = t < 0.9 ? -1 : (t < 1.8 ? 1 : 0)
            pose[.gazeY] = -0.15
        case .yawn:
            let openness = sin(min(1, t / 2.2) * .pi)
            pose[.mouthOpen] = openness * 1.1
            pose[.mouthWidth] = 10 + openness * 4
            pose[.lid] = 0.15 + openness * 0.8
            pose[.squash] = 1 + openness * 0.09
            pose[.smile] = 0
            pose[.happyEyes] = 0
        case .hum:
            pose[.happyEyes] = 1
            pose[.smile] = 0.5
            pose[.rotation] = sin(t * 6) * 0.05
        case .stretch:
            pose[.squash] = t < 0.7 ? 1.15 : (t < 1.1 ? 0.88 : 1)
            pose[.lid] = t < 1 ? 0.55 : 0
            pose[.smile] = 0.1
        case .wink:
            pose[.wink] = t < 0.55 ? 1 : 0
            pose[.smile] = 0.8
            pose[.cheek] = 0.7
        case .peek:
            pose[.lift] = t < 1.2 ? FaceGeometry.tuckedLift : 0
            pose[.gazeY] = t > 1.2 ? -0.5 : 0
        case .wiggle:
            pose[.rotation] = sin(t * 14) * 0.07 * (1 - t / duration)
        case .giggle:
            pose[.happyEyes] = 1
            pose[.smile] = 1
            pose[.cheek] = 1.1
        }
    }
}
