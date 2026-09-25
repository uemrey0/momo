import SwiftUI

/// Draws a ``FaceState`` into a SwiftUI `GraphicsContext`.
public enum FaceRenderer {
    static let bodyColor = Color(red: 0x12 / 255, green: 0x13 / 255, blue: 0x18 / 255)
    static let blushColor = Color(red: 1, green: 0x8F / 255, blue: 0xA3 / 255)
    static let tongueColor = Color(red: 1, green: 0x7F / 255, blue: 0x90 / 255)

    /// Draws one frame.
    public static func draw(
        _ state: FaceState, in context: inout GraphicsContext, layout: FaceLayout
    ) {
        let eyeColor = Color(
            red: state[.eyeRed] / 255, green: state[.eyeGreen] / 255, blue: state[.eyeBlue] / 255)
        let resting = BrainSource.local.eyeColor
        let glow =
            min(
                1,
                (pow(state[.eyeRed] - resting.red, 2) + pow(state[.eyeGreen] - resting.green, 2)
                    + pow(state[.eyeBlue] - resting.blue, 2)).squareRoot() / 60)

        var body = context
        body.translateBy(x: layout.anchor.x, y: layout.anchor.y)
        body.scaleBy(x: layout.scale, y: layout.scale)
        body.translateBy(x: 0, y: state[.lift])
        body.rotate(by: .radians(state[.rotation]))
        let squash = state[.squash]
        body.scaleBy(x: 1 + (1 - squash) * 0.75, y: squash)

        drawBody(in: body)
        drawCheeks(state, in: body)
        for side in [-1.0, 1.0] {
            drawEye(state, side: side, color: eyeColor, glow: glow, in: body)
        }
        drawMouth(state, color: eyeColor, in: body)
        drawThoughtBubbles(state, in: body)

        drawCap(layout: layout, in: context)

        var particles = context
        particles.translateBy(x: layout.anchor.x, y: layout.anchor.y)
        particles.scaleBy(x: layout.scale, y: layout.scale)
        drawParticles(state.particles, in: particles)
    }

    // MARK: - Body

    private static func drawBody(in context: GraphicsContext) {
        let width = FaceGeometry.bodyWidth
        let height = FaceGeometry.bodyHeight
        let top = -FaceGeometry.hiddenTop
        var path = Path()
        path.move(to: CGPoint(x: -width / 2, y: top))
        path.addLine(to: CGPoint(x: width / 2, y: top))
        path.addArc(
            tangent1End: CGPoint(x: width / 2, y: height), tangent2End: CGPoint(x: 0, y: height),
            radius: FaceGeometry.cornerRadius)
        path.addArc(
            tangent1End: CGPoint(x: -width / 2, y: height),
            tangent2End: CGPoint(x: -width / 2, y: top), radius: FaceGeometry.cornerRadius)
        path.closeSubpath()

        var shadowed = context
        shadowed.addFilter(.shadow(color: .black.opacity(0.35), radius: 9, x: 0, y: 6))
        shadowed.fill(path, with: .color(bodyColor))
        context.stroke(path, with: .color(.white.opacity(0.07)), lineWidth: 1.2)
    }

    private static func drawCap(layout: FaceLayout, in context: GraphicsContext) {
        guard layout.capWidth > 0, layout.topInset > 0 else { return }
        let rect = CGRect(
            x: layout.anchor.x - layout.capWidth / 2, y: -1, width: layout.capWidth,
            height: layout.topInset + 1)
        let radius = min(10, layout.topInset / 3)
        let cap = UnevenRoundedRectangle(bottomLeadingRadius: radius, bottomTrailingRadius: radius)
            .path(in: rect)
        context.fill(cap, with: .color(bodyColor))
    }

    // MARK: - Face

    private static func drawCheeks(_ state: FaceState, in context: GraphicsContext) {
        let intensity = clamp01(state[.cheek])
        guard intensity > 0.02 else { return }
        var cheeks = context
        cheeks.opacity = intensity * 0.75
        cheeks.addFilter(.blur(radius: 2))
        for side in [-1.0, 1.0] {
            let rect = CGRect(x: side * 41 - 8, y: 51, width: 16, height: 8)
            cheeks.fill(Path(ellipseIn: rect), with: .color(blushColor))
        }
    }

