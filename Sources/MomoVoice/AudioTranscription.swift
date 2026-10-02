import Foundation

/// Transcribes recorded audio: a dictated utterance, or a chunk of a longer recording.
///
/// Implementations send the audio to a cloud service with the user's own key, so callers must
/// only use them after the user chose that service, and should log each request. Services
/// are stateless values and safe to share between tasks.
///
/// ```swift
/// let service = OpenAITranscriptionService(apiKey: key, model: .gpt4oTranscribe)
/// let clip = AudioClip.wav(samples: samples, sampleRate: 16_000)
/// let transcript = try await service.transcribe(clip, options: TranscriptionOptions())
/// print(transcript.text)
/// ```
///
/// For long recordings (meetings), split the audio into chunks below the service's size limit
/// (``AudioClip/maximumUploadBytes``) with ``AudioChunker``, transcribe each with
/// ``TranscriptionOptions/wantsSegments`` and shift each chunk's segments by its start time
/// with ``Transcript/offset(by:)``, or ``Transcript/chunkSegments(index:start:)`` to also
/// scope speaker labels to the chunk. ``OnDeviceTranscriptionService`` does the same on the Mac.
public protocol AudioTranscriptionService: Sendable {
    /// A short name for logs, such as "OpenAI gpt-4o-transcribe".
    var displayName: String { get }
    /// Transcribes `audio`. Throws ``CloudVoiceError`` when the request fails.
    func transcribe(_ audio: AudioClip, options: TranscriptionOptions) async throws -> Transcript
}

/// Audio ready to upload.
public struct AudioClip: Sendable, Equatable {
    /// The encoded audio file.
    public var data: Data
    /// Its media type, such as `audio/wav`.
    public var mimeType: String
    /// A file name with the right extension; some services look at it to detect the format.
    public var fileName: String
    /// The length in seconds, when known. Used for single-segment transcripts and logs.
    public var duration: TimeInterval?

    /// The largest file the cloud services accept in one request (OpenAI allows 25 MB,
    /// Gemini about 20 MB of inline data per request).
    public static let maximumUploadBytes = 19_000_000

    public init(data: Data, mimeType: String, fileName: String, duration: TimeInterval? = nil) {
        self.data = data
        self.mimeType = mimeType
        self.fileName = fileName
        self.duration = duration
    }

    /// How long to wait for a service to transcribe this clip: a little longer than the clip
    /// itself, between 30 seconds and 5 minutes, so a stalled connection fails in time for the
    /// next clip rather than minutes later.
    public var requestTimeout: TimeInterval {
        guard let duration else { return 300 }
        return min(300, max(30, 20 + duration))
    }

    /// Mono samples from -1 to 1, encoded as 16-bit WAV.
    public static func wav(samples: [Float], sampleRate: Int) -> AudioClip {
        AudioClip(
            data: WAVEncoder.encode(samples: samples, sampleRate: sampleRate),
            mimeType: "audio/wav", fileName: "audio.wav",
            duration: Double(samples.count) / Double(max(1, sampleRate)))
    }

    /// Reads an audio file (wav, m4a, mp3, mp4, webm…), guessing its type from the extension.
    public init(contentsOf url: URL, duration: TimeInterval? = nil) throws {
        let types = [
            "wav": "audio/wav", "m4a": "audio/mp4", "mp4": "audio/mp4", "mp3": "audio/mpeg",
            "mpeg": "audio/mpeg", "mpga": "audio/mpeg", "webm": "audio/webm", "ogg": "audio/ogg",
            "flac": "audio/flac", "aac": "audio/aac",
        ]
        let fileExtension = url.pathExtension.lowercased()
        self.init(
            data: try Data(contentsOf: url), mimeType: types[fileExtension] ?? "audio/wav",
            fileName: url.lastPathComponent, duration: duration)
    }
}

/// What to ask of a transcription.
public struct TranscriptionOptions: Sendable, Equatable {
    /// The spoken language as an ISO 639-1 code ("en", "tr"), or `nil` to detect it.
    public var language: String?
    /// Words or context that help the service spell names correctly.
    public var prompt: String?
    /// Ask for timed segments rather than just the text.
    public var wantsSegments: Bool
    /// Ask the service to tell speakers apart. With OpenAI this uses
    /// `gpt-4o-transcribe-diarize`, whatever model the service was created with.
    public var identifiesSpeakers: Bool

