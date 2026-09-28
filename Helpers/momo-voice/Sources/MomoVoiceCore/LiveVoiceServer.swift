import Foundation
import MomoLiveProtocol

/// What the protocol server drives: the models and the audio session.
///
/// Methods are called one at a time, in the order the commands arrive, except the ones the
/// server runs in its own tasks (`downloadModels`, `importModel`, `transcribe`), which may run
/// alongside the others. The ones that affect a running session (`speak`, `cancelSpeech`, …)
/// must return quickly, and the long ones must not hold them up.
public protocol LiveVoiceBackend: Sendable {
    /// Conversation languages the backend can serve with downloaded or downloadable models.
    func supportedLanguages() async -> [String]
    /// Every model, built in or added, marking the ones on this Mac and the ones a
    /// conversation in `locale` needs when it speaks with `textToSpeechModel` (or the
    /// backend's choice for `nil`).
    func models(locale: String, textToSpeechModel: String?) async -> [LiveModelInfo]
    /// Downloads models, reporting `downloadProgress`, `downloadFinished` or `downloadFailed`
    /// for each. Returns when all are done.
    func downloadModels(ids: [String]) async
    /// Deletes downloaded models and models the user added.
    func deleteModels(ids: [String]) async throws
    /// Copies the speech synthesis model in the folder at `path` and returns its new id.
    /// Errors describe for the user what is wrong with the folder.
    func importModel(path: String) async throws -> String
    /// Adds the voice file at `path` to the model `modelID` and returns the voice's name.
    func importVoice(modelID: String, path: String) async throws -> String
    /// Deletes a voice the user added to `modelID`.
    func deleteVoice(modelID: String, voice: String) async throws
    /// Transcribes the recording at `path` in `locale`'s language, without the audio devices.
    func transcribe(path: String, locale: String) async throws -> [LiveTranscriptSegment]
    /// Loads and warms up the models a session with `configuration` needs, without opening
    /// the microphone.
    func prepare(_ configuration: LiveSessionConfiguration) async throws
    /// Starts a session in the configuration's mode; reports `listening` when it runs.
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
    /// Downloads, imports and transcriptions, which run alongside other commands.
    private var backgroundTasks: [UUID: Task<Void, Never>] = [:]
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
        case .listModels(let locale, let textToSpeechModel):
            emit(
                .models(
                    await backend.models(locale: locale, textToSpeechModel: textToSpeechModel)))
        case .downloadModels(let ids):
            let backend = backend
            runInBackground { await backend.downloadModels(ids: ids) }
        case .deleteModels(let ids):
            do {
                try await backend.deleteModels(ids: ids)
            } catch {
                emit(
                    .error(
                        message: "Could not delete models: \(Self.message(for: error))",
                        isFatal: false))
            }
        case .importModel(let path):
            let (backend, emit) = (backend, emit)
            runInBackground {
                do {
                    emit(.modelImported(id: try await backend.importModel(path: path)))
                } catch {
                    emit(.importFailed(message: Self.message(for: error)))
                }
            }
        case .importVoice(let modelID, let path):
            do {
                let voice = try await backend.importVoice(modelID: modelID, path: path)
                emit(.voiceImported(modelID: modelID, voice: voice))
            } catch {
                emit(.importFailed(message: Self.message(for: error)))
            }
        case .deleteVoice(let modelID, let voice):
            do {
                try await backend.deleteVoice(modelID: modelID, voice: voice)
            } catch {
                emit(
                    .error(
                        message: "Could not delete the voice: \(Self.message(for: error))",
                        isFatal: false))
            }
        case .transcribe(let id, let path, let locale):
            let (backend, emit) = (backend, emit)
            runInBackground {
                do {
                    let segments = try await backend.transcribe(path: path, locale: locale)
                    emit(.transcribed(id: id, segments: segments))
                } catch {
                    emit(.transcriptionFailed(id: id, message: Self.message(for: error)))
                }
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

    /// Stops the session and cancels downloads, imports and transcriptions, for `quit` or
    /// the end of input.
    public func shutDown() async {
        await stopSession()
        for task in backgroundTasks.values { task.cancel() }
        backgroundTasks.removeAll()
    }

    /// Waits for running downloads, imports and transcriptions, for tests and the command
    /// line.
    public func waitForBackgroundTasks() async {
        while let task = backgroundTasks.values.first {
            await task.value
        }
    }

    /// Runs long work in its own task, so the commands after it are not held up.
    private func runInBackground(_ work: @escaping @Sendable () async -> Void) {
        let id = UUID()
        backgroundTasks[id] = Task {
            await work()
            self.finishBackgroundTask(id)
        }
    }

    private func finishBackgroundTask(_ id: UUID) {
        backgroundTasks[id] = nil
    }

    /// The text Momo shows for an error: its localized description when it has one.
    static func message(for error: any Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }

    private func stopSession() async {
        guard isSessionRunning else { return }
        isSessionRunning = false
        await backend.stop()
    }
}
