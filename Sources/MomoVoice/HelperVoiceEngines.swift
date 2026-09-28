import Foundation
import MomoLiveProtocol

// Everything in Momo that listens or speaks outside a live conversation, built on Momo's
// voice models in the `momo-voice` helper: dictation, the wake word, replies read aloud and
// the transcription of recordings. Each one runs a ``HelperLiveSpeechIO`` session in the mode
// it needs, so the helper's model loading, timeouts and crash recovery apply everywhere.

/// Dictation with Momo's voice models: a listening session whose turns become the transcript.
///
/// Without ``isContinuous`` the first finished turn is delivered and the session ends. With
/// it (push to talk), turns are collected until ``stop(deliver:)``, so pauses don't cut the
/// user off.
@MainActor
public final class HelperDictationEngine: DictationEngine {
    public var onPartial: ((String) -> Void)?
    public var onFinal: ((String) -> Void)?
    public var onLevel: ((Double) -> Void)?
    public var isContinuous = false
    public private(set) var isListening = false

    private let io: HelperLiveSpeechIO
    private let configuration: (Locale) -> LiveSpeechConfiguration
    private var turns: [String] = []
    private var partial = ""
    private var delivered = false

    /// - Parameters:
    ///   - client: The helper.
    ///   - configuration: The session for a language; its mode is set to listening.
    public init(
        client: LiveVoiceHelperClient,
        configuration: @escaping (Locale) -> LiveSpeechConfiguration = {
            LiveSpeechConfiguration(locale: $0)
        }
    ) {
        io = HelperLiveSpeechIO(client: client)
        self.configuration = configuration
        io.onEvent = { [weak self] event in self?.handle(event) }
    }

    public func start(locale: Locale) async throws {
        stop(deliver: false)
        turns = []
        partial = ""
        delivered = false
        var session = configuration(locale)
        session.mode = .listen
        session.endsTurnsOnPause = !isContinuous
        try await io.start(session)
        isListening = true
    }

    public func stop(deliver: Bool) {
        guard isListening else { return }
        if deliver {
            // Reports what was heard so far as a turn, which delivers it.
            io.endTurn()
            finish()
        } else {
            delivered = true
            isListening = false
            io.stop()
        }
    }

    private var transcript: String {
        (turns + [partial]).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private func handle(_ event: LiveSpeechEvent) {
        switch event {
        case .level(let level):
            onLevel?(level)
        case .partial(let text):
            partial = text
            onPartial?(transcript)
        case .turn(let text):
            partial = ""
            if !text.isEmpty { turns.append(text) }
            onPartial?(transcript)
            if !isContinuous { finish() }
        case .error(_, let isFatal) where isFatal:
            finish()
        case .stopped:
            finish()
        default:
            break
        }
    }

    private func finish() {
        guard !delivered else { return }
        delivered = true
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        isListening = false
        io.stop()
        onFinal?(text)
    }
}

/// Listens for "Hey Momo" in the background with Momo's voice models.
///
/// The helper's voice activity detector gates speech recognition, so the listener only
/// transcribes while someone talks. After the wake phrase, it waits for the end of the
/// sentence, then reports what followed it.
@MainActor
public final class HelperWakeWordListener {
    /// Called with whatever the user said after the wake word (may be empty).
    public var onWake: ((String) -> Void)?
    public private(set) var isRunning = false

    private let client: LiveVoiceHelperClient
    private let detector = WakeWordDetector()
    private var io: HelperLiveSpeechIO?
    private var locale = Locale.current
    private var heardWake = false
    private var wakeTranscript = ""
    private var wakeTimer: Task<Void, Never>?
    private var restartTask: Task<Void, Never>?

    public init(client: LiveVoiceHelperClient) {
        self.client = client
    }

    public func start(locale: Locale = .current) async throws {
        self.locale = locale
        isRunning = true
        try await listen()
    }

    public func stop() {
        isRunning = false
        restartTask?.cancel()
        restartTask = nil
        wakeTimer?.cancel()
        wakeTimer = nil
        io?.stop()
        io = nil
    }

