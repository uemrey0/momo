import Foundation
import MomoLiveProtocol
import Observation

/// The open source on-device live engine: the `momo-voice` helper process, which owns the
/// microphone and the speaker during a session and speaks `MomoLiveProtocol`.
///
/// Commands and events map one to one. Two things are added on this side:
/// ``endTurn()`` (push to talk), which the protocol lacks, is emulated by pausing the helper's
/// turn detection and reporting the words heard so far; and a helper that crashes in a
/// session is started again once, with the same configuration, before the session fails.
@MainActor
public final class HelperLiveSpeechIO: LiveSpeechIO {
    public var onEvent: ((LiveSpeechEvent) -> Void)?
    public private(set) var isRunning = false

    private let client: LiveVoiceHelperClient
    private let startTimeout: Duration
    private var observer: UUID?
    private var configuration: LiveSessionConfiguration?
    private var hasClient = false
    private var started: CheckedContinuation<Void, any Error>?
    private var lastPartial = ""
    /// A turn reported by ``endTurn()``, so the helper's own report of it is not repeated.
    private var emulatedTurn: (text: String, time: Date)?
    private var restarts: [Date] = []

    /// - Parameters:
    ///   - client: The helper, shared with the model list.
    ///   - startTimeout: How long the helper may take to open the microphone and load its
    ///     models.
    public init(client: LiveVoiceHelperClient, startTimeout: Duration = .seconds(20)) {
        self.client = client
        self.startTimeout = startTimeout
    }

    /// The helper's session configuration for `configuration`.
    public static func sessionConfiguration(
        for configuration: LiveSpeechConfiguration
    )
        -> LiveSessionConfiguration
    {
        var appleVoice: String?
        if case .apple(let identifier, _) = configuration.voice { appleVoice = identifier }
        return LiveSessionConfiguration(
            locale: configuration.locale.identifier(.bcp47),
            speechToTextModel: configuration.speechToTextModel,
            textToSpeechModel: configuration.textToSpeechModel, voice: configuration.modelVoice,
            appleVoiceIdentifier: appleVoice, allowsBargeIn: configuration.allowsBargeIn,
            maximumPause: configuration.maximumPause)
    }

    public func start(_ configuration: LiveSpeechConfiguration) async throws {
        stop()
        let session = Self.sessionConfiguration(for: configuration)
        self.configuration = session
        client.acquire()
        hasClient = true
        observer = client.addObserver { [weak self] message in self?.handle(message) }
        do {
            try await begin(session)
            isRunning = true
        } catch {
            releaseClient()
            throw error
        }
        onEvent?(.listening)
    }

