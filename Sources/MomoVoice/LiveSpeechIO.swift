import Foundation

// The speech layer of a live conversation: it listens all the time, decides when the user
// finished a turn, speaks the reply as it streams in and stops when the user talks over it.
// It never thinks; `LiveConversation` sends turns to Momo's brain and streams the reply back.
//
// The vocabulary mirrors `MomoLiveProtocol` (the `momo-voice` helper protocol) one to one, so
// the helper engine maps each command and event directly, and so can any other engine, such
// as a cloud realtime session used as a speech layer.

/// How the reply is spoken.
public enum LiveVoiceOutput: Sendable, Equatable {
    /// A Mac voice. `identifier` is the user's chosen voice, or `nil` for the best voice of
    /// the conversation language. `rate` goes from 0.5 (slow) to 1.5 (fast).
    case apple(identifier: String?, rate: Float)
    /// An OpenAI voice with the user's key; each sentence is sent to OpenAI.
    case openAI(OpenAISpeechRequest)
}

extension OpenAISpeechRequest: Equatable {
    public static func == (lhs: OpenAISpeechRequest, rhs: OpenAISpeechRequest) -> Bool {
        lhs.apiKey == rhs.apiKey && lhs.model == rhs.model && lhs.voice == rhs.voice
            && lhs.instructions == rhs.instructions && lhs.baseURL == rhs.baseURL
    }
}

/// How a live session should listen and speak. Mirrors `LiveSessionConfiguration` of the
/// helper protocol, plus what only in-app engines need.
public struct LiveSpeechConfiguration: Sendable, Equatable {
    /// The conversation language.
    public var locale: Locale
    /// How replies are spoken.
    public var voice: LiveVoiceOutput
    /// Whether the user speaking over Momo stops Momo at once.
    public var allowsBargeIn: Bool
    /// The longest pause inside a turn, in seconds. Turns that sound complete end sooner.
    public var maximumPause: TimeInterval
    /// Whether pauses end turns. Off for push to talk, where ``LiveSpeechIO/endTurn()`` does.
    public var endsTurnsOnPause: Bool
    /// A speech recognition model to prefer (helper engine), or `nil` for its choice.
    public var speechToTextModel: String?
    /// A speech synthesis model to prefer (helper engine), or `nil` for its choice.
    public var textToSpeechModel: String?
    /// A voice of that model (helper engine), or `nil` for its default.
    public var modelVoice: String?

    public init(
        locale: Locale, voice: LiveVoiceOutput = .apple(identifier: nil, rate: 1),
        allowsBargeIn: Bool = true, maximumPause: TimeInterval = 1.4,
        endsTurnsOnPause: Bool = true, speechToTextModel: String? = nil,
        textToSpeechModel: String? = nil, modelVoice: String? = nil
    ) {
        self.locale = locale
        self.voice = voice
        self.allowsBargeIn = allowsBargeIn
        self.maximumPause = maximumPause
        self.endsTurnsOnPause = endsTurnsOnPause
        self.speechToTextModel = speechToTextModel
        self.textToSpeechModel = textToSpeechModel
        self.modelVoice = modelVoice
    }
}

/// What a live speech engine reports. Mirrors `LiveVoiceEvent` of the helper protocol, minus
/// the model management events.
public enum LiveSpeechEvent: Sendable, Equatable {
    /// The session runs and the microphone is open.
    case listening
    /// The microphone level, 0...1, a few times a second.
    case level(Double)
    /// The user started talking. When barge-in is on and Momo was talking, the engine
    /// already stopped and also reports ``interrupted(id:)``.
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
    /// The user interrupted the utterance `id`; its playback has stopped.
    case interrupted(id: String)
    /// Something went wrong. A fatal error ends the session (``stopped`` follows).
    case error(message: String, isFatal: Bool)
    /// The session ended and the audio devices are released.
    case stopped
}

