import Foundation
import Testing

@testable import MomoVoice

/// Server events as the GA Realtime API documents them.
enum OpenAIFixtures {
    static let sessionCreated = #"""
        {"type":"session.created","event_id":"event_C9G5RJeJ2gF77mV7f2B1j","session":{"type":"realtime","object":"realtime.session","id":"sess_C9G5QPteg4UIbotdKLoYQ","model":"gpt-realtime-2025-08-28","output_modalities":["audio"],"instructions":"","tools":[],"tool_choice":"auto"}}
        """#
    static let sessionUpdated = #"""
        {"type":"session.updated","event_id":"event_C9G8mqI3IucaojlVKE8Cs","session":{"type":"realtime","object":"realtime.session","id":"sess_C9G8l3zp50uFv4qgxfJ8o","model":"gpt-realtime-2025-08-28","output_modalities":["audio"],"audio":{"input":{"format":{"type":"audio/pcm","rate":24000},"turn_detection":{"type":"server_vad","threshold":0.5,"prefix_padding_ms":300,"silence_duration_ms":200,"idle_timeout_ms":null,"create_response":true,"interrupt_response":true}},"output":{"format":{"type":"audio/pcm","rate":24000},"voice":"marin","speed":1}}}}
        """#
    static let speechStarted = #"""
        {"event_id":"event_1516","type":"input_audio_buffer.speech_started","audio_start_ms":1000,"item_id":"msg_003"}
        """#
    static let speechStopped = #"""
        {"event_id":"event_1718","type":"input_audio_buffer.speech_stopped","audio_end_ms":2000,"item_id":"msg_003"}
        """#
    static func transcriptionDelta(_ delta: String) -> String {
        #"{"type":"conversation.item.input_audio_transcription.delta","event_id":"event_001","item_id":"item_001","content_index":0,"delta":"\#(delta)"}"#
    }
    static let transcriptionCompleted = #"""
        {"type":"conversation.item.input_audio_transcription.completed","event_id":"event_CCXGRvtUVrax5SJAnNOWZ","item_id":"item_001","content_index":0,"transcript":"Hey, can you hear me?","usage":{"type":"tokens","total_tokens":22,"input_tokens":13,"input_token_details":{"text_tokens":0,"audio_tokens":13},"output_tokens":9}}
        """#
    static let responseCreated = #"""
        {"type":"response.created","event_id":"event_C9G8pqbTEddBSIxbBN6Os","response":{"object":"realtime.response","id":"resp_C9G8p7IH2WxLbkgPNouYL","status":"in_progress","status_details":null,"output":[]}}
        """#
    static func audioDelta(_ audio: Data, item: String = "msg_008") -> String {
        #"{"event_id":"event_4950","type":"response.output_audio.delta","response_id":"resp_001","item_id":"\#(item)","output_index":0,"content_index":0,"delta":"\#(audio.base64EncodedString())"}"#
    }
    static let transcriptDelta = #"""
        {"event_id":"event_4546","type":"response.output_audio_transcript.delta","response_id":"resp_001","item_id":"msg_008","output_index":0,"content_index":0,"delta":"Hello, how can I a"}
        """#
    static let transcriptDone = #"""
        {"event_id":"event_4748","type":"response.output_audio_transcript.done","response_id":"resp_001","item_id":"msg_008","output_index":0,"content_index":0,"transcript":"Hello, how can I assist you today?"}
        """#
    static let functionCallDone = #"""
        {"type":"response.output_item.done","event_id":"event_CCXLgMZPo3qioWCeQa4WH","response_id":"resp_CCXLfxmM5sXVJVz4mCa2S","output_index":0,"item":{"id":"item_CCXLecNJVIVR2HUy3ABLj","type":"function_call","status":"completed","name":"ask_momo","call_id":"call_sHlR7iaFwQ2YQOqm","arguments":"{\"request\":\"Yarın saat 9'a diş hekimi randevusu ekle\"}"}}
        """#
    static let messageItemDone = #"""
        {"type":"response.output_item.done","event_id":"event_1","response_id":"resp_1","output_index":0,"item":{"id":"item_1","type":"message","status":"completed","role":"assistant","content":[{"type":"output_audio","transcript":"Hi"}]}}
        """#
    static let responseDone = #"""
        {"type":"response.done","event_id":"event_CCXHxcMy86rrKhBLDdqCh","response":{"object":"realtime.response","id":"resp_CCXHw0UJld10EzIUXQCNh","status":"completed","status_details":null,"output":[{"id":"item_CCXHwGjjDUfOXbiySlK7i","type":"message","status":"completed","role":"assistant","content":[{"type":"output_audio","transcript":"Loud and clear! I can hear you perfectly. How can I help you today?"}]}],"usage":{"total_tokens":253,"input_tokens":132,"output_tokens":121}}}
        """#
    static let responseCancelled = #"""
        {"type":"response.done","event_id":"event_2","response":{"object":"realtime.response","id":"resp_2","status":"cancelled","status_details":{"type":"cancelled","reason":"turn_detected"},"output":[]}}
        """#
    static let responseFailed = #"""
        {"type":"response.done","event_id":"event_3","response":{"object":"realtime.response","id":"resp_3","status":"failed","status_details":{"type":"failed","error":{"type":"invalid_request_error","code":"insufficient_quota","message":"You exceeded your current quota."}},"output":[]}}
        """#
    static func error(code: String, message: String) -> String {
        #"{"type":"error","event_id":"event_890","error":{"type":"invalid_request_error","code":"\#(code)","message":"\#(message)","param":null,"event_id":"event_567"}}"#
    }
}

@Suite("OpenAI Realtime protocol")
struct OpenAIRealtimeCodecTests {
    let configuration = RealtimeSessionConfiguration(
        instructions: "You are Momo.", voice: "cedar", language: "tr-TR",
        tools: [
            RealtimeFunction(
                name: "ask_momo", description: "Ask Momo.",
                parameters: [RealtimeParameter(name: "request", description: "The request.")])
        ])

    @Test("connects to the GA endpoint with the model and a bearer key")
    func request() throws {
        let codec = OpenAIRealtimeCodec(apiKey: "sk-test", model: "gpt-realtime-2.1-mini")
        let request = try codec.connectionRequest()
        #expect(
            request.url?.absoluteString
                == "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1-mini")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(request.value(forHTTPHeaderField: "OpenAI-Beta") == nil)
    }

    @Test("sets up audio formats, voice, turn detection, transcription and tools")
    func setup() throws {
        let codec = OpenAIRealtimeCodec(apiKey: "sk", model: OpenAIRealtime.defaultModel)
        let messages = try codec.setupMessages(for: configuration)
        #expect(messages.count == 1)
        let json = try #require(RealtimeJSON.object(messages[0]))
        #expect(json["type"] as? String == "session.update")
        let session = try #require(json["session"] as? [String: Any])
        #expect(session["type"] as? String == "realtime")
        #expect(session["instructions"] as? String == "You are Momo.")
        #expect(session["output_modalities"] as? [String] == ["audio"])
        #expect(session["tool_choice"] as? String == "auto")
        let audio = try #require(session["audio"] as? [String: Any])
        let input = try #require(audio["input"] as? [String: Any])
        let output = try #require(audio["output"] as? [String: Any])
        let format = try #require(input["format"] as? [String: Any])
        #expect(format["type"] as? String == "audio/pcm")
        #expect(format["rate"] as? Int == 24_000)
        #expect((output["format"] as? [String: Any])?["rate"] as? Int == 24_000)
        #expect(output["voice"] as? String == "cedar")
        let turn = try #require(input["turn_detection"] as? [String: Any])
        #expect(turn["type"] as? String == "semantic_vad")
        #expect(turn["interrupt_response"] as? Bool == true)
        #expect(turn["create_response"] as? Bool == true)
        let transcription = try #require(input["transcription"] as? [String: Any])
        #expect(transcription["model"] as? String == "gpt-4o-mini-transcribe")
        #expect(transcription["language"] as? String == "tr")
        let tools = try #require(session["tools"] as? [[String: Any]])
        #expect(tools.first?["type"] as? String == "function")
        #expect(tools.first?["name"] as? String == "ask_momo")
        let parameters = try #require(tools.first?["parameters"] as? [String: Any])
        #expect(parameters["type"] as? String == "object")
        #expect(parameters["required"] as? [String] == ["request"])
    }

    @Test("uses server VAD for silence-based turns and skips transcription when off")
    func serverVAD() throws {
        var configuration = configuration
        configuration.turnDetection = .silence(milliseconds: 700)
        configuration.transcribesInput = false
        configuration.voice = nil
        configuration.tools = []
        let codec = OpenAIRealtimeCodec(apiKey: "sk", model: "m")
        let json = try #require(RealtimeJSON.object(try codec.setupMessages(for: configuration)[0]))
        let session = try #require(json["session"] as? [String: Any])
        let audio = try #require(session["audio"] as? [String: Any])
        let input = try #require(audio["input"] as? [String: Any])
        let turn = try #require(input["turn_detection"] as? [String: Any])
        #expect(turn["type"] as? String == "server_vad")
        #expect(turn["silence_duration_ms"] as? Int == 700)
        #expect(input["transcription"] == nil)
        #expect((audio["output"] as? [String: Any])?["voice"] as? String == "marin")
        #expect(session["tools"] == nil)
    }

    @Test("appends base64 audio to the input buffer")
    func audioAppend() throws {
        let codec = OpenAIRealtimeCodec(apiKey: "sk", model: "m")
        let pcm = RealtimePCM.encode([0.25, -0.25, 0.5])
        let json = try #require(RealtimeJSON.object(codec.audioMessage(pcm)))
        #expect(json["type"] as? String == "input_audio_buffer.append")
        #expect(json["audio"] as? String == pcm.base64EncodedString())
    }

    @Test("returns a function result as a conversation item, then asks for a response")
    func functionResult() throws {
        let codec = OpenAIRealtimeCodec(apiKey: "sk", model: "m")
        let call = RealtimeFunctionCall(id: "call_1", name: "ask_momo", arguments: "{}")
        let messages = try codec.functionResultMessages(#"{"status":"done"}"#, for: call)
            .compactMap(RealtimeJSON.object)
        #expect(messages.count == 2)
        #expect(messages[0]["type"] as? String == "conversation.item.create")
        let item = try #require(messages[0]["item"] as? [String: Any])
        #expect(item["type"] as? String == "function_call_output")
        #expect(item["call_id"] as? String == "call_1")
        #expect(item["output"] as? String == #"{"status":"done"}"#)
        #expect(messages[1]["type"] as? String == "response.create")
    }

    @Test("adds a typed turn as a user message, then asks for a response")
    func userText() throws {
        let messages = try OpenAIRealtimeCodec(apiKey: "sk", model: "m")
            .userTextMessages("What's on my calendar?").compactMap(RealtimeJSON.object)
        #expect(messages.count == 2)
        #expect(messages[0]["type"] as? String == "conversation.item.create")
        let item = try #require(messages[0]["item"] as? [String: Any])
        #expect(item["role"] as? String == "user")
        let content = try #require((item["content"] as? [[String: Any]])?.first)
        #expect(content["type"] as? String == "input_text")
        #expect(content["text"] as? String == "What's on my calendar?")
        #expect(messages[1]["type"] as? String == "response.create")
    }

    @Test("decodes every handled server event")
    func decodes() {
        var codec = OpenAIRealtimeCodec(apiKey: "sk", model: "m")
        #expect(codec.decode(OpenAIFixtures.sessionCreated).isEmpty)
        #expect(codec.decode(OpenAIFixtures.sessionUpdated) == [.ready])
        #expect(codec.decode(OpenAIFixtures.speechStarted) == [.userSpeechStarted])
        #expect(codec.decode(OpenAIFixtures.speechStopped) == [.userSpeechStopped])
        #expect(
            codec.decode(OpenAIFixtures.transcriptionDelta("Hey, "))
                == [.userTranscript("Hey, ", isFinal: false)])
        #expect(
            codec.decode(OpenAIFixtures.transcriptionDelta("can you"))
                == [.userTranscript("Hey, can you", isFinal: false)])
        #expect(
            codec.decode(OpenAIFixtures.transcriptionCompleted)
                == [.userTranscript("Hey, can you hear me?", isFinal: true)])
        #expect(codec.decode(OpenAIFixtures.responseCreated).isEmpty)
        #expect(codec.responseActive)
        let audio = RealtimePCM.encode([0.1, 0.2])
        #expect(codec.decode(OpenAIFixtures.audioDelta(audio)) == [.assistantAudio(audio)])
        #expect(codec.audioItemID == "msg_008")
        #expect(
            codec.decode(OpenAIFixtures.transcriptDelta)
                == [.assistantTranscriptDelta("Hello, how can I a")])
        #expect(
            codec.decode(OpenAIFixtures.transcriptDone)
                == [.assistantTranscriptDone("Hello, how can I assist you today?")])
        #expect(
            codec.decode(OpenAIFixtures.functionCallDone) == [
                .functionCall(
                    RealtimeFunctionCall(
                        id: "call_sHlR7iaFwQ2YQOqm", name: "ask_momo",
                        arguments: #"{"request":"Yarın saat 9'a diş hekimi randevusu ekle"}"#))
            ])
        #expect(codec.decode(OpenAIFixtures.messageItemDone).isEmpty)
        #expect(codec.decode(OpenAIFixtures.responseDone) == [.responseDone(.completed)])
        #expect(!codec.responseActive)
        #expect(codec.decode(OpenAIFixtures.responseCancelled) == [.responseDone(.cancelled)])
        #expect(codec.decode(#"{"type":"rate_limits.updated","rate_limits":[]}"#).isEmpty)
        #expect(codec.decode("not json").isEmpty)
    }

    @Test("maps errors to readable messages and ignores expected ones")
    func errors() throws {
        var codec = OpenAIRealtimeCodec(apiKey: "sk", model: "m")
        let key = codec.decode(
            OpenAIFixtures.error(code: "invalid_api_key", message: "Incorrect API key provided."))
        guard case .error(let error) = key.first else {
            Issue.record("expected an error")
            return
        }
        #expect(error.status == 401)
        #expect(error.message.contains("Check it in Settings"))
        #expect(
            codec.decode(
                OpenAIFixtures.error(
                    code: "response_cancel_not_active", message: "No active response.")
            ).isEmpty)
        let other = codec.decode(OpenAIFixtures.error(code: "invalid_value", message: "Bad."))
        #expect(
            other == [.error(CloudVoiceError("The live voice service reported an error. Bad."))])
        let failed = codec.decode(OpenAIFixtures.responseFailed)
        #expect(failed.count == 2)
        #expect(failed.last == .responseDone(.failed))
        guard case .error(let quota) = failed.first else {
            Issue.record("expected an error")
            return
        }
        #expect(quota.status == 429)
    }

    @Test("cancels and truncates to what was heard on barge-in")
    func bargeIn() throws {
        var codec = OpenAIRealtimeCodec(apiKey: "sk", model: "m")
        _ = codec.decode(OpenAIFixtures.responseCreated)
        // One second of speech.
        _ = codec.decode(OpenAIFixtures.audioDelta(Data(count: 48_000), item: "item_9"))
        let messages = codec.interruptMessages(playedMilliseconds: 5_000)
            .compactMap(RealtimeJSON.object)
        #expect(messages.count == 2)
        #expect(messages[0]["type"] as? String == "response.cancel")
        #expect(messages[1]["type"] as? String == "conversation.item.truncate")
        #expect(messages[1]["item_id"] as? String == "item_9")
        #expect(messages[1]["content_index"] as? Int == 0)
        #expect(messages[1]["audio_end_ms"] as? Int == 1_000)  // no more than was received
        #expect(codec.audioItemID == nil)
        // After the response ended there is nothing to cancel or truncate.
        _ = codec.decode(OpenAIFixtures.responseCancelled)
        #expect(codec.interruptMessages(playedMilliseconds: 100).isEmpty)
    }
}

@Suite("Realtime voice session", .timeLimit(.minutes(1)))
struct RealtimeVoiceSessionTests {
    /// A session whose fake server accepts the configuration.
    func readySession() async throws -> (
        RealtimeVoiceSession, FakeRealtimeTransportFactory, AsyncStream<RealtimeEvent>.Iterator
    ) {
        let factory = FakeRealtimeTransportFactory()
        factory.transport.autoReply { text in
            text.contains("\"session.update\"") ? [OpenAIFixtures.sessionUpdated] : []
        }
        factory.transport.push(OpenAIFixtures.sessionCreated)
        let session = RealtimeVoiceSession(
            service: .openAI(apiKey: "sk-secret"), transportFactory: factory, readyTimeout: 5)
        var events = session.events.makeAsyncIterator()
        try await session.connect(RealtimeSessionConfiguration(instructions: "Hi"))
        #expect(await nextEvent(&events) == .ready)
        return (session, factory, events)
    }

    @Test("connects, configures first and becomes ready")
    func connects() async throws {
        let (session, factory, _) = try await readySession()
        #expect(await session.state == .ready)
        #expect(factory.transport.sentObjects.first?["type"] as? String == "session.update")
        #expect(factory.lastRequest?.url?.query() == "model=gpt-realtime-2.1")
        #expect(session.displayName == "OpenAI gpt-realtime-2.1")
        #expect(!session.displayName.contains("sk-secret"))
        #expect(session.inputSampleRate == 24_000 && session.outputSampleRate == 24_000)
        #expect(await session.usage.textCharactersSent == 2)
        await session.close()
    }

    @Test("streams microphone audio and counts it")
    func audio() async throws {
        let (session, factory, _) = try await readySession()
        let frame = Data(count: 960 * 2)  // 40 ms at 24 kHz
        await session.sendAudio(frame)
        await session.sendAudio(frame)
        await factory.transport.waitForSent(3)
        let appends = factory.transport.sentObjects.filter {
            $0["type"] as? String == "input_audio_buffer.append"
        }
        #expect(appends.count == 2)
        #expect(appends.first?["audio"] as? String == frame.base64EncodedString())
        #expect(abs(await session.usage.inputAudioSeconds - 0.08) < 0.0001)
        await session.close()
    }

    @Test("round-trips a function call")
    func functionCall() async throws {
        let (session, factory, iterator) = try await readySession()
        var events = iterator
        factory.transport.push(OpenAIFixtures.functionCallDone)
        guard case .functionCall(let call) = await nextEvent(&events) else {
            Issue.record("expected a function call")
            return
        }
        #expect(call.name == "ask_momo")
        let output = AskMomoResult.answer("Added.").output
        await session.sendFunctionResult(output, for: call)
        await factory.transport.waitForSent(3)
        let sent = factory.transport.sentObjects.suffix(2)
        #expect(sent.first?["type"] as? String == "conversation.item.create")
        #expect((sent.first?["item"] as? [String: Any])?["call_id"] as? String == call.id)
        #expect(sent.last?["type"] as? String == "response.create")
        #expect(await session.usage.textCharactersSent == 2 + output.count)
        await session.close()
    }

    @Test("sends a typed turn and counts its characters")
    func userTextTurn() async throws {
        let (session, factory, _) = try await readySession()
        await session.sendUserText("  Hello  ")
        await factory.transport.waitForSent(3)
        #expect(
            factory.transport.sentObjects.suffix(2).first?["type"] as? String
                == "conversation.item.create")
        #expect(await session.usage.textCharactersSent == 2 + 5)
        await session.close()
    }

    @Test("reports barge-in and sends cancel and truncate")
    func bargeIn() async throws {
        let (session, factory, iterator) = try await readySession()
        var events = iterator
        factory.transport.push(OpenAIFixtures.responseCreated)
        factory.transport.push(OpenAIFixtures.audioDelta(Data(count: 24_000), item: "item_7"))
        factory.transport.push(OpenAIFixtures.speechStarted)
        #expect(await nextEvent(&events) == .assistantAudio(Data(count: 24_000)))
        #expect(await nextEvent(&events) == .userSpeechStarted)
        #expect(abs(await session.usage.outputAudioSeconds - 0.5) < 0.0001)
        await session.interrupt(playedMilliseconds: 250)
        await factory.transport.waitForSent(3)
        let sent = factory.transport.sentObjects.suffix(2)
        #expect(sent.first?["type"] as? String == "response.cancel")
        #expect(sent.last?["type"] as? String == "conversation.item.truncate")
        #expect(sent.last?["audio_end_ms"] as? Int == 250)
        await session.close()
    }

    @Test("close ends the stream cleanly and ignores later audio")
    func close() async throws {
        let (session, factory, iterator) = try await readySession()
        var events = iterator
        await session.close()
        #expect(await nextEvent(&events) == .closed(nil))
        #expect(await nextEvent(&events) == nil)
        #expect(factory.transport.isClosed)
        let count = factory.transport.sentMessages.count
        await session.sendAudio(Data(count: 10))
        #expect(factory.transport.sentMessages.count == count)
        #expect(await session.state == .closed)
        await #expect(throws: CloudVoiceError.self) {
            try await session.connect(RealtimeSessionConfiguration(instructions: ""))
        }
    }

    @Test("a dropped connection closes the session with the reason")
    func dropped() async throws {
        let (session, factory, iterator) = try await readySession()
        var events = iterator
        factory.transport.fail(RealtimeErrors.noConnection)
        #expect(await nextEvent(&events) == .closed(RealtimeErrors.noConnection))
        #expect(await session.state == .closed)
    }

    @Test("times out when the service never confirms the configuration")
    func timeout() async throws {
        let factory = FakeRealtimeTransportFactory()
        let session = RealtimeVoiceSession(
            service: .openAI(apiKey: "sk"), transportFactory: factory, readyTimeout: 0.05)
        await #expect(throws: RealtimeErrors.timedOut) {
            try await session.connect(RealtimeSessionConfiguration(instructions: ""))
        }
        var events = session.events.makeAsyncIterator()
        #expect(await nextEvent(&events) == .closed(RealtimeErrors.timedOut))
        #expect(factory.transport.isClosed)
    }

    @Test("fails to connect when the service rejects the key")
    func rejected() async throws {
        let factory = FakeRealtimeTransportFactory()
        factory.transport.autoReply { _ in
            [OpenAIFixtures.error(code: "invalid_api_key", message: "Incorrect API key provided.")]
        }
        let session = RealtimeVoiceSession(
            service: .openAI(apiKey: "sk"), transportFactory: factory, readyTimeout: 5)
        do {
            try await session.connect(RealtimeSessionConfiguration(instructions: ""))
            Issue.record("expected a failure")
        } catch let error as CloudVoiceError {
            #expect(error.status == 401)
            #expect(!error.message.contains("sk"))
        }
        #expect(await session.state == .closed)
    }

    @Test("reports a failed handshake")
    func handshake() async {
        let failure = CloudVoiceError.http(status: 401, body: Data())
        let session = RealtimeVoiceSession(
            service: .openAI(apiKey: "sk"),
            transportFactory: FakeRealtimeTransportFactory(failure: failure))
        await #expect(throws: failure) {
            try await session.connect(RealtimeSessionConfiguration(instructions: ""))
        }
    }
}

@Suite("Realtime errors")
struct RealtimeErrorTests {
    @Test("maps socket failures to readable errors")
    func socketErrors() {
        func map(
            _ error: any Error, code: Int? = nil, reason: String = "", status: Int? = nil
        )
            -> (any Error)
        {
            URLSessionRealtimeTransport.map(
                error, closeCode: code, closeReason: reason, handshakeStatus: status)
        }
        #expect(map(URLError(.cancelled)) is CancellationError)
        #expect(map(URLError(.timedOut)) as? CloudVoiceError == RealtimeErrors.timedOut)
        #expect(
            map(URLError(.notConnectedToInternet)) as? CloudVoiceError
                == RealtimeErrors.noConnection)
        #expect((map(URLError(.badServerResponse), status: 401) as? CloudVoiceError)?.status == 401)
        let key = map(
            URLError(.networkConnectionLost), code: 1008,
            reason: "API key not valid. Please pass a valid API key.")
        #expect((key as? CloudVoiceError)?.status == 401)
        #expect((key as? CloudVoiceError)?.message.contains("Settings") == true)
        let server = map(URLError(.networkConnectionLost), code: 1011, reason: "Internal error")
        #expect(
            (server as? CloudVoiceError)?.message
                == "The live voice service had a server error. Internal error")
        #expect(
            RealtimeErrors.closed(code: 1000, reason: "").message
                == "The live voice service ended the session.")
        #expect(RealtimeErrors.closed(code: 1007, reason: "Quota exceeded").status == 429)
    }
}
