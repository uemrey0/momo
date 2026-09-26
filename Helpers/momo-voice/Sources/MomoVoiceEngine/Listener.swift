import Foundation
import MomoLiveProtocol
import MomoVoiceCore
@preconcurrency import NemotronStreamingASR
@preconcurrency import SpeechVAD

/// Turns microphone audio into `speechStarted`, `partial`, `turn` and `level` events.
///
/// Silero VAD finds speech; after a short pause Smart Turn listens to how the sentence ended
/// and either ends the turn or waits, up to `maximumPause`. Speech is transcribed by a
/// streaming Nemotron session while the user talks, so partial words appear live and the
/// final text is ready right after the turn ends. Everything runs on one serial queue.
final class Listener: @unchecked Sendable {
    /// What the listener needs from the speaker.
    struct SpeakerControl: Sendable {
        /// Stops playback at once; returns the utterance that was playing.
        var interrupt: @Sendable () -> String?
    }

    private static let sampleRate = 16_000
    /// Audio kept from before the detector confirmed speech, so the first word is not cut.
    private static let preRollSeconds = 0.4
    private static let levelInterval = 1_600  // 100 ms
    /// Silence fed to a new recognition session before speech.
    private static let primingSeconds = 1.0
    /// Silence fed after speech, so the recognizer's look-ahead releases the last word.
    private static let flushingSeconds = 0.32

    private let queue = DispatchQueue(label: "momo-voice.listen", qos: .userInitiated)
    private let vad: StreamingVADProcessor
    private let recognizer: NemotronStreamingASRModel
    private let language: String
    private let emit: @Sendable (LiveVoiceEvent) -> Void
    private let speaker: SpeakerControl

    // State below is only touched on `queue`.
    private var bargeIn: BargeInController
    private var isPaused = false
    private var isInSpeech = false
    private var session: StreamingSession?
    /// A session fed with silence ahead of time. Nemotron drops the first words of a
    /// session that starts cold on speech; a second of silence first fixes that.
    private var primedSession: StreamingSession?
    private var lastPartial = ""
    private var history: [Float] = []
    private var processedSamples = 0
    private var levelSamples: [Float] = []
    private var speechStartTime: Date?
    /// When the current speech began, in seconds of session audio.
    private var speechOnset: Double = 0
    private var partialLatencyLogged = false

    init(
        vad: SileroVADModel, turnDetector: SmartTurnModel, recognizer: NemotronStreamingASRModel,
        configuration: LiveSessionConfiguration, recognitionLanguage: String,
        emit: @escaping @Sendable (LiveVoiceEvent) -> Void, speaker: SpeakerControl
    ) {
        vad.resetState()
        self.vad = StreamingVADProcessor(
            model: vad,
            config: VADConfig(
                onset: 0.5, offset: 0.35, minSpeechDuration: 0.25, minSilenceDuration: 0.3,
                windowDuration: 0.032, stepRatio: 1),
            turnCompletion: turnDetector,
            turnCompletionConfig: TurnCompletionConfig(
                threshold: 0.5, maxSilenceDuration: Float(max(0.3, configuration.maximumPause)),
                preRollDuration: 0.5))
        self.recognizer = recognizer
        self.language = recognitionLanguage
        self.emit = emit
        self.speaker = speaker
        bargeIn = BargeInController(allowsBargeIn: configuration.allowsBargeIn)
    }

    /// Adds 16 kHz microphone samples. Called from the audio thread; returns at once.
    func push(_ samples: [Float]) {
        queue.async { [self] in process(samples) }
    }

    func setPaused(_ paused: Bool) {
        queue.async { [self] in
            isPaused = paused
            if paused { endTranscription(emitTurn: false) }
        }
    }

    func playbackStarted(id: String) {
        queue.async { [self] in bargeIn.playbackStarted(id: id) }
    }

    func playbackStopped() {
        queue.async { [self] in perform(bargeIn.playbackStopped()) }
    }

    /// Waits for queued audio to be processed, for a clean stop.
    func drain() {
        queue.sync {}
    }

