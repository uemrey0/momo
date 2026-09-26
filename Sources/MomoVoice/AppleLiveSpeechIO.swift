import AVFoundation
import Foundation
import Speech

/// The built-in live speech engine: works on every supported Mac without downloads.
///
/// One `AVAudioEngine` does everything, with voice processing on the input node, which turns
/// on Apple's echo cancellation: the microphone hears the user but not Momo, because Momo's
/// voice plays through the same engine and serves as the echo reference. Speech is
/// recognised continuously (`SpeechAnalyzer` on macOS 26 when the language's model is
/// installed, Apple Speech otherwise), one recognition session per turn.
/// ``LiveTurnDetector`` ends turns from the echo-cancelled level and the words so far.
///
/// Replies are rendered sentence by sentence (`AVSpeechSynthesizer.write`, or an OpenAI voice
/// streamed as PCM) into an `AVAudioPlayerNode` on the same engine, and the mouth follows the
/// output level. When the user talks over Momo, playback stops at once and
/// ``LiveSpeechEvent/interrupted(id:)`` is reported.
@MainActor
public final class AppleLiveSpeechIO: LiveSpeechIO {
    public var onEvent: ((LiveSpeechEvent) -> Void)?
    /// Called for each sentence sent to a cloud voice, with the service's name and the number
    /// of characters, for the privacy log.
    public var onCloudSpeech: ((String, Int) -> Void)?
    public private(set) var isRunning = false

    private var configuration = LiveSpeechConfiguration(locale: .current)
    private var audio: LiveAudioGraph?
    private let router = LiveInputRouter()
    private var configurationObserver: (any NSObjectProtocol)?
    /// Bumped by ``stop()``, so a start that is still waiting for permissions gives up.
    private var sessionToken = 0
    private var pendingTurnEnd: Task<Void, Never>?

    // Listening
    private var detector = LiveTurnDetector()
    private var recognition: (any LiveRecognitionSession)?
    private var recognitionStartedAt: TimeInterval = 0
    private var usesAnalyzer = false
    private var recognitionLocale = Locale.current
    private var turnPrefix = ""
    private var sessionText = ""
    private var lastPartial = ""
    private var isListeningPaused = false
    /// Set when the user talked over Momo, so what they say counts even though output was
    /// active when they started.
    private var isBargingIn = false

