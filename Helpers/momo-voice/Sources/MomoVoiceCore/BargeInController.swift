/// Decides what the user starting to speak means while Momo may be talking.
///
/// When Momo is silent, detected speech is the start of a turn. While Momo speaks, the
/// microphone can still carry a little of Momo's own voice after echo cancellation, so with
/// barge-in on the speech must last ``minimumOverlap`` seconds before Momo stops; speech that
/// ends sooner is treated as echo and dropped. With barge-in off, the user's speech is a turn
/// like any other and Momo keeps talking.
public struct BargeInController: Sendable, Equatable {
    /// What the audio session should do.
    public enum Action: Sendable, Equatable {
        /// Stop playback at once and report that the user interrupted utterance `id`.
        case interrupt(id: String)
        /// Report that the user started talking and begin transcribing the turn.
        case beginTurn
        /// Forget the speech: it was Momo's own voice.
        case discardSpeech
    }

    private enum State: Sendable, Equatable {
        case idle
        /// The user's speech was accepted as a turn.
        case userSpeaking
        /// Speech started while Momo talks; not yet long enough to interrupt.
        case pending(since: Double)
    }

    /// Whether the user speaking over Momo stops Momo.
    public var allowsBargeIn: Bool
    /// Seconds of speech during playback before it counts as an interruption.
    public var minimumOverlap: Double

    private var state: State = .idle
    /// The utterance playing now, if any.
    public private(set) var playingID: String?

    public init(allowsBargeIn: Bool, minimumOverlap: Double = 0.3) {
        self.allowsBargeIn = allowsBargeIn
        self.minimumOverlap = minimumOverlap
    }

    /// Whether the current speech was accepted as a turn.
    public var isInTurn: Bool { state == .userSpeaking }

    /// Utterance `id` started playing.
    public mutating func playbackStarted(id: String) {
        playingID = id
    }

    /// Playback ended, because it finished or was cancelled. Speech that was waiting to
    /// count as an interruption becomes a turn.
    public mutating func playbackStopped() -> [Action] {
        playingID = nil
        if case .pending = state {
            state = .userSpeaking
            return [.beginTurn]
        }
        return []
    }

    /// The voice activity detector confirmed speech starting at `time` seconds.
    public mutating func speechStarted(at time: Double) -> [Action] {
        guard state == .idle else { return [] }
        guard let id = playingID, allowsBargeIn else {
            state = .userSpeaking
            return [.beginTurn]
        }
        if minimumOverlap <= 0 {
            return interrupt(id)
        }
        state = .pending(since: time)
        return []
    }

    /// Speech is still going on at `time` seconds.
    public mutating func speechContinues(at time: Double) -> [Action] {
        guard case .pending(let since) = state, let id = playingID else { return [] }
        return time - since >= minimumOverlap ? interrupt(id) : []
    }

    /// The speech, or the turn, ended.
    public mutating func speechEnded() -> [Action] {
        defer { state = .idle }
        if case .pending = state { return [.discardSpeech] }
        return []
    }

    /// Forgets everything, for a new session.
    public mutating func reset() {
        state = .idle
        playingID = nil
    }

    private mutating func interrupt(_ id: String) -> [Action] {
        playingID = nil
        state = .userSpeaking
        return [.interrupt(id: id), .beginTurn]
    }
}
