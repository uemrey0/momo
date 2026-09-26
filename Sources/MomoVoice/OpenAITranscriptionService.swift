import Foundation

/// Transcribes audio with OpenAI's `/v1/audio/transcriptions` endpoint and the user's key.
///
/// - `gpt-4o-transcribe` and `gpt-4o-mini-transcribe` return text only, so a transcript has
///   one segment for the whole clip.
/// - `whisper-1` returns timed segments (`verbose_json`) when segments are asked for.
/// - `gpt-4o-transcribe-diarize` returns segments with speaker labels (`diarized_json`). It
///   is used whenever ``TranscriptionOptions/identifiesSpeakers`` is set.
public struct OpenAITranscriptionService: AudioTranscriptionService {
    /// The transcription models Momo offers.
    public enum Model: String, CaseIterable, Sendable, Identifiable {
        case gpt4oTranscribe = "gpt-4o-transcribe"
        case gpt4oMiniTranscribe = "gpt-4o-mini-transcribe"
        case whisper1 = "whisper-1"
        case gpt4oTranscribeDiarize = "gpt-4o-transcribe-diarize"

        public var id: String { rawValue }

        /// Models suitable for dictation, in the order Settings shows them.
        public static let dictationModels: [Model] = [
            .gpt4oMiniTranscribe, .gpt4oTranscribe, .whisper1,
        ]
    }

    public static let defaultModel = Model.gpt4oMiniTranscribe

    let apiKey: String
    let model: Model
    let baseURL: URL
    let session: URLSession

    public init(
        apiKey: String, model: Model = Self.defaultModel,
        baseURL: URL = URL(string: "https://api.openai.com/v1") ?? URL(fileURLWithPath: "/"),
        session: URLSession = .shared
    ) {
        self.apiKey = apiKey
        self.model = model
        self.baseURL = baseURL
        self.session = session
    }

    public var displayName: String { "OpenAI \(model.rawValue)" }

    /// The model a request with `options` uses.
    func effectiveModel(for options: TranscriptionOptions) -> Model {
        options.identifiesSpeakers ? .gpt4oTranscribeDiarize : model
    }

    public func transcribe(
        _ audio: AudioClip, options: TranscriptionOptions
    ) async throws
        -> Transcript
    {
        guard audio.data.count <= 25_000_000 else {
            throw CloudVoiceError("The recording is larger than OpenAI's 25 MB limit.")
        }
        let data = try await VoiceHTTP.send(makeRequest(audio, options: options), session: session)
        return try Self.parse(data, duration: audio.duration)
    }

    /// Builds the upload request.
    func makeRequest(_ audio: AudioClip, options: TranscriptionOptions) -> URLRequest {
        let model = effectiveModel(for: options)
        var form = MultipartForm()
        form.addFile("file", fileName: audio.fileName, mimeType: audio.mimeType, data: audio.data)
        form.addField("model", model.rawValue)
        if let language = options.language.flatMap(Self.isoLanguage) {
            form.addField("language", language)
        }
        switch model {
        case .gpt4oTranscribeDiarize:
            // The diarizing model takes no prompt, and needs a chunking strategy for audio
            // longer than 30 seconds.
            form.addField("response_format", "diarized_json")
            form.addField("chunking_strategy", "auto")
        case .whisper1 where options.wantsSegments:
            if let prompt = options.prompt { form.addField("prompt", prompt) }
            form.addField("response_format", "verbose_json")
            form.addField("timestamp_granularities[]", "segment")
        default:
            if let prompt = options.prompt { form.addField("prompt", prompt) }
            form.addField("response_format", "json")
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(form.contentType, forHTTPHeaderField: "Content-Type")
        request.httpBody = form.finished
        return request
    }

    /// Reads a `json`, `verbose_json` or `diarized_json` response.
    static func parse(_ data: Data, duration: TimeInterval?) throws -> Transcript {
        let object = try VoiceHTTP.object(from: data)
        let rawSegments = object["segments"] as? [[String: Any]] ?? []
        let segments = rawSegments.compactMap { segment -> TranscriptSegment? in
            guard
                let text = (segment["text"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
            else { return nil }
            let speaker =
                (segment["speaker"] as? String) ?? (segment["speaker"] as? Int).map(String.init)
            return TranscriptSegment(
                text: text, start: VoiceHTTP.seconds(segment["start"]) ?? 0,
                end: VoiceHTTP.seconds(segment["end"]) ?? 0, speaker: speaker)
        }
        let text =
            (object["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? segments.map(\.text).joined(separator: " ")
        let language = object["language"] as? String
        if !segments.isEmpty {
            return Transcript(text: text, segments: segments, language: language)
        }
        let whole =
            text.isEmpty
            ? [] : [TranscriptSegment(text: text, start: 0, end: duration ?? 0)]
        return Transcript(text: text, segments: whole, language: language)
    }

    /// "tr-TR" → "tr"; OpenAI expects ISO 639-1 codes.
    static func isoLanguage(_ language: String) -> String? {
        let code = language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first
            .map { $0.lowercased() }
        guard let code, code.count == 2 else { return nil }
        return code
    }
}