    /// Resumes listening after the conversation triggered by the wake word ends.
    public func resume() {
        guard isRunning else { return }
        heardWake = false
        guard io == nil else { return }
        scheduleRestart(after: .milliseconds(300))
    }

    private func listen() async throws {
        guard isRunning else { return }
        heardWake = false
        wakeTranscript = ""
        let session = HelperLiveSpeechIO(client: client)
        session.onEvent = { [weak self, weak session] event in
            guard let self, let session, self.io === session else { return }
            self.handle(event)
        }
        io = session
        do {
            try await session.start(
                LiveSpeechConfiguration(locale: locale, mode: .listen, maximumPause: 0.8))
        } catch {
            if io === session { io = nil }
            throw error
        }
    }

    private func handle(_ event: LiveSpeechEvent) {
        switch event {
        case .partial(let text):
            heard(text, finished: false)
        case .turn(let text):
            heard(text, finished: true)
        case .stopped:
            io = nil
            // The helper stopped (a crash that couldn't be recovered): try again later.
            if isRunning, !heardWake { scheduleRestart(after: .seconds(5)) }
        default:
            break
        }
    }

    private func heard(_ transcript: String, finished: Bool) {
        if heardWake {
            wakeTranscript = transcript
            if finished { wake() }
            return
        }
        guard detector.matches(transcript) else { return }
        heardWake = true
        wakeTranscript = transcript
        if finished {
            wake()
            return
        }
        // Give the user a moment to finish the sentence after "Hey Momo".
        wakeTimer?.cancel()
        wakeTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            self?.wake()
        }
    }

    private func wake() {
        guard heardWake, io != nil else { return }
        wakeTimer?.cancel()
        wakeTimer = nil
        let command = detector.command(in: wakeTranscript)
        io?.stop()
        io = nil
        onWake?(command)
    }

    private func scheduleRestart(after delay: Duration) {
        restartTask?.cancel()
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, self.isRunning, self.io == nil else { return }
            try? await self.listen()
        }
    }
}

/// Reads text aloud with Momo's voice models, without opening the microphone.
@MainActor
public final class HelperSpeaker {
    /// Called when speech starts.
    public var onStart: (() -> Void)?
    /// The output level, 0...1, for moving Momo's mouth.
    public var onLevel: ((Double) -> Void)?
    /// Called when speech finishes or is stopped.
    public var onFinish: (() -> Void)?
    /// Called when speaking failed, with the reason.
    public var onError: ((String) -> Void)?
    public private(set) var isSpeaking = false

    /// The session for a language code such as "tr": the model and voice the user chose
    /// when they speak it. Its mode is set to speaking.
    public var configuration: (String) -> LiveSpeechConfiguration
    private let client: LiveVoiceHelperClient
    private var io: HelperLiveSpeechIO?
    private var utterance = 0

    /// - Parameters:
    ///   - client: The helper.
    ///   - configuration: The session for a language code such as "tr": the model and voice
    ///     the user chose when they speak it. Its mode is set to speaking.
    public init(
        client: LiveVoiceHelperClient,
        configuration: @escaping (String) -> LiveSpeechConfiguration = {
            LiveSpeechConfiguration(locale: Locale(identifier: $0))
        }
    ) {
        self.client = client
        self.configuration = configuration
    }

    /// Speaks Markdown text in its own language.
    public func speak(_ markdown: String, fallbackLanguage: String = "en") {
        stop()
        let text = SpeechText.plain(fromMarkdown: markdown)
        guard !text.isEmpty else { return }
        let language = SpeechText.language(of: text) ?? fallbackLanguage
        var session = configuration(language)
        session.mode = .speak
        utterance += 1
        let id = "say-\(utterance)"
        let io = HelperLiveSpeechIO(client: client)
        io.onEvent = { [weak self, weak io] event in
            guard let self, let io, self.io === io else { return }
            self.handle(event, id: id)
        }
        self.io = io
        isSpeaking = true
        Task {
            do {
                try await io.start(session)
                guard self.io === io else { return }
                io.speak(id: id, text: text, isFinal: true)
            } catch {
                guard self.io === io else { return }
                self.io = nil
                isSpeaking = false
                onError?(error.localizedDescription)
                onFinish?()
            }
        }
    }

