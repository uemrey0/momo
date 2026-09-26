import Foundation

/// Simulates the character.
///
/// Every frame, ``advance(by:input:)`` combines five layers into channel targets, steps the
/// springs and particles, and returns a ``FaceState`` for the renderer:
///
/// 1. **Life:** breathing, blinking and small gaze saccades.
/// 2. **Mood:** the base expression, plus procedural motion for some moods.
/// 3. **Action:** one-shot behaviours such as yawning, some chosen at random while idle.
/// 4. **Reaction:** cursor attention, pokes, falling asleep and waking up, events.
/// 5. **Particles:** snoozes, notes, hearts and friends.
///
/// Randomness comes from an injectable generator so tests are deterministic.
@MainActor
public final class FaceEngine {
    /// Information about the outside world for one frame.
    public struct Input: Sendable, Equatable {
        /// Cursor position relative to the anchor, in design points (`y` grows downwards).
        /// `nil` when unknown.
        public var pointer: SIMD2<Double>?
        /// Seconds since the user last touched the keyboard, mouse or trackpad.
        public var systemIdleTime: Double

        public init(pointer: SIMD2<Double>? = nil, systemIdleTime: Double = 0) {
            self.pointer = pointer
            self.systemIdleTime = systemIdleTime
        }
    }

    /// The mood Momo returns to after temporary reactions.
    public private(set) var baseMood: Mood = .idle
    /// The mood currently shown, which may be a temporary reaction.
    public private(set) var mood: Mood = .idle
    /// The brain currently doing the thinking, shown through the eye colour.
    public var brain: BrainSource = .local
    /// Whether Momo plays idle behaviours and falls asleep on its own.
    public var isLifeEnabled = true
    /// Disables idle behaviours and particles, for the system's Reduce Motion setting.
    public var reducesMotion = false
    /// Seconds of system idle time before Momo falls asleep.
    public var sleepDelay: Double = 60
    /// Whether Momo is hiding inside the notch, for example during screen sharing.
    public private(set) var isTucked = false
    /// The most recent frame.
    public private(set) var state = FaceState.resting

    private enum ScheduledStep {
        case flash(Mood, duration: Double)
    }

    private var springs: [FaceChannel: Spring]
    private var random: AnyRandomNumberGenerator
    private var lastTimestamp: Double?
    private var clock = 0.0
    private var moodElapsed = 0.0
    private var temporaryMoodRemaining: Double?
    private var action: (kind: FaceAction, elapsed: Double)?
    private var idleActionCountdown = 3.0
    private var lastIdleAction: FaceAction?
    private var blinkCountdown = 1.2
    private var blinkPhase: Double?
    private var pendingDoubleBlink = false
    private var saccadeCountdown = 0.0
    private var saccade = SIMD2<Double>(0, 0)
    private var emissionTimers: [ParticleKind: Double] = [:]
    private var pokeTimes: [Double] = []
    private var fellAsleepOnItsOwn = false
    private var scheduled: [(remaining: Double, step: ScheduledStep)] = []
    private var particles: [Particle] = []
    private var isVoiceDriven = false
    private var mouthEnvelope = 0.0

    /// Creates an engine that uses `random` for every random decision.
    public init(random: some RandomNumberGenerator) {
        self.random = AnyRandomNumberGenerator(random)
        var springs: [FaceChannel: Spring] = [:]
        for channel in FaceChannel.allCases {
            let constants = channel.springConstants
            springs[channel] = Spring(
                channel.restingValue, stiffness: constants.stiffness, damping: constants.damping)
        }
        self.springs = springs
    }

    /// Creates an engine that uses the system random number generator.
    public convenience init() {
        self.init(random: SystemRandomNumberGenerator())
    }

    // MARK: - Controls

    /// Sets the mood Momo stays in.
    public func setMood(_ newMood: Mood) {
        baseMood = newMood
        temporaryMoodRemaining = nil
        fellAsleepOnItsOwn = false
        enter(newMood)
    }