    public init(
        language: String? = nil, prompt: String? = nil, wantsSegments: Bool = false,
        identifiesSpeakers: Bool = false
    ) {
        self.language = language
        self.prompt = prompt
        self.wantsSegments = wantsSegments || identifiesSpeakers
        self.identifiesSpeakers = identifiesSpeakers
    }
}

/// A piece of a transcript.
public struct TranscriptSegment: Sendable, Equatable, Codable {
    public var text: String
    /// Seconds from the start of the audio.
    public var start: TimeInterval
    /// Seconds from the start of the audio.
    public var end: TimeInterval
    /// The speaker's label from the service ("A", "speaker_0"), when speakers were identified.
    public var speaker: String?

    public init(text: String, start: TimeInterval, end: TimeInterval, speaker: String? = nil) {
        self.text = text
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

/// The result of a transcription.
public struct Transcript: Sendable, Equatable {
    /// The whole text.
    public var text: String
    /// Timed segments. Services that return only text produce one segment for the whole clip.
    public var segments: [TranscriptSegment]
    /// The detected language, when the service reports it.
    public var language: String?

    public init(text: String, segments: [TranscriptSegment], language: String? = nil) {
        self.text = text
        self.segments = segments
        self.language = language
    }

    /// The transcript with every segment moved `seconds` later, for stitching chunks of a long
    /// recording together.
    public func offset(by seconds: TimeInterval) -> Transcript {
        var copy = self
        copy.segments = segments.map {
            TranscriptSegment(
                text: $0.text, start: $0.start + seconds, end: $0.end + seconds,
                speaker: $0.speaker)
        }
        return copy
    }
}

/// Why a cloud speech request failed. Messages are in English, like other library errors.
public struct CloudVoiceError: LocalizedError, Equatable, Sendable {
    /// The HTTP status, or `nil` when the request never got an answer or the answer was
    /// unreadable.
    public var status: Int?
    public var message: String

    public init(status: Int? = nil, _ message: String) {
        self.status = status
        self.message = message
    }

    public var errorDescription: String? { message }

    /// Turns an error response into a message the user can act on.
    static func http(status: Int, body: Data) -> CloudVoiceError {
        let text = String(decoding: body, as: UTF8.self)
        let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        let error = object?["error"]
        let detail =
            ((error as? [String: Any])?["message"] as? String) ?? (error as? String)
            ?? (object?["message"] as? String) ?? String(text.prefix(300))
        switch status {
        case 401, 403:
            return CloudVoiceError(
                status: status,
                "The API key was rejected (\(status)). Check it in Settings. \(detail)"
            )
        case 404:
            return CloudVoiceError(
                status: status, "The model or endpoint was not found (404). \(detail)")
        case 413:
            return CloudVoiceError(status: status, "The recording is too large to upload (413).")
        case 429:
            return CloudVoiceError(
                status: status, "Rate limit or quota reached (429). Try again shortly. \(detail)")
        case 500...:
            return CloudVoiceError(
                status: status, "The service had a server error (\(status)). \(detail)")
        default:
            return CloudVoiceError(status: status, "Request failed (\(status)). \(detail)")
        }
    }
}

/// Sends requests for the cloud voice services.
enum VoiceHTTP {
    /// Sends `request` and returns the body of a successful response.
    static func send(_ request: URLRequest, session: URLSession) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw CloudVoiceError.http(status: status, body: data)
        }
        return data
    }

    /// Parses a JSON object, or throws a readable error.
    static func object(from data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudVoiceError("The service sent an answer Momo could not read.")
        }
        return object
    }

    /// Reads a number that may arrive as a number or a string ("12.5", "01:05", "1:02:03").
    static func seconds(_ value: Any?) -> TimeInterval? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? NSNumber { return number.doubleValue }
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty
        else { return nil }
        let cleaned = text.hasSuffix("s") ? String(text.dropLast()) : text
        let parts = cleaned.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }
}

/// Builds `multipart/form-data` bodies for file uploads.
struct MultipartForm {
    let boundary: String
    private(set) var body = Data()

    init(boundary: String = "momo-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    mutating func addField(_ name: String, _ value: String) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
        body.append(Data("\(value)\r\n".utf8))
    }

    mutating func addFile(_ name: String, fileName: String, mimeType: String, data: Data) {
        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(
            Data(
                "Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n"
                    .utf8))
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(data)
        body.append(Data("\r\n".utf8))
    }

    /// The finished body, with the closing boundary.
    var finished: Data {
        body + Data("--\(boundary)--\r\n".utf8)
    }
}
