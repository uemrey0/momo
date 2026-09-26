/// An animatable property of the character.
///
/// Each channel is driven by its own ``Spring``. Values are unitless unless noted.
public enum FaceChannel: CaseIterable, Sendable, Hashable {
    /// Horizontal gaze from -1 (left) to 1 (right).
    case gazeX
    /// Vertical gaze from -1 (up) to 1 (down).
    case gazeY
    /// Eye size multiplier.
    case eyeScale
    /// Blend towards happy, arc-shaped eyes (0...1).
    case happyEyes
    /// Mouth curve from -1 (frown) to 1 (smile).
    case smile
    /// How far the mouth is open (0...1).
    case mouthOpen
    /// Mouth width in points.
    case mouthWidth
    /// Cheek blush intensity (0...1).
    case cheek
    /// How far the upper lids cover the eyes (0...1).
    case lid
    /// Lid slant; positive values raise the inner corners (sad), negative lower them (cross).
    case lidTilt
    /// Blend towards the listening sound bars that replace the mouth (0...1).
    case listening
    /// Blend towards dizzy spiral eyes (0...1).
    case dizzy
    /// Visibility of the thought bubbles (0...1).
    case thinking
    /// Vertical offset of the body in points; negative values pull it up into the notch.
    case lift
    /// Pendulum rotation of the body around its anchor, in radians.
    case rotation
    /// Right eye closure for a wink (0...1).
    case wink
    /// How far the tip of the tongue sticks out (0...1).
    case tongue
    /// Vertical stretch of the body; values below 1 squash it, above 1 stretch it.
    case squash
    /// Eye colour, red component (0...255).
    case eyeRed
    /// Eye colour, green component (0...255).
    case eyeGreen
    /// Eye colour, blue component (0...255).
    case eyeBlue

    /// The value the channel takes when nothing else asks for a different one.
    public var restingValue: Double {
        switch self {
        case .eyeScale, .squash: 1
        case .smile: 0.25
        case .mouthWidth: 16
        case .cheek: 0.15
        case .eyeRed: BrainSource.local.eyeColor.red
        case .eyeGreen: BrainSource.local.eyeColor.green
        case .eyeBlue: BrainSource.local.eyeColor.blue
        default: 0
        }
    }

    /// Spring constants tuned for how this channel should move.
    var springConstants: (stiffness: Double, damping: Double) {
        switch self {
        case .gazeX, .gazeY: (200, 22)
        case .eyeScale: (170, 15)
        case .happyEyes: (120, 16)
        case .mouthOpen: (320, 22)
        case .lid: (160, 18)
        case .thinking: (80, 14)
        case .lift: (110, 11)
        case .squash: (240, 9)
        case .rotation: (55, 4.5)
        case .wink: (320, 24)
        case .tongue: (220, 20)
        case .eyeRed, .eyeGreen, .eyeBlue: (60, 14)
        default: (140, 16)
        }
    }
}

/// A set of channel values. Channels that are not set report their resting value.
public struct FacePose: Sendable, Equatable {
    private var values: [FaceChannel: Double]

    public init(_ values: [FaceChannel: Double] = [:]) {
        self.values = values
    }

    public subscript(channel: FaceChannel) -> Double {
        get { values[channel] ?? channel.restingValue }
        set { values[channel] = newValue }
    }
}
