import Foundation

// The protocol between Momo and `momo-voice`, the helper process that runs Momo's on-device
// voice models: streaming speech recognition, turn detection, echo cancellation, speech
// synthesis and the transcription of recordings. Every part of Momo that listens or speaks
// goes through it.
//
// Momo starts `momo-voice` as a child process and exchanges one JSON object per line over
// its standard input (commands) and standard output (events). The helper owns the
// microphone and the speaker while a session runs, because echo cancellation needs both in
// one place. It never thinks: finished user turns go to Momo, and Momo streams the reply
// back sentence by sentence.

/// The protocol version. Momo refuses a helper that reports another major version.
public let liveVoiceProtocolVersion = 2

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
    /// Whether the user added the model from a folder on this Mac.
    public var isCustom: Bool
    /// The voices of a downloaded speech synthesis model; empty for other models.
    public var voices: [String]
    /// The voices among ``voices`` that the user added from files, which can be deleted.
    public var customVoices: [String]

    public init(
        id: String, kind: LiveModelKind, name: String, languages: [String], sizeBytes: Int64,
        isDownloaded: Bool, isRequired: Bool = false, isCustom: Bool = false,
        voices: [String] = [], customVoices: [String] = []
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.languages = languages
        self.sizeBytes = sizeBytes
        self.isDownloaded = isDownloaded
        self.isRequired = isRequired
        self.isCustom = isCustom
        self.voices = voices
        self.customVoices = customVoices
    }
}

/// What a session does with the audio devices.
public enum LiveSessionMode: String, Codable, Sendable, Hashable {
    /// Listens with turn detection and speaks, with echo cancellation: a live conversation.
    case conversation
    /// Only listens and reports partials and turns (dictation, the wake word). No speech
    /// synthesis model is needed.
    case listen
    /// Only speaks (reading replies aloud). The microphone stays closed and only the speech
    /// synthesis model is needed.
    case speak
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
    /// What the session does with the audio devices.
    public var mode: LiveSessionMode
    /// Whether the user speaking over Momo stops Momo at once.
    public var allowsBargeIn: Bool
    /// How long a pause may be, in seconds, before a turn can end. The turn detector may end
    /// it sooner when the sentence is clearly complete.
    public var maximumPause: Double

    public init(
        locale: String, speechToTextModel: String? = nil, textToSpeechModel: String? = nil,
        voice: String? = nil, mode: LiveSessionMode = .conversation, allowsBargeIn: Bool = true,
        maximumPause: Double = 1.2
    ) {
        self.locale = locale
        self.speechToTextModel = speechToTextModel
        self.textToSpeechModel = textToSpeechModel
        self.voice = voice
        self.mode = mode
        self.allowsBargeIn = allowsBargeIn
        self.maximumPause = maximumPause
    }

    /// Whether the session opens the microphone.
    public var listens: Bool { mode != .speak }
    /// Whether the session speaks and needs a speech synthesis model.
    public var speaks: Bool { mode != .listen }
}

/// A timed piece of a transcribed recording.
public struct LiveTranscriptSegment: Codable, Sendable, Hashable {
    public var text: String
    /// Seconds from the start of the recording.
    public var start: Double
    /// Seconds from the start of the recording.
    public var end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// A command from Momo to the helper.
public enum LiveVoiceCommand: Codable, Sendable, Hashable {
    /// The first message. The helper answers with ``LiveVoiceEvent/ready(version:languages:)``.
    case hello(version: Int)
    /// Asks for ``LiveVoiceEvent/models(_:)``, marking which models a conversation in
    /// `locale` needs, speaking with `textToSpeechModel` (or the helper's choice for `nil`).
    case listModels(locale: String, textToSpeechModel: String?)
    /// Downloads models, reporting progress. Only sent after the user asked for it.
    case downloadModels(ids: [String])
    /// Deletes downloaded models, including models the user added.
    case deleteModels(ids: [String])
    /// Adds the speech synthesis model in the folder at `path`, which must hold a conversion
    /// the helper can run (Kokoro or Supertonic). The folder is copied. Answers with
    /// ``LiveVoiceEvent/modelImported(id:)`` or ``LiveVoiceEvent/importFailed(message:)``.
    case importModel(path: String)
    /// Adds the voice file at `path` (a voice style for the model's architecture) to the
    /// speech synthesis model `modelID`. Answers with
    /// ``LiveVoiceEvent/voiceImported(modelID:voice:)`` or ``LiveVoiceEvent/importFailed(message:)``.
    case importVoice(modelID: String, path: String)
    /// Deletes a voice the user added to `modelID`.
    case deleteVoice(modelID: String, voice: String)
    /// Transcribes the recording at `path` (a WAV file) in `locale`'s language, without
    /// touching the audio devices. Runs alongside other commands and answers with
    /// ``LiveVoiceEvent/transcribed(id:segments:)`` or
    /// ``LiveVoiceEvent/transcriptionFailed(id:message:)``.
    case transcribe(id: String, path: String, locale: String)
    /// Loads and warms up the models a session with this configuration needs, without
    /// opening the microphone, and answers with ``LiveVoiceEvent/prepared``, or a non-fatal
    /// ``LiveVoiceEvent/error(message:isFatal:)``. The first load of a new helper build
    /// compiles its models, which can take much longer than a normal start.
    case prepare(LiveSessionConfiguration)
    /// Starts a session: listening with the microphone, speaking, or both, as its
    /// ``LiveSessionConfiguration/mode`` says.
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
    /// A model from a folder was added as `id`.
    case modelImported(id: String)
    /// A voice file was added to `modelID` as `voice`.
    case voiceImported(modelID: String, voice: String)
    /// Adding a model or a voice failed.
    case importFailed(message: String)
    /// The recording of ``LiveVoiceCommand/transcribe(id:path:locale:)`` `id` was transcribed.
    case transcribed(id: String, segments: [LiveTranscriptSegment])
    case transcriptionFailed(id: String, message: String)
    /// The session runs: the microphone is open, or for a speaking session, the speaker is.
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
