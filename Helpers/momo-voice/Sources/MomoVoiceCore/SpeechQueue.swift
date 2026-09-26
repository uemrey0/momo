/// A piece of an utterance to synthesise.
public struct SpeechPiece: Sendable, Equatable {
    /// The utterance the piece belongs to.
    public var utteranceID: String
    /// The text to say, or `nil` for a marker that only ends the utterance.
    public var text: String?
    /// Whether this is the utterance's last piece.
    public var isLast: Bool

    public init(utteranceID: String, text: String?, isLast: Bool) {
        self.utteranceID = utteranceID
        self.text = text
        self.isLast = isLast
    }
}

/// Turns `speak` commands into pieces to synthesise, in order.
///
/// Each utterance has its own ``SentenceChunker``, so chunks of two utterances never mix.
/// A piece is marked last only once the utterance's final chunk arrived, which is when the
/// helper can report `speakingFinished` after it plays.
public struct SpeechQueue: Sendable {
    private var chunkers: [String: SentenceChunker] = [:]
    /// Utterances that were cancelled; late chunks of them are dropped.
    private var cancelled: Set<String> = []
    private let makeChunker: @Sendable () -> SentenceChunker

    public init(makeChunker: @escaping @Sendable () -> SentenceChunker = { SentenceChunker() }) {
        self.makeChunker = makeChunker
    }

    /// Whether utterance `id` is still waiting for text.
    public func isOpen(_ id: String) -> Bool { chunkers[id] != nil }

    /// Adds a chunk of utterance `id` and returns the pieces ready to synthesise.
    public mutating func speak(id: String, text: String, isFinal: Bool) -> [SpeechPiece] {
        guard !cancelled.contains(id) else { return [] }
        var chunker = chunkers[id] ?? makeChunker()
        var texts = chunker.append(text)
        if isFinal {
            texts += chunker.finish()
            chunkers[id] = nil
        } else {
            chunkers[id] = chunker
        }
        var pieces = texts.map { SpeechPiece(utteranceID: id, text: $0, isLast: false) }
        if isFinal {
            if pieces.isEmpty {
                pieces.append(SpeechPiece(utteranceID: id, text: nil, isLast: true))
            } else {
                pieces[pieces.count - 1].isLast = true
            }
        }
        return pieces
    }

    /// Drops every utterance, for `cancelSpeech` or barge-in. Text that still arrives for
    /// these utterances, or for the ones in `alsoCancelled` (such as the one playing), is
    /// ignored.
    public mutating func cancelAll(alsoCancelled: some Sequence<String> = []) {
        cancelled.formUnion(chunkers.keys)
        cancelled.formUnion(alsoCancelled)
        chunkers.removeAll()
    }
}
