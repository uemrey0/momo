@preconcurrency import AVFoundation
import Foundation
@preconcurrency import KokoroTTS
import MomoLiveProtocol
import MomoVoiceCore
@preconcurrency import NemotronStreamingASR
@preconcurrency import SpeechVAD
@preconcurrency import SupertonicTTS

/// The live voice engine behind the protocol: model management and the audio session.
public actor VoiceEngine: LiveVoiceBackend {
    private let store: ModelStore
    private let emit: @Sendable (LiveVoiceEvent) -> Void
    private let loaded = LoadedModels()
    private var session: LiveSession?

    /// - Parameters:
    ///   - store: Where models live.
    ///   - emit: Writes one event to Momo. Called from any thread.
    public init(
        store: ModelStore = ModelStore(), emit: @escaping @Sendable (LiveVoiceEvent) -> Void
    ) {
        self.store = store
        self.emit = emit
    }

    // MARK: Models

    public func supportedLanguages() async -> [String] {
        ModelSelection.supportedLanguages
    }

    public func models(locale: String) async -> [LiveModelInfo] {
        let required = Set(ModelSelection.plan(locale: locale)?.requiredModelIDs ?? [])
        return ModelCatalog.all.map {
            $0.info(isDownloaded: store.isDownloaded($0), isRequired: required.contains($0.id))
        }
    }

    public func downloadModels(ids: [String]) async {
        for id in ids {
            guard let model = ModelCatalog.model(id: id) else {
                emit(.downloadFailed(id: id, message: "Unknown model \(id)."))
                continue
            }
            if store.isDownloaded(model) {
                emit(.downloadProgress(id: id, fraction: 1))
                emit(.downloadFinished(id: id))
                continue
            }
            let throttle = ProgressThrottle()
            let emit = emit
            Log.info("Downloading \(id) from \(model.repository)")
            do {
                emit(.downloadProgress(id: id, fraction: 0))
                try await store.download(model) { fraction in
                    if throttle.shouldReport(fraction) {
                        emit(.downloadProgress(id: id, fraction: fraction))
                    }
                }
                emit(.downloadProgress(id: id, fraction: 1))
                emit(.downloadFinished(id: id))
                Log.info("Downloaded \(id)")
            } catch {
                Log.error("Download of \(id) failed: \(error)")
                emit(.downloadFailed(id: id, message: String(describing: error)))
            }
        }
    }

    public func deleteModels(ids: [String]) async throws {
        for id in ids {
            guard let model = ModelCatalog.model(id: id) else {
                throw VoiceEngineError.unknownModel(id)
            }
            loaded.forget(id)
            try store.delete(model)
            Log.info("Deleted \(id)")
        }
    }

    // MARK: Session

    /// Loads and warms up the models of a session, without opening the microphone, so the
    /// Core ML compilation a new helper build needs happens before the user waits on it.
    public func prepare(_ configuration: LiveSessionConfiguration) async throws {
        let startedAt = Date()
        let plan = try ModelSelection.plan(for: configuration)
        try checkDownloaded(plan)
        _ = try await loaded.vad(store: store)
        _ = try await loaded.turnDetector(store: store)
        _ = try await loaded.recognizer(store: store)
        _ = try await loaded.synthesizer(for: plan.output, store: store)
        Log.info("Prepared in \(Int(Date().timeIntervalSince(startedAt) * 1000)) ms")
    }

    private func checkDownloaded(_ plan: VoicePlan) throws {
        let missing = plan.requiredModelIDs.filter { id in
            ModelCatalog.model(id: id).map { !store.isDownloaded($0) } ?? true
        }
        guard missing.isEmpty else { throw VoiceEngineError.modelsMissing(missing) }
    }

    public func start(_ configuration: LiveSessionConfiguration) async throws {
        await stop(reportStopped: false)
        let startedAt = Date()
        let plan = try ModelSelection.plan(for: configuration)
        try checkDownloaded(plan)
        try await Self.requestMicrophoneAccess()

        let vad = try await loaded.vad(store: store)
        let turnDetector = try await loaded.turnDetector(store: store)
        let recognizer = try await loaded.recognizer(store: store)
        let synthesizer = try await loaded.synthesizer(for: plan.output, store: store)
        Log.info("Models ready in \(Int(Date().timeIntervalSince(startedAt) * 1000)) ms")

        let audio = AudioIO()
        let listenerBox = ListenerBox()
        let maximumPieceLength =
            if case .kokoro = plan.output { KokoroSynthesizer.maximumPieceLength } else { 180 }
        let speaker = Speaker(
            audio: audio, synthesizer: synthesizer, maximumPieceLength: maximumPieceLength,
            emit: emit,
            observer: Speaker.Observer(
                started: { listenerBox.listener?.playbackStarted(id: $0) },
                stopped: { listenerBox.listener?.playbackStopped() }))
        let listener = Listener(
            vad: vad, turnDetector: turnDetector, recognizer: recognizer,
            configuration: configuration, recognitionLanguage: plan.recognitionLanguage, emit: emit,
            speaker: Listener.SpeakerControl(interrupt: { [weak speaker] in speaker?.cancel() }))
        listenerBox.listener = listener
        listener.prepare()
        try audio.start(capture: { listener.push($0) })
        session = LiveSession(audio: audio, listener: listener, speaker: speaker)
        Log.info(
            "Listening in \(plan.recognitionLanguage), speaking with \(plan.output), after \(Int(Date().timeIntervalSince(startedAt) * 1000)) ms"
        )
        emit(.listening)
    }

    public func stop() async {
        await stop(reportStopped: true)
    }

    private func stop(reportStopped: Bool) async {
        guard let session else { return }
        self.session = nil
        session.speaker.cancel()
        session.audio.stop()
        session.listener.drain()
        if reportStopped { emit(.stopped) }
    }

    public func speak(id: String, text: String, isFinal: Bool) async {
        guard let session else {
            emit(.error(message: "No live session is running.", isFatal: false))
            return
        }
        session.speaker.speak(id: id, text: text, isFinal: isFinal)
    }

    public func cancelSpeech() async {
        session?.speaker.cancel()
    }

    public func setListeningPaused(_ isPaused: Bool) async {
        session?.listener.setPaused(isPaused)
    }

    // MARK: Command line

    /// Synthesises and plays `text` without listening, for `--say`. Returns the time to first
    /// audio and the real-time factor of each piece through the log.
    public func say(_ text: String, configuration: LiveSessionConfiguration) async throws {
        let plan = try ModelSelection.plan(for: configuration)
        if let id = plan.output.modelID, let model = ModelCatalog.model(id: id),
            !store.isDownloaded(model)
        {
            throw VoiceEngineError.modelsMissing([id])
        }
        let synthesizer = try await loaded.synthesizer(for: plan.output, store: store)
        let audio = AudioIO()
        let finished = AsyncStream<Void>.makeStream()
        let maximumPieceLength =
            if case .kokoro = plan.output { KokoroSynthesizer.maximumPieceLength } else { 180 }
        let emit = emit
        let requested = RequestClock()
        let speaker = Speaker(
            audio: audio, synthesizer: synthesizer, maximumPieceLength: maximumPieceLength,
            emit: { event in
                emit(event)
                if case .speakingStarted = event {
                    Log.info("First audio \(requested.milliseconds) ms after the request")
                }
                if case .speakingFinished = event { finished.continuation.finish() }
            },
            observer: Speaker.Observer(started: { _ in }, stopped: {}))
        try audio.start(capture: { _ in })
        requested.reset()
        speaker.speak(id: "say", text: text, isFinal: true)
        for await _ in finished.stream {}
        Log.info("Spoke in \(requested.milliseconds) ms in total")
        audio.stop()
    }

    private static func requestMicrophoneAccess() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return }
            throw VoiceEngineError.microphoneDenied
        default:
            throw VoiceEngineError.microphoneDenied
        }
    }
}