    private static func drawEye(
        _ state: FaceState, side: Double, color: Color, glow: Double, in context: GraphicsContext
    ) {
        let scale = state[.eyeScale]
        let width = FaceGeometry.eyeWidth * scale
        let height = FaceGeometry.eyeHeight * scale
        let centerX = side * FaceGeometry.eyeOffset + state[.gazeX] * 7
        let centerY = FaceGeometry.eyeY + state[.gazeY] * 5

        var openness = state.eyeOpenness
        if side > 0 { openness *= 1 - clamp01(state[.wink]) * 0.95 }
        let happy = clamp01(state[.happyEyes])
        let dizzy = clamp01(state[.dizzy])
        let normal = (1 - happy) * (1 - dizzy)

        var eyes = context
        if glow > 0.01 {
            eyes.addFilter(.shadow(color: color.opacity(0.9), radius: glow * 6))
        }

        if normal > 0.01 {
            let visibleHeight = max(3, height * openness)
            let rect = CGRect(
                x: centerX - width / 2, y: centerY - visibleHeight / 2, width: width,
                height: visibleHeight)
            var open = eyes
            open.opacity = normal
            open.fill(
                Path(roundedRect: rect, cornerRadius: min(width, visibleHeight) / 2),
                with: .color(color))

            let lid = clamp01(state[.lid])
            let tilt = state[.lidTilt]
            if lid > 0.02 || abs(tilt) > 0.02 {
                // A body-coloured rectangle slides down over the eye; tilting it raises or
                // lowers the inner corner.
                var cover = context
                cover.translateBy(x: centerX, y: centerY - visibleHeight / 2 + lid * visibleHeight)
                cover.rotate(by: .radians(tilt * 0.42 * side))
                cover.fill(
                    Path(CGRect(x: -width / 2 - 7, y: -60, width: width + 14, height: 60)),
                    with: .color(bodyColor))
            }
        }

        if happy > 0.01 {
            var arc = Path()
            arc.addArc(
                center: CGPoint(x: centerX, y: centerY + 5), radius: width * 0.56,
                startAngle: .radians(.pi * 1.12), endAngle: .radians(.pi * 1.88), clockwise: false)
            var happyEyes = eyes
            happyEyes.opacity = happy
            happyEyes.stroke(
                arc, with: .color(color), style: StrokeStyle(lineWidth: 4.6, lineCap: .round))
        }

        if dizzy > 0.01 {
            var spiral = Path()
            var angle = 0.0
            spiral.move(to: CGPoint(x: centerX, y: centerY))
            while angle < 4 * .pi {
                let radius = 0.5 + angle * 1.05
                let turned = angle + state.time * 7 * side
                spiral.addLine(
                    to: CGPoint(
                        x: centerX + cos(turned) * radius, y: centerY + sin(turned) * radius))
                angle += 0.25
            }
            var dizzyEyes = eyes
            dizzyEyes.opacity = dizzy
            dizzyEyes.stroke(
                spiral, with: .color(color), style: StrokeStyle(lineWidth: 2.3, lineCap: .round))
        }
    }