    /// Connects, starts the session and waits until the helper listens.
    private func begin(_ session: LiveSessionConfiguration) async throws {
        try await client.connect()
        lastPartial = ""
        let timeout = startTimeout
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.finishStart(.failure(LiveVoiceHelperError.noAnswer))
        }
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { continuation in
            started = continuation
            do {
                try client.send(.start(session))
            } catch {
                finishStart(.failure(error))
            }
        }
    }

    private func finishStart(_ result: Result<Void, any Error>) {
        let continuation = started
        started = nil
        continuation?.resume(with: result)
    }

    public func stop() {
        finishStart(.failure(CancellationError()))
        let wasRunning = isRunning
        isRunning = false
        if wasRunning { try? client.send(.stop) }
        releaseClient()
        if wasRunning { onEvent?(.stopped) }
    }

    private func releaseClient() {
        if let observer { client.removeObserver(observer) }
        observer = nil
        if hasClient { client.release() }
        hasClient = false
    }

    public func speak(id: String, text: String, isFinal: Bool) {
        send(.speak(id: id, text: text, isFinal: isFinal))
    }

    public func cancelSpeech() {
        send(.cancelSpeech)
    }

    public func pauseListening() {
        send(.pauseListening)
    }

    public func resumeListening() {
        lastPartial = ""
        send(.resumeListening)
    }

    public func endTurn() {
        guard isRunning else { return }
        let text = lastPartial
        send(.pauseListening)
        lastPartial = ""
        emulatedTurn = (text, Date())
        onEvent?(.turn(text))
        send(.resumeListening)
    }

    private func send(_ command: LiveVoiceCommand) {
        guard isRunning else { return }
        do {
            try client.send(command)
        } catch {
            onEvent?(.error(message: error.localizedDescription, isFatal: false))
        }
    }

    // MARK: - Events

    private func handle(_ message: LiveVoiceClientMessage) {
        switch message {
        case .event(let event):
            handle(event)
        case .disconnected(let crashed):
            finishStart(.failure(LiveVoiceHelperError.failed("The voice helper quit.")))
            guard isRunning else { return }
            if crashed { recover() } else { endAfterFailure(nil) }
        }
    }

    private func handle(_ event: LiveVoiceEvent) {
        switch event {
        case .ready, .models, .downloadProgress, .downloadFinished, .downloadFailed, .prepared:
            break
        case .listening:
            finishStart(.success(()))
        case .level(let level):
            forward(.level(level))
        case .speechStarted:
            forward(.speechStarted)
        case .partial(let text):
            lastPartial = text
            forward(.partial(text))
        case .turn(let text):
            lastPartial = ""
            if let emulated = emulatedTurn, Date().timeIntervalSince(emulated.time) < 2,
                text.isEmpty || emulated.text.hasPrefix(text) || text.hasPrefix(emulated.text)
            {
                emulatedTurn = nil
                return
            }
            forward(.turn(text))
        case .speakingStarted(let id):
            forward(.speakingStarted(id: id))
        case .mouth(let level):
            forward(.mouth(level))
        case .speakingFinished(let id):
            forward(.speakingFinished(id: id))
        case .interrupted(let id):
            forward(.interrupted(id: id))
        case .error(let message, let isFatal):
            if started != nil, isFatal {
                finishStart(.failure(LiveVoiceHelperError.failed(message)))
            } else if isFatal {
                endAfterFailure(message)
            } else {
                forward(.error(message: message, isFatal: false))
            }
        case .stopped:
            if isRunning { endAfterFailure(nil) }
        }
    }

    private func forward(_ event: LiveSpeechEvent) {
        guard isRunning else { return }
        onEvent?(event)
    }

    /// Starts a crashed helper again with the same session, at most once a minute.
    private func recover() {
        restarts = restarts.filter { Date().timeIntervalSince($0) < 60 }
        guard restarts.isEmpty, let configuration else {
            endAfterFailure("The voice helper stopped unexpectedly.")
            return
        }
        restarts.append(Date())
        onEvent?(.error(message: "The voice helper restarted.", isFatal: false))
        Task {
            do {
                try await begin(configuration)
            } catch {
                guard isRunning else { return }
                endAfterFailure(error.localizedDescription)
            }
        }
    }

    private func endAfterFailure(_ message: String?) {
        guard isRunning else { return }
        isRunning = false
        releaseClient()
        if let message { onEvent?(.error(message: message, isFatal: true)) }
        onEvent?(.stopped)
    }
}

/// The helper's models, for Settings: which exist, which are downloaded, download progress.
///
/// Nothing is downloaded until the user asks with ``download(_:)``.
@MainActor
@Observable
public final class LiveVoiceModels {
    public private(set) var models: [LiveModelInfo] = []
    /// Download progress from 0 to 1, by model identifier.
    public private(set) var progress: [String: Double] = [:]
    public private(set) var errorMessage: String?
    public private(set) var isLoading = false
    /// The conversation languages the helper can serve.
    public private(set) var languages: [String] = []
    /// The conversation language the required models are marked for, e.g. "tr-TR".
    public var locale: String

    @ObservationIgnored private let client: LiveVoiceHelperClient?
    @ObservationIgnored private var observer: UUID?
    @ObservationIgnored private var listing: CheckedContinuation<Void, Never>?
    @ObservationIgnored private let listTimeout: Duration
    @ObservationIgnored private var holdsClient = false

