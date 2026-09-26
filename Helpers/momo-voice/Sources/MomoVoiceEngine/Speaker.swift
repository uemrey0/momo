import Foundation
import MomoLiveProtocol
import MomoVoiceCore

/// Speaks Momo's replies: queues `speak` chunks, synthesises them sentence by sentence on its
/// own queue and plays them through ``AudioIO``.
///
/// The first sentence starts playing as soon as it is synthesised while later ones are
/// rendered behind it. `speakingStarted` is reported when an utterance's first audio starts,
/// `speakingFinished` when its last piece has played, and `mouth` levels follow the output.
final class Speaker: @unchecked Sendable {
    /// Playback state changes, for barge-in.
    struct Observer: Sendable {
        var started: @Sendable (String) -> Void
        var stopped: @Sendable () -> Void
    }

    private let audio: AudioIO
    private let synthesizer: any SpeechSynthesizing
    private let emit: @Sendable (LiveVoiceEvent) -> Void
    private let observer: Observer
    private let synthesisQueue = DispatchQueue(label: "momo-voice.synthesis", qos: .userInitiated)

    private let lock = NSLock()
    private var queue: SpeechQueue
    private var generation = 0
    /// Utterances that started playing and have not finished.
    private var started: Set<String> = []
    /// Scheduled pieces not yet played, per utterance.
    private var pendingPieces: [String: Int] = [:]
    /// Utterances whose last piece was scheduled.
    private var ended: Set<String> = []
    /// The utterance heard now, for interruptions.
    private var current: String?

    init(
        audio: AudioIO, synthesizer: any SpeechSynthesizing, maximumPieceLength: Int,
        emit: @escaping @Sendable (LiveVoiceEvent) -> Void, observer: Observer
    ) {
        self.audio = audio
        self.synthesizer = synthesizer
        self.emit = emit
        self.observer = observer
        queue = SpeechQueue(makeChunker: {
            SentenceChunker(maximumLength: maximumPieceLength, firstPieceLength: 60)
        })
    }

    /// Adds a chunk of utterance `id`. Returns at once.
    func speak(id: String, text: String, isFinal: Bool) {
        let (pieces, expected) = lock.withLock {
            let pieces = queue.speak(id: id, text: text, isFinal: isFinal)
            for piece in pieces { pendingPieces[piece.utteranceID, default: 0] += 1 }
            return (pieces, generation)
        }
        for piece in pieces {
            synthesisQueue.async { [self] in render(piece, generation: expected) }
        }
    }

    /// Stops speaking and drops queued text. Returns the utterance that was playing, if any.
    @discardableResult
    func cancel() -> String? {
        let interrupted: String? = lock.withLock {
            generation += 1
            let playing = current
            queue.cancelAll(alsoCancelled: started.union(pendingPieces.keys))
            started.removeAll()
            pendingPieces.removeAll()
            ended.removeAll()
            current = nil
            return playing
        }
        audio.stopPlayback()
        emit(.mouth(0))
        if interrupted != nil { observer.stopped() }
        return interrupted
    }

    private func isCurrent(_ expected: Int) -> Bool {
        lock.withLock { generation == expected }
    }

    /// Synthesises and schedules one piece. Runs on the synthesis queue.
    private func render(_ piece: SpeechPiece, generation expected: Int) {
        guard isCurrent(expected) else { return }
        var speech = SynthesizedSpeech(samples: [], sampleRate: 24_000)
        if let text = piece.text {
            let start = Date()
            do {
                speech = try synthesizer.synthesize(text)
                let seconds = Double(speech.samples.count) / speech.sampleRate
                let elapsed = Date().timeIntervalSince(start)
                Log.info(
                    String(
                        format: "Synthesised %.2f s of speech in %.0f ms (RTF %.2f): %@", seconds,
                        elapsed * 1000, elapsed / max(seconds, 0.01), text))
            } catch {
                emit(.error(message: "Could not synthesise speech: \(error)", isFatal: false))
            }
        }
        guard isCurrent(expected) else { return }
        let id = piece.utteranceID
        let isLast = piece.isLast
        if speech.samples.isEmpty {
            pieceFinished(id: id, isLast: isLast, generation: expected, startIfNeeded: true)
            return
        }
        audio.schedule(
            speech.samples, sampleRate: speech.sampleRate,
            sliceStarted: { [weak self] level in
                self?.sliceStarted(id: id, level: level, generation: expected)
            },
            finished: { [weak self] in
                self?.pieceFinished(
                    id: id, isLast: isLast, generation: expected, startIfNeeded: false)
            })
    }

    private func sliceStarted(id: String, level: Double, generation expected: Int) {
        let isFirst: Bool? = lock.withLock {
            guard generation == expected else { return nil }
            current = id
            return started.insert(id).inserted
        }
        guard let isFirst else { return }
        if isFirst {
            emit(.speakingStarted(id: id))
            observer.started(id)
        }
        emit(.mouth(level))
    }

    private func pieceFinished(
        id: String, isLast: Bool, generation expected: Int, startIfNeeded: Bool
    ) {
        enum Outcome { case none, finished(neverStarted: Bool) }
        let outcome: Outcome = lock.withLock {
            guard generation == expected else { return .none }
            pendingPieces[id, default: 1] -= 1
            if isLast { ended.insert(id) }
            guard ended.contains(id), pendingPieces[id, default: 0] <= 0 else { return .none }
            let neverStarted = !started.contains(id)
            ended.remove(id)
            started.remove(id)
            pendingPieces[id] = nil
            if current == id { current = nil }
            return .finished(neverStarted: neverStarted)
        }
        guard case .finished(let neverStarted) = outcome else { return }
        if neverStarted, startIfNeeded {
            // Nothing to say, but Momo still waits for the utterance to begin and end.
            emit(.speakingStarted(id: id))
        }
        emit(.mouth(0))
        emit(.speakingFinished(id: id))
        observer.stopped()
    }
}
