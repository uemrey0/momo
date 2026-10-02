import Foundation
import Testing

@testable import MomoVoice

@Suite("Engine selection")
struct EngineSelectionTests {
    @Test("Momo's voice models recognise speech by default")
    func onDevice() {
        #expect(
            DictationEngineSelector.select(.onDevice, hasOpenAIKey: true, hasGeminiKey: true)
                == .init(kind: .onDevice))
    }

    @Test("cloud engines need a key, otherwise the voice models run and the user is told")
    func cloud() {
        #expect(
            DictationEngineSelector.select(.openAI, hasOpenAIKey: true, hasGeminiKey: false)
                == .init(kind: .openAI))
        #expect(
            DictationEngineSelector.select(.openAI, hasOpenAIKey: false, hasGeminiKey: true)
                == .init(kind: .onDevice, isMissingKey: true))
        #expect(
            DictationEngineSelector.select(.gemini, hasOpenAIKey: true, hasGeminiKey: true)
                == .init(kind: .gemini))
        #expect(
            DictationEngineSelector.select(.gemini, hasOpenAIKey: true, hasGeminiKey: false)
                == .init(kind: .onDevice, isMissingKey: true))
        #expect(DictationEngineChoice.openAI.isRemote)
        #expect(!DictationEngineChoice.onDevice.isRemote)
    }

    @Test("reads Apple's engines of earlier versions as Momo's voice models")
    func legacyChoices() throws {
        for legacy in ["automatic", "appleSpeech"] {
            let data = Data("\"\(legacy)\"".utf8)
            #expect(try JSONDecoder().decode(DictationEngineChoice.self, from: data) == .onDevice)
        }
        #expect(
            try JSONDecoder().decode(SpeechVoiceChoice.self, from: Data("\"apple\"".utf8))
                == .onDevice)
        #expect(
            try JSONDecoder().decode(SpeechVoiceChoice.self, from: Data("\"openAI\"".utf8))
                == .openAI)
    }
}

@Suite("Voice activity detection")
struct VoiceActivityTests {
    /// Feeds `levels` at 20 per second from `start` and returns each event with its time.
    func run(
        _ detector: inout VoiceActivityDetector, _ levels: [Double], start: Double = 0
    ) -> [(Double, VoiceActivityDetector.Event)] {
        levels.enumerated().compactMap { index, level in
            let time = start + Double(index) * 0.05
            let event = detector.process(level: level, at: time)
            return event == .none ? nil : (time, event)
        }
    }

    @Test("ends the utterance after about a second of silence following speech")
    func endsOnSilence() {
        var detector = VoiceActivityDetector()
        let levels =
            Array(repeating: 0.05, count: 10) + Array(repeating: 0.7, count: 30)
            + Array(repeating: 0.05, count: 40)
        let events = run(&detector, levels)
        #expect(events.map(\.1) == [.speechStarted, .endOfUtterance])
        let speechEnd = 2.0  // the first quiet level after speech
        let ended = events.last?.0 ?? 0
        #expect(ended >= speechEnd + 0.95 && ended <= speechEnd + 1.1)
        #expect(detector.hasSpeech)
    }

    @Test("short pauses inside a sentence do not end it")
    func shortPause() {
        var detector = VoiceActivityDetector()
        let phrase = Array(repeating: 0.7, count: 10)
        let pause = Array(repeating: 0.05, count: 10)  // half a second
        let events = run(&detector, phrase + pause + phrase + pause + phrase)
        #expect(events.map(\.1) == [.speechStarted])
    }

    @Test("clicks are not speech")
    func ignoresClicks() {
        var detector = VoiceActivityDetector(noSpeechTimeout: 3)
        var levels = Array(repeating: 0.05, count: 80)
        levels[10] = 0.9
        levels[30] = 0.9
        let events = run(&detector, levels)
        #expect(events.map(\.1) == [.noSpeech])
        #expect(!detector.hasSpeech)
    }

    @Test("levels between the thresholds neither start nor end speech")
    func hysteresis() {
        var detector = VoiceActivityDetector()
        let events = run(
            &detector, Array(repeating: 0.7, count: 10) + Array(repeating: 0.25, count: 60))
        #expect(events.map(\.1) == [.speechStarted])
    }

    @Test("stops at the maximum duration")
    func maximumDuration() {
        var detector = VoiceActivityDetector(maximumDuration: 2)
        let events = run(&detector, Array(repeating: 0.7, count: 60))
        #expect(events.map(\.1) == [.speechStarted, .maximumDurationReached])
        #expect(detector.process(level: 0.7, at: 10) == .none)
    }

    @Test("push to talk ignores silence until the user lets go")
    func pushToTalk() {
        var detector = VoiceActivityDetector(endsOnSilence: false)
        let events = run(
            &detector, Array(repeating: 0.7, count: 10) + Array(repeating: 0.0, count: 300))
        #expect(events.map(\.1) == [.speechStarted])
    }

