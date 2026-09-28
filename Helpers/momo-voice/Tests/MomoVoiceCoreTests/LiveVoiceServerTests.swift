import Foundation
import MomoLiveProtocol
import Synchronization
import Testing

@testable import MomoVoiceCore

/// Records what the server asks of the engine.
final class FakeBackend: LiveVoiceBackend {
    let calls = Mutex<[String]>([])
    let emit: @Sendable (LiveVoiceEvent) -> Void
    let failsToStart: Bool

    init(failsToStart: Bool = false, emit: @escaping @Sendable (LiveVoiceEvent) -> Void) {
        self.failsToStart = failsToStart
        self.emit = emit
    }

    func record(_ call: String) { calls.withLock { $0.append(call) } }

    func supportedLanguages() async -> [String] { ["en", "tr"] }

    func models(locale: String, textToSpeechModel: String?) async -> [LiveModelInfo] {
        record("models \(locale) \(textToSpeechModel ?? "-")")
        return [ModelCatalog.nemotron.info(isDownloaded: false, isRequired: true)]
    }

    func downloadModels(ids: [String]) async {
        record("download \(ids.joined(separator: ","))")
        for id in ids { emit(.downloadFinished(id: id)) }
    }

    func deleteModels(ids: [String]) async throws {
        record("delete \(ids.joined(separator: ","))")
        if ids.contains("locked") { throw CocoaError(.fileWriteNoPermission) }
    }

    func importModel(path: String) async throws -> String {
        record("import model \(path)")
        guard path.hasSuffix("Kokoro") else {
            throw SpeechModelImportError.unrecognizedFolder(path)
        }
        return "custom-kokoro-abcdef"
    }

    func importVoice(modelID: String, path: String) async throws -> String {
        record("import voice \(modelID) \(path)")
        guard path.hasSuffix(".json") else {
            throw SpeechModelImportError.notAVoiceFile(path)
        }
        return "mine"
    }

    func deleteVoice(modelID: String, voice: String) async throws {
        record("delete voice \(modelID) \(voice)")
        if voice == "F1" { throw SpeechModelImportError.notACustomVoice(voice) }
    }

    func transcribe(path: String, locale: String) async throws -> [LiveTranscriptSegment] {
        record("transcribe \(path) \(locale)")
        guard path.hasSuffix(".wav") else { throw CocoaError(.fileReadCorruptFile) }
        return [LiveTranscriptSegment(text: "Merhaba.", start: 0.5, end: 1.2)]
    }

    func prepare(_ configuration: LiveSessionConfiguration) async throws {
        record("prepare \(configuration.locale)")
        if failsToStart { throw ModelSelectionError.unsupportedLanguage(configuration.locale) }
    }

    func start(_ configuration: LiveSessionConfiguration) async throws {
        record("start \(configuration.locale)")
        if failsToStart { throw ModelSelectionError.unsupportedLanguage(configuration.locale) }
        emit(.listening)
    }

    func stop() async {
        record("stop")
        emit(.stopped)
    }

    func speak(id: String, text: String, isFinal: Bool) async {
        record("speak \(id) \(text) \(isFinal)")
    }

    func cancelSpeech() async { record("cancel") }

    func setListeningPaused(_ isPaused: Bool) async { record("paused \(isPaused)") }
}

/// Collects emitted events.
final class EventLog: Sendable {
    let events = Mutex<[LiveVoiceEvent]>([])
    func append(_ event: LiveVoiceEvent) { events.withLock { $0.append(event) } }
    var all: [LiveVoiceEvent] { events.withLock { $0 } }
}

@Suite("Protocol server")
struct LiveVoiceServerTests {
    func line(_ command: LiveVoiceCommand) throws -> String {
        try #require(String(data: LiveVoiceCoding.line(command), encoding: .utf8))
    }

