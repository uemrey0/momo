import Testing

@testable import MomoFace

/// A small deterministic generator (SplitMix64) so engine behaviour is reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E9B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

@MainActor
@Suite("FaceEngine")
struct FaceEngineTests {
    private let frame = 1.0 / 60.0

    private func makeEngine(seed: UInt64 = 42) -> FaceEngine {
        FaceEngine(random: SeededGenerator(seed: seed))
    }

    private func run(
        _ engine: FaceEngine, seconds: Double, input: FaceEngine.Input = .init(),
        each: (FaceState) -> Void = { _ in }
    ) {
        for _ in 0..<Int(seconds / frame) {
            each(engine.advance(by: frame, input: input))
        }
    }

    @Test("a flashed mood returns to the base mood")
    func flashedMoodReturnsToBase() {
        let engine = makeEngine()
        engine.setMood(.focused)
        engine.flashMood(.happy, for: 1)
        #expect(engine.mood == .happy)
        run(engine, seconds: 1.2)
        #expect(engine.mood == .focused)
        #expect(engine.baseMood == .focused)
    }

    @Test("five quick pokes make Momo dizzy, then it recovers")
    func fivePokesMakeMomoDizzy() {
        let engine = makeEngine()
        for _ in 0..<5 {
            engine.poke(atX: 10)
            run(engine, seconds: 0.1)
        }
        #expect(engine.mood == .dizzy)
        run(engine, seconds: 4)
        #expect(engine.mood == .idle)
    }

    @Test("a poke makes the body swing")
    func pokeMakesBodySwing() {
        let engine = makeEngine()
        engine.isLifeEnabled = false
        engine.poke(atX: 30)
        var maximumRotation = 0.0
        run(engine, seconds: 1) { maximumRotation = max(maximumRotation, abs($0[.rotation])) }
        #expect(maximumRotation > 0.1)
    }

    @Test("falls asleep when the user is away and wakes up surprised")
    func fallsAsleepAndWakesUp() {
        let engine = makeEngine()
        engine.sleepDelay = 30
        run(engine, seconds: 0.5, input: .init(systemIdleTime: 31))
        #expect(engine.mood == .sleepy)
        #expect(engine.state.activity == .asleep)

        run(engine, seconds: 0.1, input: .init(systemIdleTime: 0))
        #expect(engine.mood == .surprised)
        #expect(engine.baseMood == .idle)
    }

    @Test("does not fall asleep when life is disabled")
    func staysAwakeWithoutLife() {
        let engine = makeEngine()
        engine.isLifeEnabled = false
        engine.sleepDelay = 30
        run(engine, seconds: 0.5, input: .init(systemIdleTime: 120))
        #expect(engine.mood == .idle)
    }

    @Test("plays idle actions only when life is enabled")
    func playsIdleActionsWithLife() {
        let alive = makeEngine()
        var sawAction = false
        run(alive, seconds: 12) { state in
            if case .action = state.activity { sawAction = true }
        }
        #expect(sawAction)

        let still = makeEngine()
        still.isLifeEnabled = false
        var stillSawAction = false
        run(still, seconds: 12) { state in
            if case .action = state.activity { stillSawAction = true }
        }
        #expect(!stillSawAction)
    }

    @Test("blinks on its own")
    func blinks() {
        let engine = makeEngine()
        var minimumOpenness = 1.0
        run(engine, seconds: 8) { minimumOpenness = min(minimumOpenness, $0.eyeOpenness) }
        #expect(minimumOpenness < 0.2)
    }

    @Test("eye colour follows the active brain")
    func eyeColourFollowsBrain() {
        let engine = makeEngine()
        engine.brain = .subscription
        run(engine, seconds: 2)
        let expected = BrainSource.subscription.eyeColor
        #expect(abs(engine.state[.eyeRed] - expected.red) < 1)
        #expect(abs(engine.state[.eyeBlue] - expected.blue) < 1)
    }

    @Test("looks towards the cursor")
    func looksTowardsCursor() {
        let engine = makeEngine()
        engine.isLifeEnabled = false
        run(engine, seconds: 1, input: .init(pointer: SIMD2(300, 0)))
        #expect(engine.state[.gazeX] > 0.8)
        run(engine, seconds: 1, input: .init(pointer: SIMD2(-300, 0)))
        #expect(engine.state[.gazeX] < -0.8)
    }

    @Test("gets curious when the cursor is close")
    func getsCuriousWhenCursorIsClose() {
        let engine = makeEngine()
        run(engine, seconds: 0.2, input: .init(pointer: SIMD2(60, 40)))
        #expect(engine.state.activity == .curious)
    }

    @Test("hides in the notch during screen sharing")
    func hidesDuringScreenSharing() {
        let engine = makeEngine()
        engine.handle(.screenSharingStarted)
        run(engine, seconds: 2)
        #expect(engine.state[.lift] < FaceGeometry.tuckedLift + 5)
        #expect(engine.state.activity == .tucked)
        #expect(!engine.hitTest(SIMD2(0, 30)))

        engine.handle(.screenSharingEnded)
        run(engine, seconds: 2)
        #expect(abs(engine.state[.lift]) < 5)
        #expect(engine.hitTest(SIMD2(0, 30)))
    }

    @Test("a failure shows surprise, then sadness, then recovers")
    func failureSequence() {
        let engine = makeEngine()
        engine.handle(.failure)
        #expect(engine.mood == .surprised)
        run(engine, seconds: 1)
        #expect(engine.mood == .sad)
        run(engine, seconds: 3)
        #expect(engine.mood == .idle)
    }

    @Test("particles are emitted and expire")
    func particlesExpire() {
        let engine = makeEngine()
        engine.setMood(.love)
        run(engine, seconds: 1)
        #expect(!engine.state.particles.isEmpty)
        engine.setMood(.idle)
        engine.isLifeEnabled = false
        run(engine, seconds: 3)
        #expect(engine.state.particles.isEmpty)
    }

    @Test("reduce motion disables particles")
    func reduceMotionDisablesParticles() {
        let engine = makeEngine()
        engine.reducesMotion = true
        engine.setMood(.music)
        run(engine, seconds: 2)
        #expect(engine.state.particles.isEmpty)
    }

    @Test("every channel stays finite across all moods and events")
    func channelsStayFinite() {
        let engine = makeEngine()
        for mood in Mood.allCases {
            engine.setMood(mood)
            for event in FaceEvent.allCases { engine.handle(event) }
            run(engine, seconds: 1, input: .init(pointer: SIMD2(20, 20))) { state in
                for channel in FaceChannel.allCases {
                    #expect(state[channel].isFinite)
                }
            }
        }
    }

    @Test("opens the mouth with each spoken word while voice driven")
    func lipSync() {
        let engine = makeEngine()
        engine.isLifeEnabled = false
        engine.setMood(.speaking)
        engine.setVoiceDriven(true)
        run(engine, seconds: 1)
        #expect(engine.state[.mouthOpen] < 0.1)
        engine.pulseMouth()
        var widest = 0.0
        run(engine, seconds: 0.2) { widest = max(widest, $0[.mouthOpen]) }
        #expect(widest > 0.4)
        run(engine, seconds: 1.5)
        #expect(engine.state[.mouthOpen] < 0.1)
    }

    @Test("clamps long gaps between timestamps")
    func clampsLongGaps() {
        let engine = makeEngine()
        engine.advance(to: 100, input: .init())
        let state = engine.advance(to: 200, input: .init())
        #expect(state.time < 0.1)
    }
}