    @Test("reset starts a new utterance")
    func reset() {
        var detector = VoiceActivityDetector()
        _ = run(&detector, Array(repeating: 0.7, count: 10) + Array(repeating: 0.0, count: 30))
        detector.reset()
        #expect(!detector.hasSpeech)
        let events = run(&detector, Array(repeating: 0.7, count: 10), start: 100)
        #expect(events.map(\.1) == [.speechStarted])
    }
}

@Suite("Audio encoding")
struct AudioEncodingTests {
    @Test("writes a 16-bit mono WAV header")
    func wavHeader() {
        let data = WAVEncoder.encode(samples: [0, 0.5, -0.5, 1], sampleRate: 16_000)
        #expect(data.count == 44 + 8)
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<12], as: UTF8.self) == "WAVE")
        func uint32(_ offset: Int) -> UInt32 {
            data[offset..<offset + 4].enumerated().reduce(0) { $0 | UInt32($1.1) << (8 * $1.0) }
        }
        #expect(uint32(24) == 16_000)
        #expect(uint32(40) == 8)
    }

    @Test("round-trips samples through 16-bit PCM")
    func pcmRoundTrip() {
        let samples: [Float] = [0, 0.5, -0.5, 1, -1]
        let wav = WAVEncoder.encode(samples: samples, sampleRate: 24_000)
        let decoded = WAVEncoder.samples(fromPCM16: Data(wav.dropFirst(44)))
        #expect(decoded.count == samples.count)
        for (original, value) in zip(samples, decoded) {
            #expect(abs(original - value) < 0.001)
        }
        #expect(WAVEncoder.samples(fromPCM16: Data([1, 2, 3])).count == 1)
    }

    @Test("a clip knows its length")
    func clipDuration() {
        let clip = AudioClip.wav(samples: Array(repeating: 0, count: 8_000), sampleRate: 16_000)
        #expect(clip.duration == 0.5)
        #expect(clip.mimeType == "audio/wav")
    }

    @Test("transcripts from chunks can be stitched together")
    func offset() {
        let transcript = Transcript(
            text: "hi", segments: [TranscriptSegment(text: "hi", start: 1, end: 2, speaker: "A")])
        #expect(
            transcript.offset(by: 30).segments == [
                TranscriptSegment(text: "hi", start: 31, end: 32, speaker: "A")
            ])
    }
}

@Suite("OpenAI transcription")
struct OpenAITranscriptionTests {
    let clip = AudioClip(
        data: Data("RIFFfake".utf8), mimeType: "audio/wav", fileName: "a.wav", duration: 2)

    func form(_ request: URLRequest) -> String {
        String(decoding: request.httpBody ?? Data(), as: UTF8.self)
    }

    func field(_ name: String, in body: String) -> String? {
        let marker = "name=\"\(name)\"\r\n\r\n"
        guard let range = body.range(of: marker) else { return nil }
        return body[range.upperBound...].components(separatedBy: "\r\n").first
    }

