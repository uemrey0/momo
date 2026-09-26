import Foundation

/// Models and voices of OpenAI's Realtime API.
///
/// Reference: https://developers.openai.com/api/docs/guides/realtime-websocket and
/// https://developers.openai.com/api/reference/resources/realtime/client-events (GA events).
public enum OpenAIRealtime {
    /// The speech-to-speech model Momo uses by default.
    public static let defaultModel = "gpt-realtime-2.1"
    /// The models Settings offers, best first. Any Realtime model name works.
    public static let suggestedModels = ["gpt-realtime-2.1", "gpt-realtime-2.1-mini"]
    /// The Realtime voices. `marin` and `cedar` sound the most natural.
    public static let voices = [
        "marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse",
    ]
    public static let defaultVoice = "marin"
    /// The PCM rate in both directions.
    public static let sampleRate = 24_000
    /// The model that transcribes the user's speech for captions.
    public static let transcriptionModel = "gpt-4o-mini-transcribe"
    /// The WebSocket endpoint; the model goes in the `model` query item.
    public static let endpoint = URL(string: "wss://api.openai.com/v1/realtime")
}

/// Speaks the GA Realtime protocol: `session.update`, `input_audio_buffer.append`,
/// `response.cancel`, `conversation.item.truncate`, `conversation.item.create` with a
/// `function_call_output` and `response.create`.
struct OpenAIRealtimeCodec: RealtimeCodec {
    let apiKey: String
    let model: String
    let endpoint: URL?

    /// Whether a response is being generated (between `response.created` and `response.done`).
    private(set) var responseActive = false
    /// The assistant message whose audio arrives, for truncation on barge-in.
    private(set) var audioItemID: String?
    /// Milliseconds of audio received for ``audioItemID``; truncation may not go beyond it.
    private var audioItemMilliseconds = 0
    private var audioItemSamples = 0
    /// Transcripts in progress, by user item.
    private var userTranscripts: [String: String] = [:]

    init(apiKey: String, model: String, endpoint: URL? = OpenAIRealtime.endpoint) {
        self.apiKey = apiKey
        self.model = model
        self.endpoint = endpoint
    }

    var inputSampleRate: Int { OpenAIRealtime.sampleRate }
    var outputSampleRate: Int { OpenAIRealtime.sampleRate }