    /// Shows `newMood` for `duration` seconds, then returns to the base mood.
    public func flashMood(_ newMood: Mood, for duration: Double) {
        temporaryMoodRemaining = duration
        enter(newMood)
    }

    /// Starts a one-shot action, replacing any action in progress.
    public func perform(_ newAction: FaceAction) {
        action = (newAction, 0)
    }

    /// Reacts to the user clicking the body at horizontal design position `x`.
    public func poke(atX x: Double) {
        let side: Double = x >= 0 ? 1 : -1
        springs[.rotation]?.velocity += side * 2.6
        springs[.squash]?.velocity -= 3.8
        perform(.giggle)
        spawn(.heart)

        if fellAsleepOnItsOwn {
            wakeUp()
            return
        }
        pokeTimes = pokeTimes.filter { clock - $0 < 2 }
        pokeTimes.append(clock)
        if pokeTimes.count >= 5 {
            pokeTimes.removeAll()
            action = nil
            flashMood(.dizzy, for: 3.4)
        }
    }

    /// Reacts to something that happened on the Mac.
    public func handle(_ event: FaceEvent) {
        switch event {
        case .taskCompleted:
            flashMood(.happy, for: 2.6)
            spawn(.sparkle, count: 10)
        case .meetingSoon:
            flashMood(.surprised, for: 1.6)
            springs[.rotation]?.velocity += 3.2
        case .newMail:
            perform(.peek)
            schedule(.flash(.surprised, duration: 1.2), after: 1.25)
        case .lowBattery:
            flashMood(.sad, for: 3.6)
        case .failure:
            flashMood(.surprised, for: 0.8)
            schedule(.flash(.sad, duration: 2.6), after: 0.8)
        case .screenSharingStarted:
            isTucked = true
        case .screenSharingEnded:
            isTucked = false
            springs[.squash]?.velocity += 2
        case .lateNight:
            perform(.yawn)
            schedule(.flash(.sleepy, duration: 6), after: FaceAction.yawn.duration)
        }
    }

    /// Starts or stops lip sync from speech. While on, the speaking mouth follows
    /// ``pulseMouth(strength:)`` instead of its built-in rhythm.
    public func setVoiceDriven(_ enabled: Bool) {
        isVoiceDriven = enabled
        if !enabled { mouthEnvelope = 0 }
    }

    /// Opens the mouth for a spoken word or syllable; it closes again on its own.
    public func pulseMouth(strength: Double = 1) {
        mouthEnvelope = max(mouthEnvelope, min(1, strength))
    }

    /// Whether a point in design space lies on the body.
    public func hitTest(_ point: SIMD2<Double>) -> Bool {
        !isTucked
            && FaceGeometry.bodyContains(x: point.x, y: point.y, lift: spring(.lift).value)
    }

    // MARK: - Simulation

    /// Advances the simulation to an absolute timestamp in seconds. The first call only
    /// establishes the timeline; gaps longer than 50 ms are clamped.
    @discardableResult
    public func advance(to timestamp: Double, input: Input) -> FaceState {
        let dt = lastTimestamp.map { min(0.05, max(0, timestamp - $0)) } ?? 1.0 / 60.0
        lastTimestamp = timestamp
        return advance(by: dt, input: input)
    }

