import Foundation

/// Live dictation: turns what the user says into text while they speak.
///
/// Call ``start(locale:)``; partial transcripts arrive through ``onPartial`` and the final one
/// through ``onFinal``, exactly once per session, after the user pauses or ``stop(deliver:)``
/// is called. Engines that finish their work after the microphone closes (on-device
/// finalisation, cloud transcription) may call ``onFinal`` some time after `stop` returns.
@MainActor
public protocol DictationEngine: AnyObject {
    /// The transcript so far, updated while the user speaks.
    var onPartial: ((String) -> Void)? { get set }
    /// The finished transcript; empty when nothing was understood.
    var onFinal: ((String) -> Void)? { get set }
    /// Input level from 0 to 1, about 20 times a second.
    var onLevel: ((Double) -> Void)? { get set }
    /// Keep listening through pauses, until ``stop(deliver:)`` (push to talk, wake word).
    var isContinuous: Bool { get set }
    /// Whether the microphone is open.
    var isListening: Bool { get }

    /// Starts listening in `locale`'s language. Throws when permissions are missing or the
    /// engine cannot run, so the caller can fall back to another engine.
    func start(locale: Locale) async throws
    /// Stops listening. With `deliver`, the transcript is sent to ``onFinal``; without it the
    /// session is cancelled and nothing is delivered.
    func stop(deliver: Bool)
}

/// The speech recognition engine the user picked in Settings.
public enum DictationEngineChoice: String, Codable, CaseIterable, Sendable, Identifiable {
    /// The best engine that runs on this Mac: `SpeechAnalyzer` on macOS 26 and later,
    /// otherwise Apple Speech.
    case automatic
    /// Apple Speech (`SFSpeechRecognizer`), the engine that works everywhere.
    case appleSpeech
    /// OpenAI transcription with the user's own key.
    case openAI
    /// Gemini audio understanding with the user's own key.
    case gemini

    public var id: String { rawValue }

    /// Whether this choice sends audio off the Mac.
    public var isRemote: Bool { self == .openAI || self == .gemini }
}

/// The engine that will actually run.
public enum DictationEngineKind: Equatable, Sendable {
    case appleSpeech
    case speechAnalyzer
    case openAI
    case gemini

    /// Whether this engine sends audio off the Mac.
    public var isRemote: Bool { self == .openAI || self == .gemini }
}

/// Decides which engine runs for a choice, given what the Mac and the user's keys allow.
public enum DictationEngineSelector {
    /// The outcome of a selection.
    public struct Selection: Equatable, Sendable {
        /// The engine to run.
        public var kind: DictationEngineKind
        /// Set when a cloud engine was chosen but its key is missing, so an on-device engine
        /// runs instead and the user should be told.
        public var isMissingKey: Bool

        public init(kind: DictationEngineKind, isMissingKey: Bool = false) {
            self.kind = kind
            self.isMissingKey = isMissingKey
        }
    }

    /// Picks the engine for `choice`.
    public static func select(
        _ choice: DictationEngineChoice, speechAnalyzerAvailable: Bool, hasOpenAIKey: Bool,
        hasGeminiKey: Bool
    ) -> Selection {
        let onDevice: DictationEngineKind = speechAnalyzerAvailable ? .speechAnalyzer : .appleSpeech
        switch choice {
        case .automatic:
            return Selection(kind: onDevice)
        case .appleSpeech:
            return Selection(kind: .appleSpeech)
        case .openAI:
            return hasOpenAIKey
                ? Selection(kind: .openAI) : Selection(kind: onDevice, isMissingKey: true)
        case .gemini:
            return hasGeminiKey
                ? Selection(kind: .gemini) : Selection(kind: onDevice, isMissingKey: true)
        }
    }

    /// Whether Apple's `SpeechAnalyzer` can run on this Mac. Languages are checked when an
    /// engine starts; an unsupported one makes it throw so the caller can fall back.
    public static var isSpeechAnalyzerAvailable: Bool {
        if #available(macOS 26, *) {
            return AnalyzerDictationEngine.isAvailable
        }
        return false
    }
}
