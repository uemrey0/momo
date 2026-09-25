/// A damped spring that eases a value towards a target.
///
/// Every animatable property of the character is driven by one of these. Stiff, well-damped
/// springs settle quickly (eye movements); soft, lightly damped springs overshoot and swing
/// (the body's pendulum sway after a poke).
///
/// Integration uses semi-implicit Euler with fixed sub-steps, so a long frame gap never makes
/// the spring explode.
public struct Spring: Sendable, Equatable {
    /// The current value.
    public var value: Double
    /// The current rate of change, in units per second.
    public var velocity: Double
    /// The value the spring is moving towards.
    public var target: Double
    /// How strongly the spring pulls towards the target.
    public var stiffness: Double
    /// How strongly motion is slowed down.
    public var damping: Double

    /// The largest integration step, in seconds.
    static let maximumStep = 1.0 / 240.0

    public init(_ value: Double, stiffness: Double = 140, damping: Double = 16) {
        self.value = value
        self.velocity = 0
        self.target = value
        self.stiffness = stiffness
        self.damping = damping
    }

    /// Whether the spring has effectively come to rest at its target.
    public var isSettled: Bool {
        abs(target - value) < 0.001 && abs(velocity) < 0.001
    }

    /// Advances the simulation by `duration` seconds.
    public mutating func step(by duration: Double) {
        guard duration > 0 else { return }
        var remaining = duration
        while remaining > 0 {
            let dt = min(remaining, Self.maximumStep)
            let acceleration = stiffness * (target - value) - damping * velocity
            velocity += acceleration * dt
            value += velocity * dt
            remaining -= dt
        }
    }
}
