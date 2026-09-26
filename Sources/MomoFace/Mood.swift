/// A persistent emotional state. Moods set the character's base expression and can add
/// procedural motion (see `FaceEngine`).
public enum Mood: String, CaseIterable, Sendable, Codable, Identifiable {
    case idle
    case happy
    case listening
    case thinking
    case speaking
    case focused
    case sleepy
    case surprised
    case sad
    case love
    case music
    case dizzy

    public var id: String { rawValue }

    /// Channel targets that differ from the resting pose.
    public var targets: FacePose {
        switch self {
        case .idle:
            FacePose()
        case .happy:
            FacePose([.happyEyes: 1, .smile: 1, .cheek: 1, .mouthWidth: 20])
        case .listening:
            FacePose([.eyeScale: 1.18, .smile: 0.1, .listening: 1, .lift: 4])
        case .thinking:
            FacePose([.lid: 0.28, .smile: -0.15, .mouthWidth: 9, .thinking: 1])
        case .speaking:
            FacePose([.smile: 0.45, .cheek: 0.3])
        case .focused:
            FacePose([.lid: 0.42, .smile: 0, .mouthWidth: 10, .eyeScale: 0.95])
        case .sleepy:
            FacePose([.lid: 0.82, .smile: 0, .mouthWidth: 8, .cheek: 0.2])
        case .surprised:
            FacePose([.eyeScale: 1.35, .smile: 0, .mouthWidth: 9, .mouthOpen: 0.9, .lift: -2])
        case .sad:
            FacePose([
                .lid: 0.3, .lidTilt: 0.9, .smile: -0.8, .mouthWidth: 14, .eyeScale: 0.95, .lift: 3,
            ])
        case .love:
            FacePose([.happyEyes: 1, .smile: 0.9, .cheek: 1.2])
        case .music:
            FacePose([.happyEyes: 1, .smile: 0.7, .cheek: 0.5])
        case .dizzy:
            FacePose([.dizzy: 1, .smile: -0.3, .mouthWidth: 12])
        }
    }

    /// Whether Momo follows the cursor while in this mood.
    public var tracksPointer: Bool {
        switch self {
        case .idle, .happy, .listening, .speaking, .love, .surprised: true
        default: false
        }
    }

    /// Whether spontaneous blinks happen in this mood.
    var allowsBlinking: Bool {
        self != .sleepy && self != .dizzy
    }
}
