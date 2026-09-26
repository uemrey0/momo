import Foundation
import Testing

@testable import MomoVoice

/// Server messages as the Live API documents them.
enum GeminiFixtures {
    static let setupComplete = #"{"setupComplete":{}}"#
    static func inputTranscription(_ text: String) -> String {
        #"{"serverContent":{"inputTranscription":{"text":"\#(text)"}}}"#
    }
    static func modelAudio(_ audio: Data) -> String {
        #"{"serverContent":{"modelTurn":{"role":"model","parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"\#(audio.base64EncodedString())"}}]}}}"#
    }
    static let thought = #"""
        {"serverContent":{"modelTurn":{"parts":[{"text":"**Planning** the reply","thought":true}]}}}
        """#
    static func outputTranscription(_ text: String) -> String {
        #"{"serverContent":{"outputTranscription":{"text":"\#(text)"}}}"#
    }
    static let interrupted = #"{"serverContent":{"interrupted":true}}"#
    static let turnComplete = #"""
        {"serverContent":{"turnComplete":true},"usageMetadata":{"promptTokenCount":412,"responseTokenCount":96,"totalTokenCount":508}}
        """#
    static let toolCall = #"""
        {"toolCall":{"functionCalls":[{"id":"function-call-6216","name":"ask_momo","args":{"request":"Bugün takvimimde ne var?"}}]}}
        """#
    static let toolCallCancellation = #"{"toolCallCancellation":{"ids":["function-call-6216"]}}"#
    static let goAway = #"{"goAway":{"timeLeft":"30s"}}"#
}

@Suite("Gemini Live protocol")
struct GeminiLiveCodecTests {
    let configuration = RealtimeSessionConfiguration(
        instructions: "You are Momo.", voice: "Puck", language: "tr-TR",
        tools: [
            RealtimeFunction(
                name: "ask_momo", description: "Ask Momo.",
                parameters: [RealtimeParameter(name: "request", description: "The request.")])
        ], turnDetection: .silence(milliseconds: 800))

    @Test("connects to BidiGenerateContent with the key in a header")
    func request() throws {
        let request = try GeminiLiveCodec(apiKey: "AIza-test", model: "m").connectionRequest()
        #expect(
            request.url?.absoluteString
                == "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        )
        #expect(request.url?.query() == nil)
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "AIza-test")
    }

    @Test("sets up audio responses, voice, transcription, activity detection and tools")
    func setup() throws {
        let codec = GeminiLiveCodec(apiKey: "k", model: GeminiLive.defaultModel)
        let messages = try codec.setupMessages(for: configuration)
        #expect(messages.count == 1)
        let json = try #require(RealtimeJSON.object(messages[0]))
        let setup = try #require(json["setup"] as? [String: Any])
        #expect(setup["model"] as? String == "models/gemini-3.8-live")
        let generation = try #require(setup["generationConfig"] as? [String: Any])
        #expect(generation["responseModalities"] as? [String] == ["AUDIO"])
        let speech = try #require(generation["speechConfig"] as? [String: Any])
        let voice = (speech["voiceConfig"] as? [String: Any])?["prebuiltVoiceConfig"]
        #expect((voice as? [String: Any])?["voiceName"] as? String == "Puck")
        let system = try #require(setup["systemInstruction"] as? [String: Any])
        let text = (system["parts"] as? [[String: Any]])?.first?["text"] as? String
        #expect(text?.hasPrefix("You are Momo.") == true)
        #expect(text?.contains("Speak Turkish") == true)
        #expect(setup["inputAudioTranscription"] is [String: Any])
        #expect(setup["outputAudioTranscription"] is [String: Any])
        let activity = (setup["realtimeInputConfig"] as? [String: Any])?[
            "automaticActivityDetection"]
        #expect((activity as? [String: Any])?["silenceDurationMs"] as? Int == 800)
        let tools = try #require(setup["tools"] as? [[String: Any]])
        let declaration = try #require(
            (tools.first?["functionDeclarations"] as? [[String: Any]])?.first)
        #expect(declaration["name"] as? String == "ask_momo")
        #expect(declaration["behavior"] as? String == "NON_BLOCKING")
        let parameters = try #require(declaration["parameters"] as? [String: Any])
        #expect(parameters["type"] as? String == "OBJECT")
        let request = (parameters["properties"] as? [String: Any])?["request"]
        #expect((request as? [String: Any])?["type"] as? String == "STRING")
        #expect(parameters["required"] as? [String] == ["request"])
    }

    @Test("leaves out optional parts when not needed")
    func minimalSetup() throws {
        let codec = GeminiLiveCodec(apiKey: "k", model: "models/x", nonBlockingCalls: false)
        let configuration = RealtimeSessionConfiguration(
            instructions: "Hi", transcribesInput: false)
        let json = try #require(RealtimeJSON.object(try codec.setupMessages(for: configuration)[0]))
        let setup = try #require(json["setup"] as? [String: Any])
        #expect(setup["model"] as? String == "models/x")
        #expect(setup["inputAudioTranscription"] == nil)
        #expect(setup["realtimeInputConfig"] == nil)
        #expect(setup["tools"] == nil)
    }

    @Test("sends 16 kHz PCM as realtime input")
    func audio() throws {
        let pcm = RealtimePCM.encode([0.5, -0.5])
        let json = try #require(
            RealtimeJSON.object(GeminiLiveCodec(apiKey: "k", model: "m").audioMessage(pcm)))
        let audio = (json["realtimeInput"] as? [String: Any])?["audio"] as? [String: Any]
        #expect(audio?["mimeType"] as? String == "audio/pcm;rate=16000")
        #expect(audio?["data"] as? String == pcm.base64EncodedString())
    }

    @Test("sends a typed turn as realtime text")
    func userText() throws {
        let messages = try GeminiLiveCodec(apiKey: "k", model: "m").userTextMessages("Merhaba")
        #expect(messages.count == 1)
        let json = try #require(RealtimeJSON.object(messages[0]))
        #expect((json["realtimeInput"] as? [String: Any])?["text"] as? String == "Merhaba")
    }

    @Test("answers a tool call with a function response scheduled when idle")
    func toolResponse() throws {
        let codec = GeminiLiveCodec(apiKey: "k", model: "m")
        let call = RealtimeFunctionCall(id: "function-call-1", name: "ask_momo", arguments: "{}")
        let json = try #require(
            RealtimeJSON.object(
                try codec.functionResultMessages(#"{"status":"done","answer":"Hi"}"#, for: call)[0])
        )
        let responses = (json["toolResponse"] as? [String: Any])?["functionResponses"]
        let response = try #require((responses as? [[String: Any]])?.first)
        #expect(response["id"] as? String == "function-call-1")
        #expect(response["name"] as? String == "ask_momo")
        let body = try #require(response["response"] as? [String: Any])
        #expect(body["answer"] as? String == "Hi")
        #expect(body["scheduling"] as? String == "WHEN_IDLE")
        let plain = try #require(
            RealtimeJSON.object(try codec.functionResultMessages("Plain text", for: call)[0]))
        let wrapped =
            ((plain["toolResponse"] as? [String: Any])?["functionResponses"]
            as? [[String: Any]])?.first?["response"] as? [String: Any]
        #expect(wrapped?["result"] as? String == "Plain text")
    }

    @Test("decodes a whole turn")
    func decodesTurn() {
        var codec = GeminiLiveCodec(apiKey: "k", model: "m")
        #expect(codec.decode(GeminiFixtures.setupComplete) == [.ready])
        #expect(
            codec.decode(GeminiFixtures.inputTranscription("Merhaba"))
                == [.userTranscript("Merhaba", isFinal: false)])
        #expect(
            codec.decode(GeminiFixtures.inputTranscription(" Momo"))
                == [.userTranscript("Merhaba Momo", isFinal: false)])
        #expect(codec.decode(GeminiFixtures.thought).isEmpty)
        let audio = RealtimePCM.encode([0.1])
        #expect(
            codec.decode(GeminiFixtures.modelAudio(audio)) == [
                .userTranscript("Merhaba Momo", isFinal: true), .assistantAudio(audio),
            ])
        #expect(
            codec.decode(GeminiFixtures.outputTranscription("Selam!"))
                == [.assistantTranscriptDelta("Selam!")])
        #expect(
            codec.decode(GeminiFixtures.turnComplete) == [
                .assistantTranscriptDone("Selam!"), .responseDone(.completed),
            ])
        #expect(codec.decode(GeminiFixtures.turnComplete).isEmpty)
    }

    @Test("reports interruptions, tool calls, cancellations and the end of a session")
    func decodesControl() {
        var codec = GeminiLiveCodec(apiKey: "k", model: "m")
        _ = codec.decode(GeminiFixtures.modelAudio(Data(count: 4)))
        #expect(
            codec.decode(GeminiFixtures.interrupted) == [
                .userSpeechStarted, .responseDone(.cancelled),
            ])
        #expect(codec.decode(GeminiFixtures.turnComplete).isEmpty)
        #expect(
            codec.decode(GeminiFixtures.toolCall) == [
                .functionCall(
                    RealtimeFunctionCall(
                        id: "function-call-6216", name: "ask_momo",
                        arguments: #"{"request":"Bugün takvimimde ne var?"}"#))
            ])
        #expect(
            codec.decode(GeminiFixtures.toolCallCancellation)
                == [.functionCallsCancelled(ids: ["function-call-6216"])])
        #expect(codec.decode(GeminiFixtures.goAway) == [.sessionEnding(timeLeft: 30)])
        #expect(codec.interruptMessages(playedMilliseconds: 300).isEmpty)
        #expect(codec.decode("[]").isEmpty)
    }
}

@Suite("Gemini Live session", .timeLimit(.minutes(1)))
struct GeminiLiveSessionTests {
    @Test("sets up first, becomes ready on a binary setupComplete and streams 16 kHz audio")
    func session() async throws {
        let factory = FakeRealtimeTransportFactory()
        factory.transport.autoReply { text in
            if text.contains("\"setup\"") {
                factory.transport.pushData(GeminiFixtures.setupComplete)
            }
            return []
        }
        let session = RealtimeVoiceSession(
            service: .gemini(apiKey: "AIza-secret"), transportFactory: factory, readyTimeout: 5)
        var events = session.events.makeAsyncIterator()
        try await session.connect(
            RealtimeSessionConfiguration(instructions: "Hi", tools: [MomoRealtimeAgent.askMomo]))
        #expect(await nextEvent(&events) == .ready)
        #expect(session.inputSampleRate == 16_000 && session.outputSampleRate == 24_000)
        #expect(session.displayName == "Gemini gemini-3.8-live")
        #expect(factory.lastRequest?.value(forHTTPHeaderField: "x-goog-api-key") == "AIza-secret")
        #expect(factory.transport.sentObjects.first?["setup"] != nil)

        await session.sendAudio(Data(count: 640))  // 20 ms at 16 kHz
        factory.transport.push(GeminiFixtures.toolCall)
        guard case .functionCall(let call) = await nextEvent(&events) else {
            Issue.record("expected a function call")
            return
        }
        await session.sendFunctionResult(
            AskMomoResult.answer("Saat üçte toplantın var.").output, for: call)
        await factory.transport.waitForSent(3)
        #expect(factory.transport.sentObjects[1]["realtimeInput"] != nil)
        #expect(factory.transport.sentObjects[2]["toolResponse"] != nil)
        #expect(abs(await session.usage.inputAudioSeconds - 0.02) < 0.0001)
        await session.close()
        #expect(await nextEvent(&events) == .closed(nil))
    }
}