/// The objects of a running session.
private struct LiveSession: @unchecked Sendable {
    let audio: AudioIO
    let listener: Listener
    let speaker: Speaker
}

/// Lets the speaker reach the listener, which is created after it.
private final class ListenerBox: @unchecked Sendable {
    private let lock = NSLock()
    private weak var stored: Listener?
    var listener: Listener? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// Measures time since a request.
private final class RequestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var start = Date()

    func reset() { lock.withLock { start = Date() } }

    var milliseconds: Int { lock.withLock { Int(Date().timeIntervalSince(start) * 1000) } }
}

/// Reports download progress at most every whole percent.
private final class ProgressThrottle: @unchecked Sendable {
    private let lock = NSLock()
    private var last = 0.0

    func shouldReport(_ fraction: Double) -> Bool {
        lock.withLock {
            guard fraction - last >= 0.01 else { return false }
            last = fraction
            return true
        }
    }
}

/// Models stay loaded between sessions, so starting again is quick.
private final class LoadedModels: @unchecked Sendable {
    private let lock = NSLock()
    private var models: [String: AnyObject] = [:]
    private var warmed: Set<String> = []

    func forget(_ id: String) {
        lock.withLock {
            models[id] = nil
            warmed.removeAll()
        }
    }

    private func cached<Model: AnyObject>(
        _ id: String, load: () async throws -> Model
    ) async rethrows -> Model {
        if let model = lock.withLock({ models[id] as? Model }) { return model }
        let start = Date()
        let model = try await load()
        Log.info("Loaded \(id) in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        lock.withLock { models[id] = model }
        return model
    }

    func vad(store: ModelStore) async throws -> SileroVADModel {
        let model = ModelCatalog.sileroVAD
        return try await cached(model.id) {
            try await SileroVADModel.fromPretrained(
                modelId: model.repository, engine: .coreml, cacheDir: store.directory(for: model),
                offlineMode: true)
        }
    }

    func turnDetector(store: ModelStore) async throws -> SmartTurnModel {
        let model = ModelCatalog.smartTurn
        return try await cached(model.id) {
            let detector = try await SmartTurnModel.fromPretrained(
                modelId: model.repository, cacheDir: store.directory(for: model), offlineMode: true)
            try detector.prewarm()
            return detector
        }
    }

    func recognizer(store: ModelStore) async throws -> NemotronStreamingASRModel {
        let model = ModelCatalog.nemotron
        return try await cached(model.id) {
            // The Neural Engine keeps the GPU free and runs the INT8 encoder fastest on M1.
            let recognizer = try await NemotronStreamingASRModel.fromLocal(
                bundleDir: store.directory(for: model), computeUnits: .cpuAndNeuralEngine)
            try recognizer.warmUp()
            return recognizer
        }
    }

    func synthesizer(
        for output: SpeechOutputEngine, store: ModelStore
    ) async throws
        -> any SpeechSynthesizing
    {
        let synthesizer: any SpeechSynthesizing
        switch output {
        case .kokoro(let voice, let language):
            let model = ModelCatalog.kokoro
            let kokoro = try await cached(model.id) {
                try await KokoroTTSModel.fromPretrained(
                    modelId: model.repository, cacheDir: store.directory(for: model),
                    offlineMode: true)
            }
            synthesizer = try KokoroSynthesizer(model: kokoro, voice: voice, language: language)
        case .supertonic(let voice, let language):
            let model = ModelCatalog.supertonic
            let supertonic = try await cached(model.id) {
                // The CPU is fastest here (RTF 0.14 on an M1); the GPU path crashes in
                // MPSGraph on dynamic shapes and the Neural Engine is 3× slower.
                try await SupertonicTTSModel.fromPretrained(
                    modelId: model.repository, cacheDir: store.directory(for: model),
                    offlineMode: true,
                    computeUnits: .cpuOnly)
            }
            synthesizer = try SupertonicSynthesizer(
                model: supertonic, voice: voice, language: language)
        case .apple(let identifier, let locale):
            synthesizer = AppleSpeechSynthesizer(voiceIdentifier: identifier, locale: locale)
        }
        // The first synthesis compiles the models; do it before the first real sentence.
        let key = String(describing: output)
        if lock.withLock({ warmed.insert(key).inserted }) {
            let start = Date()
            _ = try? synthesizer.synthesize("Hi.")
            Log.info("Speech warm-up took \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        }
        return synthesizer
    }
}
