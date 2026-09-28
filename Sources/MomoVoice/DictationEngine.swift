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
    /// Momo's voice models, on this Mac.
    case onDevice
    /// OpenAI transcription with the user's own key.
    case openAI
    /// Gemini audio understanding with the user's own key.
    case gemini

    public var id: String { rawValue }

    /// Whether this choice sends audio off the Mac.
    public var isRemote: Bool { self == .openAI || self == .gemini }

    /// Reads the choice; Apple's engines of earlier versions mean Momo's voice models now.
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = DictationEngineChoice(rawValue: value) ?? .onDevice
    }
}

/// The engine that will actually run.
public enum DictationEngineKind: Equatable, Sendable {
    case onDevice
    case openAI
    case gemini

    /// Whether this engine sends audio off the Mac.
    public var isRemote: Bool { self == .openAI || self == .gemini }
}

/// Decides which engine runs for a choice, given the user's keys.
public enum DictationEngineSelector {
    /// The outcome of a selection.
    public struct Selection: Equatable, Sendable {
        /// The engine to run.
        public var kind: DictationEngineKind
        /// Set when a cloud engine was chosen but its key is missing, so Momo's voice models
        /// run instead and the user should be told.
        public var isMissingKey: Bool

        public init(kind: DictationEngineKind, isMissingKey: Bool = false) {
            self.kind = kind
            self.isMissingKey = isMissingKey
        }
    }

    /// Picks the engine for `choice`.
    public static func select(
        _ choice: DictationEngineChoice, hasOpenAIKey: Bool, hasGeminiKey: Bool
    ) -> Selection {
        switch choice {
        case .onDevice:
            return Selection(kind: .onDevice)
        case .openAI:
            return hasOpenAIKey
                ? Selection(kind: .openAI) : Selection(kind: .onDevice, isMissingKey: true)
        case .gemini:
            return hasGeminiKey
                ? Selection(kind: .gemini) : Selection(kind: .onDevice, isMissingKey: true)
        }
    }
}