    // Speaking
    private var utterances: [LiveUtterance] = []
    private var queue: [(id: String, text: String)] = []
    private var worker: Task<Void, Never>?
    private var workerToken = 0
    private let synthesizer = AVSpeechSynthesizer()
    private let synthesisRelay = SynthesisRelay()
    private var cloudFailed = false
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
        synthesizer.delegate = synthesisRelay
    }

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: - Session

    public func start(_ configuration: LiveSpeechConfiguration) async throws {
        stop()
        let token = sessionToken
        try await SpeechRecognizer.requestPermissions()
        guard token == sessionToken else { throw CancellationError() }
        self.configuration = configuration
        detector = LiveTurnDetector(
            configuration: .init(
                maximumPause: configuration.maximumPause,
                endsTurnsOnPause: configuration.endsTurnsOnPause))
        recognitionLocale = configuration.locale
        usesAnalyzer = false
        if #available(macOS 26, *) {
            usesAnalyzer = await AnalyzerRecognitionSession.isReady(for: configuration.locale)
            guard token == sessionToken else { throw CancellationError() }
        }
        guard SFSpeechRecognizer(locale: configuration.locale) != nil || usesAnalyzer else {
            throw DictationError.unsupportedLanguage(configuration.locale.identifier)
        }
        try startAudio()
        isRunning = true
        isListeningPaused = false
        cloudFailed = false
        startRecognition(withPreroll: false)
        onEvent?(.listening)
    }

    public func stop() {
        sessionToken += 1
        pendingTurnEnd?.cancel()
        pendingTurnEnd = nil
        guard isRunning || audio != nil else { return }
        cancelSpeech()
        stopRecognition()
        stopAudio()
        let wasRunning = isRunning
        isRunning = false
        if wasRunning { onEvent?(.stopped) }
    }

    private func startAudio() throws {
        let graph = try LiveAudioGraph(router: router) { [weak self] in
            self?.outputChanged()
        } onOutputLevel: { [weak self] level in
            self?.outputLevel(level)
        } onInputLevel: { [weak self] level in
            self?.inputLevel(level)
        }
        audio = graph
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: graph.engine, queue: nil,
            using: Self.makeConfigurationHandler { [weak self] in self?.audioConfigurationChanged()
            })
    }

    private func stopAudio() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        audio?.shutDown()
        audio = nil
    }

    private nonisolated static func makeConfigurationHandler(
        _ handle: @escaping @MainActor @Sendable () -> Void
    ) -> @Sendable (Notification) -> Void {
        { _ in Task { @MainActor in handle() } }
    }

    /// The audio devices changed (headphones plugged in, a new default microphone): the
    /// engine stopped, so build it again.
    private func audioConfigurationChanged() {
        guard isRunning else { return }
        cancelSpeech()
        stopAudio()
        do {
            try startAudio()
            startRecognition(withPreroll: false)
        } catch {
            onEvent?(.error(message: error.localizedDescription, isFatal: true))
            stop()
        }
    }

    // MARK: - Listening

    public func pauseListening() {
        isListeningPaused = true
        lastPartial = ""
    }

    public func resumeListening() {
        isListeningPaused = false
        startRecognition(withPreroll: false)
    }

    public func endTurn() {
        guard isRunning, pendingTurnEnd == nil else { return }
        // The recogniser lags the voice a little; let the last words arrive.
        pendingTurnEnd = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            self.pendingTurnEnd = nil
            let text = self.transcript
            self.startRecognition(withPreroll: false)
            self.onEvent?(.turn(text))
        }
    }

    private var transcript: String {
        [turnPrefix, sessionText].filter { !$0.isEmpty }.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Starts a fresh recognition session for a new turn. With `withPreroll`, the last
    /// moment of audio is replayed into it, so the first words of a barge-in are not lost.
    private func startRecognition(withPreroll: Bool) {
        stopRecognition()
        detector.reset()
        turnPrefix = ""
        sessionText = ""
        lastPartial = ""
        guard isRunning, audio != nil else { return }
        let session = makeRecognitionSession()
        recognition = session
        recognitionStartedAt = now
        session.onResult = { [weak self, weak session] text, isFinal in
            guard let self, let session, session === self.recognition else { return }
            self.recognized(text, isFinal: isFinal)
        }
        session.onEnd = { [weak self, weak session] in
            guard let self, let session, session === self.recognition else { return }
            self.recognitionEnded()
        }
        router.setTarget(session.feed, withPreroll: withPreroll)
        Task { [weak self] in
            do {
                try await session.start()
            } catch {
                guard let self, session === self.recognition else { return }
                if self.usesAnalyzer {
                    // Fall back to Apple Speech for the rest of the session.
                    self.usesAnalyzer = false
                    self.startRecognition(withPreroll: withPreroll)
                } else {
                    self.onEvent?(.error(message: error.localizedDescription, isFatal: true))
                    self.stop()
                }
            }
        }
    }

    private func makeRecognitionSession() -> any LiveRecognitionSession {
        if usesAnalyzer, #available(macOS 26, *) {
            return AnalyzerRecognitionSession(locale: recognitionLocale)
        }
        return SpeechRecognizerSession(locale: recognitionLocale)
    }

    private func stopRecognition() {
        router.setTarget(nil, withPreroll: false)
        recognition?.cancel()
        recognition = nil
    }

    private func recognized(_ text: String, isFinal: Bool) {
        guard isRunning else { return }
        // While Momo talks, whatever is recognised is Momo's own echo unless the user barged in.
        guard !isOutputActive || isBargingIn, !isListeningPaused else { return }
        sessionText = text
        let words = transcript
        if detector.update(transcript: words, at: now) == .speechStarted {
            onEvent?(.speechStarted)
        }
        if words != lastPartial, !words.isEmpty {
            lastPartial = words
            onEvent?(.partial(words))
        }
        if isFinal {
            // The recogniser closed its session mid-turn; keep the words and go on.
            continueTurnInNewSession()
        }
    }

    private func recognitionEnded() {
        guard isRunning else { return }
        if detector.hasSpeech {
            continueTurnInNewSession()
        } else {
            startRecognition(withPreroll: false)
        }
    }

    /// Replaces the recognition session without ending the turn.
    private func continueTurnInNewSession() {
        let prefix = transcript
        let detectorState = detector
        let partial = lastPartial
        startRecognition(withPreroll: false)
        turnPrefix = prefix
        detector = detectorState
        lastPartial = partial
    }

    private func inputLevel(_ level: Double) {
        guard isRunning else { return }
        onEvent?(.level(level))
        let active = isOutputActive
        let event = detector.process(
            level: level, at: now, isOutputActive: active && configuration.allowsBargeIn)
        switch event {
        case .speechStarted:
            if active {
                guard configuration.allowsBargeIn, let id = utterances.first?.id else { break }
                onEvent?(.speechStarted)
                cancelSpeech()
                onEvent?(.interrupted(id: id))
                // Recognise from just before the user started, without Momo's echo.
                let state = detector
                startRecognition(withPreroll: true)
                detector = state
                isBargingIn = true
            } else {
                onEvent?(.speechStarted)
            }
        case .endOfTurn:
            let text = transcript
            startRecognition(withPreroll: false)
            isBargingIn = false
            if !isListeningPaused, !text.isEmpty { onEvent?(.turn(text)) }
        case .discarded:
            startRecognition(withPreroll: false)
            isBargingIn = false
        case .none:
            // Recognition sessions are limited in length; renew an idle one now and then.
            if !detector.hasSpeech, now - recognitionStartedAt > 50 {
                startRecognition(withPreroll: false)
            }
        }
    }

    // MARK: - Speaking

    /// Whether Momo is talking: an utterance has started and not finished.
    private var isOutputActive: Bool { utterances.contains(where: \.hasStarted) }

    public func speak(id: String, text: String, isFinal: Bool) {
        guard isRunning else { return }
        let index: Int
        if let existing = utterances.firstIndex(where: { $0.id == id }) {
            index = existing
        } else {
            utterances.append(LiveUtterance(id: id))
            index = utterances.count - 1
        }
        var sentences = utterances[index].splitter.append(text)
        sentences +=
            isFinal
            ? utterances[index].splitter.flush() : utterances[index].splitter.flushIfComplete()
        if isFinal { utterances[index].isFinal = true }
        for sentence in sentences {
            if utterances[index].language == nil, sentence.count >= 16 {
                utterances[index].language = SpeechText.language(of: sentence)
            }
            utterances[index].pendingSentences += 1
            queue.append((id, sentence))
        }
        startWorker()
        outputChanged()
    }

    public func cancelSpeech() {
        worker?.cancel()
        worker = nil
        queue.removeAll()
        utterances.removeAll()
        synthesisRelay.cancelCurrent()
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        audio?.scheduler.cancel()
        isBargingIn = false
    }

    private func startWorker() {
        guard worker == nil, !queue.isEmpty else { return }
        workerToken += 1
        let token = workerToken
        worker = Task { [weak self] in
            await self?.work(token: token)
        }
    }

    private func work(token: Int) async {
        while !Task.isCancelled, !queue.isEmpty, let scheduler = audio?.scheduler {
            let item = queue.removeFirst()
            let generation = scheduler.generation
            let language =
                utterances.first { $0.id == item.id }?.language
                ?? configuration.locale.language.languageCode?.identifier ?? "en"
            await render(item.text, id: item.id, language: language, scheduler: scheduler)
            guard !Task.isCancelled, generation == scheduler.generation else { return }
            if let index = utterances.firstIndex(where: { $0.id == item.id }) {
                utterances[index].pendingSentences -= 1
            }
            outputChanged()
        }
        guard token == workerToken else { return }
        worker = nil
        startWorker()
    }

    private func render(
        _ text: String, id: String, language: String, scheduler: LivePlaybackScheduler
    ) async {
        if case .openAI(let request) = configuration.voice, !cloudFailed {
            do {
                onCloudSpeech?(request.displayName, text.count)
                try await renderCloud(text, request: request, id: id, scheduler: scheduler)
                return
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                cloudFailed = true

                onEvent?(.error(message: error.localizedDescription, isFatal: false))
            }
        }
        await renderApple(text, id: id, language: language, scheduler: scheduler)
    }

    private func renderApple(
        _ text: String, id: String, language: String, scheduler: LivePlaybackScheduler
    ) async {
        let utterance = AVSpeechUtterance(string: text)
        var preferred: String?
        var rate: Float = 1
        if case .apple(let identifier, let chosenRate) = configuration.voice {
            preferred = identifier
            rate = chosenRate
        }
        if let descriptor = VoiceDescriptor.best(
            for: language, among: SpeechSynthesizer.voices, preferredID: preferred),
            let voice = AVSpeechSynthesisVoice(identifier: descriptor.id)
        {
            utterance.voice = voice
        } else {
            utterance.voice = AVSpeechSynthesisVoice(language: language)
        }
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * min(1.5, max(0.5, rate))
        utterance.prefersAssistiveTechnologySettings = true
        let render = SynthesisRender(
            scheduler: scheduler, id: id, generation: scheduler.generation)
        synthesisRelay.current = render
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                render.begin(continuation)
                synthesizer.write(utterance, toBufferCallback: Self.makeBufferCallback(render))
                render.startWatchdog()
            }
        } onCancel: {
            render.finish()
        }
        synthesisRelay.clear(render)
    }

    private nonisolated static func makeBufferCallback(
        _ render: SynthesisRender
    ) -> AVSpeechSynthesizer.BufferCallback {
        { buffer in render.receive(buffer) }
    }

    private func renderCloud(
        _ text: String, request: OpenAISpeechRequest, id: String,
        scheduler: LivePlaybackScheduler
    ) async throws {
        let generation = scheduler.generation
        let (bytes, response) = try await session.bytes(for: request.urlRequest(for: text))
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw CloudVoiceError.http(status: status, body: Data())
        }
        let chunkBytes = OpenAISpeechRequest.sampleRate / 10 * 2
        var chunk = Data()
        chunk.reserveCapacity(chunkBytes)
        var played = false
        for try await byte in bytes {
            try Task.checkCancellation()
            chunk.append(byte)
            if chunk.count >= chunkBytes {
                played = scheduler.schedulePCM16(chunk, id: id, generation: generation) || played
                chunk.removeAll(keepingCapacity: true)
            }
        }
        if chunk.count >= 2 {
            played = scheduler.schedulePCM16(chunk, id: id, generation: generation) || played
        }
        if !played, generation == scheduler.generation {
            throw CloudVoiceError("The voice service sent no audio.")
        }
    }

    /// Reports started and finished utterances as playback moves on. Utterances play in
    /// order, so only the first one can be playing.
    private func outputChanged() {
        guard let scheduler = audio?.scheduler else { return }
        while let head = utterances.first {
            let counts = scheduler.counts(for: head.id)
            if !head.hasStarted, counts.scheduled > 0 {
                utterances[0].hasStarted = true
                onEvent?(.speakingStarted(id: head.id))
            }
            guard head.isFinal, head.pendingSentences == 0, counts.played >= counts.scheduled
            else { return }
            if !utterances[0].hasStarted { onEvent?(.speakingStarted(id: head.id)) }
            utterances.removeFirst()
            scheduler.forget(head.id)
            onEvent?(.mouth(0))
            onEvent?(.speakingFinished(id: head.id))
            if !isOutputActive, !isBargingIn, !detector.hasSpeech {
                // Whatever was recognised meanwhile was Momo's own voice.
                startRecognition(withPreroll: false)
            }
        }
    }

    private func outputLevel(_ level: Double) {
        guard isOutputActive else { return }
        onEvent?(.mouth(level))
    }
}

