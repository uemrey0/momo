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

    public func models(locale: String, textToSpeechModel: String?) async -> [LiveModelInfo] {
        let catalog = store.allModels()
        let configuration = LiveSessionConfiguration(
            locale: locale, textToSpeechModel: textToSpeechModel)
        // A chosen model that cannot speak the language falls back to the default choice.
        let plan =
            (try? ModelSelection.plan(for: configuration, catalog: catalog))
            ?? ModelSelection.plan(locale: locale)
        let required = Set(plan?.requiredModelIDs ?? [])
        return catalog.map { model in
            let isDownloaded = store.isDownloaded(model)
            let hasVoices = model.kind == .textToSpeech && isDownloaded
            return model.info(
                isDownloaded: isDownloaded, isRequired: required.contains(model.id),
                voices: hasVoices ? store.voices(of: model) : [],
                customVoices: hasVoices ? store.customVoices(of: model) : [])
        }
    }

    public func downloadModels(ids: [String]) async {
        for id in ids {
            guard let model = store.model(id: id) else {
                emit(.downloadFailed(id: id, message: "Unknown model \(id)."))
                continue
            }
            guard !model.isCustom else {
                emit(
                    .downloadFailed(
                        id: id,
                        message: String(
                            describing: VoiceEngineError.customModelNotDownloadable(id))))
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
            guard let model = store.model(id: id) else {
                throw VoiceEngineError.unknownModel(id)
            }
            loaded.forget(id)
            try store.delete(model)
            Log.info("Deleted \(id)")
        }
    }

    /// Copies a model folder into the store. Copying can take a while, so it runs off the
    /// actor and never holds up a running session.
    public nonisolated func importModel(path: String) async throws -> String {
        try store.importModel(from: URL(fileURLWithPath: path, isDirectory: true)).id
    }

    public func importVoice(modelID: String, path: String) async throws -> String {
        guard let model = store.model(id: modelID) else {
            throw VoiceEngineError.unknownModel(modelID)
        }
        let voice = try store.importVoice(from: URL(fileURLWithPath: path), into: model)
        // A loaded model only knows the voices it was loaded with.
        loaded.forget(modelID)
        return voice
    }

    public func deleteVoice(modelID: String, voice: String) async throws {
        guard let model = store.model(id: modelID) else {
            throw VoiceEngineError.unknownModel(modelID)
        }
        try store.deleteVoice(voice, of: model)
        loaded.forget(modelID)
    }

    // MARK: Transcription

    /// Transcribes a recording: Silero VAD finds the speech, and each stretch of it goes
    /// through its own Nemotron session, as the listener does for a turn.
    ///
    /// It runs off the actor, so a running session keeps speaking and listening meanwhile.
    /// Its VAD is a separate instance, because the listener's carries streaming state.
    public nonisolated func transcribe(
        path: String, locale: String
    ) async throws -> [LiveTranscriptSegment] {
        let startedAt = Date()
        let language = ModelSelection.languageCode(of: locale)
        guard ModelCatalog.nemotron.languages.contains(language) else {
            throw ModelSelectionError.unsupportedLanguage(locale)
        }
        let missing = [ModelCatalog.sileroVAD, ModelCatalog.nemotron]
            .filter { !store.isDownloaded($0) }.map(\.id)
        guard missing.isEmpty else { throw VoiceEngineError.modelsMissing(missing) }

        let audio = try RecordingReader.samples(of: URL(fileURLWithPath: path))
        try Task.checkCancellation()
        let vad = try await SileroVADModel.fromPretrained(
            modelId: ModelCatalog.sileroVAD.repository, engine: .coreml,
            cacheDir: store.directory(for: ModelCatalog.sileroVAD), offlineMode: true)
        let recognizer = try await loaded.recognizer(store: store)
        let transcriber = RecordingTranscriber(
            vad: vad, recognizer: recognizer,
            recognitionLanguage: ModelSelection.recognitionTag(for: locale))
        let segments = try await transcriber.transcribe(audio)
        let seconds = Double(audio.count) / RecordingTranscriber.sampleRate
        Log.info(
            String(
                format: "Transcribed %.1f s of audio into %d segments in %.0f ms", seconds,
                segments.count, Date().timeIntervalSince(startedAt) * 1000))
        return segments
    }

    // MARK: Session

    /// The plan for a session, choosing among the built-in and added models.
    private func plan(for configuration: LiveSessionConfiguration) throws -> VoicePlan {
        try ModelSelection.plan(for: configuration, catalog: store.allModels())
    }

    /// Loads and warms up the models of a session, without opening the microphone, so the
    /// Core ML compilation a new helper build needs happens before the user waits on it.
    public func prepare(_ configuration: LiveSessionConfiguration) async throws {
        let startedAt = Date()
        let plan = try plan(for: configuration)
        try checkDownloaded(plan)
        if plan.speechToTextModel != nil {
            _ = try await loaded.vad(store: store)
            _ = try await loaded.turnDetector(store: store)
            _ = try await loaded.recognizer(store: store)
        }
        if let output = plan.output {
            _ = try await loaded.synthesizer(
                for: output, locale: plan.recognitionLanguage, store: store)
        }
        Log.info("Prepared in \(Int(Date().timeIntervalSince(startedAt) * 1000)) ms")
    }

    private func checkDownloaded(_ plan: VoicePlan) throws {
        let missing = plan.requiredModelIDs.filter { id in
            store.model(id: id).map { !store.isDownloaded($0) } ?? true
        }
        guard missing.isEmpty else { throw VoiceEngineError.modelsMissing(missing) }
    }

    public func start(_ configuration: LiveSessionConfiguration) async throws {
        await stop(reportStopped: false)
        let startedAt = Date()
        let plan = try plan(for: configuration)
        try checkDownloaded(plan)
        // A session that only speaks never asks for the microphone.
        if configuration.listens { try await Self.requestMicrophoneAccess() }

        var synthesizer: (any SpeechSynthesizing)?
        if let output = plan.output {
            synthesizer = try await loaded.synthesizer(
                for: output, locale: plan.recognitionLanguage, store: store)
        }
        var listenerModels:
            (
                vad: SileroVADModel, turnDetector: SmartTurnModel,
                recognizer: NemotronStreamingASRModel
            )?
        if plan.speechToTextModel != nil {
            listenerModels = (
                try await loaded.vad(store: store), try await loaded.turnDetector(store: store),
                try await loaded.recognizer(store: store)
            )
        }
        Log.info("Models ready in \(Int(Date().timeIntervalSince(startedAt) * 1000)) ms")

        let audio = AudioIO()
        let listenerBox = ListenerBox()
        var speaker: Speaker?
        if let synthesizer, let output = plan.output {
            speaker = Speaker(
                audio: audio, synthesizer: synthesizer,
                maximumPieceLength: Self.maximumPieceLength(for: output), emit: emit,
                observer: Speaker.Observer(
                    started: { listenerBox.listener?.playbackStarted(id: $0) },
                    stopped: { listenerBox.listener?.playbackStopped() }))
        }
        var listener: Listener?
        if let models = listenerModels {
            let newListener = Listener(
                vad: models.vad, turnDetector: models.turnDetector, recognizer: models.recognizer,
                configuration: configuration, recognitionLanguage: plan.recognitionLanguage,
                emit: emit,
                speaker: Listener.SpeakerControl(interrupt: { [weak speaker] in
                    speaker?.cancel()
                }))
            listenerBox.listener = newListener
            newListener.prepare()
            try audio.start(playsOutput: speaker != nil, capture: { newListener.push($0) })
            listener = newListener
        } else {
            try audio.startOutputOnly()
        }
        session = LiveSession(audio: audio, listener: listener, speaker: speaker)
        let listening =
            listener != nil ? "listening in \(plan.recognitionLanguage)" : "not listening"
        let speaking = plan.output.map { "speaking with \($0)" } ?? "not speaking"
        Log.info(
            "Session \(configuration.mode.rawValue): \(listening), \(speaking), after \(Int(Date().timeIntervalSince(startedAt) * 1000)) ms"
        )
        emit(.listening)
    }

    /// The longest piece of text the model reads at once.
    private static func maximumPieceLength(for output: SpeechOutputEngine) -> Int {
        switch output.architecture {
        case .kokoro: KokoroSynthesizer.maximumPieceLength
        case .supertonic: 180
        }
    }

    public func stop() async {
        await stop(reportStopped: true)
    }

    private func stop(reportStopped: Bool) async {
        guard let session else { return }
        self.session = nil
        session.speaker?.cancel()
        session.audio.stop()
        session.listener?.drain()
        if reportStopped { emit(.stopped) }
    }

    public func speak(id: String, text: String, isFinal: Bool) async {
        guard let session else {
            emit(.error(message: "No live session is running.", isFatal: false))
            return
        }
        guard let speaker = session.speaker else {
            emit(
                .error(
                    message: String(describing: VoiceEngineError.sessionDoesNotSpeak),
                    isFatal: false))
            return
        }
        speaker.speak(id: id, text: text, isFinal: isFinal)
    }

    public func cancelSpeech() async {
        session?.speaker?.cancel()
    }

    public func setListeningPaused(_ isPaused: Bool) async {
        session?.listener?.setPaused(isPaused)
    }

    // MARK: Command line

    /// Synthesises and plays `text` without listening, for `--say`. Returns the time to first
    /// audio and the real-time factor of each piece through the log.
    public func say(_ text: String, configuration: LiveSessionConfiguration) async throws {
        var configuration = configuration
        configuration.mode = .speak
        let plan = try plan(for: configuration)
        try checkDownloaded(plan)
        guard let output = plan.output else { throw VoiceEngineError.sessionDoesNotSpeak }
        let synthesizer = try await loaded.synthesizer(
            for: output, locale: plan.recognitionLanguage, store: store)
        let audio = AudioIO()
        let finished = AsyncStream<Void>.makeStream()
        let emit = emit
        let requested = RequestClock()
        let speaker = Speaker(
            audio: audio, synthesizer: synthesizer,
            maximumPieceLength: Self.maximumPieceLength(for: output),
            emit: { event in
                emit(event)
                if case .speakingStarted = event {
                    Log.info("First audio \(requested.milliseconds) ms after the request")
                }
                if case .speakingFinished = event { finished.continuation.finish() }
            },
            observer: Speaker.Observer(started: { _ in }, stopped: {}))
        try audio.startOutputOnly()
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

/// The objects of a running session. A session that only speaks has no listener, and one
/// that only listens has no speaker.
private struct LiveSession: @unchecked Sendable {
    let audio: AudioIO
    let listener: Listener?
    let speaker: Speaker?
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

    /// The synthesizer for `output`, loading its model (built in or added) from the store.
    /// A `nil` voice becomes the model's default for `locale`.
    func synthesizer(
        for output: SpeechOutputEngine, locale: String, store: ModelStore
    ) async throws -> any SpeechSynthesizing {
        guard let model = store.model(id: output.modelID), let architecture = model.architecture
        else {
            throw VoiceEngineError.unknownModel(output.modelID)
        }
        let directory = store.directory(for: model)
        let repository = model.repository.isEmpty ? model.id : model.repository
        let synthesizer: any SpeechSynthesizing
        let voice: String
        switch architecture {
        case .kokoro:
            let kokoro = try await cached(model.id) {
                try await KokoroTTSModel.fromPretrained(
                    modelId: repository, cacheDir: directory, offlineMode: true)
            }
            voice = try Self.resolve(output, locale: locale, available: kokoro.availableVoices)
            synthesizer = try KokoroSynthesizer(
                model: kokoro, voice: voice, language: output.language)
        case .supertonic:
            let supertonic = try await cached(model.id) {
                // The CPU is fastest here (RTF 0.14 on an M1); the GPU path crashes in
                // MPSGraph on dynamic shapes and the Neural Engine is 3× slower.
                try await SupertonicTTSModel.fromPretrained(
                    modelId: repository, localPath: directory.path, computeUnits: .cpuOnly)
            }
            voice = try Self.resolve(
                output, locale: locale, available: supertonic.availableVoices)
            synthesizer = try SupertonicSynthesizer(
                model: supertonic, voice: voice, language: output.language)
        }
        Log.info("Speech: \(model.id), voice \(voice), language \(output.language)")
        // The first synthesis compiles the models; do it before the first real sentence.
        let key = "\(model.id)|\(voice)|\(output.language)"
        if lock.withLock({ warmed.insert(key).inserted }) {
            let start = Date()
            _ = try? synthesizer.synthesize("Hi.")
            Log.info("Speech warm-up took \(Int(Date().timeIntervalSince(start) * 1000)) ms")
        }
        return synthesizer
    }

    /// The requested voice, or the model's default.
    private static func resolve(
        _ output: SpeechOutputEngine, locale: String, available: [String]
    ) throws -> String {
        if let voice = output.voice { return voice }
        guard
            let voice = ModelSelection.defaultVoice(
                architecture: output.architecture, language: output.language, locale: locale,
                available: available)
        else {
            throw VoiceEngineError.noVoices(output.modelID)
        }
        return voice
    }
}
