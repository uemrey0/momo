/// Fixed dimensions of the character in design space.
///
/// Design space is measured in points. Its origin is the anchor: the top centre of the body,
/// where Momo hangs from the notch. `x` grows to the right and `y` grows downwards.
public enum FaceGeometry {
    /// Body width.
    public static let bodyWidth = 140.0
    /// Body height below the anchor.
    public static let bodyHeight = 78.0
    /// Radius of the body's bottom corners.
    public static let cornerRadius = 32.0
    /// How far the body extends above the anchor, off screen or behind the notch, so its top
    /// corners stay hidden even when it swings.
    public static let hiddenTop = 30.0
    /// Horizontal distance from the centre to each eye.
    public static let eyeOffset = 27.0
    /// Vertical position of the eyes.
    public static let eyeY = 36.0
    /// Eye width at scale 1.
    public static let eyeWidth = 17.0
    /// Eye height at scale 1.
    public static let eyeHeight = 25.0
    /// Vertical position of the mouth.
    public static let mouthY = 58.0
    /// Lift that hides the body completely inside the notch.
    public static let tuckedLift = -90.0
    /// Width of the area the character and its particles need.
    public static let canvasWidth = 320.0
    /// Height of the area below the anchor the character and its particles need.
    public static let canvasHeight = 190.0
    /// Gap between the top edge (or the bottom of the notch) and the anchor.
    public static let anchorInset = 4.0

    /// Whether a point in design space lies on the body, given the current lift.
    public static func bodyContains(x: Double, y: Double, lift: Double) -> Bool {
        abs(x) < bodyWidth / 2 + 12 && y > -hiddenTop / 2 && y < bodyHeight + 14 + lift
    }
}
