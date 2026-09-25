import CoreGraphics

/// Where and how large the character is drawn inside its view.
public struct FaceLayout: Sendable, Equatable {
    /// Height of the hardware notch (or zero). The body hangs just below it.
    public var topInset: Double
    /// Width of the cap drawn over the hardware notch, or zero on screens without one. The cap
    /// hides the body when Momo retreats into the notch.
    public var capWidth: Double
    /// Multiplier from design points to view points.
    public var scale: Double

    public init(topInset: Double = 0, capWidth: Double = 0, scale: Double = 1) {
        self.topInset = topInset
        self.capWidth = capWidth
        self.scale = scale
    }

    /// Size of the view that shows the character and its particles.
    public var canvasSize: CGSize {
        CGSize(
            width: FaceGeometry.canvasWidth * scale,
            height: topInset + (FaceGeometry.anchorInset + FaceGeometry.canvasHeight) * scale)
    }

    /// The anchor (top centre of the body) in view coordinates.
    public var anchor: CGPoint {
        CGPoint(
            x: canvasSize.width / 2,
            y: topInset + FaceGeometry.anchorInset * scale)
    }

    /// Converts a point in view coordinates to design space.
    public func designPoint(from viewPoint: CGPoint) -> SIMD2<Double> {
        SIMD2(
            (viewPoint.x - anchor.x) / scale,
            (viewPoint.y - anchor.y) / scale)
    }
}