// MARK: - Utterances

/// An utterance being spoken, in the order utterances play.
private struct LiveUtterance {
    var id: String
    var splitter = SpeechSentenceSplitter()
    var language: String?
    var isFinal = false
    var hasStarted = false
    /// Sentences queued or rendering.
    var pendingSentences = 0
}

extension OpenAISpeechRequest {
    /// The name shown in the privacy log.
    public var displayName: String { "OpenAI \(model) (\(voice))" }
}

// MARK: - Audio graph

/// The audio engine of a live session: the microphone with voice processing, and a player
/// for Momo's voice on the same engine.
@MainActor
private final class LiveAudioGraph {
    let engine = AVAudioEngine()
    let player: AVAudioPlayerNode
    let scheduler: LivePlaybackScheduler

    init(
        router: LiveInputRouter, onOutputChange: @escaping @MainActor @Sendable () -> Void,
        onOutputLevel: @escaping @MainActor @Sendable (Double) -> Void,
        onInputLevel: @escaping @MainActor @Sendable (Double) -> Void
    ) throws {
        let player = AVAudioPlayerNode()
        self.player = player
        guard
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: Double(OpenAISpeechRequest.sampleRate), channels: 1,
                interleaved: false)
        else { throw DictationError.unavailable }
        scheduler = LivePlaybackScheduler(
            player: player, format: format,
            onChange: Self.mainActorRelay(onOutputChange))
        let input = engine.inputNode
        // Echo cancellation: Momo's voice, played by this engine, is removed from the input.
        try input.setVoiceProcessingEnabled(true)
        input.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false, duckingLevel: .min)
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)

        router.levels = LevelReporter(Self.levelRelay(onInputLevel))
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            try? input.setVoiceProcessingEnabled(false)
            throw DictationError.unavailable
        }
        input.installTap(
            onBus: 0, bufferSize: 1024, format: inputFormat, block: Self.makeInputTap(router))
        player.installTap(
            onBus: 0, bufferSize: 1024, format: nil,
            block: Self.makeOutputTap(LevelReporter(Self.levelRelay(onOutputLevel))))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            player.removeTap(onBus: 0)
            try? input.setVoiceProcessingEnabled(false)
            throw error
        }
        player.play()
    }

    func shutDown() {
        scheduler.cancel(restart: false)
        engine.inputNode.removeTap(onBus: 0)
        player.removeTap(onBus: 0)
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
    }

    // Audio callbacks run on the audio thread, so they must not inherit main actor isolation.

    private nonisolated static func makeInputTap(_ router: LiveInputRouter) -> AVAudioNodeTapBlock {
        { buffer, _ in router.receive(buffer) }
    }

    private nonisolated static func makeOutputTap(_ levels: LevelReporter) -> AVAudioNodeTapBlock {
        { buffer, _ in levels.report(buffer) }
    }

    private nonisolated static func levelRelay(
        _ handle: @escaping @MainActor @Sendable (Double) -> Void
    ) -> @Sendable (Double) -> Void {
        { level in Task { @MainActor in handle(level) } }
    }

    private nonisolated static func mainActorRelay(
        _ handle: @escaping @MainActor @Sendable () -> Void
    ) -> @Sendable () -> Void {
        { Task { @MainActor in handle() } }
    }
}

