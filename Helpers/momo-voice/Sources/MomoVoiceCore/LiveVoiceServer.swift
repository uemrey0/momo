import Foundation
import MomoLiveProtocol

/// What the protocol server drives: the models and the audio session.
///
/// Methods are called one at a time, in the order the commands arrive. The ones that affect
/// a running session (`speak`, `cancelSpeech`, …) must return quickly; long work belongs in
/// the backend's own tasks, reporting through the event sink it was given.
public protocol LiveVoiceBackend: Sendable {
    /// Conversation languages the backend can serve with downloaded or downloadable models.
    func supportedLanguages() async -> [String]
    /// Every model, marking the ones `locale` needs and the ones on this Mac.
    func models(locale: String) async -> [LiveModelInfo]
    /// Downloads models, reporting `downloadProgress`, `downloadFinished` or `downloadFailed`
    /// for each. Returns when all are done.
    func downloadModels(ids: [String]) async
    /// Deletes downloaded models.
    func deleteModels(ids: [String]) async throws
    /// Loads and warms up the models a session with `configuration` needs, without opening
    /// the microphone.
    func prepare(_ configuration: LiveSessionConfiguration) async throws
    /// Opens the microphone and starts a session; reports `listening` when it runs.
    func start(_ configuration: LiveSessionConfiguration) async throws
    /// Ends the session and releases the audio devices; reports `stopped`.
    func stop() async
    func speak(id: String, text: String, isFinal: Bool) async
    func cancelSpeech() async
    func setListeningPaused(_ isPaused: Bool) async
}

/// Reads protocol commands and dispatches them to a ``LiveVoiceBackend``.
///
/// It never throws: malformed input and failures are reported as `error` events, so a bad
/// line from Momo cannot bring the helper down.
public actor LiveVoiceServer {
    /// Whether the server should keep reading after a command.
    public enum Outcome: Sendable, Equatable {
        case proceed
        case quit
    }

    private let backend: any LiveVoiceBackend
    private let emit: @Sendable (LiveVoiceEvent) -> Void
    private var downloads: [Task<Void, Never>] = []
    private var isSessionRunning = false

    /// - Parameters:
    ///   - backend: The engine that does the work.
    ///   - emit: Writes one event to Momo.
    public init(backend: any LiveVoiceBackend, emit: @escaping @Sendable (LiveVoiceEvent) -> Void) {
        self.backend = backend
        self.emit = emit
    }

    /// Handles one line of input.
    public func handle(line: String) async -> Outcome {
        let command: LiveVoiceCommand
        do {
            command = try LiveVoiceCoding.decode(LiveVoiceCommand.self, from: line)
        } catch {
            let excerpt = line.count > 120 ? String(line.prefix(120)) + "…" : line
            emit(.error(message: "Unreadable command: \(excerpt)", isFatal: false))
            return .proceed
        }
        return await handle(command)
    }

    /// Handles one command.
    public func handle(_ command: LiveVoiceCommand) async -> Outcome {
        switch command {
        case .hello(let version):
            if version != liveVoiceProtocolVersion {
                emit(
                    .error(
                        message:
                            "Momo speaks protocol version \(version); this helper speaks \(liveVoiceProtocolVersion).",
                        isFatal: false))
            }
            emit(
                .ready(
                    version: liveVoiceProtocolVersion, languages: await backend.supportedLanguages()
                ))
        case .listModels(let locale):
            emit(.models(await backend.models(locale: locale)))
        case .downloadModels(let ids):
            let backend = backend
            downloads.append(Task { await backend.downloadModels(ids: ids) })
        case .deleteModels(let ids):
            do {
                try await backend.deleteModels(ids: ids)
            } catch {
                emit(.error(message: "Could not delete models: \(error)", isFatal: false))
            }
        case .prepare(let configuration):
            do {
                try await backend.prepare(configuration)
                emit(.prepared)
            } catch {
                emit(.error(message: String(describing: error), isFatal: false))
            }
        case .start(let configuration):
            if isSessionRunning { await backend.stop() }
            do {
                try await backend.start(configuration)
                isSessionRunning = true
            } catch {
                isSessionRunning = false
                emit(.error(message: String(describing: error), isFatal: true))
                emit(.stopped)
            }
        case .stop:
            if isSessionRunning {
                await stopSession()
            } else {
                emit(.stopped)
            }
        case .speak(let id, let text, let isFinal):
            guard isSessionRunning else {
                emit(.error(message: "No live session is running.", isFatal: false))
                return .proceed
            }
            await backend.speak(id: id, text: text, isFinal: isFinal)
        case .cancelSpeech:
            await backend.cancelSpeech()
        case .pauseListening:
            await backend.setListeningPaused(true)
        case .resumeListening:
            await backend.setListeningPaused(false)
        case .quit:
            await shutDown()
            return .quit
        }
        return .proceed
    }

    /// Stops the session and cancels downloads, for `quit` or the end of input.
    public func shutDown() async {
        await stopSession()
        for download in downloads { download.cancel() }
        downloads.removeAll()
    }

    /// Waits for running downloads, for the command line mode.
    public func waitForDownloads() async {
        for download in downloads { await download.value }
        downloads.removeAll()
    }

    private func stopSession() async {
        guard isSessionRunning else { return }
        isSessionRunning = false
        await backend.stop()
    }
}
