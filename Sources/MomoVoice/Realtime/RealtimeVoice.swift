import Foundation

// Cloud realtime voice: a speech-to-speech model that hears and speaks natively, used as the
// live layer of a conversation. It owns turn-taking (voice activity, interruptions) and small
// talk, and hands anything real to Momo's assistant through one function (see
// ``MomoRealtimeAgent``). The audio leaves the Mac; see ``RealtimeVoicePrivacy``.

/// A realtime speech-to-speech service and the user's key for it.
public enum RealtimeVoiceService: Sendable, Equatable, CustomStringConvertible {
    /// OpenAI's Realtime API over WebSocket.
    case openAI(apiKey: String, model: String = OpenAIRealtime.defaultModel)

    /// The model name.
    public var model: String {
        switch self {
        case .openAI(_, let model): model
        }
    }

    /// A name for logs and the privacy log, such as "OpenAI gpt-realtime-2.1". Never
    /// contains the key.
    public var displayName: String {
        switch self {
        case .openAI(_, let model): "OpenAI \(model)"
        }
    }

    public var description: String { displayName }
}

/// How the service decides that the user finished speaking.
public enum RealtimeTurnDetection: Sendable, Equatable {
    /// How quickly a semantic turn detector answers.
    public enum Eagerness: String, Sendable, Equatable {
        case low, medium, high, auto
    }

    /// The model judges from the words whether the user is done (OpenAI semantic VAD). Gemini
    /// uses its automatic activity detection with default settings.
    case semantic(eagerness: Eagerness = .auto)
    /// A turn ends after `milliseconds` of silence (OpenAI server VAD, Gemini automatic
    /// activity detection with that silence duration).
    case silence(milliseconds: Int = 500)
}

/// A parameter of a ``RealtimeFunction``.
public struct RealtimeParameter: Sendable, Equatable {
    /// The JSON type of a parameter.
    public enum Kind: String, Sendable, Equatable {
        case string, boolean, number
    }

    public var name: String
    public var kind: Kind
    /// What the model should put there.
    public var description: String
    public var isRequired: Bool

    public init(name: String, kind: Kind = .string, description: String, isRequired: Bool = true) {
        self.name = name
        self.kind = kind
        self.description = description
        self.isRequired = isRequired
    }

    /// The JSON Schema object of the parameters, as both services take it.
    static func schema(
        _ parameters: [RealtimeParameter], upperCaseTypes: Bool = false
    )
        -> [String: Any]
    {
        func type(_ name: String) -> String { upperCaseTypes ? name.uppercased() : name }
        var properties: [String: Any] = [:]
        for parameter in parameters {
            properties[parameter.name] = [
                "type": type(parameter.kind.rawValue), "description": parameter.description,
            ]
        }
        return [
            "type": type("object"), "properties": properties,
            "required": parameters.filter(\.isRequired).map(\.name),
        ]
    }
}

/// A function the model may call.
public struct RealtimeFunction: Sendable, Equatable {
    public var name: String
    /// When and how to call it, for the model.
    public var description: String
    public var parameters: [RealtimeParameter]

    public init(name: String, description: String, parameters: [RealtimeParameter]) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

/// A function call the model asks for. Answer it with
/// ``RealtimeVoiceSession/sendFunctionResult(_:for:)``.
public struct RealtimeFunctionCall: Sendable, Equatable {
    /// The call's identifier, echoed in the result.
    public var id: String
    public var name: String
    /// The arguments as a JSON object string.
    public var arguments: String

    public init(id: String, name: String, arguments: String) {
        self.id = id
        self.name = name
        self.arguments = arguments
    }
}

/// How a session is set up.
public struct RealtimeSessionConfiguration: Sendable, Equatable {
    /// The system instructions (see ``MomoRealtimeAgent/instructions(_:)``).
    public var instructions: String
    /// A voice of the service, or `nil` for Momo's default for that service.
    public var voice: String?
    /// The conversation language as a BCP 47 code ("tr-TR", "en"), or `nil` to follow the
    /// user. Helps transcription; native audio models pick the spoken language themselves.
    public var language: String?
    /// The functions the model may call, usually just ``MomoRealtimeAgent/askMomo``.
    public var tools: [RealtimeFunction]
    public var turnDetection: RealtimeTurnDetection
    /// Whether the service transcribes what the user says (for captions and history).
    public var transcribesInput: Bool

    public init(
        instructions: String, voice: String? = nil, language: String? = nil,
        tools: [RealtimeFunction] = [], turnDetection: RealtimeTurnDetection = .semantic(),
        transcribesInput: Bool = true
    ) {
        self.instructions = instructions
        self.voice = voice
        self.language = language
        self.tools = tools
        self.turnDetection = turnDetection
        self.transcribesInput = transcribesInput
    }