    /// Advances the simulation by `dt` seconds.
    @discardableResult
    public func advance(by dt: Double, input: Input) -> FaceState {
        clock += dt
        moodElapsed += dt
        runScheduledSteps(dt)
        expireTemporaryMood(dt)
        expireAction(dt)

        var pose = mood.targets
        var breathing = (rate: 1.7, amplitude: 0.018)
        applyMoodMotion(to: &pose, breathing: &breathing, dt: dt)
        let curious = applyAttention(to: &pose, input: input, dt: dt)
        updateLife(input: input, curious: curious, dt: dt)

        if let action {
            action.kind.apply(at: action.elapsed, to: &pose)
            if let emission = action.kind.emission {
                emit(emission.kind, every: emission.interval, dt: dt)
            }
        }
        if isTucked {
            pose[.lift] = FaceGeometry.tuckedLift
        }
        pose[.squash] += sin(clock * breathing.rate * .pi) * breathing.amplitude

        let eye = brain.eyeColor
        pose[.eyeRed] = eye.red
        pose[.eyeGreen] = eye.green
        pose[.eyeBlue] = eye.blue

        var current = FacePose()
        for channel in FaceChannel.allCases {
            guard var spring = springs[channel] else { continue }
            spring.target = pose[channel]
            spring.step(by: dt)
            springs[channel] = spring
            current[channel] = spring.value
        }

        let openness = updateBlink(dt)
        for index in particles.indices { particles[index].step(by: dt) }
        particles.removeAll { !$0.isAlive }

        state = FaceState(
            pose: current, eyeOpenness: openness, particles: particles, time: clock,
            activity: activity(curious: curious))
        return state
    }

    // MARK: - Layers

    private func applyMoodMotion(
        to pose: inout FacePose, breathing: inout (rate: Double, amplitude: Double), dt: Double
    ) {
        switch mood {
        case .speaking:
            if isVoiceDriven {
                // Each word opens the mouth; a quick flutter makes it look like syllables.
                mouthEnvelope *= exp(-dt * 7)
                pose[.mouthOpen] = mouthEnvelope * (0.7 + 0.3 * abs(sin(clock * 22)))
            } else {
                let syllable = max(0, sin(clock * 13)) * (0.55 + 0.45 * sin(clock * 2.3))
                pose[.mouthOpen] = sin(clock * 0.9) > 0.75 ? 0 : syllable
            }
            pose[.rotation] = sin(clock * 3) * 0.025
            if sin(clock * 1.7) > 0.93 { pose[.happyEyes] = 1 }
        case .happy:
            pose[.lift] = -abs(sin(clock * 5)) * 4
            emit(.sparkle, every: 0.6, dt: dt)
        case .thinking:
            pose[.gazeX] = 0.7 + sin(clock * 0.8) * 0.25
            pose[.gazeY] = -0.85 + sin(clock * 1.3) * 0.1
            pose[.rotation] = sin(clock * 0.7) * 0.03
        case .sleepy:
            breathing = (0.75, 0.045)
            emit(.snooze, every: 1.3, dt: dt)
            // Every seven seconds the head drops, then Momo startles awake for a moment.
            let cycle = moodElapsed.truncatingRemainder(dividingBy: 7)
            if (5..<6.3).contains(cycle) {
                pose[.lid] = 1
                pose[.rotation] = 0.08
                pose[.lift] = 3
            } else if (6.3..<6.7).contains(cycle) {
                pose[.lid] = 0.25
                pose[.eyeScale] = 1.12
            }
        case .focused:
            // Reads along an imaginary line of text.
            pose[.gazeX] = sin(clock * 1.1) * 0.55
            pose[.gazeY] = 0.35
            breathing.amplitude = 0.008
        case .music:
            let beat = clock * .pi * 2.2
            pose[.rotation] = sin(beat) * 0.085
            pose[.lift] = -abs(sin(beat)) * 3
            emit(.note, every: 0.5, dt: dt)
        case .love:
            pose[.lift] = sin(clock * 3) * 2
            emit(.heart, every: 0.45, dt: dt)
        case .sad:
            pose[.gazeY] = 0.6
            pose[.gazeX] = sin(clock * 0.5) * 0.2
            breathing.rate = 1.1
            emit(.sweat, every: 2.6, dt: dt)
        case .dizzy:
            pose[.rotation] = sin(clock * 4.5) * 0.12
        case .listening:
            pose[.gazeY] = 0.35
        case .idle, .surprised:
            break
        }
    }

