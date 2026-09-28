import Foundation
import Testing

@testable import MomoLiveProtocol

@Suite("Live voice protocol")
struct LiveVoiceProtocolTests {
    @Test("commands survive a round trip as single lines")
    func commandsRoundTrip() throws {
        let commands: [LiveVoiceCommand] = [
            .hello(version: liveVoiceProtocolVersion),
            .listModels(locale: "tr-TR", textToSpeechModel: nil),
            .listModels(locale: "tr-TR", textToSpeechModel: "supertonic-3"),
            .downloadModels(ids: ["kokoro", "silero-vad"]),
            .prepare(LiveSessionConfiguration(locale: "tr-TR")),
            .start(LiveSessionConfiguration(locale: "tr-TR", voice: "af_heart")),
            .start(LiveSessionConfiguration(locale: "tr-TR", mode: .speak)),
            .start(LiveSessionConfiguration(locale: "tr-TR", mode: .listen, maximumPause: 0.8)),
            .importModel(path: "/Users/me/My Voice"),
            .importVoice(modelID: "kokoro-82m", path: "/tmp/voice.json"),
            .deleteVoice(modelID: "kokoro-82m", voice: "my_voice"),
            .transcribe(id: "t1", path: "/tmp/a.wav", locale: "tr-TR"),
            .speak(id: "1", text: "Merhaba, \"nasılsın\"?\nİyi misin?", isFinal: false),
            .cancelSpeech, .stop, .quit,
        ]
        for command in commands {
            let line = try LiveVoiceCoding.line(command)
            #expect(line.last == 0x0A)
            #expect(line.dropLast().contains(0x0A) == false)
            let text = try #require(String(data: line, encoding: .utf8))
            #expect(try LiveVoiceCoding.decode(LiveVoiceCommand.self, from: text) == command)
        }
    }

    @Test("events survive a round trip")
    func eventsRoundTrip() throws {
        let model = LiveModelInfo(
            id: "nemotron", kind: .speechToText, name: "Nemotron", languages: ["en", "tr"],
            sizeBytes: 600_000_000, isDownloaded: false, isRequired: true)
        let voice = LiveModelInfo(
            id: "custom-mine-a1b2c3", kind: .textToSpeech, name: "Mine", languages: ["tr"],
            sizeBytes: 1_000, isDownloaded: true, isCustom: true, voices: ["F1", "me"],
            customVoices: ["me"])
        let events: [LiveVoiceEvent] = [
            .ready(version: 2, languages: ["en", "tr"]), .models([model, voice]),
            .modelImported(id: "custom-mine-a1b2c3"),
            .voiceImported(modelID: "kokoro-82m", voice: "me"),
            .importFailed(message: "The folder has no voices."),
            .transcribed(
                id: "t1", segments: [LiveTranscriptSegment(text: "merhaba", start: 0.4, end: 1.1)]),
            .transcriptionFailed(id: "t2", message: "models missing"),
            .downloadProgress(id: "nemotron", fraction: 0.5), .partial("yarın"),
            .turn("yarın hava nasıl"), .interrupted(id: "3"), .prepared,
            .error(message: "no microphone", isFatal: true),
        ]
        for event in events {
            let text = try #require(String(data: LiveVoiceCoding.line(event), encoding: .utf8))
            #expect(try LiveVoiceCoding.decode(LiveVoiceEvent.self, from: text) == event)
        }
    }

    @Test("sessions say whether they listen and speak")
    func sessionModes() {
        #expect(LiveSessionConfiguration(locale: "tr-TR").listens)
        #expect(LiveSessionConfiguration(locale: "tr-TR").speaks)
        #expect(!LiveSessionConfiguration(locale: "tr-TR", mode: .speak).listens)
        #expect(!LiveSessionConfiguration(locale: "tr-TR", mode: .listen).speaks)
    }

    @Test("splits a byte stream into lines across chunk boundaries")
    func splitsLines() {
        var buffer = LiveVoiceLineBuffer()
        let bytes = Data("{\"a\":1}\n\n{\"b\":\"ş".utf8)
        #expect(buffer.append(bytes) == ["{\"a\":1}"])
        #expect(buffer.append(Data("\"}\n".utf8)) == ["{\"b\":\"ş\"}"])
        #expect(buffer.append(Data()) == [])
    }
}
