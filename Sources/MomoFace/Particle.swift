/// The kinds of particles Momo can emit.
public enum ParticleKind: Sendable, Hashable {
    /// A drifting "z" while sleeping.
    case snooze
    /// A musical note.
    case note
    /// A small heart.
    case heart
    /// A four-pointed sparkle.
    case sparkle
    /// A falling sweat drop.
    case sweat
    /// An exclamation mark.
    case exclamation
    /// A question mark.
    case question
}

/// A single short-lived particle, positioned in design space (see ``FaceGeometry``).
public struct Particle: Sendable, Equatable {
    public let kind: ParticleKind
    public var x: Double
    public var y: Double
    public var velocityX: Double
    public var velocityY: Double
    public var age: Double = 0
    public let lifetime: Double
    public var gravity: Double = 0
    /// Chooses between visual variants, for example "♪" or "♫".
    public let variant: Int

    /// Life progress from 0 (born) to 1 (gone).
    public var progress: Double {
        min(1, age / lifetime)
    }

    /// Opacity that fades in quickly and fades out over the last 40 % of the lifetime.
    public var opacity: Double {
        let progress = progress
        if progress < 0.15 { return progress / 0.15 }
        return max(0, min(1, 1 - (progress - 0.6) / 0.4))
    }

    var isAlive: Bool { age < lifetime }

    mutating func step(by dt: Double) {
        age += dt
        x += velocityX * dt
        y += velocityY * dt
        velocityY += gravity * dt
    }
}
