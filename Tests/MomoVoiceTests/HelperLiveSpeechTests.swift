import Foundation
import MomoLiveProtocol
import Testing

@testable import MomoVoice

/// A helper that runs in the test: it reads the real protocol lines Momo writes and answers
/// with real event lines, split in two to exercise the line buffering.
@MainActor
final class FakeHelperTransport: LiveVoiceTransport {
    var version = liveVoiceProtocolVersion
    var answersHello = true
    /// Whether the helper answers `start` (a helper still compiling its models doesn't).
    var answersStart = true
    /// How the helper answers `prepare`: `nil` never, `true` prepared, `false` an error.
    var preparesSuccessfully: Bool? = true
    /// Whether the helper answers `transcribe` (a long recording takes a while).
    var answersTranscribe = true
    var models: [LiveModelInfo] = []
    private(set) var commands: [LiveVoiceCommand] = []
    private(set) var isRunning = false
    private var onData: ((Data) -> Void)?
    private var onExit: ((Int32) -> Void)?
    private var buffer = LiveVoiceLineBuffer()

    func launch(onData: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws {
        self.onData = onData
        self.onExit = onExit
        isRunning = true
    }

    func write(_ data: Data) throws {
        guard isRunning else { throw LiveVoiceHelperError.notRunning }
        for line in buffer.append(data) {
            let command = try LiveVoiceCoding.decode(LiveVoiceCommand.self, from: line)
            commands.append(command)
            answer(command)
        }
    }

    func terminate() {
        isRunning = false
    }

    private func answer(_ command: LiveVoiceCommand) {
        switch command {
        case .hello:
            if answersHello { emit(.ready(version: version, languages: ["en", "tr"])) }
        case .start:
            if answersStart { emit(.listening) }
        case .prepare:
            switch preparesSuccessfully {
            case true?: emit(.prepared)
            case false?:
                emit(.error(message: "No speech recognition model understands xx.", isFatal: false))
            case nil: break
            }
        case .listModels:
            emit(.models(models))
        case .downloadModels(let ids):
            for id in ids {
                emit(.downloadProgress(id: id, fraction: 0.5))
                emit(.downloadFinished(id: id))
            }
        case .importModel(let path):
            if path.hasSuffix("Broken") {
                emit(.importFailed(message: "The folder has no voices."))
            } else {
                emit(.modelImported(id: "custom-mine"))
            }
        case .importVoice(let modelID, _):
            emit(.voiceImported(modelID: modelID, voice: "my_voice"))
        case .transcribe(let id, _, _) where answersTranscribe:
            emit(
                .transcribed(
                    id: id,
                    segments: [
                        LiveTranscriptSegment(text: "Merhaba", start: 0.2, end: 0.9),
                        LiveTranscriptSegment(text: "nasılsın?", start: 1.4, end: 2.0),
                    ]))
        case .quit:
            crash(status: 0)
        default:
            break
        }
    }

    /// Sends an event as the helper would, in two pieces.
    func emit(_ event: LiveVoiceEvent) {
        guard let data = try? LiveVoiceCoding.line(event) else { return }
        let middle = data.count / 2
        let onData = onData
        Task { @MainActor in
            onData?(data.prefix(middle))
            onData?(data.suffix(from: middle))
        }
    }

    /// Ends the helper as if it died.
    func crash(status: Int32 = 1) {
        isRunning = false
        let onExit = onExit
        Task { @MainActor in onExit?(status) }
    }
}

/// Remembers prepared models in memory, so tests leave the user's defaults alone.
@MainActor
final class PreparedMemory {
    var value: String?
    var record: LiveVoicePreparedRecord {
        LiveVoicePreparedRecord(load: { self.value }, save: { self.value = $0 })
    }
}

/// Waits until `condition` holds, for up to about two seconds.
@MainActor
func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
@Suite("Voice helper client")
struct HelperClientTests {
    final class Launches {
        var transports: [FakeHelperTransport] = []
        var latest: FakeHelperTransport? { transports.last }
    }

    func makeClient(
        _ configure: @escaping (FakeHelperTransport) -> Void = { _ in }
    )
        -> (LiveVoiceHelperClient, Launches)
    {
        let launches = Launches()
        let client = LiveVoiceHelperClient(handshakeTimeout: .milliseconds(300)) {
            let transport = FakeHelperTransport()
            configure(transport)
            launches.transports.append(transport)
            return transport
        }
        return (client, launches)
    }

    @Test("greets the helper, starts a session and maps its events")
    func session() async throws {
        let (client, launches) = makeClient()
        let io = HelperLiveSpeechIO(client: client, startTimeout: .seconds(1))
        var events: [LiveSpeechEvent] = []
        io.onEvent = { events.append($0) }
        try await io.start(
            LiveSpeechConfiguration(
                locale: Locale(identifier: "tr_TR"), maximumPause: 1.1,
                textToSpeechModel: "supertonic-3", modelVoice: "F2"))
        #expect(io.isRunning)
        #expect(client.languages == ["en", "tr"])
        let helper = try #require(launches.latest)
        #expect(helper.commands.first == .hello(version: liveVoiceProtocolVersion))
        #expect(
            helper.commands.dropFirst().first
                == .start(
                    LiveSessionConfiguration(
                        locale: "tr-TR", textToSpeechModel: "supertonic-3", voice: "F2",
                        maximumPause: 1.1)))

