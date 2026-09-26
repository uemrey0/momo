import Foundation

/// Models and voices of Google's Gemini Live API.
///
/// Reference: https://ai.google.dev/api/live (messages),
/// https://ai.google.dev/gemini-api/docs/live-api/get-started-websocket and
/// https://ai.google.dev/gemini-api/docs/models (Live models).
public enum GeminiLive {
    /// The native audio model Momo uses by default.
    public static let defaultModel = "gemini-3.8-live"
    /// The models Settings offers, best first. Any Live model name works.
    public static let suggestedModels = [
        "gemini-3.8-live", "gemini-2.5-flash-native-audio-preview-12-2025",
    ]
    /// Prebuilt voices.
    public static let voices = [
        "Kore", "Puck", "Charon", "Fenrir", "Aoede", "Leda", "Orus", "Zephyr",
    ]
    public static let defaultVoice = "Kore"
    /// The rate of the audio Gemini takes.
    public static let inputSampleRate = 16_000
    /// The rate of the audio Gemini sends.
    public static let outputSampleRate = 24_000
    /// The BidiGenerateContent WebSocket endpoint.
    public static let endpoint = URL(
        string:
            "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
    )
}

/// Speaks the Live API's BidiGenerateContent protocol: `setup`, `realtimeInput` audio and
/// `toolResponse`; reads `setupComplete`, `serverContent`, `toolCall`,
/// `toolCallCancellation` and `goAway`.
///
/// Gemini interrupts itself when the user talks over it (`serverContent.interrupted`) and has
/// no truncation: the model assumes the user heard what it generated.
struct GeminiLiveCodec: RealtimeCodec {
    let apiKey: String
    let model: String
    let endpoint: URL?
    /// Declares functions as `NON_BLOCKING`, so the model keeps talking (a short filler)
    /// while Momo works. Gemini 3.8 Live does this by default.
    let nonBlockingCalls: Bool

    private var userText = ""
    private var assistantText = ""
    /// Whether the model produced anything in the current turn.
    private var responseOpen = false

