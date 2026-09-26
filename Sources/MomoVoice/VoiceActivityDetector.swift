import Foundation

/// Decides when a spoken utterance ends, from input levels alone.
///
/// Feed it the level (0…1, as reported by the recorders) with a timestamp. It waits for speech
/// that lasts at least ``minimumSpeech``, then ends the utterance after ``silenceAfterSpeech``
/// of quiet. It also gives up when nobody speaks within ``noSpeechTimeout`` and stops at
/// ``maximumDuration``. The detector is a plain value, so it is easy to test with synthetic
/// levels.
public struct VoiceActivityDetector: Sendable {
    /// What the latest level means.
    public enum Event: Equatable, Sendable {
        /// Nothing changed.
        case none
        /// The user started speaking.
        case speechStarted
        /// The user spoke and then paused long enough: the utterance is complete.
        case endOfUtterance
        /// Nobody spoke before the timeout.
        case noSpeech
        /// The recording reached its maximum length.
        case maximumDurationReached
    }

    /// Level above which input counts as speech.
    public var speechThreshold: Double
    /// Level below which input counts as silence again. Lower than ``speechThreshold`` so
    /// that a level hovering around the threshold does not flicker.
    public var silenceThreshold: Double
    /// How long input must stay loud to count as speech, which ignores clicks and taps.
    public var minimumSpeech: TimeInterval
    /// How long a pause after speech ends the utterance.
    public var silenceAfterSpeech: TimeInterval
    /// How long to wait for the user to start speaking.
    public var noSpeechTimeout: TimeInterval
    /// The longest utterance.
    public var maximumDuration: TimeInterval
    /// Whether pauses end the utterance. Off for push to talk, where the user decides.
    public var endsOnSilence: Bool

    /// Whether speech was heard in this utterance.
    public private(set) var hasSpeech = false
    private var startTime: TimeInterval?
    private var loudSince: TimeInterval?
    private var quietSince: TimeInterval?
    private var isFinished = false

    public init(
        speechThreshold: Double = 0.3, silenceThreshold: Double = 0.2,
        minimumSpeech: TimeInterval = 0.15, silenceAfterSpeech: TimeInterval = 1.0,
        noSpeechTimeout: TimeInterval = 8, maximumDuration: TimeInterval = 60,
        endsOnSilence: Bool = true
    ) {
        self.speechThreshold = speechThreshold
        self.silenceThreshold = silenceThreshold
        self.minimumSpeech = minimumSpeech
        self.silenceAfterSpeech = silenceAfterSpeech
        self.noSpeechTimeout = noSpeechTimeout
        self.maximumDuration = maximumDuration
        self.endsOnSilence = endsOnSilence
    }

    /// Feeds one level measured at `time` (seconds, any monotonic clock). After an ending
    /// event the detector reports `.none` until ``reset()``.
    public mutating func process(level: Double, at time: TimeInterval) -> Event {
        guard !isFinished else { return .none }
        let start = startTime ?? time
        startTime = start
        if time - start >= maximumDuration {
            isFinished = true
            return .maximumDurationReached
        }

        if level >= speechThreshold {
            quietSince = nil
            let since = loudSince ?? time
            loudSince = since
            if !hasSpeech, time - since >= minimumSpeech {
                hasSpeech = true
                return .speechStarted
            }
            return .none
        }

        if level < silenceThreshold {
            loudSince = nil
            let since = quietSince ?? time
            quietSince = since
            guard endsOnSilence else { return .none }
            if hasSpeech, time - since >= silenceAfterSpeech {
                isFinished = true
                return .endOfUtterance
            }
            if !hasSpeech, time - start >= noSpeechTimeout {
                isFinished = true
                return .noSpeech
            }
        }
        return .none
    }

    /// Starts over for a new utterance.
    public mutating func reset() {
        hasSpeech = false
        startTime = nil
        loudSince = nil
        quietSince = nil
        isFinished = false
    }
}
