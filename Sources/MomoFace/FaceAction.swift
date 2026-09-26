import Foundation

/// A short, one-shot behaviour with its own timeline.
public enum FaceAction: String, CaseIterable, Sendable, Identifiable {
    /// Glances to one side, then the other, then back.
    case lookAround
    /// A big yawn with a stretch.
    case yawn
    /// Hums a little tune with closed, happy eyes.
    case hum
    /// Gathers itself, stretches down, then springs back.
    case stretch
    /// Winks with the right eye.
    case wink
    /// A quick side-to-side wiggle.
    case wiggle
    /// A ticklish reaction to being poked.
    case giggle
    /// Squints, holds its breath and sneezes.
    case sneeze
    /// Shakes itself off like a wet puppy.
    case shakeOff
    /// Tilts its head, wondering about something.
    case curiousTilt
    /// Whistles a tune while looking innocently at the ceiling.
    case whistle
    /// Sticks the tip of its tongue out.
    case blep
    /// Looks down at the screen, as if reading along with the user.
    case watch
    /// Drifts off into a happy daydream.
    case daydream
    /// Breathes in deeply and lets out a sigh.
    case sigh
    /// Slowly nods off, then snaps awake and looks around.
    case nodOff
    /// Perks up and glances at a notification.
    case notice

    public var id: String { rawValue }

    /// Actions that can play on their own while Momo is idle.
    public static let idlePool: [FaceAction] = [
        .lookAround, .yawn, .hum, .stretch, .wink, .wiggle, .sneeze, .shakeOff, .curiousTilt,
        .whistle, .blep, .watch, .daydream, .sigh, .nodOff,
    ]

    /// How long the action lasts, in seconds.
    public var duration: Double {
        switch self {
        case .lookAround: 3.2
        case .yawn: 2.8
        case .hum: 3.4
        case .stretch: 1.9
        case .wink: 1.0
        case .wiggle: 1.4
        case .giggle: 0.9
        case .sneeze: 2.2
        case .shakeOff: 1.4
        case .curiousTilt: 2.6
        case .whistle: 3.6
        case .blep: 2.4
        case .watch: 3.6
        case .daydream: 4.0
        case .sigh: 2.4
        case .nodOff: 4.2
        case .notice: 1.8
        }
    }

    /// Whether Momo keeps following the cursor during the action.
    public var tracksPointer: Bool {
        switch self {
        case .lookAround, .watch, .daydream, .nodOff, .notice, .whistle, .yawn, .sneeze: false
        default: true
        }
    }

    /// How likely the action is to be picked while idle. Quiet behaviours are common; big ones
    /// are rare. `awayness` goes from 0 (the user is active) to 1 (about to fall asleep).
    func idleWeight(awayness: Double) -> Double {
        let tired = 1 + awayness * 3
        let busy = awayness < 0.05
        return switch self {
        case .lookAround: 3
        case .watch: busy ? 4 : 1.5
        case .curiousTilt: 2
        case .wink: 1.5
        case .hum: 1.4
        case .sigh: 1.3
        case .daydream: 1.2
        case .whistle: 1
        case .blep: 1
        case .stretch: 0.9 * tired
        case .yawn: 0.7 * tired
        case .nodOff: 0.4 * tired
        case .wiggle: busy ? 0.5 : 0.9
        case .shakeOff: busy ? 0.3 : 0.6
        case .sneeze: 0.35
        case .giggle, .notice: 0
        }
    }

    /// Particles the action emits, and how often.
    var emission: (kind: ParticleKind, interval: Double)? {
        switch self {
        case .hum: (.note, 0.45)
        case .whistle: (.note, 0.6)
        case .daydream: (.sparkle, 0.9)
        default: nil
        }
    }

    /// Moments in the timeline that nudge a spring, emit particles or trigger a blink.
    /// `side` is 1 or -1 and mirrors the action.
    func cues(side: Double) -> [(at: Double, cue: FaceCue)] {
        switch self {
        case .lookAround: [(1.3, .blink)]
        case .stretch: [(1.35, .kick(.squash, -2.5))]
        case .sneeze: [(1.0, .kick(.squash, -4)), (1.0, .kick(.rotation, -side * 1.6))]
        case .shakeOff: [(1.2, .burst(.sparkle, count: 3))]
        case .curiousTilt: [(1.3, .blink)]
        case .watch: [(1.8, .blink)]
        case .nodOff: [(2.65, .kick(.squash, 3.5))]
        case .notice: [(0, .kick(.squash, 3))]
        case .sigh: [(2.2, .blink)]
        default: []
        }
    }