    /// Points the eyes at the cursor when Momo is paying attention, otherwise lets the gaze
    /// wander. Returns whether Momo is curious (cursor very close).
    private func applyAttention(to pose: inout FacePose, input: Input, dt: Double) -> Bool {
        let attentive = mood.tracksPointer && (action?.kind.tracksPointer ?? true) && !isTucked
        if attentive, let pointer = input.pointer {
            let distance = max(0.001, (pointer * pointer).sum().squareRoot())
            if distance < 440 {
                let strength = min(1, distance / 150)
                pose[.gazeX] = pointer.x / distance * strength
                pose[.gazeY] = min(1, max(-0.6, pointer.y / distance * strength))
                if distance < 130 && mood == .idle {
                    pose[.eyeScale] = 1.12
                    pose[.rotation] = min(0.12, max(-0.12, -pointer.x * 0.0011))
                    pose[.smile] = 0.45
                    return true
                }
                return false
            }
        }
        if mood == .idle || mood == .speaking {
            saccadeCountdown -= dt
            if saccadeCountdown <= 0 {
                saccadeCountdown = Double.random(in: 0.6...2.6, using: &random)
                saccade = SIMD2(
                    Double.random(in: -0.6...0.6, using: &random),
                    Double.random(in: -0.35...0.35, using: &random))
            }
            pose[.gazeX] += saccade.x
            pose[.gazeY] += saccade.y
        }
        return false
    }

    /// Plays idle behaviours, and falls asleep or wakes up with the user.
    private func updateLife(input: Input, curious: Bool, dt: Double) {
        if fellAsleepOnItsOwn && input.systemIdleTime < 1 {
            wakeUp()
            return
        }
        let calm = baseMood == .idle && mood == .idle && action == nil && !isTucked
        guard isLifeEnabled, calm else { return }

        if input.systemIdleTime > sleepDelay {
            setMood(.sleepy)
            fellAsleepOnItsOwn = true
            return
        }
        guard !reducesMotion, !curious else { return }
        idleActionCountdown -= dt
        if idleActionCountdown <= 0 {
            let candidates = FaceAction.idlePool.filter { $0 != lastIdleAction }
            if let next = candidates.randomElement(using: &random) {
                lastIdleAction = next
                perform(next)
            }
        }
    }

    private func wakeUp() {
        setMood(.idle)
        flashMood(.surprised, for: 0.9)
    }

    /// Returns blink openness for this frame (1 open, 0 closed).
    private func updateBlink(_ dt: Double) -> Double {
        let blinkDuration = 0.17
        if blinkPhase == nil {
            blinkCountdown -= dt
            if blinkCountdown <= 0 && mood.allowsBlinking {
                blinkPhase = 0
            }
        }
        guard var phase = blinkPhase else { return 1 }
        phase += dt
        let openness = abs(cos(min(1, phase / blinkDuration) * .pi))
        if phase > blinkDuration {
            blinkPhase = nil
            if pendingDoubleBlink {
                pendingDoubleBlink = false
                blinkCountdown = 0.1
            } else {
                blinkCountdown = Double.random(in: 1.8...6, using: &random)
                pendingDoubleBlink = Double.random(in: 0..<1, using: &random) < 0.2
            }
        } else {
            blinkPhase = phase
        }
        return openness
    }

    // MARK: - Bookkeeping

    private func enter(_ newMood: Mood) {
        mood = newMood
        moodElapsed = 0
        switch newMood {
        case .surprised:
            springs[.squash]?.velocity += 3.5
            spawn(.exclamation)
        case .happy:
            springs[.squash]?.velocity -= 3
            spawn(.sparkle, count: 6)
        case .love:
            spawn(.heart, count: 3)
        case .sad:
            spawn(.sweat)
        case .dizzy:
            springs[.rotation]?.velocity += 2.5
        case .thinking:
            spawn(.question)
        default:
            break
        }
    }

