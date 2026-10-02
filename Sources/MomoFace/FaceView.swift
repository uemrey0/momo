import SwiftUI

/// A view that runs a ``FaceEngine`` and draws the character.
///
/// The engine advances only while the view draws frames. It draws at the display's full rate
/// while Momo moves, at a low rate while it rests or sleeps (see ``FramePacing``), at no more
/// than 30 frames a second in Low Power Mode, and not at all while `isPaused` is set, which
/// the owner does while nobody can see the character. Clicking the body pokes Momo.
public struct FaceView: View {
    private let engine: FaceEngine
    private let layout: FaceLayout
    private let appearance: CharacterAppearance
    private let input: @MainActor () -> FaceEngine.Input
    private let onTap: (@MainActor () -> Void)?
    private let isPaused: Bool
    @State private var pacer = FramePacer()

    /// - Parameters:
    ///   - engine: The engine to run and draw.
    ///   - layout: Where to place the character.
    ///   - input: Called once per frame to read the cursor position and idle time.
    ///   - onTap: Called after the body is clicked (and poked).
    ///   - isPaused: Stops drawing, and so the engine, for example while nobody can see it.
    public init(
        engine: FaceEngine, layout: FaceLayout, appearance: CharacterAppearance = .classic,
        input: @escaping @MainActor () -> FaceEngine.Input = { FaceEngine.Input() },
        onTap: (@MainActor () -> Void)? = nil, isPaused: Bool = false
    ) {
        self.engine = engine
        self.layout = layout
        self.appearance = appearance
        self.input = input
        self.onTap = onTap
        self.isPaused = isPaused
    }

    public var body: some View {
        TimelineView(.animation(minimumInterval: pacer.minimumInterval, paused: isPaused)) {
            timeline in
            Canvas { context, _ in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let state = engine.advance(to: time, input: input())
                pacer.record(isResting: engine.isResting, at: time)
                FaceRenderer.draw(state, in: &context, layout: layout, appearance: appearance)
            }
        }
        .frame(width: layout.canvasSize.width, height: layout.canvasSize.height)
        .contentShape(Rectangle())
        .onTapGesture(coordinateSpace: .local) { location in
            let point = layout.designPoint(from: location)
            if engine.hitTest(point) {
                pacer.wake()
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