/// Passes microphone audio from the audio thread to the current recognition session, as
/// mono buffers, keeping the last moment for barge-in.
final class LiveInputRouter: @unchecked Sendable {
    private let lock = NSLock()
    private var target: (@Sendable (AVAudioPCMBuffer) -> Void)?
    private var preroll: [AVAudioPCMBuffer] = []
    private var prerollFrames: AVAudioFrameCount = 0
    /// How much audio is kept for barge-in, in seconds.
    private let prerollSeconds = 0.5
    private var _levels: LevelReporter?

    var levels: LevelReporter? {
        get { lock.withLock { _levels } }
        set { lock.withLock { _levels = newValue } }
    }

    /// Sends audio to `target` from now on; with `withPreroll`, the kept audio first.
    func setTarget(_ target: (@Sendable (AVAudioPCMBuffer) -> Void)?, withPreroll: Bool) {
        lock.withLock {
            self.target = target
            if withPreroll, let target {
                for buffer in preroll { target(buffer) }
            }
        }
    }

    func receive(_ buffer: AVAudioPCMBuffer) {
        guard let mono = Self.mono(buffer) else { return }
        lock.withLock {
            _levels?.report(mono)
            preroll.append(mono)
            prerollFrames += mono.frameLength
            let limit = AVAudioFrameCount(mono.format.sampleRate * prerollSeconds)
            while prerollFrames > limit, let first = preroll.first {
                prerollFrames -= first.frameLength
                preroll.removeFirst()
            }
            target?(mono)
        }
    }