    /// Writes the action's targets for time `t` (seconds since it started) into `pose`.
    /// `side` is 1 or -1 and mirrors the action.
    func apply(at t: Double, side: Double, to pose: inout FacePose) {
        switch self {
        case .lookAround:
            pose[.gazeX] =
                side * keyframes(t, [(0, 0), (0.25, -1), (1.2, -1), (1.45, 1), (2.4, 1), (2.7, 0)])
            pose[.gazeY] = -0.1
            pose[.eyeScale] = 1.04
        case .yawn:
            let openness = keyframes(t, [(0, 0), (0.4, 0.15), (1.3, 1), (1.9, 1), (2.5, 0)])
            pose[.mouthOpen] = openness * 1.1
            pose[.mouthWidth] = 10 + openness * 3
            pose[.lid] = 0.1 + openness * 0.85
            pose[.squash] = 1 + openness * 0.08
            pose[.rotation] = side * openness * 0.04
            pose[.gazeY] = -0.3 * openness
            pose[.smile] = 0
            pose[.happyEyes] = 0
        case .hum:
            pose[.happyEyes] = 1
            pose[.smile] = 0.5
            pose[.cheek] = 0.45
            pose[.rotation] = sin(t * 4.2) * 0.05
            pose[.lift] = abs(sin(t * 4.2)) * 1.5
        case .stretch:
            pose[.squash] = keyframes(
                t,
                [
                    (0, 1), (0.3, 0.93), (0.75, 1.14), (1.15, 1.14), (1.35, 0.92), (1.6, 1.02),
                    (1.9, 1),
                ])
            pose[.lid] = keyframes(t, [(0, 0), (0.35, 0.7), (1.2, 0.7), (1.4, 0)])
            pose[.mouthOpen] = keyframes(t, [(0.4, 0), (0.7, 0.35), (1.1, 0.35), (1.3, 0)])
            pose[.mouthWidth] = 11
            pose[.smile] = t > 1.4 ? 0.5 : 0.1
        case .wink:
            pose[.wink] = t < 0.55 ? 1 : 0
            pose[.smile] = 0.8
            pose[.cheek] = 0.7
            pose[.rotation] = -0.05 * keyframes(t, [(0, 0), (0.2, 1), (0.6, 1), (0.9, 0)])
        case .wiggle:
            pose[.rotation] = sin(t * 14) * 0.07 * (1 - t / duration)
            pose[.smile] = 0.6
        case .giggle:
            pose[.happyEyes] = 1
            pose[.smile] = 1
            pose[.cheek] = 1.1
            pose[.rotation] = sin(t * 20) * 0.035 * (1 - t / duration)
        case .sneeze:
            pose[.lid] = keyframes(t, [(0, 0), (0.9, 0.75), (1.0, 1), (1.25, 1), (1.45, 0.1)])
            pose[.squash] = keyframes(t, [(0, 1), (0.9, 1.07), (1.0, 0.88), (1.2, 0.97), (1.4, 1)])
            pose[.mouthOpen] = keyframes(t, [(0, 0), (0.85, 0.45), (0.98, 0.7), (1.05, 0)])
            pose[.mouthWidth] = 9
            pose[.smile] = t > 1.4 ? 0.35 : 0
            pose[.gazeY] = t < 1 ? -0.4 : 0
            let shake = (1.4..<1.9).contains(t) ? sin(t * 18) * 0.03 : 0
            pose[.rotation] =
                side * keyframes(t, [(0, 0), (0.9, 0.05), (1.0, -0.06), (1.3, 0)]) + shake
        case .shakeOff:
            let envelope = keyframes(t, [(0, 0), (0.15, 1), (0.9, 0.8), (1.2, 0)])
            pose[.rotation] = sin(t * 22) * 0.09 * envelope
            pose[.squash] = 1 - 0.03 * envelope
            pose[.lid] = 0.85 * envelope
            pose[.smile] = t > 1.1 ? 0.7 : 0.1
        case .curiousTilt:
            let tilt = keyframes(t, [(0, 0), (0.35, 1), (2.1, 1), (2.5, 0)])
            pose[.rotation] = -side * 0.1 * tilt
            pose[.eyeScale] = 1 + 0.14 * tilt
            pose[.gazeX] = side * 0.3 * tilt
            pose[.mouthOpen] = 0.2 * tilt
            pose[.mouthWidth] = 16 - 7 * tilt
            pose[.smile] = 0.25 - 0.25 * tilt
        case .whistle:
            pose[.mouthWidth] = 6
            pose[.mouthOpen] = 0.3
            pose[.smile] = 0
            pose[.gazeY] = -0.55
            pose[.gazeX] = sin(t * 1.2) * 0.5 * side
            pose[.rotation] = sin(t * 2.4) * 0.04
            pose[.lid] = 0.15
        case .blep:
            pose[.tongue] = keyframes(t, [(0, 0), (0.4, 1), (1.9, 1), (2.2, 0)])
            pose[.smile] = 0.35
            pose[.cheek] = 0.6
            pose[.gazeX] = side * 0.2
            pose[.lid] = 0.12
        case .watch:
            let look = keyframes(t, [(0, 0), (0.4, 1), (3.1, 1), (3.5, 0)])
            pose[.gazeY] = 0.95 * look
            pose[.gazeX] = (side * 0.3 + sin(t * 1.3) * 0.25) * look
            pose[.lift] = 4 * look
            pose[.eyeScale] = 1 + 0.06 * look
            pose[.smile] = 0.35
        case .daydream:
            let dream = keyframes(t, [(0, 0), (0.6, 1), (3.4, 1), (3.9, 0)])
            pose[.gazeX] = -side * 0.5 * dream
            pose[.gazeY] = -0.7 * dream
            pose[.lid] = 0.25 * dream
            pose[.smile] = 0.25 + 0.3 * dream
            pose[.cheek] = 0.5 * dream
            pose[.thinking] = 0.7 * dream
            pose[.rotation] = side * 0.04 * dream + sin(t * 1.1) * 0.015
        case .sigh:
            pose[.squash] = keyframes(t, [(0, 1), (0.8, 1.06), (1.7, 0.95), (2.4, 1)])
            pose[.lid] = keyframes(t, [(0, 0), (0.8, 0.1), (1.2, 0.5), (2.0, 0.45), (2.4, 0)])
            pose[.lift] = keyframes(t, [(0.8, 0), (1.6, 3), (2.4, 0)])
            pose[.mouthOpen] = keyframes(t, [(0.8, 0), (1.0, 0.25), (1.6, 0.1), (1.8, 0)])
            pose[.mouthWidth] = 10
            pose[.smile] = keyframes(t, [(0, 0.25), (1, 0), (2.4, 0.25)])
            pose[.gazeY] = 0.3
        case .nodOff:
            pose[.lid] = keyframes(t, [(0, 0), (2.6, 0.95), (2.75, 0)])
            pose[.lift] = keyframes(t, [(0, 0), (2.6, 5), (2.75, -1), (3.2, 0)])
            pose[.rotation] = side * keyframes(t, [(0, 0), (2.6, 0.07), (2.8, 0)])
            pose[.mouthOpen] = keyframes(t, [(1.2, 0), (2.4, 0.2), (2.6, 0)])
            pose[.eyeScale] = keyframes(t, [(2.6, 1), (2.8, 1.25), (3.6, 1)])
            pose[.gazeX] = side * keyframes(t, [(2.8, 0), (3.1, -0.7), (3.5, 0.7), (3.9, 0)])
            pose[.smile] = t < 2.7 ? 0 : 0.25
        case .notice:
            pose[.eyeScale] = keyframes(t, [(0, 1), (0.15, 1.3), (1.2, 1.2), (1.8, 1)])
            pose[.lift] = keyframes(t, [(0, 0), (0.15, -6), (0.5, 0)])
            pose[.gazeX] = keyframes(t, [(0.3, 0), (0.5, 0.9), (1.4, 0.9), (1.8, 0)])
            pose[.gazeY] = -0.3
            pose[.smile] = 0.5
        }
    }
}

/// Something that happens at one moment of an action's timeline.
enum FaceCue {
    /// Adds velocity to a channel's spring.
    case kick(FaceChannel, Double)
    /// Emits particles.
    case burst(ParticleKind, count: Int)
    /// Blinks, if the mood allows it.
    case blink
}

/// Interpolates between `(time, value)` keys with smoothstep easing, holding the first and
/// last values outside the keys.
func keyframes(_ t: Double, _ keys: [(Double, Double)]) -> Double {
    guard let first = keys.first, let last = keys.last else { return 0 }
    if t <= first.0 { return first.1 }
    for (from, to) in zip(keys, keys.dropFirst()) where t < to.0 {
        let progress = (t - from.0) / max(0.0001, to.0 - from.0)
        let eased = progress * progress * (3 - 2 * progress)
        return from.1 + (to.1 - from.1) * eased
    }
    return last.1
}