    /// "tr-TR" → "tr".
    var languageCode: String? {
        language.flatMap(OpenAITranscriptionService.isoLanguage)
    }
}

/// How a model response ended.
public enum RealtimeResponseStatus: String, Sendable, Equatable {
    /// The model finished speaking (or finished a turn that called a function).
    case completed
    /// Cancelled, usually because the user spoke over the model.
    case cancelled
    /// Cut short, for example by the output token limit or a content filter.
    case incomplete
    /// The service failed to answer; an ``RealtimeEvent/error(_:)`` precedes it.
    case failed
}

/// Something that happened in a realtime session.
public enum RealtimeEvent: Sendable, Equatable {
    /// The session is set up; audio can flow.
    case ready
    /// The user started talking. Stop local playback at once and call
    /// ``RealtimeVoiceSession/interrupt(playedMilliseconds:)`` (barge-in). Gemini reports it
    /// only when the user talks over the model.
    case userSpeechStarted
    /// The user stopped talking (OpenAI only).
    case userSpeechStopped
    /// What the user said so far in this turn; `isFinal` marks the finished transcript.
    case userTranscript(String, isFinal: Bool)
    /// More words of what the model is saying.
    case assistantTranscriptDelta(String)
    /// The whole transcript of what the model said in this response.
    case assistantTranscriptDone(String)
    /// Speech from the model: mono PCM16 at ``RealtimeVoiceSession/outputSampleRate``.
    case assistantAudio(Data)
    /// The response ended.
    case responseDone(RealtimeResponseStatus)
    /// The model calls a function; answer with ``RealtimeVoiceSession/sendFunctionResult(_:for:)``.
    case functionCall(RealtimeFunctionCall)
    /// The model no longer wants the results of these calls (Gemini, after an interruption).
    case functionCallsCancelled(ids: [String])
    /// The service will end the session soon, for example at its time limit.
    case sessionEnding(timeLeft: TimeInterval?)
    /// A problem the session survives.
    case error(CloudVoiceError)
    /// The session ended: `nil` after ``RealtimeVoiceSession/close()``, otherwise why.
    case closed(CloudVoiceError?)
}

/// A message on the realtime socket.
public enum RealtimeTransportMessage: Sendable, Equatable {
    case text(String)
    case data(Data)

    /// The message as text; services send JSON either way.
    var text: String? {
        switch self {
        case .text(let text): text
        case .data(let data): String(data: data, encoding: .utf8)
        }
    }
}

/// An open WebSocket, abstracted so sessions can be tested without a network.
public protocol RealtimeTransport: Sendable {
    /// Sends a text frame.
    func send(_ text: String) async throws
    /// Waits for the next frame. Throws ``CloudVoiceError`` when the connection fails or the
    /// server closes it, and `CancellationError` after ``close()``.
    func receive() async throws -> RealtimeTransportMessage
    /// Closes the connection normally.
    func close()
}

/// Opens ``RealtimeTransport`` connections.
public protocol RealtimeTransportFactory: Sendable {
    func connect(_ request: URLRequest) async throws -> any RealtimeTransport
}

/// Speaks one service's protocol: builds its messages and turns its events into
/// ``RealtimeEvent``s. Codecs keep the little state their protocol needs (the item being
/// spoken, transcripts in progress) and are used by one session at a time.
protocol RealtimeCodec: Sendable {
    /// Sample rate of the audio the service expects.
    var inputSampleRate: Int { get }
    /// Sample rate of the audio the service sends.
    var outputSampleRate: Int { get }
    /// The WebSocket request, with authentication.
    func connectionRequest() throws -> URLRequest
    /// The messages that set the session up, sent first.
    func setupMessages(for configuration: RealtimeSessionConfiguration) throws -> [String]
    /// A message carrying microphone audio.
    func audioMessage(_ pcm16: Data) -> String
    /// The messages that return a function result and let the model continue.
    func functionResultMessages(
        _ output: String, for call: RealtimeFunctionCall
    ) throws
        -> [String]
    /// The messages for a barge-in, given how much of the current speech the user heard.
    mutating func interruptMessages(playedMilliseconds: Int?) -> [String]
    /// Turns one server message into events.
    mutating func decode(_ text: String) -> [RealtimeEvent]
}

/// Builds and reads the JSON of realtime messages.
enum RealtimeJSON {
    /// Compact JSON with sorted keys, so messages are stable (and testable).
    static func string(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    static func object(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    /// A JSON object string for a function result: the text itself when it already is one,
    /// otherwise `{"result": text}`.
    static func resultObject(_ output: String) -> [String: Any] {
        object(output) ?? ["result": output]
    }
}

/// Turns connection failures into messages the user can act on.
enum RealtimeErrors {
    static let timedOut = CloudVoiceError("The live voice service did not answer in time.")
    static let noConnection = CloudVoiceError(
        "The internet connection was lost, so live voice stopped.")
    static let notConnected = CloudVoiceError("Live voice is not connected.")

    /// A WebSocket close frame from the server.
    static func closed(code: Int, reason: String) -> CloudVoiceError {
        let reason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        func message(_ base: String) -> String { reason.isEmpty ? base : "\(base) \(reason)" }
        let lower = reason.lowercased()
        if lower.contains("api key") || lower.contains("api_key") || lower.contains("unauthori")
            || lower.contains("permission")
        {
            return CloudVoiceError(
                status: 401, message("The API key was rejected. Check it in Settings."))
        }
        if lower.contains("quota") || lower.contains("rate limit")
            || lower.contains("resource_exhausted") || lower.contains("resource exhausted")
        {
            return CloudVoiceError(
                status: 429, message("Rate limit or quota reached. Try again shortly."))
        }
        if lower.contains("not found") || lower.contains("not supported") {
            return CloudVoiceError(
                status: 404, message("The live voice model is not available."))
        }
        switch code {
        case 1000:
            return CloudVoiceError(message("The live voice service ended the session."))
        case 1011, 1013, 1014:
            return CloudVoiceError(message("The live voice service had a server error."))
        default:
            return CloudVoiceError(
                message("The live voice service closed the connection (\(code))."))
        }
    }
}
