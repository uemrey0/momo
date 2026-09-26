import Foundation

/// How finished the words of a turn sound, judged from the transcript alone.
public enum TurnCompleteness: Sendable, Equatable {
    /// It ends like a finished sentence: a full stop, a question mark, a question particle.
    case complete
    /// Nothing points either way.
    case neutral
    /// It trails off: a comma, "and", "because", "ve", "çünkü", a filler like "um".
    case incomplete

    /// Words after which a speaker is almost certainly not done, folded (lower case, no
    /// diacritics, dotless i as i), in English and Turkish.
    static let continuingWords: Set<String> = [
        "and", "or", "but", "because", "so", "the", "a", "an", "to", "of", "for", "with", "in",
        "on", "at", "my", "your", "um", "uh", "erm", "hmm", "like", "if", "then", "that",
        "about", "from", "into", "than", "which", "whose", "also", "plus", "is", "are", "was",
        "ve", "veya", "ya", "yada", "ama", "fakat", "ancak", "cunku", "ile", "icin", "de", "da",
        "ki", "sey", "yani", "hani", "eger", "sonra", "bir", "bu", "su", "mesela", "ayrica",
        "hem", "gibi", "kadar", "once", "ee", "ii", "hmm",
    ]
    /// Words that end questions or polite requests, folded.
    static let endingWords: Set<String> = [
        "mi", "mu", "misin", "musun", "miyim", "muyum", "midir", "mudur", "please", "thanks",
        "lutfen", "tesekkurler",
    ]

    /// Judges `transcript`, the words of the current turn so far.
    public static func assess(_ transcript: String) -> TurnCompleteness {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return .neutral }
        if [",", ";", ":", "-", "–", "—"].contains(last) { return .incomplete }
        let words = SpeechText.foldedWords(trimmed)
        if let word = words.last {
            if continuingWords.contains(word) { return .incomplete }
            if endingWords.contains(word) { return .complete }
        }
        if [".", "!", "?", "…", "。", "？", "！"].contains(last) {
            // A full stop after a single word is often just the recogniser's guess.
            return words.count >= 2 || last != "." ? .complete : .neutral
        }
        return .neutral
    }
}

/// Decides when the user has finished a turn in a live conversation, and when they start
/// speaking (which interrupts Momo when it is talking).
///
/// It combines the input level with the words recognised so far: after speech, a short pause
/// ends a turn that sounds complete, a medium one a neutral turn, and a turn that trails off
/// gets the full ``Configuration/maximumPause``. While Momo is talking, starting speech needs
/// a louder and longer sound (the echo-cancelled input can still carry a little of Momo's
/// voice), so a cough or residual echo does not cut Momo off. The detector is a plain value,
/// easy to test with synthetic levels.
public struct LiveTurnDetector: Sendable {
    /// Thresholds and pauses, in seconds and input levels from 0 to 1.
    public struct Configuration: Sendable, Equatable {
        /// Level above which input counts as speech.
        public var speechThreshold: Double
        /// Level below which input counts as silence.
        public var silenceThreshold: Double
        /// How long input must stay loud to count as speech.
        public var minimumSpeech: TimeInterval
        /// Level that counts as the user talking over Momo.
        public var bargeInThreshold: Double
        /// How long the user must talk over Momo before Momo stops.
        public var bargeInMinimumSpeech: TimeInterval
        /// The pause that ends a turn that sounds complete.
        public var completePause: TimeInterval
        /// The pause that ends a turn when nothing points either way.
        public var neutralPause: TimeInterval
        /// The longest pause inside a turn, used when the turn trails off.
        public var maximumPause: TimeInterval
        /// How long to wait for words after speech before treating it as noise.
        public var transcriptWait: TimeInterval
        /// How much longer than ``maximumPause`` unchanged words may wait while the input
        /// never gets quiet (background noise), before the turn ends anyway.
        public var stallGrace: TimeInterval
        /// Whether pauses end turns. Off for push to talk, where the user ends them.
        public var endsTurnsOnPause: Bool

        public init(
            speechThreshold: Double = 0.3, silenceThreshold: Double = 0.2,
            minimumSpeech: TimeInterval = 0.15, bargeInThreshold: Double = 0.45,
            bargeInMinimumSpeech: TimeInterval = 0.3, completePause: TimeInterval = 0.6,
            neutralPause: TimeInterval = 0.85, maximumPause: TimeInterval = 1.4,
            transcriptWait: TimeInterval = 1.5, stallGrace: TimeInterval = 1.0,
            endsTurnsOnPause: Bool = true
        ) {
            self.speechThreshold = speechThreshold
            self.silenceThreshold = silenceThreshold
            self.minimumSpeech = minimumSpeech
            self.bargeInThreshold = bargeInThreshold
            self.bargeInMinimumSpeech = bargeInMinimumSpeech
            self.completePause = completePause
            self.neutralPause = neutralPause
            self.maximumPause = maximumPause
            self.transcriptWait = transcriptWait
            self.stallGrace = stallGrace
            self.endsTurnsOnPause = endsTurnsOnPause
        }

        /// The pause that ends a turn with these words.
        public func pause(for transcript: String) -> TimeInterval {
            switch TurnCompleteness.assess(transcript) {
            case .complete: completePause
            case .neutral: max(completePause, min(neutralPause, maximumPause))
            case .incomplete: maximumPause
            }
        }
    }

    /// What the latest input means.
    public enum Event: Sendable, Equatable {
        case none
        /// The user started speaking.
        case speechStarted
        /// The user finished the turn.
        case endOfTurn
        /// Something loud was heard but no words came; the turn starts over.
        case discarded
    }