/// The speech layer of a live conversation: continuous listening with turn detection, echo
/// cancellation and barge-in, and streamed speech output.
///
/// Engines: ``AppleLiveSpeechIO`` (built in, every Mac), ``HelperLiveSpeechIO`` (the open
/// source `momo-voice` helper) and, later, cloud realtime sessions. Commands mirror
/// `LiveVoiceCommand` of the helper protocol.
///
/// Rules every engine follows:
/// - Events arrive on the main actor through ``onEvent``, in order.
/// - ``speak(id:text:isFinal:)`` appends text to the utterance `id`; playback starts as soon
///   as a sentence is ready. Utterances play one after another in the order they were first
///   spoken to; `isFinal` marks the last chunk, after which ``LiveSpeechEvent/speakingFinished(id:)``
///   follows once it has played.
/// - ``cancelSpeech()`` stops playback at once and drops everything queued, without reporting
///   `speakingFinished` for what was dropped.
/// - While listening is paused, no partials or turns are reported, but voice activity (level,
///   speech started) and barge-in still are.
@MainActor
public protocol LiveSpeechIO: AnyObject {
    /// Receives events on the main actor.
    var onEvent: ((LiveSpeechEvent) -> Void)? { get set }
    /// Whether a session runs.
    var isRunning: Bool { get }

    /// Opens the microphone and starts listening. Throws when permissions are missing or the
    /// engine cannot run, so the caller can fall back to another engine.
    func start(_ configuration: LiveSpeechConfiguration) async throws
    /// Stops listening and speaking and releases the audio devices; ``LiveSpeechEvent/stopped``
    /// follows.
    func stop()
    /// Adds text to the utterance `id`. `isFinal` marks the last chunk.
    func speak(id: String, text: String, isFinal: Bool)
    /// Stops speaking at once and drops queued text.
    func cancelSpeech()
    /// Stops turning speech into turns, for example while a button answers a question.
    func pauseListening()
    /// Turns speech into turns again, starting a fresh turn.
    func resumeListening()
    /// Ends the user's turn now with what was heard so far (push to talk). An empty turn is
    /// reported as an empty ``LiveSpeechEvent/turn(_:)``.
    func endTurn()
}

/// The live conversation engine the user picked in Settings.
public enum LiveEngineChoice: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The open source helper when its models are downloaded, otherwise Apple.
    case automatic
    /// Apple's speech recognition and voices with the Mac's echo cancellation.
    case apple
    /// The open source on-device engine in the `momo-voice` helper.
    case openSource
    /// A cloud realtime voice session (OpenAI Realtime, Gemini Live) with the user's key.
    case cloudRealtime

    public var id: String { rawValue }

    /// Whether this choice sends audio off the Mac.
    public var isRemote: Bool { self == .cloudRealtime }
}

/// The live engine that will actually run.
public enum LiveEngineKind: Sendable, Equatable {
    case apple
    case openSource
    case cloudRealtime
}

/// Decides which live engine runs for a choice.
public enum LiveEngineSelector {
    /// The outcome of a selection.
    public struct Selection: Sendable, Equatable {
        public var kind: LiveEngineKind
        /// Set when the chosen engine can't run, so another one runs and the user should be
        /// told why.
        public var isFallback: Bool

        public init(kind: LiveEngineKind, isFallback: Bool = false) {
            self.kind = kind
            self.isFallback = isFallback
        }
    }

    /// Picks the engine for `choice`.
    /// - Parameters:
    ///   - helperReady: The helper exists, runs on this Mac and has the models for the
    ///     conversation language.
    ///   - cloudRealtimeReady: A cloud realtime engine is set up with a key.
    public static func select(
        _ choice: LiveEngineChoice, helperReady: Bool, cloudRealtimeReady: Bool
    ) -> Selection {
        switch choice {
        case .automatic:
            return Selection(kind: helperReady ? .openSource : .apple)
        case .apple:
            return Selection(kind: .apple)
        case .openSource:
            return helperReady
                ? Selection(kind: .openSource) : Selection(kind: .apple, isFallback: true)
        case .cloudRealtime:
            return cloudRealtimeReady
                ? Selection(kind: .cloudRealtime) : Selection(kind: .apple, isFallback: true)
        }
    }
}