    /// The first channel of `buffer` as a new mono float buffer. Voice processing can deliver
    /// several channels, and the tap's buffer is reused after the tap returns.
    static func mono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0, let source = buffer.floatChannelData?[0],
            let format = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                channels: 1, interleaved: false),
            let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
            let destination = copy.floatChannelData?[0]
        else { return nil }
        copy.frameLength = buffer.frameLength
        let stride = buffer.format.isInterleaved ? Int(buffer.format.channelCount) : 1
        for frame in 0..<Int(buffer.frameLength) {
            destination[frame] = source[frame * stride]
        }
        return copy
    }
}

/// Schedules Momo's voice on the player from any thread and counts, per utterance, what was
/// scheduled and what has played. Cancelling bumps the generation, so audio still being
/// rendered for the old one is dropped.
final class LivePlaybackScheduler: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private let player: AVAudioPlayerNode
    let format: AVAudioFormat
    private let onChange: @Sendable () -> Void
    private var _generation = 0
    private var scheduled: [String: Int] = [:]
    private var played: [String: Int] = [:]

    init(player: AVAudioPlayerNode, format: AVAudioFormat, onChange: @escaping @Sendable () -> Void)
    {
        self.player = player
        self.format = format
        self.onChange = onChange
    }

    var generation: Int { lock.withLock { _generation } }

    /// What was scheduled and has played for the utterance `id`.
    func counts(for id: String) -> (scheduled: Int, played: Int) {
        lock.withLock { (scheduled[id] ?? 0, played[id] ?? 0) }
    }

    func forget(_ id: String) {
        lock.withLock {
            scheduled[id] = nil
            played[id] = nil
        }
    }

    /// Stops playback at once and drops everything scheduled.
    func cancel(restart: Bool = true) {
        lock.withLock {
            _generation += 1
            scheduled.removeAll()
            played.removeAll()
            player.stop()
            if restart, player.engine?.isRunning == true { player.play() }
        }
    }

    /// Schedules a buffer in ``format``. Returns `false` when it belongs to a cancelled
    /// generation.
    @discardableResult
    func schedule(_ buffer: AVAudioPCMBuffer, id: String, generation: Int) -> Bool {
        let accepted: Bool = lock.withLock {
            guard generation == _generation, buffer.frameLength > 0 else { return false }
            scheduled[id, default: 0] += 1
            player.scheduleBuffer(
                buffer, completionCallbackType: .dataPlayedBack,
                completionHandler: Self.makeCompletion(self, id: id, generation: generation))
            return true
        }
        if accepted { onChange() }
        return accepted
    }

    /// Schedules 16-bit little-endian PCM at 24 kHz, as OpenAI streams it.
    func schedulePCM16(_ data: Data, id: String, generation: Int) -> Bool {
        let samples = WAVEncoder.samples(fromPCM16: data)
        guard !samples.isEmpty,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
            let channel = buffer.floatChannelData?[0]
        else { return false }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let base = source.baseAddress { channel.update(from: base, count: samples.count) }
        }
        return schedule(buffer, id: id, generation: generation)
    }

    private func played(_ id: String, generation: Int) {
        let counted: Bool = lock.withLock {
            guard generation == _generation, scheduled[id] != nil else { return false }
            played[id, default: 0] += 1
            return true
        }
        if counted { onChange() }
    }

    private static func makeCompletion(
        _ scheduler: LivePlaybackScheduler, id: String, generation: Int
    ) -> @Sendable (AVAudioPlayerNodeCompletionCallbackType) -> Void {
        { [weak scheduler] _ in scheduler?.played(id, generation: generation) }
    }
}