    @Test("answers hello with the protocol version and languages")
    func handshake() async throws {
        let log = EventLog()
        let server = LiveVoiceServer(backend: FakeBackend(emit: log.append), emit: log.append)
        #expect(
            await server.handle(line: try line(.hello(version: liveVoiceProtocolVersion)))
                == .proceed)
        #expect(log.all == [.ready(version: liveVoiceProtocolVersion, languages: ["en", "tr"])])
    }

    @Test("warns about another protocol version but still answers")
    func versionMismatch() async {
        let log = EventLog()
        let server = LiveVoiceServer(backend: FakeBackend(emit: log.append), emit: log.append)
        _ = await server.handle(.hello(version: 99))
        #expect(log.all.count == 2)
        #expect(log.all.last == .ready(version: liveVoiceProtocolVersion, languages: ["en", "tr"]))
    }

    @Test("reports unreadable input instead of crashing")
    func badInput() async {
        let log = EventLog()
        let server = LiveVoiceServer(backend: FakeBackend(emit: log.append), emit: log.append)
        #expect(await server.handle(line: "not json") == .proceed)
        #expect(await server.handle(line: "{\"launchRockets\":{}}") == .proceed)
        #expect(log.all.count == 2)
        for event in log.all {
            guard case .error(_, let isFatal) = event else {
                Issue.record("expected an error, got \(event)")
                continue
            }
            #expect(!isFatal)
        }
    }

    @Test("dispatches commands in order")
    func dispatches() async throws {
        let log = EventLog()
        let backend = FakeBackend(emit: log.append)
        let server = LiveVoiceServer(backend: backend, emit: log.append)
        _ = await server.handle(.listModels(locale: "tr-TR", textToSpeechModel: nil))
        _ = await server.handle(.speak(id: "0", text: "early", isFinal: true))
        _ = await server.handle(.start(LiveSessionConfiguration(locale: "tr-TR")))
        _ = await server.handle(.speak(id: "1", text: "Merhaba.", isFinal: false))
        _ = await server.handle(.pauseListening)
        _ = await server.handle(.resumeListening)
        _ = await server.handle(.cancelSpeech)
        _ = await server.handle(.deleteModels(ids: ["kokoro-82m"]))
        _ = await server.handle(.stop)
        #expect(
            backend.calls.withLock { $0 } == [
                "models tr-TR -", "start tr-TR", "speak 1 Merhaba. false", "paused true",
                "paused false", "cancel", "delete kokoro-82m", "stop",
            ])
        let events = log.all
        #expect(
            events.first
                == .models([ModelCatalog.nemotron.info(isDownloaded: false, isRequired: true)]))
        #expect(events.contains(.listening))
        #expect(events.last == .stopped)
        // Speaking without a session is an error, not a crash.
        #expect(events.contains { if case .error = $0 { true } else { false } })
    }

    @Test("a session that cannot start reports a fatal error and stops")
    func failedStart() async {
        let log = EventLog()
        let server = LiveVoiceServer(
            backend: FakeBackend(failsToStart: true, emit: log.append), emit: log.append)
        _ = await server.handle(.start(LiveSessionConfiguration(locale: "xx")))
        #expect(log.all.count == 2)
        #expect(log.all.last == .stopped)
        if case .error(_, let isFatal) = log.all.first {
            #expect(isFatal)
        } else {
            Issue.record("no error")
        }
    }

    @Test("prepares models without a session and reports the outcome")
    func prepares() async {
        let log = EventLog()
        let backend = FakeBackend(emit: log.append)
        let server = LiveVoiceServer(backend: backend, emit: log.append)
        _ = await server.handle(.prepare(LiveSessionConfiguration(locale: "tr-TR")))
        #expect(backend.calls.withLock { $0 } == ["prepare tr-TR"])
        #expect(log.all == [.prepared])

        let failing = EventLog()
        let broken = LiveVoiceServer(
            backend: FakeBackend(failsToStart: true, emit: failing.append), emit: failing.append)
        _ = await broken.handle(.prepare(LiveSessionConfiguration(locale: "xx")))
        #expect(failing.all.count == 1)
        if case .error(_, let isFatal) = failing.all.first {
            #expect(!isFatal)
        } else {
            Issue.record("no error")
        }
    }

    @Test("stop without a session still answers stopped")
    func stopWithoutSession() async {
        let log = EventLog()
        let server = LiveVoiceServer(backend: FakeBackend(emit: log.append), emit: log.append)
        _ = await server.handle(.stop)
        #expect(log.all == [.stopped])
    }

    @Test("downloads run in the background and failed deletes are reported")
    func downloadsAndDeletes() async {
        let log = EventLog()
        let server = LiveVoiceServer(backend: FakeBackend(emit: log.append), emit: log.append)
        _ = await server.handle(.downloadModels(ids: ["silero-vad", "kokoro-82m"]))
        await server.waitForBackgroundTasks()
        #expect(
            log.all == [.downloadFinished(id: "silero-vad"), .downloadFinished(id: "kokoro-82m")])
        _ = await server.handle(.deleteModels(ids: ["locked"]))
        #expect(log.all.count == 3)
    }

    @Test("adding models and voices reports the outcome or a readable error")
    func imports() async {
        let log = EventLog()
        let backend = FakeBackend(emit: log.append)
        let server = LiveVoiceServer(backend: backend, emit: log.append)
        _ = await server.handle(.importModel(path: "/tmp/My Kokoro"))
        await server.waitForBackgroundTasks()
        _ = await server.handle(.importModel(path: "/tmp/Photos"))
        await server.waitForBackgroundTasks()
        _ = await server.handle(.importVoice(modelID: "kokoro-82m", path: "/tmp/mine.json"))
        _ = await server.handle(.importVoice(modelID: "kokoro-82m", path: "/tmp/mine.wav"))
        #expect(
            log.all == [
                .modelImported(id: "custom-kokoro-abcdef"),
                .importFailed(
                    message: SpeechModelImportError.unrecognizedFolder("/tmp/Photos").description),
                .voiceImported(modelID: "kokoro-82m", voice: "mine"),
                .importFailed(
                    message: SpeechModelImportError.notAVoiceFile("/tmp/mine.wav").description),
            ])
    }

    @Test("deleting a built-in voice is a non-fatal error")
    func deletesVoices() async {
        let log = EventLog()
        let backend = FakeBackend(emit: log.append)
        let server = LiveVoiceServer(backend: backend, emit: log.append)
        _ = await server.handle(.deleteVoice(modelID: "supertonic-3", voice: "mine"))
        #expect(log.all.isEmpty)
        _ = await server.handle(.deleteVoice(modelID: "supertonic-3", voice: "F1"))
        #expect(log.all.count == 1)
        if case .error(let message, let isFatal) = log.all.first {
            #expect(!isFatal)
            #expect(message.contains("cannot be deleted"))
        } else {
            Issue.record("no error")
        }
    }

    @Test("transcriptions run in the background and report their id")
    func transcribes() async {
        let log = EventLog()
        let backend = FakeBackend(emit: log.append)
        let server = LiveVoiceServer(backend: backend, emit: log.append)
        _ = await server.handle(.transcribe(id: "a", path: "/tmp/meeting.wav", locale: "tr-TR"))
        _ = await server.handle(.transcribe(id: "b", path: "/tmp/meeting.txt", locale: "tr-TR"))
        await server.waitForBackgroundTasks()
        let events = log.all
        #expect(events.count == 2)
        #expect(
            events.contains(
                .transcribed(
                    id: "a",
                    segments: [LiveTranscriptSegment(text: "Merhaba.", start: 0.5, end: 1.2)])))
        #expect(
            events.contains {
                if case .transcriptionFailed(let id, _) = $0 { id == "b" } else { false }
            })
    }

    @Test("speaking sessions take speech")
    func speakingSession() async {
        let log = EventLog()
        let backend = FakeBackend(emit: log.append)
        let server = LiveVoiceServer(backend: backend, emit: log.append)
        _ = await server.handle(.start(LiveSessionConfiguration(locale: "tr-TR", mode: .speak)))
        _ = await server.handle(.speak(id: "1", text: "Merhaba.", isFinal: true))
        #expect(backend.calls.withLock { $0 } == ["start tr-TR", "speak 1 Merhaba. true"])
        #expect(log.all == [.listening])
    }

    @Test("quit stops the session and ends the loop")
    func quits() async {
        let log = EventLog()
        let backend = FakeBackend(emit: log.append)
        let server = LiveVoiceServer(backend: backend, emit: log.append)
        _ = await server.handle(.start(LiveSessionConfiguration(locale: "en-US")))
        #expect(await server.handle(.quit) == .quit)
        #expect(backend.calls.withLock { $0 }.last == "stop")
        #expect(log.all.last == .stopped)
    }
}
