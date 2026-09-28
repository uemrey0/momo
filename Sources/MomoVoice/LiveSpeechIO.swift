import Foundation
import MomoLiveProtocol

// The speech layer of a live conversation: it listens all the time, decides when the user
// finished a turn, speaks the reply as it streams in and stops when the user talks over it.
// It never thinks; `LiveConversation` sends turns to Momo's brain and streams the reply back.
//
// The vocabulary mirrors `MomoLiveProtocol` (the `momo-voice` helper protocol) one to one, so
// the helper engine maps each command and event directly. Momo's on-device voice models in the
// helper are the only speech layer; cloud realtime models replace the whole live layer.

/// How a live session should listen and speak. Mirrors `LiveSessionConfiguration` of the
/// helper protocol.
public struct LiveSpeechConfiguration: Sendable, Equatable {
    /// The conversation language.
    public var locale: Locale
    /// Whether the session listens, speaks or both.
    public var mode: LiveSessionMode
    /// Whether the user speaking over Momo stops Momo at once.
    public var allowsBargeIn: Bool
    /// The longest pause inside a turn, in seconds. Turns that sound complete end sooner.
    public var maximumPause: TimeInterval
    /// Whether pauses end turns. Off for push to talk, where ``LiveSpeechIO/endTurn()`` does.
    public var endsTurnsOnPause: Bool
    /// A speech recognition model to prefer, or `nil` for the helper's choice.
    public var speechToTextModel: String?
    /// A speech synthesis model to prefer, or `nil` for the helper's choice.
    public var textToSpeechModel: String?
    /// A voice of that model, or `nil` for its default.
    public var modelVoice: String?

    public init(
        locale: Locale, mode: LiveSessionMode = .conversation, allowsBargeIn: Bool = true,
        maximumPause: TimeInterval = 1.4, endsTurnsOnPause: Bool = true,
        speechToTextModel: String? = nil, textToSpeechModel: String? = nil,
        modelVoice: String? = nil
    ) {
        self.locale = locale
        self.mode = mode
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
/// The engine is ``HelperLiveSpeechIO``: Momo's voice models in the `momo-voice` helper.
/// Cloud realtime models are not a speech layer but the live layer itself
/// (``RealtimeConversation``). Commands mirror `LiveVoiceCommand` of the helper protocol.
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
    /// Momo's voice models, on this Mac.
    case onDevice
    /// A cloud realtime voice session (OpenAI Realtime, Gemini Live) with the user's key.
    case cloudRealtime

    public var id: String { rawValue }

    /// Whether this choice sends audio off the Mac.
    public var isRemote: Bool { self == .cloudRealtime }

    /// Reads the choice; choices of earlier versions (Apple's engine, automatic, open
    /// source) all mean Momo's voice models now.
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = LiveEngineChoice(rawValue: value) ?? .onDevice
    }
}

/// The live engine that will actually run.
public enum LiveEngineKind: Sendable, Equatable {
    case onDevice
    case cloudRealtime
}

/// Where Momo's voice models stand for the conversation language.
public enum LiveHelperStatus: Sendable, Equatable {
    /// The voice helper is not installed or can't run on this Mac.
    case unavailable
    /// The helper didn't start or didn't answer in time.
    case notResponding
    /// Models the conversation language needs are not downloaded.
    case modelsMissing
    /// The models are downloaded but this helper build hasn't loaded them yet. The first
    /// load compiles them, which takes far longer than a conversation may wait.
    case preparing
    /// The helper answers, the models are downloaded and warm.
    case ready
}

/// Decides which live engine runs for a choice.
public enum LiveEngineSelector {
    /// The outcome of a selection.
    public struct Selection: Sendable, Equatable {
        /// The engine that runs, or `nil` when none can: Momo's voice models aren't ready and
        /// the cloud isn't an option.
        public var kind: LiveEngineKind?
        /// Set when the chosen engine can't run, so another one runs (or none), and the user
        /// should be told why.
        public var isFallback: Bool