    public var configuration: Configuration
    /// Whether speech was heard in the current turn.
    public private(set) var hasSpeech = false
    /// The words of the current turn so far.
    public private(set) var transcript = ""

    private var loudSince: TimeInterval?
    private var quietSince: TimeInterval?
    private var transcriptChangedAt: TimeInterval?

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    /// Notes the words recognised so far in this turn, at `time`. Words count as speech even
    /// when the voice was too soft for the level threshold, so this may report
    /// ``Event/speechStarted``.
    public mutating func update(transcript: String, at time: TimeInterval) -> Event {
        if transcript != self.transcript { transcriptChangedAt = time }
        self.transcript = transcript
        let hasWords = !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasWords, !hasSpeech else { return .none }
        hasSpeech = true
        return .speechStarted
    }

    /// Feeds one input level measured at `time` (seconds, any monotonic clock).
    /// `isOutputActive` says whether Momo is talking, which makes starting speech harder.
    public mutating func process(
        level: Double, at time: TimeInterval, isOutputActive: Bool = false
    )
        -> Event
    {
        let threshold =
            isOutputActive && !hasSpeech
            ? configuration.bargeInThreshold : configuration.speechThreshold
        let minimum =
            isOutputActive && !hasSpeech
            ? configuration.bargeInMinimumSpeech : configuration.minimumSpeech
        if level >= threshold {
            quietSince = nil
            let since = loudSince ?? time
            loudSince = since
            if !hasSpeech, time - since >= minimum {
                hasSpeech = true
                return .speechStarted
            }
            return .none
        }
        if level < configuration.silenceThreshold || (isOutputActive && !hasSpeech) {
            loudSince = nil
        }
        if configuration.endsTurnsOnPause, hasSpeech, let changed = transcriptChangedAt,
            !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            time - changed >= configuration.maximumPause + configuration.stallGrace
        {
            // The words stopped changing but the room never got quiet (a fan, music).
            reset()
            return .endOfTurn
        }
        guard level < configuration.silenceThreshold, hasSpeech else { return .none }
        let since = quietSince ?? time
        quietSince = since
        guard configuration.endsTurnsOnPause else { return .none }
        let quiet = time - since
        let words = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if words.isEmpty {
            guard quiet >= configuration.transcriptWait else { return .none }
            reset()
            return .discarded
        }
        guard quiet >= configuration.pause(for: words) else { return .none }
        reset()
        return .endOfTurn
    }

    /// Starts over for a new turn.
    public mutating func reset() {
        hasSpeech = false
        transcript = ""
        loudSince = nil
        quietSince = nil
        transcriptChangedAt = nil
    }
}

extension SpeechText {
    /// The words of `text`, folded: lower case, without diacritics or apostrophes, with the
    /// Turkish dotless i as i.
    static func foldedWords(_ text: String) -> [String] {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en")
        )
        .replacingOccurrences(of: "ı", with: "i")
        .replacingOccurrences(of: "\u{2019}", with: "")
        .replacingOccurrences(of: "'", with: "")
        return folded.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
    }

    /// Phrases that close a conversation, folded, in English and Turkish.
    static let closingPhrases: Set<String> = [
        "thanks", "thank you", "thanks thats all", "thank you thats all", "thats all",
        "thats it", "thats all for now", "thats all thanks", "thats it thanks", "bye",
        "goodbye", "bye bye", "thanks bye", "see you", "nothing else", "no thanks",
        "no thank you", "never mind", "stop", "were done", "im done", "all done",
        "tesekkurler", "tesekkur ederim", "cok tesekkurler", "cok tesekkur ederim", "sag ol",
        "sagol", "sagolun", "bu kadar", "tamam bu kadar", "simdilik bu kadar", "baska bir sey yok",
        "baska yok", "yok tesekkurler", "gorusuruz", "hosca kal", "hoscakal", "kapat", "bitti",
        "tamamdir", "eyvallah",
    ]
    /// Words that may surround a closing phrase without changing it, folded.
    static let closingFillers: Set<String> = [
        "ok", "okay", "alright", "great", "cool", "perfect", "super", "well", "hey", "momo",
        "so", "then", "oh", "ah", "tamam", "peki", "super", "harika", "iyi", "guzel", "o", "zaman",
        "hadi", "en", "a", "lot", "very", "much", "tesekkurler", "thanks",
    ]

    /// Whether `transcript` only closes the conversation, like "thanks, that's all",
    /// "teşekkürler" or "tamam bu kadar". Anything with a request in it is not closing.
    public static func isClosingPhrase(_ transcript: String) -> Bool {
        let words = foldedWords(transcript)
        guard !words.isEmpty, words.count <= 7 else { return false }
        if closingPhrases.contains(words.joined(separator: " ")) { return true }
        // Allow fillers around one closing phrase: "okay, thanks momo", "tamam teşekkürler".
        var core = words
        while let first = core.first, closingFillers.contains(first),
            !closingPhrases.contains(core.joined(separator: " "))
        {
            core.removeFirst()
        }
        while let last = core.last, closingFillers.contains(last),
            !closingPhrases.contains(core.joined(separator: " "))
        {
            core.removeLast()
        }
        if core.isEmpty {
            // Only fillers: "okay thanks" folds to thanks, which closes; "okay" alone does not.
            return words.contains("thanks") || words.contains("tesekkurler")
        }
        return closingPhrases.contains(core.joined(separator: " "))
    }
}