// MARK: - Synthesis

/// Receives `AVSpeechSynthesizer` delegate callbacks off the main actor and ends the current
/// render when the synthesizer finishes or is stopped.
private final class SynthesisRelay: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _current: SynthesisRender?

    var current: SynthesisRender? {
        get { lock.withLock { _current } }
        set { lock.withLock { _current = newValue } }
    }

    func clear(_ render: SynthesisRender) {
        lock.withLock { if _current === render { _current = nil } }
    }

    func cancelCurrent() {
        current?.finish()
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance
    ) {
        // The last buffer normally ends the render; this is a backup in case it never comes.
        let render = current
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            render?.finish()
        }
    }

    func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance
    ) {
        current?.finish()
    }
}

/// One sentence rendered by `AVSpeechSynthesizer.write`: converts each buffer to the
/// player's format, schedules it, and resumes the renderer once, when the last buffer
/// arrived, the synthesizer finished, the render was cancelled or nothing came for too long.
private final class SynthesisRender: @unchecked Sendable {
    private let lock = NSLock()
    private let scheduler: LivePlaybackScheduler
    private let id: String
    private let generation: Int
    private var converter: AVAudioConverter?
    private var continuation: CheckedContinuation<Void, Never>?
    private var isFinished = false

    init(scheduler: LivePlaybackScheduler, id: String, generation: Int) {
        self.scheduler = scheduler
        self.id = id
        self.generation = generation
    }

