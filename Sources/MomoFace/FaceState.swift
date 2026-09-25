/// What the character is doing right now, suitable for captions and accessibility.
public enum FaceActivity: Equatable, Sendable {
    case mood(Mood)
    case action(FaceAction)
    /// The cursor is close and Momo is leaning in to look.
    case curious
    /// Momo fell asleep because the user has been away.
    case asleep
    /// Momo is hiding inside the notch.
    case tucked
}

/// A snapshot of everything the renderer needs to draw one frame.
public struct FaceState: Sendable {
    /// Current spring values for every channel.
    public var pose: FacePose
    /// Blink openness from 0 (closed) to 1 (open).
    public var eyeOpenness: Double
    /// Live particles.
    public var particles: [Particle]
    /// Seconds of simulated time since the engine started.
    public var time: Double
    /// What the character is doing.
    public var activity: FaceActivity

    public subscript(channel: FaceChannel) -> Double {
        pose[channel]
    }

    /// The resting character.
    public static let resting = FaceState(
        pose: FacePose(), eyeOpenness: 1, particles: [], time: 0, activity: .mood(.idle))
}