    func connectionRequest() throws -> URLRequest {
        guard let endpoint,
            var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        else { throw CloudVoiceError("The live voice address is invalid.") }
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        guard let url = components.url else {
            throw CloudVoiceError("The live voice address is invalid.")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        return request
    }

    func setupMessages(for configuration: RealtimeSessionConfiguration) throws -> [String] {
        let format: [String: Any] = ["type": "audio/pcm", "rate": OpenAIRealtime.sampleRate]
        var input: [String: Any] = [
            "format": format,
            "noise_reduction": ["type": "near_field"],
            "turn_detection": Self.turnDetection(configuration.turnDetection),
        ]
        if configuration.transcribesInput {
            var transcription: [String: Any] = ["model": OpenAIRealtime.transcriptionModel]
            if let language = configuration.languageCode { transcription["language"] = language }
            input["transcription"] = transcription
        }
        var session: [String: Any] = [
            "type": "realtime",
            "instructions": configuration.instructions,
            "output_modalities": ["audio"],
            "audio": [
                "input": input,
                "output": [
                    "format": format, "voice": configuration.voice ?? OpenAIRealtime.defaultVoice,
                ],
            ],
        ]
        if !configuration.tools.isEmpty {
            session["tools"] = configuration.tools.map { tool in
                [
                    "type": "function", "name": tool.name, "description": tool.description,
                    "parameters": RealtimeParameter.schema(tool.parameters),
                ] as [String: Any]
            }
            session["tool_choice"] = "auto"
        }
        return [try RealtimeJSON.string(["type": "session.update", "session": session])]
    }

    static func turnDetection(_ detection: RealtimeTurnDetection) -> [String: Any] {
        switch detection {
        case .semantic(let eagerness):
            [
                "type": "semantic_vad", "eagerness": eagerness.rawValue,
                "create_response": true, "interrupt_response": true,
            ]
        case .silence(let milliseconds):
            [
                "type": "server_vad", "silence_duration_ms": milliseconds,
                "prefix_padding_ms": 300, "threshold": 0.5,
                "create_response": true, "interrupt_response": true,
            ]
        }
    }

    func audioMessage(_ pcm16: Data) -> String {
        // Base64 has no characters that need escaping, so skip JSONSerialization here: this
        // runs 25 to 50 times a second.
        #"{"audio":"\#(pcm16.base64EncodedString())","type":"input_audio_buffer.append"}"#
    }

    func userTextMessages(_ text: String) throws -> [String] {
        [
            try RealtimeJSON.string([
                "type": "conversation.item.create",
                "item": [
                    "type": "message", "role": "user",
                    "content": [["type": "input_text", "text": text]],
                ],
            ]),
            try RealtimeJSON.string(["type": "response.create"]),
        ]
    }

    func functionResultMessages(
        _ output: String, for call: RealtimeFunctionCall
    ) throws
        -> [String]
    {
        [
            try RealtimeJSON.string([
                "type": "conversation.item.create",
                "item": ["type": "function_call_output", "call_id": call.id, "output": output],
            ]),
            try RealtimeJSON.string(["type": "response.create"]),
        ]
    }

    mutating func interruptMessages(playedMilliseconds: Int?) -> [String] {
        var messages: [String] = []
        if responseActive {
            messages.append(#"{"type":"response.cancel"}"#)
        }
        if let item = audioItemID, let played = playedMilliseconds {
            let end = max(0, min(played, audioItemMilliseconds))
            if let message = try? RealtimeJSON.string([
                "type": "conversation.item.truncate", "item_id": item, "content_index": 0,
                "audio_end_ms": end,
            ]) {
                messages.append(message)
            }
        }
        audioItemID = nil
        audioItemSamples = 0
        audioItemMilliseconds = 0
        return messages
    }

    mutating func decode(_ text: String) -> [RealtimeEvent] {
        guard let event = RealtimeJSON.object(text), let type = event["type"] as? String else {
            return []
        }
        switch type {
        case "session.updated":
            return [.ready]
        case "input_audio_buffer.speech_started":
            return [.userSpeechStarted]
        case "input_audio_buffer.speech_stopped":
            return [.userSpeechStopped]
        case "conversation.item.input_audio_transcription.delta":
            guard let item = event["item_id"] as? String, let delta = event["delta"] as? String
            else { return [] }
            let text = userTranscripts[item, default: ""] + delta
            userTranscripts[item] = text
            return [.userTranscript(text, isFinal: false)]
        case "conversation.item.input_audio_transcription.completed":
            if let item = event["item_id"] as? String { userTranscripts[item] = nil }
            let transcript = (event["transcript"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return [.userTranscript(transcript, isFinal: true)]
        case "response.created":
            responseActive = true
            return []
        case "response.output_audio.delta":
            guard let delta = event["delta"] as? String, let audio = Data(base64Encoded: delta)
            else { return [] }
            if let item = event["item_id"] as? String, item != audioItemID {
                audioItemID = item
                audioItemSamples = 0
            }
            audioItemSamples += audio.count / RealtimePCM.bytesPerSample
            audioItemMilliseconds = audioItemSamples * 1000 / OpenAIRealtime.sampleRate
            return [.assistantAudio(audio)]
        case "response.output_audio_transcript.delta":
            guard let delta = event["delta"] as? String, !delta.isEmpty else { return [] }
            return [.assistantTranscriptDelta(delta)]
        case "response.output_audio_transcript.done":
            return [.assistantTranscriptDone(event["transcript"] as? String ?? "")]
        case "response.output_item.done":
            // The finished item carries the call's id, name and complete arguments.
            guard let item = event["item"] as? [String: Any],
                item["type"] as? String == "function_call",
                let callID = item["call_id"] as? String, let name = item["name"] as? String
            else { return [] }
            let arguments = item["arguments"] as? String ?? "{}"
            return [
                .functionCall(RealtimeFunctionCall(id: callID, name: name, arguments: arguments))
            ]
        case "response.done":
            responseActive = false
            return Self.responseDone(event["response"] as? [String: Any])
        case "error":
            return Self.error(event["error"] as? [String: Any]).map { [.error($0)] } ?? []
        default:
            return []
        }
    }

    static func responseDone(_ response: [String: Any]?) -> [RealtimeEvent] {
        let status = response?["status"] as? String
        switch status {
        case "cancelled":
            return [.responseDone(.cancelled)]
        case "incomplete":
            return [.responseDone(.incomplete)]
        case "failed":
            let details = response?["status_details"] as? [String: Any]
            let failure =
                error(details?["error"] as? [String: Any])
                ?? CloudVoiceError("The live voice model could not answer.")
            return [.error(failure), .responseDone(.failed)]
        default:
            return [.responseDone(.completed)]
        }
    }

    /// Maps an `error` object to a readable error, or `nil` for errors that are expected
    /// (cancelling a response that already ended).
    static func error(_ error: [String: Any]?) -> CloudVoiceError? {
        let code = error?["code"] as? String ?? ""
        let message = (error?["message"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        func text(_ base: String) -> String { message.isEmpty ? base : "\(base) \(message)" }
        switch code {
        case "response_cancel_not_active":
            return nil
        case "invalid_api_key", "invalid_authentication", "unauthorized":
            return CloudVoiceError(
                status: 401, text("The API key was rejected. Check it in Settings."))
        case "insufficient_quota", "rate_limit_exceeded":
            return CloudVoiceError(
                status: 429, text("Rate limit or quota reached. Try again shortly."))
        case "model_not_found":
            return CloudVoiceError(status: 404, text("The live voice model is not available."))
        case "session_expired":
            return CloudVoiceError(text("The live session reached its time limit."))
        default:
            return CloudVoiceError(text("The live voice service reported an error."))
        }
    }
}