    @Test("builds a multipart upload with the model and key")
    func request() {
        let service = OpenAITranscriptionService(apiKey: "sk-test", model: .gpt4oMiniTranscribe)
        let request = service.makeRequest(
            clip, options: TranscriptionOptions(language: "tr-TR", prompt: "Momo"))
        let body = form(request)
        #expect(request.url?.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        #expect(
            request.value(forHTTPHeaderField: "Content-Type")?
                .hasPrefix("multipart/form-data; boundary=") == true)
        #expect(field("model", in: body) == "gpt-4o-mini-transcribe")
        #expect(field("language", in: body) == "tr")
        #expect(field("prompt", in: body) == "Momo")
        #expect(field("response_format", in: body) == "json")
        #expect(body.contains("filename=\"a.wav\""))
        #expect(body.contains("RIFFfake"))
        #expect(body.hasSuffix("--\r\n"))
    }

    @Test("asks the diarizing model for speakers")
    func diarize() {
        let service = OpenAITranscriptionService(apiKey: "k", model: .gpt4oTranscribe)
        let body = form(
            service.makeRequest(
                clip, options: TranscriptionOptions(prompt: "ignored", identifiesSpeakers: true)))
        #expect(field("model", in: body) == "gpt-4o-transcribe-diarize")
        #expect(field("response_format", in: body) == "diarized_json")
        #expect(field("chunking_strategy", in: body) == "auto")
        #expect(field("prompt", in: body) == nil)
    }

    @Test("asks whisper for timed segments")
    func whisperSegments() {
        let service = OpenAITranscriptionService(apiKey: "k", model: .whisper1)
        let body = form(
            service.makeRequest(clip, options: TranscriptionOptions(wantsSegments: true)))
        #expect(field("response_format", in: body) == "verbose_json")
        #expect(field("timestamp_granularities[]", in: body) == "segment")
    }

    @Test("waits a little longer than the clip, not five minutes")
    func requestTimeout() throws {
        let service = OpenAITranscriptionService(apiKey: "k", model: .gpt4oTranscribe)
        let meetingChunk = AudioClip(
            data: Data(), mimeType: "audio/wav", fileName: "a.wav", duration: 30)
        #expect(service.makeRequest(meetingChunk, options: .init()).timeoutInterval == 50)
        let gemini = GeminiTranscriptionService(apiKey: "g", model: "gemini-2.5-flash")
        #expect(try gemini.makeRequest(meetingChunk, options: .init()).timeoutInterval == 50)
        #expect(
            AudioClip(data: Data(), mimeType: "", fileName: "", duration: 1).requestTimeout == 30)
        #expect(
            AudioClip(data: Data(), mimeType: "", fileName: "", duration: 900).requestTimeout == 300
        )
        #expect(AudioClip(data: Data(), mimeType: "", fileName: "").requestTimeout == 300)
    }

    @Test("reads a plain transcript as one segment")
    func parsePlain() throws {
        let transcript = try OpenAITranscriptionService.parse(
            Data(#"{"text":" Hello there. "}"#.utf8), duration: 2)
        #expect(transcript.text == "Hello there.")
        #expect(
            transcript.segments == [TranscriptSegment(text: "Hello there.", start: 0, end: 2)])
        let empty = try OpenAITranscriptionService.parse(Data(#"{"text":""}"#.utf8), duration: 1)
        #expect(empty.segments.isEmpty)
    }

    @Test("reads diarized segments with speakers")
    func parseDiarized() throws {
        let json = """
            {"text":"Hi. Hello.","segments":[
              {"type":"transcript.text.segment","id":"seg_0","speaker":"A","start":0.0,"end":1.2,"text":"Hi."},
              {"type":"transcript.text.segment","id":"seg_1","speaker":"B","start":1.4,"end":2.5,"text":" Hello."}
            ]}
            """
        let transcript = try OpenAITranscriptionService.parse(Data(json.utf8), duration: nil)
        #expect(transcript.text == "Hi. Hello.")
        #expect(
            transcript.segments == [
                TranscriptSegment(text: "Hi.", start: 0, end: 1.2, speaker: "A"),
                TranscriptSegment(text: "Hello.", start: 1.4, end: 2.5, speaker: "B"),
            ])
    }

    @Test("reads whisper's verbose segments")
    func parseVerbose() throws {
        let json = """
            {"language":"english","text":"One. Two.","segments":[
              {"id":0,"seek":0,"start":0,"end":1,"text":" One.","avg_logprob":-0.2},
              {"id":1,"seek":0,"start":1,"end":2,"text":" Two.","avg_logprob":-0.3}
            ]}
            """
        let transcript = try OpenAITranscriptionService.parse(Data(json.utf8), duration: nil)
        #expect(transcript.language == "english")
        #expect(transcript.segments.map(\.text) == ["One.", "Two."])
        #expect(transcript.segments.allSatisfy { $0.speaker == nil })
    }

    @Test("rejects an unreadable answer")
    func unreadable() {
        #expect(throws: CloudVoiceError.self) {
            _ = try OpenAITranscriptionService.parse(Data("<html>".utf8), duration: nil)
        }
    }

    @Test("sends the request and reports rejected keys")
    func roundTrip() async throws {
        let (session, url) = MockURLProtocol.session(responses: [
            .init(body: #"{"text":"merhaba"}"#),
            .init(status: 401, body: #"{"error":{"message":"Incorrect API key"}}"#),
        ])
        let service = OpenAITranscriptionService(apiKey: "k", baseURL: url, session: session)
        let transcript = try await service.transcribe(clip, options: TranscriptionOptions())
        #expect(transcript.text == "merhaba")
        do {
            _ = try await service.transcribe(clip, options: TranscriptionOptions())
            Issue.record("expected an error")
        } catch let error as CloudVoiceError {
            #expect(error.status == 401)
            #expect(error.message.contains("Incorrect API key"))
        }
        let requests = MockURLProtocol.requests(for: url)
        #expect(requests.count == 2)
        #expect(requests.first?.request.url?.path() == "/v1/audio/transcriptions")
    }
}

@Suite("Gemini transcription")
struct GeminiTranscriptionTests {
    let clip = AudioClip(
        data: Data([1, 2, 3]), mimeType: "audio/wav", fileName: "a.wav", duration: 3)

    func body(_ request: URLRequest) throws -> [String: Any] {
        try #require(
            try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    }

    /// A `generateContent` answer whose text is `text`.
    func answer(_ text: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "candidates": [["content": ["parts": [["text": text]]]]]
        ])
    }

    @Test("sends the audio inline with a verbatim instruction")
    func request() throws {
        let service = GeminiTranscriptionService(apiKey: "g-key", model: "gemini-2.5-flash")
        let request = try service.makeRequest(clip, options: TranscriptionOptions(language: "tr"))
        #expect(
            request.url?.absoluteString
                == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent"
        )
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "g-key")
        #expect(request.url?.query() == nil)
        let json = try body(request)
        let contents = try #require(json["contents"] as? [[String: Any]])
        let parts = try #require(contents.first?["parts"] as? [[String: Any]])
        let instruction = try #require(parts.first?["text"] as? String)
        #expect(instruction.contains("verbatim"))
        #expect(instruction.contains("tr"))
        let inline = try #require(parts.last?["inline_data"] as? [String: Any])
        #expect(inline["mime_type"] as? String == "audio/wav")
        #expect(inline["data"] as? String == Data([1, 2, 3]).base64EncodedString())
        let config = try #require(json["generationConfig"] as? [String: Any])
        #expect(config["responseMimeType"] == nil)
    }

    @Test("asks for JSON segments when segments are wanted")
    func segmentRequest() throws {
        let service = GeminiTranscriptionService(apiKey: "k", model: "")
        let request = try service.makeRequest(
            clip, options: TranscriptionOptions(identifiesSpeakers: true))
        #expect(request.url?.path().contains(GeminiTranscriptionService.defaultModel) == true)
        let config = try #require(try body(request)["generationConfig"] as? [String: Any])
        #expect(config["responseMimeType"] as? String == "application/json")
        #expect(config["responseSchema"] != nil)
    }

    @Test("reads a plain transcript")
    func parsePlain() throws {
        let json =
            #"{"candidates":[{"content":{"parts":[{"text":"Yarın "},{"text":"görüşürüz.\n"}]}}]}"#
        let transcript = try GeminiTranscriptionService.parse(
            Data(json.utf8), options: TranscriptionOptions(), duration: 3)
        #expect(transcript.text == "Yarın görüşürüz.")
        #expect(
            transcript.segments == [TranscriptSegment(text: "Yarın görüşürüz.", start: 0, end: 3)])
    }

    @Test("reads segments, even in a code fence and with clock times")
    func parseSegments() throws {
        let text = """
            ```json
            {"segments":[{"text":"Hi","start":"00:01","end":"0:02.5","speaker":"A"},{"text":"Yo","start":3,"end":4,"speaker":""}]}
            ```
            """
        let transcript = try GeminiTranscriptionService.parse(
            try answer(text), options: TranscriptionOptions(wantsSegments: true), duration: nil)
        #expect(
            transcript.segments == [
                TranscriptSegment(text: "Hi", start: 1, end: 2.5, speaker: "A"),
                TranscriptSegment(text: "Yo", start: 3, end: 4),
            ])
        #expect(transcript.text == "Hi Yo")
    }

    @Test("falls back to plain text when the segments are not JSON")
    func notJSON() throws {
        let transcript = try GeminiTranscriptionService.parse(
            try answer("Just words"), options: TranscriptionOptions(wantsSegments: true),
            duration: 2)
        #expect(transcript.segments == [TranscriptSegment(text: "Just words", start: 0, end: 2)])
    }

    @Test("explains a blocked request")
    func blocked() {
        let json = #"{"promptFeedback":{"blockReason":"SAFETY"}}"#
        #expect(throws: CloudVoiceError.self) {
            _ = try GeminiTranscriptionService.parse(
                Data(json.utf8), options: TranscriptionOptions(), duration: nil)
        }
    }

    @Test("sends the request through the session")
    func roundTrip() async throws {
        let (session, url) = MockURLProtocol.session(responses: [
            .init(body: #"{"candidates":[{"content":{"parts":[{"text":"hello"}]}}]}"#)
        ])
        let service = GeminiTranscriptionService(apiKey: "k", baseURL: url, session: session)
        let transcript = try await service.transcribe(clip, options: TranscriptionOptions())
        #expect(transcript.text == "hello")
        #expect(
            MockURLProtocol.requests(for: url).first?.request.url?.path()
                == "/v1/models/gemini-2.5-flash:generateContent")
    }
}

@Suite("Timestamps")
struct TimestampTests {
    @Test(
        "reads numbers and clock times",
        arguments: [("12.5", 12.5), ("01:05", 65.0), ("1:02:03", 3723.0), ("4s", 4.0)])
    func seconds(_ input: String, _ expected: Double) {
        #expect(VoiceHTTP.seconds(input) == expected)
    }

    @Test("rejects nonsense")
    func nonsense() {
        #expect(VoiceHTTP.seconds("soon") == nil)
        #expect(VoiceHTTP.seconds(nil) == nil)
        #expect(VoiceHTTP.seconds(3) == 3)
    }
}
