import Foundation

/// Decides what Momo says while the brain works on a reply, so a live conversation never
/// falls silent and never talks over the real answer.
///
/// When the brain has not produced its first sentence ``Configuration/acknowledgementDelay``
/// after the turn, Momo says a short acknowledgement: the contextual one a fast local brain
/// wrote ("Takvimine bakıyorum."), if it arrived in time, otherwise a canned phrase. When a
/// tool starts before the answer, its activity label is said instead ("Checking the
/// weather"). As soon as the answer's first sentence exists, a playing acknowledgement is
/// cancelled and the answer plays.
///
/// The planner is a plain value that is told the time, so it is easy to test.
public struct LiveReplyPlanner: Sendable {
    /// Timing and limits, in seconds.
    public struct Configuration: Sendable, Equatable {
        /// How long the brain may be silent before Momo acknowledges the turn.
        public var acknowledgementDelay: TimeInterval
        /// How much longer to wait for a contextual acknowledgement before a canned one.
        public var acknowledgementGrace: TimeInterval
        /// The most tool labels said for one reply.
        public var maximumToolLabels: Int

        public init(
            acknowledgementDelay: TimeInterval = 0.8, acknowledgementGrace: TimeInterval = 0.4,
            maximumToolLabels: Int = 2
        ) {
            self.acknowledgementDelay = acknowledgementDelay
            self.acknowledgementGrace = acknowledgementGrace
            self.maximumToolLabels = maximumToolLabels
        }
    }

    /// Something to say or stop saying.
    public enum Action: Sendable, Equatable {
        /// Say a short acknowledgement or tool label as its own utterance.
        case speakAcknowledgement(String)
        /// Stop the acknowledgement that is playing, because the answer is ready.
        case cancelAcknowledgement
        /// Add a sentence to the answer.
        case speakAnswer(String)
    }

    public var configuration: Configuration
    /// Whether the answer has started.
    public private(set) var hasAnswer = false
    /// Whether an acknowledgement or tool label is playing.
    public private(set) var isAcknowledging = false

    private let cannedPhrases: [String]
    private var cannedIndex: Int
    private var startedAt: TimeInterval?
    private var contextual: String?
    private var contextualIsSettled = false
    private var hasAcknowledged = false
    private var toolLabels: [String] = []
    private var isFinished = false

    /// - Parameters:
    ///   - cannedPhrases: Short phrases in the user's language, used in turn.
    ///   - firstPhrase: Which canned phrase comes first, so replies don't all start alike.
    public init(
        configuration: Configuration = Configuration(), cannedPhrases: [String],
        firstPhrase: Int = 0
    ) {
        self.configuration = configuration
        self.cannedPhrases = cannedPhrases
        cannedIndex = cannedPhrases.isEmpty ? 0 : abs(firstPhrase) % cannedPhrases.count
    }

    /// Starts planning a reply to a turn sent at `time`.
    public mutating func begin(at time: TimeInterval) {
        startedAt = time
        contextual = nil
        contextualIsSettled = false
        hasAcknowledged = false
        hasAnswer = false
        isAcknowledging = false
        toolLabels = []
        isFinished = false
    }

    /// The fast brain's acknowledgement arrived, or `nil` when it has none.
    public mutating func contextualAcknowledgementArrived(_ text: String?) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        contextual = trimmed.isEmpty ? nil : trimmed
        contextualIsSettled = true
    }

    /// Checks the time; may say an acknowledgement.
    public mutating func tick(at time: TimeInterval) -> [Action] {
        guard let startedAt, !hasAnswer, !hasAcknowledged, !isFinished else { return [] }
        let elapsed = time - startedAt
        guard elapsed >= configuration.acknowledgementDelay else { return [] }
        if let contextual {
            return acknowledge(contextual)
        }
        let waitedEnough =
            contextualIsSettled
            || elapsed >= configuration.acknowledgementDelay + configuration.acknowledgementGrace
        guard waitedEnough, !cannedPhrases.isEmpty else { return [] }
        let phrase = cannedPhrases[cannedIndex % cannedPhrases.count]
        cannedIndex += 1
        return acknowledge(phrase)
    }

    /// A sentence of the answer is ready.
    public mutating func answer(_ sentence: String) -> [Action] {
        var actions: [Action] = []
        if isAcknowledging {
            actions.append(.cancelAcknowledgement)
            isAcknowledging = false
        }
        hasAnswer = true
        actions.append(.speakAnswer(sentence))
        return actions
    }

    /// A tool started; its label is said when nothing else is being said.
    public mutating func toolStarted(label: String) -> [Action] {
        let label = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty, !hasAnswer, !isAcknowledging, !isFinished,
            toolLabels.count < configuration.maximumToolLabels, !toolLabels.contains(label)
        else { return [] }
        toolLabels.append(label)
        return acknowledge(label)
    }

    /// The acknowledgement finished playing.
    public mutating func acknowledgementFinished() {
        isAcknowledging = false
    }

    /// The reply ended; nothing more is said on its behalf.
    public mutating func finish() {
        isFinished = true
    }

    private mutating func acknowledge(_ text: String) -> [Action] {
        hasAcknowledged = true
        isAcknowledging = true
        return [.speakAcknowledgement(text)]
    }
}

/// Tells the time and runs actions later, so live conversation logic can be tested with a
/// clock the test moves forward.
@MainActor
public protocol LiveClock: AnyObject {
    /// Seconds on a monotonic clock.
    var now: TimeInterval { get }
    /// Runs `action` after `delay` seconds, unless the returned timer is cancelled.
    func schedule(
        after delay: TimeInterval, _ action: @escaping @MainActor () -> Void
    )
        -> LiveTimer
}

/// A scheduled action that can be cancelled.
@MainActor
public final class LiveTimer {
    private var cancelAction: (() -> Void)?

    public init(cancel: @escaping () -> Void) {
        cancelAction = cancel
    }

    public func cancel() {
        cancelAction?()
        cancelAction = nil
    }
}

/// The real clock.
@MainActor
public final class SystemLiveClock: LiveClock {
    public init() {}

    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    public func schedule(
        after delay: TimeInterval, _ action: @escaping @MainActor () -> Void
    )
        -> LiveTimer
    {
        let task = Task { @MainActor in
            try? await Task.sleep(for: .seconds(max(0, delay)))
            guard !Task.isCancelled else { return }
            action()
        }
        return LiveTimer { task.cancel() }
    }
}