    private func schedule(_ step: ScheduledStep, after delay: Double) {
        scheduled.append((delay, step))
    }

    private func runScheduledSteps(_ dt: Double) {
        guard !scheduled.isEmpty else { return }
        var due: [ScheduledStep] = []
        scheduled = scheduled.compactMap { item in
            let remaining = item.remaining - dt
            if remaining <= 0 {
                due.append(item.step)
                return nil
            }
            return (remaining, item.step)
        }
        for step in due {
            switch step {
            case .flash(let newMood, let duration): flashMood(newMood, for: duration)
            }
        }
    }

    private func expireTemporaryMood(_ dt: Double) {
        guard let remaining = temporaryMoodRemaining else { return }
        if remaining - dt <= 0 {
            temporaryMoodRemaining = nil
            mood = baseMood
            moodElapsed = 0
        } else {
            temporaryMoodRemaining = remaining - dt
        }
    }

    private func expireAction(_ dt: Double) {
        guard var current = action else { return }
        current.elapsed += dt
        if current.elapsed > current.kind.duration {
            action = nil
            idleActionCountdown = Double.random(in: 4...8, using: &random)
        } else {
            action = current
        }
    }

    private func activity(curious: Bool) -> FaceActivity {
        if isTucked { return .tucked }
        if let action { return .action(action.kind) }
        if curious { return .curious }
        if fellAsleepOnItsOwn { return .asleep }
        return .mood(mood)
    }

    private func spring(_ channel: FaceChannel) -> Spring {
        springs[channel] ?? Spring(channel.restingValue)
    }

    // MARK: - Particles

    private func emit(_ kind: ParticleKind, every interval: Double, dt: Double) {
        let elapsed = emissionTimers[kind, default: 0] + dt
        if elapsed > interval {
            emissionTimers[kind] = 0
            spawn(kind)
        } else {
            emissionTimers[kind] = elapsed
        }
    }

    private func spawn(_ kind: ParticleKind, count: Int = 1) {
        guard !reducesMotion else { return }
        let lift = spring(.lift).value
        for _ in 0..<count {
            particles.append(makeParticle(kind, lift: lift))
        }
    }

    private func makeParticle(_ kind: ParticleKind, lift: Double) -> Particle {
        func r(_ range: ClosedRange<Double>) -> Double {
            Double.random(in: range, using: &random)
        }
        switch kind {
        case .snooze:
            return Particle(
                kind: kind, x: 66, y: 26 + lift, velocityX: r(12...18), velocityY: r(2...8),
                lifetime: 2.4, variant: 0)
        case .note:
            let side: Double = Bool.random(using: &random) ? 1 : -1
            return Particle(
                kind: kind, x: side * 76, y: r(24...48) + lift, velocityX: side * r(14...24),
                velocityY: r(-2...8), lifetime: 2.1, variant: Int.random(in: 0...1, using: &random))
        case .heart:
            return Particle(
                kind: kind, x: r(-40...40), y: 74 + lift, velocityX: r(-12...12),
                velocityY: r(14...24), lifetime: 1.9, variant: 0)
        case .sparkle:
            return Particle(
                kind: kind, x: r(-100...100), y: r(8...96) + lift, velocityX: 0,
                velocityY: r(-4...4), lifetime: r(0.7...1.1), variant: 0)
        case .sweat:
            return Particle(
                kind: kind, x: 56, y: 12 + lift, velocityX: 8, velocityY: 0, lifetime: 1.6,
                gravity: 70, variant: 0)
        case .exclamation:
            return Particle(
                kind: kind, x: 86, y: 24 + lift, velocityX: 0, velocityY: 0, lifetime: 1.1,
                variant: 0)
        case .question:
            return Particle(
                kind: kind, x: 86, y: 26 + lift, velocityX: 0, velocityY: 0, lifetime: 1.4,
                variant: 0)
        }
    }
}