        public init(kind: LiveEngineKind?, isFallback: Bool = false) {
            self.kind = kind
            self.isFallback = isFallback
        }
    }

    /// Picks the engine for `choice`.
    /// - Parameters:
    ///   - helper: Where Momo's voice models stand. They only run when
    ///     ``LiveHelperStatus/ready``, so a conversation never waits on models that can't
    ///     start quickly.
    ///   - cloudRealtimeReady: A cloud realtime engine is set up with a key.
    public static func select(
        _ choice: LiveEngineChoice, helper: LiveHelperStatus, cloudRealtimeReady: Bool
    ) -> Selection {
        let onDevice: LiveEngineKind? = helper == .ready ? .onDevice : nil
        switch choice {
        case .onDevice:
            return Selection(kind: onDevice, isFallback: onDevice == nil)
        case .cloudRealtime:
            return cloudRealtimeReady
                ? Selection(kind: .cloudRealtime) : Selection(kind: onDevice, isFallback: true)
        }
    }
}

/// Why a live engine couldn't start, in terms of what the user can do about it.
public enum LiveStartProblem: Sendable, Equatable {
    /// Momo may not use the microphone.
    case microphoneDenied
    /// Momo's voice models are not downloaded.
    case modelsMissing
    /// The voice helper didn't start listening in time.
    case timedOut
    /// The microphone or the speakers couldn't be opened.
    case audioDevice
    /// Speech recognition doesn't understand the conversation language.
    case unsupportedLanguage
    /// Anything else, with the engine's own words.
    case other(String)

    /// Whether another engine may still work. A missing permission stops them all, so
    /// trying another one only delays the message that says what to do.
    public var allowsFallback: Bool {
        self != .microphoneDenied
    }

    /// The problem behind an error thrown by ``LiveSpeechIO/start(_:)``.
    public static func classify(_ error: any Error) -> LiveStartProblem {
        switch error {
        case let error as DictationError:
            switch error {
            case .microphoneDenied: return .microphoneDenied
            case .unsupportedLanguage: return .unsupportedLanguage
            case .unavailable: return .audioDevice
            }
        case let error as LiveVoiceHelperError:
            switch error {
            case .noAnswer: return .timedOut
            case .failed(let message): return classifyHelper(message)
            case .notRunning, .incompatible: return .other(error.localizedDescription)
            }
        case is LiveAudioError:
            return .audioDevice
        default:
            let error = error as NSError
            // AVAudioEngine and Core Audio report OSStatus codes, such as -10875 when the
            // voice processing unit can't be set up for the current devices.
            if error.domain == "com.apple.coreaudio.avfaudio"
                || error.domain == NSOSStatusErrorDomain
            {
                return .audioDevice
            }
            return .other(error.localizedDescription)
        }
    }

    /// The problem behind an error message from the helper.
    public static func classify(message: String) -> LiveStartProblem {
        classifyHelper(message)
    }

    /// The problem behind a fatal error message from the helper.
    static func classifyHelper(_ message: String) -> LiveStartProblem {
        let text = message.lowercased()
        if text.contains("microphone") && (text.contains("not allowed") || text.contains("denied"))
        {
            return .microphoneDenied
        }
        if text.contains("no microphone") { return .audioDevice }
        if text.contains("need to be downloaded") || text.contains("modelsmissing") {
            return .modelsMissing
        }
        if text.contains("understands") || text.contains("unsupportedlanguage") {
            return .unsupportedLanguage
        }
        return .other(message)
    }
}

/// What runs after a live engine failed to start.
public enum LiveFallbackPlan: Sendable, Equatable {
    /// Momo's voice models, which need no key.
    case onDevice
    /// Nothing: the user has to fix something first, and is told what.
    case stop

    /// The next step after `kind` failed with `problem`. Only a failed cloud session falls
    /// back, and only to voice models that are ready.
    public static func next(
        after kind: LiveEngineKind, problem: LiveStartProblem, helperReady: Bool
    ) -> LiveFallbackPlan {
        guard problem.allowsFallback, kind == .cloudRealtime, helperReady else { return .stop }
        return .onDevice
    }
}