    init(
        apiKey: String, model: String, endpoint: URL? = GeminiLive.endpoint,
        nonBlockingCalls: Bool = true
    ) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
        self.nonBlockingCalls = nonBlockingCalls
    }

    var inputSampleRate: Int { GeminiLive.inputSampleRate }
    var outputSampleRate: Int { GeminiLive.outputSampleRate }

    func connectionRequest() throws -> URLRequest {
        guard let endpoint else { throw CloudVoiceError("The live voice address is invalid.") }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        // A header rather than the documented `key` query item, so the key never appears in
        // a URL.
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        return request
    }

    func setupMessages(for configuration: RealtimeSessionConfiguration) throws -> [String] {
        var instructions = configuration.instructions
        if let language = configuration.language {
            // Native audio models choose the spoken language themselves and don't take a
            // language code, so the hint goes into the instructions.
            let name =
                Locale(identifier: "en").localizedString(forIdentifier: language) ?? language
            instructions += "\n\nSpeak \(name) unless the user speaks another language."
        }
        var setup: [String: Any] = [
            "model": model.hasPrefix("models/") ? model : "models/\(model)",
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": [
                    "voiceConfig": [
                        "prebuiltVoiceConfig": [
                            "voiceName": configuration.voice ?? GeminiLive.defaultVoice
                        ]
                    ]
                ],
            ],
            "systemInstruction": ["parts": [["text": instructions]]],
            "outputAudioTranscription": [String: Any](),
        ]
        if configuration.transcribesInput {
            setup["inputAudioTranscription"] = [String: Any]()
        }
        if case .silence(let milliseconds) = configuration.turnDetection {
            setup["realtimeInputConfig"] = [
                "automaticActivityDetection": ["silenceDurationMs": milliseconds]
            ]
        }
        if !configuration.tools.isEmpty {
            let declarations = configuration.tools.map { tool in
                var declaration: [String: Any] = [
                    "name": tool.name, "description": tool.description,
                    "parameters": RealtimeParameter.schema(tool.parameters, upperCaseTypes: true),
                ]
                if nonBlockingCalls { declaration["behavior"] = "NON_BLOCKING" }
                return declaration
            }
            setup["tools"] = [["functionDeclarations": declarations]]
        }
        return [try RealtimeJSON.string(["setup": setup])]
    }

    func audioMessage(_ pcm16: Data) -> String {
        let data = pcm16.base64EncodedString()
        return #"{"realtimeInput":{"audio":{"data":"\#(data)","mimeType":"audio/pcm;rate=16000"}}}"#
    }

    func userTextMessages(_ text: String) throws -> [String] {
        // Realtime text input: the model answers it like speech, with its voice.
        [try RealtimeJSON.string(["realtimeInput": ["text": text]])]
    }

    func functionResultMessages(
        _ output: String, for call: RealtimeFunctionCall
    ) throws
        -> [String]
    {
        var response = RealtimeJSON.resultObject(output)
        if nonBlockingCalls {
            // Speak the result once the model finished its filler, rather than cutting it off.
            response["scheduling"] = "WHEN_IDLE"
        }
        return [
            try RealtimeJSON.string([
                "toolResponse": [
                    "functionResponses": [["id": call.id, "name": call.name, "response": response]]
                ]
            ])
        ]
    }

    mutating func interruptMessages(playedMilliseconds: Int?) -> [String] {
        // Gemini stops generating by itself when it hears the user; there is nothing to send.
        []
    }

    mutating func decode(_ text: String) -> [RealtimeEvent] {
        guard let message = RealtimeJSON.object(text) else { return [] }
        var events: [RealtimeEvent] = []
        if message["setupComplete"] != nil {
            events.append(.ready)
        }
        if let content = message["serverContent"] as? [String: Any] {
            decodeServerContent(content, into: &events)
        }
        if let toolCall = message["toolCall"] as? [String: Any] {
            finishUserTurn(into: &events)
            responseOpen = true
            for call in toolCall["functionCalls"] as? [[String: Any]] ?? [] {
                guard let id = call["id"] as? String, let name = call["name"] as? String else {
                    continue
                }
                let args = call["args"] as? [String: Any] ?? [:]
                let arguments = (try? RealtimeJSON.string(args)) ?? "{}"
                events.append(
                    .functionCall(RealtimeFunctionCall(id: id, name: name, arguments: arguments)))
            }
        }
        if let cancellation = message["toolCallCancellation"] as? [String: Any],
            let ids = cancellation["ids"] as? [String], !ids.isEmpty
        {
            events.append(.functionCallsCancelled(ids: ids))
        }
        if let goAway = message["goAway"] as? [String: Any] {
            events.append(.sessionEnding(timeLeft: VoiceHTTP.seconds(goAway["timeLeft"])))
        }
        if let error = message["error"] as? [String: Any] {
            let detail = (error["message"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            events.append(
                .error(
                    CloudVoiceError(
                        detail.isEmpty
                            ? "The live voice service reported an error."
                            : "The live voice service reported an error. \(detail)")))
        }
        return events
    }

    private mutating func decodeServerContent(
        _ content: [String: Any], into events: inout [RealtimeEvent]
    ) {
        if let chunk = (content["inputTranscription"] as? [String: Any])?["text"] as? String,
            !chunk.isEmpty
        {
            userText += chunk
            events.append(.userTranscript(Self.trimmed(userText), isFinal: false))
        }
        if content["interrupted"] as? Bool == true {
            events.append(.userSpeechStarted)
            finishResponse(.cancelled, into: &events)
        }
        if let turn = content["modelTurn"] as? [String: Any] {
            for part in turn["parts"] as? [[String: Any]] ?? [] {
                guard part["thought"] as? Bool != true,
                    let inline = part["inlineData"] as? [String: Any],
                    (inline["mimeType"] as? String)?.hasPrefix("audio/") ?? true,
                    let base64 = inline["data"] as? String,
                    let audio = Data(base64Encoded: base64)
                else { continue }
                finishUserTurn(into: &events)
                responseOpen = true
                events.append(.assistantAudio(audio))
            }
        }
        if let chunk = (content["outputTranscription"] as? [String: Any])?["text"] as? String,
            !chunk.isEmpty
        {
            finishUserTurn(into: &events)
            responseOpen = true
            assistantText += chunk
            events.append(.assistantTranscriptDelta(chunk))
        }
        if content["turnComplete"] as? Bool == true {
            finishUserTurn(into: &events)
            finishResponse(.completed, into: &events)
        }
    }

    /// Emits the final user transcript once the model starts answering.
    private mutating func finishUserTurn(into events: inout [RealtimeEvent]) {
        let text = Self.trimmed(userText)
        userText = ""
        if !text.isEmpty { events.append(.userTranscript(text, isFinal: true)) }
    }

    private mutating func finishResponse(
        _ status: RealtimeResponseStatus, into events: inout [RealtimeEvent]
    ) {
        guard responseOpen else { return }
        let text = Self.trimmed(assistantText)
        if !text.isEmpty { events.append(.assistantTranscriptDone(text)) }
        events.append(.responseDone(status))
        assistantText = ""
        responseOpen = false
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
