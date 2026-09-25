import SwiftUI

/// A view that runs a ``FaceEngine`` and draws the character.
///
/// The engine advances while the view renders frames, so it costs nothing when the character
/// is off screen. Clicking the body pokes Momo.
public struct FaceView: View {
    private let engine: FaceEngine
    private let layout: FaceLayout
    private let appearance: CharacterAppearance
    private let input: @MainActor () -> FaceEngine.Input
    private let onTap: (@MainActor () -> Void)?

    /// - Parameters:
    ///   - engine: The engine to run and draw.
    ///   - layout: Where to place the character.
    ///   - input: Called once per frame to read the cursor position and idle time.
    ///   - onTap: Called after the body is clicked (and poked).
    public init(
        engine: FaceEngine, layout: FaceLayout, appearance: CharacterAppearance = .classic,
        input: @escaping @MainActor () -> FaceEngine.Input = { FaceEngine.Input() },
        onTap: (@MainActor () -> Void)? = nil
    ) {
        self.engine = engine
        self.layout = layout
        self.appearance = appearance
        self.input = input
        self.onTap = onTap
    }

    public var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, _ in
                let state = engine.advance(
                    to: timeline.date.timeIntervalSinceReferenceDate, input: input())
                FaceRenderer.draw(state, in: &context, layout: layout, appearance: appearance)
            }
        }
        .frame(width: layout.canvasSize.width, height: layout.canvasSize.height)
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { location in
            let point = layout.designPoint(from: location)
            if engine.hitTest(point) {
                engine.poke(atX: point.x)
                onTap?()
            }
        }
    }
}

#Preview("Momo") {
    FaceView(engine: FaceEngine(), layout: FaceLayout())
        .background(
            LinearGradient(
                colors: [.blue.opacity(0.3), .pink.opacity(0.3)], startPoint: .topLeading,
                endPoint: .bottomTrailing))
}
