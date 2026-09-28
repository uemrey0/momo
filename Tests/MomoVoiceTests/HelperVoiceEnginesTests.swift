import Foundation
import MomoLiveProtocol
import Testing

@testable import MomoVoice

@MainActor
@Suite("Voice model engines")
struct HelperVoiceEnginesTests {
    final class Launches {
        var transports: [FakeHelperTransport] = []
        var latest: FakeHelperTransport? { transports.last }
    }

    func makeClient() -> (LiveVoiceHelperClient, Launches) {
        let launches = Launches()
        let client = LiveVoiceHelperClient(handshakeTimeout: .milliseconds(300)) {
            let transport = FakeHelperTransport()
            launches.transports.append(transport)
            return transport
        }
        return (client, launches)
    }

    /// The `start` commands the helper received.
    func starts(_ helper: FakeHelperTransport) -> [LiveSessionConfiguration] {
        helper.commands.compactMap { if case .start(let session) = $0 { session } else { nil } }
    }

    @Test("dictation listens without speaking and delivers the first turn")
    func dictation() async throws {
        let (client, launches) = makeClient()
        let engine = HelperDictationEngine(client: client)
        var partials: [String] = []
        var finals: [String] = []
        engine.onPartial = { partials.append($0) }
        engine.onFinal = { finals.append($0) }
        try await engine.start(locale: Locale(identifier: "tr_TR"))
        #expect(engine.isListening)
        let helper = try #require(launches.latest)
        #expect(starts(helper).first?.mode == .listen)

        helper.emit(.partial("yarın"))
        helper.emit(.turn("yarın hava nasıl"))
        #expect(await eventually { finals == ["yarın hava nasıl"] })
        #expect(partials.first == "yarın")
        #expect(!engine.isListening)
        #expect(await eventually { helper.commands.last == .stop })
    }

    @Test("push to talk collects every turn until the key is let go")
    func continuousDictation() async throws {
        let (client, launches) = makeClient()
        let engine = HelperDictationEngine(client: client)
        engine.isContinuous = true
        var finals: [String] = []
        engine.onFinal = { finals.append($0) }
        try await engine.start(locale: Locale(identifier: "en_US"))
        let helper = try #require(launches.latest)
        helper.emit(.turn("Remind me"))
        helper.emit(.partial("to call Ayşe"))
        #expect(await eventually { engine.isListening })
        try await Task.sleep(for: .milliseconds(50))
        #expect(finals.isEmpty)
        engine.stop(deliver: true)
        #expect(finals == ["Remind me to call Ayşe"])
    }

    @Test("reads text aloud in a session that never opens the microphone")
    func speaker() async throws {
        let (client, launches) = makeClient()
        let speaker = HelperSpeaker(client: client)
        var started = 0
        var finished = 0
        speaker.onStart = { started += 1 }
        speaker.onFinish = { finished += 1 }
        speaker.speak("**Merhaba!** Bugün hava güneşli.", fallbackLanguage: "tr")
        #expect(speaker.isSpeaking)
        let helper = try #require(await eventuallyValue { launches.latest })
        #expect(
            await eventually {
                helper.commands.contains { if case .speak = $0 { true } else { false } }
            })
        #expect(starts(helper).first?.mode == .speak)
        let spoken = helper.commands.compactMap {
            if case .speak(let id, let text, let isFinal) = $0 { (id, text, isFinal) } else { nil }
        }
        let utterance = try #require(spoken.first)
        #expect(utterance.1 == "Merhaba! Bugün hava güneşli.")
        #expect(utterance.2)

        helper.emit(.speakingStarted(id: utterance.0))
        #expect(await eventually { started == 1 })
        helper.emit(.speakingFinished(id: utterance.0))
        #expect(await eventually { finished == 1 && !speaker.isSpeaking })
    }

    @Test("transcribes a recording through a temporary file and returns timed segments")
    func transcription() async throws {
        let (client, launches) = makeClient()
        let service = HelperTranscriptionService(
            client: client, locale: Locale(identifier: "tr_TR"))
        let clip = AudioClip.wav(samples: [Float](repeating: 0, count: 1_600), sampleRate: 16_000)
        let transcript = try await service.transcribe(clip, options: TranscriptionOptions())
        #expect(transcript.text == "Merhaba nasılsın?")
        #expect(transcript.segments.map(\.start) == [0.2, 1.4])
        let helper = try #require(launches.latest)
        let path = try #require(
            helper.commands.compactMap {
                if case .transcribe(_, let path, let locale) = $0, locale == "tr-TR" {
                    path
                } else {
                    nil
                }
            }.first)
        // The recording is deleted once it was transcribed.
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test("adds a model folder and a voice file, and reports what went wrong")
    func imports() async throws {
        let (client, launches) = makeClient()
        let models = LiveVoiceModels(
            client: client, locale: "tr-TR", record: PreparedMemory().record)
        let added = await models.importModel(from: URL(fileURLWithPath: "/tmp/My Voice"))
        #expect(added == .success("custom-mine"))
        let broken = await models.importModel(from: URL(fileURLWithPath: "/tmp/Broken"))
        #expect(broken == .failure(.init(message: "The folder has no voices.")))
        let voice = await models.importVoice(
            from: URL(fileURLWithPath: "/tmp/voice.json"), into: "kokoro-82m")
        #expect(voice == .success("my_voice"))
        #expect(models.lastImport == "my_voice")
        let helper = try #require(launches.latest)
        #expect(
            helper.commands.contains(
                .importVoice(modelID: "kokoro-82m", path: "/tmp/voice.json")))
        // Every import lists the models again, so Settings shows what was added.
        #expect(
            helper.commands.filter { if case .listModels = $0 { true } else { false } }.count >= 3)
    }

    @Test("wakes on “Hey Momo” and passes on what followed")
    func wakeWord() async throws {
        let (client, launches) = makeClient()
        let listener = HelperWakeWordListener(client: client)
        var commands: [String] = []
        listener.onWake = { commands.append($0) }
        try await listener.start(locale: Locale(identifier: "en_US"))
        let helper = try #require(launches.latest)
        #expect(starts(helper).first?.mode == .listen)
        helper.emit(.turn("what a nice day"))
        helper.emit(.partial("hey momo what"))
        helper.emit(.turn("hey momo what time is it"))
        #expect(await eventually { commands == ["what time is it"] })
        listener.stop()
        #expect(!listener.isRunning)
    }
}

/// Waits until `value` returns something, for up to about two seconds.
@MainActor
func eventuallyValue<Value>(_ value: () -> Value?) async -> Value? {
    for _ in 0..<200 {
        if let result = value() { return result }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return value()
}