    /// - Parameter client: The helper, or `nil` when it is missing or can't run here.
    public init(
        client: LiveVoiceHelperClient?, locale: String = Locale.current.identifier(.bcp47),
        listTimeout: Duration = .seconds(10)
    ) {
        self.client = client
        self.locale = locale
        self.listTimeout = listTimeout
    }

    /// Whether the helper exists and runs on this Mac.
    public var isAvailable: Bool { client != nil }

    /// Whether every model the conversation language needs is downloaded.
    public var isReady: Bool {
        let required = models.filter(\.isRequired)
        return !required.isEmpty && required.allSatisfy(\.isDownloaded)
    }

    /// Whether a download is running.
    public var isDownloading: Bool { !progress.isEmpty }

    /// How much the missing required models weigh, in bytes.
    public var missingDownloadSize: Int64 {
        models.filter { $0.isRequired && !$0.isDownloaded }.reduce(0) { $0 + $1.sizeBytes }
    }

    /// Asks the helper for its models.
    public func refresh() async {
        guard let client else { return }
        isLoading = true
        defer { isLoading = false }
        hold()
        defer { letGoIfIdle() }
        do {
            try await client.connect()
            languages = client.languages
            let timeout = listTimeout
            let timer = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.finishListing()
            }
            defer { timer.cancel() }
            await withCheckedContinuation { continuation in
                listing = continuation
                do {
                    try client.send(.listModels(locale: locale))
                } catch {
                    errorMessage = error.localizedDescription
                    finishListing()
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Downloads models, reporting ``progress``. Only call this when the user asked.
    public func download(_ ids: [String]) {
        guard let client, !ids.isEmpty else { return }
        errorMessage = nil
        hold()
        for id in ids { progress[id] = 0 }
        Task {
            do {
                try await client.connect()
                try client.send(.downloadModels(ids: ids))
            } catch {
                errorMessage = error.localizedDescription
                for id in ids { progress[id] = nil }
                letGoIfIdle()
            }
        }
    }

    /// Downloads every missing model the conversation language needs.
    public func downloadRequired() {
        download(models.filter { $0.isRequired && !$0.isDownloaded }.map(\.id))
    }

    /// Deletes downloaded models.
    public func delete(_ ids: [String]) {
        guard let client, !ids.isEmpty else { return }
        errorMessage = nil
        Task {
            hold()
            defer { letGoIfIdle() }
            do {
                try await client.connect()
                try client.send(.deleteModels(ids: ids))
                await refresh()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func hold() {
        guard let client else { return }
        if observer == nil {
            observer = client.addObserver { [weak self] message in self?.handle(message) }
        }
        if !holdsClient {
            client.acquire()
            holdsClient = true
        }
    }

    /// Releases the helper when nothing is loading or downloading any more.
    private func letGoIfIdle() {
        guard let client, holdsClient, progress.isEmpty, listing == nil else { return }
        holdsClient = false
        client.release()
    }

    private func finishListing() {
        let continuation = listing
        listing = nil
        continuation?.resume()
    }

    private func handle(_ message: LiveVoiceClientMessage) {
        switch message {
        case .event(.models(let models)):
            self.models = models
            finishListing()
        case .event(.downloadProgress(let id, let fraction)):
            progress[id] = min(1, max(0, fraction))
        case .event(.downloadFinished(let id)):
            progress[id] = nil
            if let index = models.firstIndex(where: { $0.id == id }) {
                models[index].isDownloaded = true
            }
            letGoIfIdle()
        case .event(.downloadFailed(let id, let message)):
            progress[id] = nil
            errorMessage = message
            letGoIfIdle()
        case .event(.ready(_, let languages)):
            self.languages = languages
        case .disconnected(let crashed):
            finishListing()
            if !progress.isEmpty, crashed {
                errorMessage = "The voice helper stopped during the download."
            }
            progress = [:]
            if holdsClient, let client {
                holdsClient = false
                client.release()
            }
        case .event:
            break
        }
    }
}
