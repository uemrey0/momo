import Testing

@testable import MomoFace

@Suite("FramePacing")
struct FramePacingTests {
    @Test("drops to the resting rate only after resting for a while")
    func slowsDownAfterSettling() {
        var pacing = FramePacing()
        pacing.record(isResting: true, at: 10)
        #expect(!pacing.isSlow)
        pacing.record(isResting: true, at: 10 + FramePacing.settleDelay / 2)
        #expect(!pacing.isSlow)
        pacing.record(isResting: true, at: 10 + FramePacing.settleDelay)
        #expect(pacing.isSlow)
    }

    @Test("returns to the full rate as soon as something moves")
    func speedsUpAtOnce() {
        var pacing = FramePacing()
        pacing.record(isResting: true, at: 0)
        pacing.record(isResting: true, at: 1)
        #expect(pacing.isSlow)
        pacing.record(isResting: false, at: 1.1)
        #expect(!pacing.isSlow)
        // The settling delay starts over.
        pacing.record(isResting: true, at: 1.2)
        #expect(!pacing.isSlow)
    }

    @Test("waking returns to the full rate")
    func wakeSpeedsUp() {
        var pacing = FramePacing()
        pacing.record(isResting: true, at: 0)
        pacing.record(isResting: true, at: 1)
        pacing.wake()
        #expect(!pacing.isSlow)
    }

    @Test("chooses the frame interval from resting and Low Power Mode")
    func minimumInterval() {
        #expect(FramePacing.minimumInterval(isSlow: false, isLowPowerModeEnabled: false) == nil)
        #expect(
            FramePacing.minimumInterval(isSlow: false, isLowPowerModeEnabled: true)
                == FramePacing.lowPowerInterval)
        #expect(
            FramePacing.minimumInterval(isSlow: true, isLowPowerModeEnabled: false)
                == FramePacing.restingInterval)
        #expect(
            FramePacing.minimumInterval(isSlow: true, isLowPowerModeEnabled: true)
                == FramePacing.restingInterval)
        #expect(FramePacing.restingInterval > FramePacing.lowPowerInterval)
    }
}

@MainActor
@Suite("FaceEngine resting")
struct FaceEngineRestingTests {
    private func makeEngine() -> FaceEngine {
        FaceEngine(random: SeededGenerator(seed: 7))
    }

    /// Runs the engine at `rate` frames a second and returns the share of frames that rested.
    private func restingShare(
        _ engine: FaceEngine, seconds: Double, rate: Double = 60,
        input: FaceEngine.Input = .init()
    ) -> Double {
        let frames = Int(seconds * rate)
        var resting = 0
        for _ in 0..<frames {
            engine.advance(by: 1 / rate, input: input)
            if engine.isResting { resting += 1 }
        }
        return Double(resting) / Double(frames)
    }

    @Test("an idle Momo with nothing going on rests most of the time")
    func idleRests() {
        let engine = makeEngine()
        engine.isLifeEnabled = false
        #expect(restingShare(engine, seconds: 30) > 0.6)
    }

    @Test("a sleeping Momo rests most of the time, snoozes included")
    func sleepRests() {
        let engine = makeEngine()
        engine.sleepDelay = 30
        let away = FaceEngine.Input(systemIdleTime: 120)
        engine.advance(by: 1.0 / 60, input: away)
        #expect(engine.state.activity == .asleep)
        _ = restingShare(engine, seconds: 3, input: away)
        #expect(restingShare(engine, seconds: 30, rate: 15, input: away) > 0.8)
    }

    @Test("a poke keeps Momo moving at the full rate")
    func pokeIsNotResting() {
        let engine = makeEngine()
        engine.isLifeEnabled = false
        _ = restingShare(engine, seconds: 3)
        engine.poke(atX: 20)
        engine.advance(by: 1.0 / 60, input: .init())
        #expect(!engine.isResting)
        // The swing dies down and Momo rests again.
        _ = restingShare(engine, seconds: 4)
        #expect(restingShare(engine, seconds: 10) > 0.5)
    }

    @Test("lively moods and reactions are never resting")
    func livelyMoodsAreActive() {
        for mood in [Mood.speaking, .happy, .music, .love, .dizzy, .listening, .thinking] {
            let engine = makeEngine()
            engine.setMood(mood)
            #expect(restingShare(engine, seconds: 3) == 0, "\(mood) rested")
        }
        let engine = makeEngine()
        engine.handle(.taskCompleted)
        #expect(restingShare(engine, seconds: 1) == 0)
    }

    @Test("a moving cursor nearby keeps the full rate")
    func movingCursorIsActive() {
        let engine = makeEngine()
        engine.isLifeEnabled = false
        for frame in 0..<120 {
            let x = 200 + Double(frame % 60) * 3
            engine.advance(by: 1.0 / 60, input: .init(pointer: SIMD2(x, 120)))
            #expect(!engine.isResting)
        }
    }

    @Test("a resting-rate frame advances by its full duration")
    func restingFrameIsNotClamped() {
        let engine = makeEngine()
        engine.advance(to: 1000, input: .init())
        let before = engine.state.time
        engine.advance(to: 1000 + FramePacing.restingInterval * 1.2, input: .init())
        #expect(abs(engine.state.time - before - FramePacing.restingInterval * 1.2) < 1e-9)
    }

    @Test("time never runs backwards")
    func backwardsTimeIsIgnored() {
        let engine = makeEngine()
        engine.advance(to: 1000, input: .init())
        let before = engine.state.time
        engine.advance(to: 990, input: .init())
        #expect(engine.state.time == before)
    }
}
