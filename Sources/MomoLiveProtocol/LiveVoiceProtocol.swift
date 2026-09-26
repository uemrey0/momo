import Foundation

// The protocol between Momo and `momo-voice`, the helper process that runs the on-device,
// open source live voice engine (streaming speech recognition, turn detection, echo
// cancellation and speech synthesis).
//
// Momo starts `momo-voice` as a child process and exchanges one JSON object per line over
// its standard input (commands) and standard output (events). The helper owns the
// microphone and the speaker while a session runs, because echo cancellation needs both in
// one place. It never thinks: finished user turns go to Momo, and Momo streams the reply
// back sentence by sentence.

/// The protocol version. Momo refuses a helper that reports another major version.
public let liveVoiceProtocolVersion = 1

/// What a live voice model does.
public enum LiveModelKind: String, Codable, Sendable, Hashable {
    /// Speech recognition.
    case speechToText
    /// Speech synthesis.
    case textToSpeech
    /// Voice activity detection.
    case voiceActivity
    /// End-of-turn detection.
    case turnDetection
    /// Acoustic echo cancellation.
    case echoCancellation
}

/// A model the helper can use, and whether it is on this Mac.
public struct LiveModelInfo: Codable, Sendable, Hashable, Identifiable {
    /// A stable identifier, e.g. "nemotron-streaming-multilingual".
    public var id: String
    public var kind: LiveModelKind
    /// A readable name, e.g. "Nemotron Streaming".
    public var name: String
    /// BCP 47 language codes the model handles, e.g. ["en", "tr"]. Empty means "many".
    public var languages: [String]
    /// The download size in bytes.
    public var sizeBytes: Int64
    public var isDownloaded: Bool
    /// Whether the model is needed for a live session in the requested language.
    public var isRequired: Bool

    public init(
        id: String, kind: LiveModelKind, name: String, languages: [String], sizeBytes: Int64,
        isDownloaded: Bool, isRequired: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.languages = languages
        self.sizeBytes = sizeBytes
        self.isDownloaded = isDownloaded
        self.isRequired = isRequired
    }
}

/// How a live session should listen and speak.
public struct LiveSessionConfiguration: Codable, Sendable, Hashable {
    /// The conversation language, e.g. "tr-TR". The helper picks models that handle it.
    public var locale: String
    /// A speech recognition model to prefer, or `nil` for the helper's choice.
    public var speechToTextModel: String?
    /// A speech synthesis model to prefer, or `nil` for the helper's choice.
    public var textToSpeechModel: String?
    /// A voice of that model, or `nil` for its default.
    public var voice: String?
    /// An Apple voice identifier, used when no open model speaks the language.
    public var appleVoiceIdentifier: String?
    /// Whether the user speaking over Momo stops Momo at once.
    public var allowsBargeIn: Bool
    /// How long a pause may be, in seconds, before a turn can end. The turn detector may end
    /// it sooner when the sentence is clearly complete.
    public var maximumPause: Double

    public init(
        locale: String, speechToTextModel: String? = nil, textToSpeechModel: String? = nil,
        voice: String? = nil, appleVoiceIdentifier: String? = nil, allowsBargeIn: Bool = true,
        maximumPause: Double = 1.2
    ) {
        self.locale = locale
        self.speechToTextModel = speechToTextModel
        self.textToSpeechModel = textToSpeechModel
        self.voice = voice
        self.appleVoiceIdentifier = appleVoiceIdentifier
        self.allowsBargeIn = allowsBargeIn
        self.maximumPause = maximumPause
    }
}

/// A command from Momo to the helper.
public enum LiveVoiceCommand: Codable, Sendable, Hashable {
    /// The first message. The helper answers with ``LiveVoiceEvent/ready(version:languages:)``.
    case hello(version: Int)
    /// Asks for ``LiveVoiceEvent/models(_:)``, marking which models `locale` needs.
    case listModels(locale: String)
    /// Downloads models, reporting progress. Only sent after the user asked for it.
    case downloadModels(ids: [String])
    /// Deletes downloaded models.
    case deleteModels(ids: [String])
    /// Loads and warms up the models a session with this configuration needs, without
    /// opening the microphone, and answers with ``LiveVoiceEvent/prepared``, or a non-fatal
    /// ``LiveVoiceEvent/error(message:isFatal:)``. The first load of a new helper build
    /// compiles its models, which can take much longer than a normal start.
    case prepare(LiveSessionConfiguration)
    /// Starts listening with the microphone.
    case start(LiveSessionConfiguration)
    /// Stops listening and speaking and releases the audio devices.
    case stop
    /// Adds text to the utterance `id`, which starts playing as soon as a sentence is ready.
    /// `isFinal` marks the last chunk.
    case speak(id: String, text: String, isFinal: Bool)
    /// Stops speaking at once and drops queued text.
    case cancelSpeech
    /// Stops turning speech into turns, for example while Momo waits on a button press.
    /// Voice activity is still reported.
    case pauseListening
    case resumeListening
    /// Ends the helper process.
    case quit
}

/// An event from the helper to Momo.
public enum LiveVoiceEvent: Codable, Sendable, Hashable {
    /// The helper is ready. `languages` are the conversation languages it can serve with
    /// downloaded or downloadable models.
    case ready(version: Int, languages: [String])
    case models([LiveModelInfo])
    case downloadProgress(id: String, fraction: Double)
    case downloadFinished(id: String)
    case downloadFailed(id: String, message: String)
    /// The models of a ``LiveVoiceCommand/prepare(_:)`` are loaded and warm.
    case prepared
    /// The session runs and the microphone is open.
    case listening
    /// The microphone level, 0...1, a few times a second.
    case level(Double)
    /// The user started talking. When barge-in is on, the helper already stopped speaking.
    case speechStarted
    /// The words so far in the user's current turn.
    case partial(String)
    /// The user finished a turn.
    case turn(String)
    /// The utterance `id` started playing.
    case speakingStarted(id: String)
    /// The output level, 0...1, for moving Momo's mouth.
    case mouth(Double)
    /// The utterance `id` finished playing.
    case speakingFinished(id: String)
    /// The user interrupted the utterance `id`.
    case interrupted(id: String)
    /// Something went wrong. A fatal error ends the session.
    case error(message: String, isFatal: Bool)
    /// The session ended and the audio devices are released.
    case stopped
}

/// Encodes and decodes protocol messages as single JSON lines.
public enum LiveVoiceCoding {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    /// A message as one line of JSON, including the trailing newline.
    public static func line(_ message: some Encodable) throws -> Data {
        var data = try encoder.encode(message)
        data.append(0x0A)
        return data
    }

    /// Decodes one line of JSON; surrounding whitespace is ignored.
    public static func decode<Message: Decodable>(
        _ type: Message.Type, from line: some StringProtocol
    ) throws -> Message {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        return try JSONDecoder().decode(type, from: Data(text.utf8))
    }
}

/// Splits a byte stream into lines, for reading messages from a pipe.
public struct LiveVoiceLineBuffer: Sendable {
    private var pending = Data()

    public init() {}

    /// Adds bytes and returns every complete line they finish, without newlines.
    public mutating func append(_ data: Data) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            if let text = String(data: line, encoding: .utf8),
                !text.trimmingCharacters(in: .whitespaces).isEmpty
            {
                lines.append(text)
            }
        }
        return lines
    }
}