    private static func drawMouth(_ state: FaceState, color: Color, in context: GraphicsContext) {
        let centerX = state[.gazeX] * 2.5
        let centerY = FaceGeometry.mouthY + state[.gazeY] * 1.5
        let width = state[.mouthWidth]
        let curve = state[.smile] * 7
        let opening = clamp01(state[.mouthOpen]) * 11
        let listening = clamp01(state[.listening])

        if listening < 0.99 {
            var mouth = Path()
            mouth.move(to: CGPoint(x: centerX - width / 2, y: centerY))
            mouth.addQuadCurve(
                to: CGPoint(x: centerX + width / 2, y: centerY),
                control: CGPoint(x: centerX, y: centerY + curve))
            var lips = context
            lips.opacity = 1 - listening
            if opening > 0.6 {
                mouth.addQuadCurve(
                    to: CGPoint(x: centerX - width / 2, y: centerY),
                    control: CGPoint(x: centerX, y: centerY + curve + opening * 2))
                mouth.closeSubpath()
                lips.fill(mouth, with: .color(tongueColor))
            }
            lips.stroke(
                mouth, with: .color(color),
                style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
        }

        if listening > 0.01 {
            var bars = context
            bars.opacity = listening
            for index in -2...2 {
                let i = Double(index)
                let level =
                    0.3 + 0.7 * abs(sin(state.time * 9 + i * 1.3))
                    * (0.6 + 0.4 * sin(state.time * 2 + i))
                let height = 3 + level * 11
                let rect = CGRect(
                    x: centerX + i * 5.5 - 1.6, y: centerY - height / 2, width: 3.2, height: height)
                bars.fill(Path(roundedRect: rect, cornerRadius: 1.6), with: .color(color))
            }
        }
    }

    private static func drawThoughtBubbles(_ state: FaceState, in context: GraphicsContext) {
        let visibility = clamp01(state[.thinking])
        guard visibility > 0.01 else { return }
        let right = FaceGeometry.bodyWidth / 2
        let bottom = FaceGeometry.bodyHeight
        let bubbles: [(x: Double, y: Double, radius: Double)] = [
            (right + 8, bottom - 8, 2.6), (right + 18, bottom + 2, 3.8),
            (right + 32, bottom + 14, 5.6),
        ]
        var thoughts = context
        thoughts.addFilter(.shadow(color: .black.opacity(0.4), radius: 1.5))
        for (index, bubble) in bubbles.enumerated() {
            var single = thoughts
            let pulse = clamp01(sin(state.time * 3 - Double(index) * 0.9) * 0.5 + 0.5)
            single.opacity = visibility * (0.35 + 0.65 * pulse)
            let rect = CGRect(
                x: bubble.x - bubble.radius, y: bubble.y - bubble.radius,
                width: bubble.radius * 2, height: bubble.radius * 2)
            single.fill(Path(ellipseIn: rect), with: .color(.white))
        }
    }

    // MARK: - Particles

    private static func drawParticles(_ particles: [Particle], in context: GraphicsContext) {
        guard !particles.isEmpty else { return }
        var base = context
        // A soft dark outline keeps light particles readable on any wallpaper.
        base.addFilter(.shadow(color: .black.opacity(0.45), radius: 1.5, x: 0, y: 0.5))
        for particle in particles {
            var layer = base
            layer.opacity = particle.opacity
            let progress = particle.progress
            let age = particle.age
            switch particle.kind {
            case .snooze:
                let text = Text("z")
                    .font(.system(size: 9 + progress * 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                layer.draw(text, at: CGPoint(x: particle.x + sin(age * 3) * 4, y: particle.y))
            case .note:
                layer.translateBy(x: particle.x, y: particle.y + sin(age * 6) * 3)
                layer.rotate(by: .radians(sin(age * 4) * 0.3))
                let text = Text(particle.variant == 0 ? "♪" : "♫")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                layer.draw(text, at: .zero)
            case .heart:
                let size = 5 + progress * 3
                layer.fill(
                    heartPath(x: particle.x + sin(age * 5) * 3, y: particle.y, size: size),
                    with: .color(Color(red: 1, green: 0x5F / 255, blue: 0x84 / 255)))
            case .sparkle:
                let size = sin(progress * .pi) * 6
                layer.fill(
                    sparklePath(x: particle.x, y: particle.y, size: size),
                    with: .color(Color(red: 0xF5 / 255, green: 0xB5 / 255, blue: 0x3D / 255)))
            case .sweat:
                layer.fill(
                    dropPath(x: particle.x, y: particle.y),
                    with: .color(Color(red: 0x63 / 255, green: 0xB9 / 255, blue: 0xF5 / 255)))
            case .exclamation, .question:
                let pop = progress < 0.2 ? 0.6 + progress * 2 : 1
                let color =
                    particle.kind == .exclamation
                    ? Color(red: 1, green: 0x5A / 255, blue: 0x4E / 255) : .white
                let text = Text(particle.kind == .exclamation ? "!" : "?")
                    .font(.system(size: 20 * pop, weight: .heavy, design: .rounded))
                    .foregroundStyle(color)
                layer.draw(text, at: CGPoint(x: particle.x, y: particle.y))
            }
        }
    }

    private static func heartPath(x: Double, y: Double, size s: Double) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: x, y: y + s * 0.3))
        path.addCurve(
            to: CGPoint(x: x - s, y: y + s * 0.35), control1: CGPoint(x: x, y: y - s * 0.2),
            control2: CGPoint(x: x - s, y: y - s * 0.2))
        path.addCurve(
            to: CGPoint(x: x, y: y + s * 1.3), control1: CGPoint(x: x - s, y: y + s * 0.8),
            control2: CGPoint(x: x, y: y + s * 1.05))
        path.addCurve(
            to: CGPoint(x: x + s, y: y + s * 0.35), control1: CGPoint(x: x, y: y + s * 1.05),
            control2: CGPoint(x: x + s, y: y + s * 0.8))
        path.addCurve(
            to: CGPoint(x: x, y: y + s * 0.3), control1: CGPoint(x: x + s, y: y - s * 0.2),
            control2: CGPoint(x: x, y: y - s * 0.2))
        return path
    }

    private static func sparklePath(x: Double, y: Double, size: Double) -> Path {
        var path = Path()
        for index in 0..<8 {
            let angle = Double(index) * .pi / 4
            let radius = index.isMultiple(of: 2) ? size : size * 0.32
            let point = CGPoint(x: x + cos(angle) * radius, y: y + sin(angle) * radius)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    private static func dropPath(x: Double, y: Double) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: x, y: y - 5))
        path.addQuadCurve(to: CGPoint(x: x, y: y + 4), control: CGPoint(x: x + 4.5, y: y + 2))
        path.addQuadCurve(to: CGPoint(x: x, y: y - 5), control: CGPoint(x: x - 4.5, y: y + 2))
        return path
    }

    private static func clamp01(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
