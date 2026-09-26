import Foundation
import Testing

@testable import MomoLiveProtocol

@Suite("Live voice protocol")
struct LiveVoiceProtocolTests {
    @Test("commands survive a round trip as single lines")
    func commandsRoundTrip() throws {
        let commands: [LiveVoiceCommand] = [
            .hello(version: liveVoiceProtocolVersion),
            .listModels(locale: "tr-TR"),
            .downloadModels(ids: ["kokoro", "silero-vad"]),
            .prepare(LiveSessionConfiguration(locale: "tr-TR")),
            .start(LiveSessionConfiguration(locale: "tr-TR", voice: "af_heart")),
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
        let events: [LiveVoiceEvent] = [
            .ready(version: 1, languages: ["en", "tr"]), .models([model]),
            .downloadProgress(id: "nemotron", fraction: 0.5), .partial("yarın"),
            .turn("yarın hava nasıl"), .interrupted(id: "3"), .prepared,
            .error(message: "no microphone", isFatal: true),
        ]
        for event in events {
            let text = try #require(String(data: LiveVoiceCoding.line(event), encoding: .utf8))
            #expect(try LiveVoiceCoding.decode(LiveVoiceEvent.self, from: text) == event)
        }
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