        helper.emit(.speechStarted)
        helper.emit(.partial("yarın hava"))
        helper.emit(.turn("yarın hava nasıl"))
        helper.emit(.speakingStarted(id: "r1"))
        helper.emit(.mouth(0.4))
        helper.emit(.interrupted(id: "r1"))
        #expect(await eventually { events.count >= 7 })
        #expect(
            events == [
                .listening, .speechStarted, .partial("yarın hava"), .turn("yarın hava nasıl"),
                .speakingStarted(id: "r1"), .mouth(0.4), .interrupted(id: "r1"),
            ])

        io.speak(id: "r2", text: "Yarın güneşli.", isFinal: true)
        io.cancelSpeech()
        io.pauseListening()
        io.resumeListening()
        #expect(
            Array(helper.commands.suffix(4)) == [
                .speak(id: "r2", text: "Yarın güneşli.", isFinal: true), .cancelSpeech,
                .pauseListening, .resumeListening,
            ])
        io.stop()
        #expect(helper.commands.last == .stop)
        #expect(events.last == .stopped)
    }

    @Test("refuses a helper that speaks another protocol version")
    func incompatible() async {
        let (client, _) = makeClient { $0.version = liveVoiceProtocolVersion + 1 }
        await #expect(
            throws: LiveVoiceHelperError.incompatible(version: liveVoiceProtocolVersion + 1)
        ) {
            try await client.connect()
        }
        #expect(!client.isConnected)
    }

    @Test("gives up on a helper that never answers")
    func silent() async {
        let (client, launches) = makeClient { $0.answersHello = false }
        await #expect(throws: LiveVoiceHelperError.noAnswer) { try await client.connect() }
        #expect(launches.latest?.isRunning == false)
    }

    @Test("restarts a crashed helper once, then ends the session")
    func crash() async throws {
        let (client, launches) = makeClient()
        let io = HelperLiveSpeechIO(client: client, startTimeout: .seconds(1))
        var events: [LiveSpeechEvent] = []
        io.onEvent = { events.append($0) }
        try await io.start(LiveSpeechConfiguration(locale: Locale(identifier: "en_US")))

        launches.latest?.crash()
        #expect(await eventually { launches.transports.count == 2 })
        #expect(await eventually { launches.latest?.commands.count == 2 })
        #expect(
            launches.latest?.commands.last.map { if case .start = $0 { true } else { false } }
                == true)
        #expect(io.isRunning)
        #expect(events.contains(.error(message: "The voice helper restarted.", isFatal: false)))

        launches.latest?.crash()
        #expect(await eventually { !io.isRunning })
        #expect(events.last == .stopped)
        #expect(
            events.contains(
                .error(message: "The voice helper stopped unexpectedly.", isFatal: true)))
    }

    @Test("push to talk ends a turn with the words so far, once")
    func endTurn() async throws {
        let (client, launches) = makeClient()
        let io = HelperLiveSpeechIO(client: client, startTimeout: .seconds(1))
        var turns: [String] = []
        io.onEvent = { if case .turn(let text) = $0 { turns.append(text) } }
        try await io.start(LiveSpeechConfiguration(locale: Locale(identifier: "en_US")))
        let helper = try #require(launches.latest)
        helper.emit(.partial("add milk"))
        #expect(await eventually { !turns.isEmpty || helper.commands.count >= 2 })
        try await Task.sleep(for: .milliseconds(50))
        io.endTurn()
        #expect(turns == ["add milk"])
        #expect(Array(helper.commands.suffix(2)) == [.pauseListening, .resumeListening])
        // The helper reporting the same turn late is not a second turn.
        helper.emit(.turn("add milk"))
        helper.emit(.turn("what's next"))
        #expect(await eventually { turns.count == 2 })
        #expect(turns == ["add milk", "what's next"])
    }

    @Test("a helper that doesn't start listening in time is ended, so it can't open the mic later")
    func startTimeout() async throws {
        let (client, launches) = makeClient { $0.answersStart = false }
        let io = HelperLiveSpeechIO(client: client, startTimeout: .milliseconds(200))
        await #expect(throws: LiveVoiceHelperError.noAnswer) {
            try await io.start(LiveSpeechConfiguration(locale: Locale(identifier: "en_US")))
        }
        #expect(!io.isRunning)
        #expect(launches.latest?.isRunning == false)
        #expect(!client.isConnected)
    }

    @Test("reports where the helper stands, and prepares its models once per build")
    func status() async throws {
        let record = PreparedMemory().record
        let stt = LiveModelInfo(
            id: "stt", kind: .speechToText, name: "Speech", languages: ["en"], sizeBytes: 600,
            isDownloaded: true, isRequired: true)
        var missing = stt
        missing.isDownloaded = false

        #expect(LiveVoiceModels(client: nil).status == .unavailable)

        let (silentClient, _) = makeClient { $0.answersHello = false }
        let silent = LiveVoiceModels(client: silentClient, locale: "en-US", record: record)
        await silent.refresh()
        #expect(silent.status == .notResponding)

        let (emptyClient, _) = makeClient { $0.models = [missing] }
        let empty = LiveVoiceModels(client: emptyClient, locale: "en-US", record: record)
        await empty.refresh()
        #expect(empty.status == .modelsMissing)

        let (client, launches) = makeClient { $0.models = [stt] }
        let models = LiveVoiceModels(
            client: client, locale: "en-US", buildID: "build-1", record: record)
        await models.refresh()
        #expect(models.status == .preparing)
        #expect(await models.prepare())
        #expect(models.status == .ready)
        #expect(
            launches.latest?.commands.last == .prepare(LiveSessionConfiguration(locale: "en-US")))

        // A new helper build has to compile its models again.
        let (nextClient, _) = makeClient { $0.models = [stt] }
        let next = LiveVoiceModels(
            client: nextClient, locale: "en-US", buildID: "build-2", record: record)
        await next.refresh()
        #expect(next.status == .preparing)
        #expect(models.status == .ready)
        models.forgetPrepared()
        #expect(models.status == .preparing)
    }

    @Test("a failed or stuck preparation leaves the helper not ready and ends it")
    func failedPreparation() async throws {
        let record = PreparedMemory().record
        let stt = LiveModelInfo(
            id: "stt", kind: .speechToText, name: "Speech", languages: ["en"], sizeBytes: 600,
            isDownloaded: true, isRequired: true)
        let (client, launches) = makeClient {
            $0.models = [stt]
            $0.preparesSuccessfully = false
        }
        let models = LiveVoiceModels(client: client, locale: "en-US", record: record)
        await models.refresh()
        #expect(!(await models.prepare()))
        #expect(models.status == .preparing)
        #expect(launches.latest?.isRunning == false)

        let (stuckClient, stuckLaunches) = makeClient {
            $0.models = [stt]
            $0.preparesSuccessfully = nil
        }
        let stuck = LiveVoiceModels(
            client: stuckClient, locale: "en-US", record: record,
            prepareTimeout: .milliseconds(200))
        await stuck.refresh()
        #expect(!(await stuck.prepare()))
        #expect(!stuck.isPreparing)
        #expect(stuckLaunches.latest?.isRunning == false)
    }

    @Test("lists, downloads and deletes models only when asked")
    func models() async throws {
        let stt = LiveModelInfo(
            id: "stt", kind: .speechToText, name: "Speech", languages: ["en", "tr"],
            sizeBytes: 600, isDownloaded: false, isRequired: true)
        let tts = LiveModelInfo(
            id: "tts", kind: .textToSpeech, name: "Voice", languages: ["en"], sizeBytes: 300,
            isDownloaded: true, isRequired: true)
        let (client, launches) = makeClient { $0.models = [stt, tts] }
        let models = LiveVoiceModels(
            client: client, locale: "en-US", record: PreparedMemory().record)
        #expect(models.isAvailable)
        await models.refresh()
        #expect(models.models == [stt, tts])
        #expect(!models.isReady)
        #expect(models.missingDownloadSize == 600)
        let helper = try #require(launches.latest)
        #expect(!helper.commands.contains { if case .downloadModels = $0 { true } else { false } })

        models.downloadRequired()
        #expect(models.isDownloading)
        #expect(await eventually { models.isReady && !models.isDownloading })
        #expect(helper.commands.contains(.downloadModels(ids: ["stt"])))

        models.delete(["tts"])
        #expect(await eventually { helper.commands.contains(.deleteModels(ids: ["tts"])) })
        #expect(!LiveVoiceModels(client: nil).isAvailable)
    }
}

@MainActor
@Suite("Voice helper process")
struct HelperProcessTests {
    @Test("talks to a real child process over standard input and output")
    func process() async throws {
        let ready = try #require(
            String(
                data: LiveVoiceCoding.line(
                    LiveVoiceEvent.ready(version: liveVoiceProtocolVersion, languages: ["en"])),
                encoding: .utf8))
        let listening = try #require(
            String(data: LiveVoiceCoding.line(LiveVoiceEvent.listening), encoding: .utf8))
        let script = """
            #!/bin/sh
            while IFS= read -r line; do
              case "$line" in
                *hello*) printf '%s' '\(ready)' ;;
                *start*) printf '%s' '\(listening)' ;;
                *quit*) exit 0 ;;
              esac
            done
            """
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("momo-voice-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("momo-voice")
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)

        let client = LiveVoiceHelperClient(executableURL: url)
        let io = HelperLiveSpeechIO(client: client, startTimeout: .seconds(5))
        try await io.start(LiveSpeechConfiguration(locale: Locale(identifier: "en_US")))
        #expect(io.isRunning)
        #expect(client.languages == ["en"])
        io.stop()
        client.disconnect()
        #expect(!client.isConnected)
    }
}