    func begin(_ continuation: CheckedContinuation<Void, Never>) {
        lock.withLock {
            if isFinished {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }
    }

    /// Ends the render if the synthesizer never answers, for example with a missing voice.
    func startWatchdog() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            self?.finish()
        }
    }

    func receive(_ buffer: AVAudioBuffer) {
        guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
            finish()
            return
        }
        let converted: AVAudioPCMBuffer? = lock.withLock {
            if pcm.format == scheduler.format { return Self.copy(pcm) }
            if converter == nil || converter?.inputFormat != pcm.format {
                converter = AVAudioConverter(from: pcm.format, to: scheduler.format)
                converter?.primeMethod = .none
            }
            return converter?.convertBuffer(pcm, to: scheduler.format)
        }
        if let converted { scheduler.schedule(converted, id: id, generation: generation) }
    }

    func finish() {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            isFinished = true
            let pending = self.continuation
            self.continuation = nil
            return pending
        }
        continuation?.resume()
    }

    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard
            let copy = AVAudioPCMBuffer(
                pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
            let source = buffer.floatChannelData, let destination = copy.floatChannelData
        else { return nil }
        copy.frameLength = buffer.frameLength
        for channel in 0..<Int(buffer.format.channelCount) {
            destination[channel].update(from: source[channel], count: Int(buffer.frameLength))
        }
        return copy
    }
}

// MARK: - Recognition sessions

/// One turn's speech recognition.
@MainActor
protocol LiveRecognitionSession: AnyObject {
    /// The session's transcript so far; `isFinal` when the recogniser closed the session.
    var onResult: ((String, Bool) -> Void)? { get set }
    /// The session ended on its own (an error, a time limit).
    var onEnd: (() -> Void)? { get set }
    /// Receives mono microphone buffers on the audio thread, from before ``start()``.
    var feed: @Sendable (AVAudioPCMBuffer) -> Void { get }
    func start() async throws
    func cancel()
}

/// Recognition with Apple Speech, on the device when the language allows it.
@MainActor
private final class SpeechRecognizerSession: LiveRecognitionSession {
    var onResult: ((String, Bool) -> Void)?
    var onEnd: (() -> Void)?
    let feed: @Sendable (AVAudioPCMBuffer) -> Void
    private let request: SFSpeechAudioBufferRecognitionRequest
    private let locale: Locale
    private var task: SFSpeechRecognitionTask?
    private var isCancelled = false

    init(locale: Locale) {
        self.locale = locale
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation
        self.request = request
        feed = Self.makeFeed(RequestBox(request))
    }

    // Runs on the audio thread, so it must not inherit main actor isolation.
    private nonisolated static func makeFeed(
        _ box: RequestBox
    ) -> @Sendable (AVAudioPCMBuffer) -> Void {
        { buffer in box.request.append(buffer) }
    }

    func start() async throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale) ?? SFSpeechRecognizer() else {
            throw DictationError.unsupportedLanguage(locale.identifier)
        }
        guard recognizer.isAvailable else { throw DictationError.unavailable }
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        guard !isCancelled else { return }
        task = recognizer.recognitionTask(
            with: request,
            resultHandler: Self.makeResultHandler { [weak self] text, isFinal, failed in
                Task { @MainActor in self?.handle(text: text, isFinal: isFinal, failed: failed) }
            })
    }

    private nonisolated static func makeResultHandler(
        _ handle: @escaping @Sendable (String?, Bool, Bool) -> Void
    ) -> (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            handle(
                result?.bestTranscription.formattedString, result?.isFinal ?? false, error != nil)
        }
    }

    private func handle(text: String?, isFinal: Bool, failed: Bool) {
        guard !isCancelled else { return }
        if let text { onResult?(text, isFinal) }
        if failed, !isFinal { onEnd?() }
    }

    func cancel() {
        isCancelled = true
        request.endAudio()
        task?.cancel()
        task = nil
    }
}

/// Lets the audio thread append to a recognition request, which is safe from any thread.
private final class RequestBox: @unchecked Sendable {
    let request: SFSpeechAudioBufferRecognitionRequest

