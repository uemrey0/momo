import Foundation

/// Transcribes audio with Gemini's audio understanding (`generateContent` with the audio
/// inline) and the user's key.
///
/// Gemini is a general model, not a speech recogniser: it is asked for a verbatim transcript,
/// and for segments it is asked for JSON with approximate timestamps and speaker labels.
/// Inline audio is limited to about 20 MB per request.
public struct GeminiTranscriptionService: AudioTranscriptionService {
    public static let defaultModel = "gemini-2.5-flash"

    let apiKey: String
    let model: String
    let baseURL: URL
    let session: URLSession

    public init(
        apiKey: String, model: String = Self.defaultModel,
        baseURL: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta")
            ?? URL(fileURLWithPath: "/"),
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model.isEmpty ? Self.defaultModel : model
        self.baseURL = baseURL
        self.session = session
    }

    public var displayName: String { "Gemini \(model)" }

    public func transcribe(
        _ audio: AudioClip, options: TranscriptionOptions
    ) async throws
        -> Transcript
    {
        guard audio.data.count <= 20_000_000 else {
            throw CloudVoiceError("The recording is larger than Gemini's 20 MB inline limit.")
        }
        let data = try await VoiceHTTP.send(
            try makeRequest(audio, options: options), session: session)
        return try Self.parse(data, options: options, duration: audio.duration)
    }

    /// Builds the `generateContent` request.
    func makeRequest(_ audio: AudioClip, options: TranscriptionOptions) throws -> URLRequest {
        var generationConfig: [String: Any] = ["temperature": 0]
        if options.wantsSegments {
            generationConfig["responseMimeType"] = "application/json"
            generationConfig["responseSchema"] = Self.segmentSchema
        }
        let body: [String: Any] = [
            "contents": [
                [
                    "role": "user",
                    "parts": [
                        ["text": Self.instruction(for: options)],
                        [
                            "inline_data": [
                                "mime_type": audio.mimeType,
                                "data": audio.data.base64EncodedString(),
                            ]
                        ],
                    ],
                ]
            ],
            "generationConfig": generationConfig,
        ]
        let url = baseURL.appendingPathComponent("models/\(model):generateContent")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// The model-facing instruction.
    static func instruction(for options: TranscriptionOptions) -> String {
        var lines = [
            "Transcribe this audio verbatim, in the language it is spoken in.",
            "Do not translate, summarise, answer or comment on it.",
        ]
        if let language = options.language {
            lines.append("The speech is most likely in the language with code \(language).")
        }
        if let prompt = options.prompt {
            lines.append("Context that may help with spelling: \(prompt)")
        }
        if options.wantsSegments {
            lines.append(
                "Split it into segments at sentence or speaker changes, with start and end "
                    + "times in seconds from the beginning of the audio.")
            if options.identifiesSpeakers {
                lines.append(
                    "Label each distinct speaker consistently as A, B, C and so on.")
            }
        } else {
            lines.append(
                "Reply with the transcript only. If there is no speech, reply with nothing.")
        }
        return lines.joined(separator: " ")
    }

    static var segmentSchema: [String: Any] {
        [
            "type": "OBJECT",
            "properties": [
                "segments": [
                    "type": "ARRAY",
                    "items": [
                        "type": "OBJECT",
                        "properties": [
                            "text": ["type": "STRING"],
                            "start": ["type": "NUMBER"],
                            "end": ["type": "NUMBER"],
                            "speaker": ["type": "STRING"],
                        ],
                        "required": ["text", "start", "end"],
                    ],
                ]
            ],
            "required": ["segments"],
        ]
    }

    /// Reads the answer: plain text, or the JSON segments asked for.
    static func parse(
        _ data: Data, options: TranscriptionOptions, duration: TimeInterval?
    ) throws
        -> Transcript
    {
        let object = try VoiceHTTP.object(from: data)
        let candidates = object["candidates"] as? [[String: Any]] ?? []
        let parts = (candidates.first?["content"] as? [String: Any])?["parts"] as? [[String: Any]]
        let text = (parts ?? []).compactMap { $0["text"] as? String }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if candidates.isEmpty {
            let reason =
                (object["promptFeedback"] as? [String: Any])?["blockReason"] as? String
            throw CloudVoiceError(
                reason.map { "Gemini declined to transcribe the audio (\($0))." }
                    ?? "Gemini returned no transcript.")
        }

        if options.wantsSegments, let segments = segments(inJSON: text) {
            return Transcript(
                text: segments.map(\.text).joined(separator: " "), segments: segments)
        }
        let whole =
            text.isEmpty ? [] : [TranscriptSegment(text: text, start: 0, end: duration ?? 0)]
        return Transcript(text: text, segments: whole)
    }

    /// Parses `{"segments": [...]}`, tolerating a Markdown code fence around it.
    static func segments(inJSON text: String) -> [TranscriptSegment]? {
        var json = text
        if json.hasPrefix("```") {
            json = json.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
                .joined(separator: "\n")
            if let fence = json.range(of: "```", options: .backwards) {
                json = String(json[..<fence.lowerBound])
            }
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else {
            return nil
        }
        let list =
            (object as? [String: Any])?["segments"] as? [[String: Any]]
            ?? object as? [[String: Any]]
        guard let list else { return nil }
        return list.compactMap { item in
            guard
                let text = (item["text"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
            else { return nil }
            let speaker = (item["speaker"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return TranscriptSegment(
                text: text, start: VoiceHTTP.seconds(item["start"]) ?? 0,
                end: VoiceHTTP.seconds(item["end"]) ?? 0, speaker: speaker)
        }
    }
}