    /// Stops speaking at once.
    public func stop() {
        guard let io else { return }
        self.io = nil
        io.cancelSpeech()
        io.stop()
        if isSpeaking {
            isSpeaking = false
            onFinish?()
        }
    }

    private func handle(_ event: LiveSpeechEvent, id: String) {
        switch event {
        case .speakingStarted(let started) where started == id:
            onStart?()
        case .mouth(let level):
            onLevel?(level)
        case .speakingFinished(let finished) where finished == id:
            stop()
        case .error(let message, let isFatal) where isFatal:
            onError?(message)
            stop()
        case .stopped:
            stop()
        default:
            break
        }
    }
}

/// Transcribes recordings with Momo's voice models, for meeting notes and as the fallback of
/// cloud transcription. The audio never leaves the Mac; it is written to a temporary file
/// the helper reads, and deleted afterwards.
public struct HelperTranscriptionService: AudioTranscriptionService {
    private let transcriber: HelperTranscriber

    /// - Parameters:
    ///   - client: The helper.
    ///   - locale: The spoken language.
    @MainActor
    public init(client: LiveVoiceHelperClient, locale: Locale = .current) {
        transcriber = HelperTranscriber(client: client, locale: locale)
    }

    public var displayName: String { "Momo voice models" }

    public func transcribe(
        _ audio: AudioClip, options: TranscriptionOptions
    ) async throws -> Transcript {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("momo-\(UUID().uuidString).wav")
        try audio.data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await transcriber.transcribe(
            fileAt: url, language: options.language, duration: audio.duration)
    }
}

/// Sends one recording at a time to the helper and waits for its transcript.
@MainActor
final class HelperTranscriber {
    private let client: LiveVoiceHelperClient
    private let locale: Locale
    private var pending: [String: CheckedContinuation<Transcript, any Error>] = [:]
    private var observer: UUID?

    init(client: LiveVoiceHelperClient, locale: Locale) {
        self.client = client
        self.locale = locale
    }

    func transcribe(
        fileAt url: URL, language: String?, duration: TimeInterval?
    ) async throws -> Transcript {
        client.acquire()
        defer { client.release() }
        try await client.connect()
        if observer == nil {
            observer = client.addObserver { [weak self] message in self?.handle(message) }
        }
        let id = UUID().uuidString
        let tag =
            language.map { Locale(identifier: $0).identifier(.bcp47) }
            ?? locale.identifier(.bcp47)
        // Recognition runs many times faster than real time; allow for a cold start.
        let timeout = Duration.seconds(90 + (duration ?? 60) * 0.5)
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.finish(id, .failure(LiveVoiceHelperError.noAnswer))
        }
        defer { timer.cancel() }
        let transcript = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do {
                    try client.send(.transcribe(id: id, path: url.path, locale: tag))
                } catch {
                    finish(id, .failure(error))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, .failure(CancellationError())) }
        }
        return transcript
    }

    private func finish(_ id: String, _ result: Result<Transcript, any Error>) {
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    private func handle(_ message: LiveVoiceClientMessage) {
        switch message {
        case .event(.transcribed(let id, let segments)):
            let parts = segments.map {
                TranscriptSegment(text: $0.text, start: $0.start, end: $0.end)
            }
            finish(
                id,
                .success(
                    Transcript(
                        text: parts.map(\.text).joined(separator: " "), segments: parts,
                        language: locale.language.languageCode?.identifier)))
        case .event(.transcriptionFailed(let id, let message)):
            finish(id, .failure(LiveVoiceHelperError.failed(message)))
        case .disconnected:
            for id in Array(pending.keys) {
                finish(id, .failure(LiveVoiceHelperError.failed("The voice helper quit.")))
            }
        case .event:
            break
        }
    }
}