    init(_ request: SFSpeechAudioBufferRecognitionRequest) {
        self.request = request
    }
}

/// Recognition with `SpeechAnalyzer` (macOS 26), used when the language's model is installed.
@available(macOS 26, *)
@MainActor
private final class AnalyzerRecognitionSession: LiveRecognitionSession {
    var onResult: ((String, Bool) -> Void)?
    var onEnd: (() -> Void)?
    let feed: @Sendable (AVAudioPCMBuffer) -> Void
    private let locale: Locale
    private let sink: AnalyzerSink
    private let stream: AsyncStream<AnalyzerInput>
    private var analyzer: SpeechAnalyzer?
    private var results: Task<Void, Never>?
    private var finalized = ""
    private var volatile = ""
    private var isCancelled = false

    init(locale: Locale) {
        self.locale = locale
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        self.stream = stream
        let sink = AnalyzerSink(continuation: continuation)
        self.sink = sink
        feed = Self.makeFeed(sink)
    }

    // Runs on the audio thread, so it must not inherit main actor isolation.
    private nonisolated static func makeFeed(
        _ sink: AnalyzerSink
    ) -> @Sendable (AVAudioPCMBuffer) -> Void {
        { buffer in sink.append(buffer) }
    }

    /// Whether the transcriber runs here and its model for `locale` is installed. Live
    /// conversation never waits for a download; without the model it uses Apple Speech.
    static func isReady(for locale: Locale) async -> Bool {
        guard SpeechTranscriber.isAvailable,
            let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        else { return false }
        let transcriber = SpeechTranscriber(
            locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults],
            attributeOptions: [])
        return await AssetInventory.status(forModules: [transcriber]) == .installed
    }

    func start() async throws {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            throw DictationError.unsupportedLanguage(locale.identifier)
        }
        let transcriber = SpeechTranscriber(
            locale: supported, transcriptionOptions: [], reportingOptions: [.volatileResults],
            attributeOptions: [])
        let modules: [any SpeechModule] = [transcriber]
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)
        else { throw DictationError.unavailable }
        guard !isCancelled else { return }
        let analyzer = SpeechAnalyzer(modules: modules)
        try await analyzer.prepareToAnalyze(in: format)
        guard !isCancelled else {
            await analyzer.cancelAndFinishNow()
            return
        }
        self.analyzer = analyzer
        sink.setFormat(format)
        results = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    self?.handle(text: String(result.text.characters), isFinal: result.isFinal)
                }
            } catch {}
            self?.resultsEnded()
        }
        try await analyzer.start(inputSequence: stream)
    }

    private func handle(text: String, isFinal: Bool) {
        guard !isCancelled else { return }
        if isFinal {
            finalized += text
            volatile = ""
        } else {
            volatile = text
        }
        onResult?((finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines), false)
    }

    private func resultsEnded() {
        guard !isCancelled else { return }
        onEnd?()
    }

    func cancel() {
        isCancelled = true
        sink.finish()
        results?.cancel()
        results = nil
        let analyzer = analyzer
        self.analyzer = nil
        Task { await analyzer?.cancelAndFinishNow() }
    }
}

/// Converts microphone buffers to the analyzer's format on the audio thread, holding them
/// until the format is known.
@available(macOS 26, *)
private final class AnalyzerSink: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncStream<AnalyzerInput>.Continuation
    private var format: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var pending: [AVAudioPCMBuffer] = []

    init(continuation: AsyncStream<AnalyzerInput>.Continuation) {
        self.continuation = continuation
    }

    func setFormat(_ format: AVAudioFormat) {
        lock.withLock {
            self.format = format
            for buffer in pending { yield(buffer, format: format) }
            pending.removeAll()
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard let format else {
                pending.append(buffer)
                // Never hold more than about ten seconds.
                if pending.count > 500 { pending.removeFirst() }
                return
            }
            yield(buffer, format: format)
        }
    }

    func finish() {
        continuation.finish()
    }

    private func yield(_ buffer: AVAudioPCMBuffer, format: AVAudioFormat) {
        if buffer.format == format {
            continuation.yield(AnalyzerInput(buffer: buffer))
            return
        }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: format)
            converter?.primeMethod = .none
        }
        guard let output = converter?.convertBuffer(buffer, to: format) else { return }
        continuation.yield(AnalyzerInput(buffer: output))
    }
}