    private func process(_ samples: [Float]) {
        remember(samples)
        reportLevel(samples)
        let existingSession = session
        for event in vad.process(samples: samples) {
            switch event {
            case .speechStarted(let time):
                isInSpeech = true
                speechStartTime = Date()
                speechOnset = Double(time)
                partialLatencyLogged = false
                perform(bargeIn.speechStarted(at: Double(time)))
            case .speechEnded(let segment):
                isInSpeech = false
                let pause = Int((vad.currentTime - segment.endTime) * 1000)
                let probability =
                    vad.lastTurnCompletionProbability.map { String(format: "%.2f", $0) } ?? "-"
                Log.info("Speech ended after a \(pause) ms pause (turn probability \(probability))")
                let wasInTurn = bargeIn.isInTurn
                perform(bargeIn.speechEnded())
                if wasInTurn { endTranscription(emitTurn: true) }
            }
        }
        if isInSpeech {
            perform(bargeIn.speechContinues(at: Double(vad.currentTime)))
        }
        // A session that began during this chunk was already fed it from the history.
        if let existingSession, existingSession === session {
            transcribe(samples, with: existingSession)
        }
    }

    private func perform(_ actions: [BargeInController.Action]) {
        for action in actions {
            switch action {
            case .interrupt:
                if let id = speaker.interrupt() {
                    emit(.interrupted(id: id))
                }
            case .beginTurn:
                emit(.speechStarted)
                beginTranscription()
            case .discardSpeech:
                Log.info("Ignored speech during playback as echo")
            }
        }
    }

    /// Starts a recognition session and feeds it the audio since speech began.
    private func beginTranscription() {
        guard !isPaused, session == nil else { return }
        do {
            let newSession = try primedSession ?? makePrimedSession()
            primedSession = nil
            session = newSession
            lastPartial = ""
            let from = max(0, Int((speechOnset - Self.preRollSeconds) * Double(Self.sampleRate)))
            let firstKept = processedSamples - history.count
            let offset = max(0, from - firstKept)
            if offset < history.count {
                transcribe(Array(history[offset...]), with: newSession)
            }
        } catch {
            emit(.error(message: "Speech recognition failed: \(error)", isFatal: false))
        }
    }

    /// A new session that has already heard a moment of silence.
    private func makePrimedSession() throws -> StreamingSession {
        let session = try recognizer.createSession(language: language)
        _ = try session.pushAudio(
            [Float](repeating: 0, count: Int(Self.primingSeconds * Double(Self.sampleRate))))
        return session
    }

    /// Prepares the session for the next turn while the user is quiet.
    func prepare() {
        queue.async { [self] in
            if primedSession == nil { primedSession = try? makePrimedSession() }
        }
    }

    private func transcribe(_ samples: [Float], with session: StreamingSession) {
        do {
            for partial in try session.pushAudio(samples) {
                report(partial.text)
            }
        } catch {
            emit(.error(message: "Speech recognition failed: \(error)", isFatal: false))
            self.session = nil
        }
    }

    private func report(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != lastPartial else { return }
        lastPartial = trimmed
        if !partialLatencyLogged, let speechStartTime {
            partialLatencyLogged = true
            Log.info(
                "First partial \(Int(Date().timeIntervalSince(speechStartTime) * 1000)) ms after speech was confirmed"
            )
        }
        emit(.partial(trimmed))
    }

    private func endTranscription(emitTurn: Bool) {
        guard let session else { return }
        self.session = nil
        // Ready the next turn's session once this one is reported.
        defer { if primedSession == nil { primedSession = try? makePrimedSession() } }
        guard emitTurn else { return }
        let start = Date()
        do {
            for partial in try session.pushAudio(
                [Float](repeating: 0, count: Int(Self.flushingSeconds * Double(Self.sampleRate))))
            {
                lastPartial = partial.text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let text =
                try session.finalize().last?.text.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? lastPartial
            Log.info(
                "Turn ended; final text took \(Int(Date().timeIntervalSince(start) * 1000)) ms")
            if !text.isEmpty {
                emit(.turn(text))
            }
        } catch {
            if !lastPartial.isEmpty { emit(.turn(lastPartial)) }
            emit(.error(message: "Speech recognition failed: \(error)", isFatal: false))
        }
        lastPartial = ""
    }

    private func remember(_ samples: [Float]) {
        processedSamples += samples.count
        history += samples
        let keep = Self.sampleRate * 3
        if history.count > keep { history.removeFirst(history.count - keep) }
    }

    private func reportLevel(_ samples: [Float]) {
        levelSamples += samples
        guard levelSamples.count >= Self.levelInterval else { return }
        emit(.level(AudioLevel.normalized(rms: AudioLevel.rms(levelSamples))))
        levelSamples.removeAll(keepingCapacity: true)
    }
}
