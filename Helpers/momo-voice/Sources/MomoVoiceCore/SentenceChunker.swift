import Foundation

/// Splits streamed reply text into pieces a speech synthesizer can say one at a time.
///
/// Text arrives in arbitrary chunks. A piece is released as soon as it ends a sentence, so
/// the first sentence can play while the rest of the reply is still being written. A
/// sentence that runs past ``maximumLength`` is cut at a clause break or a space, because
/// synthesizers have a fixed input window, and the first piece of an utterance may be cut
/// at a clause break already after ``firstPieceLength`` characters to start speaking sooner.
public struct SentenceChunker: Sendable {
    /// The longest piece, in characters.
    public var maximumLength: Int
    /// The length after which the first piece may end at a clause break.
    public var firstPieceLength: Int

    private var buffer = ""
    private var hasReleasedPiece = false

    private static let sentenceEnds: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    private static let clauseBreaks: Set<Character> = [",", ";", ":", "—", "–", "、", "，"]
    /// Marks that may follow a sentence end, including Markdown emphasis.
    private static let closingMarks: Set<Character> = [
        "\"", "'", "”", "’", ")", "]", "»", "*", "_", "`",
    ]

    public init(maximumLength: Int = 180, firstPieceLength: Int = 60) {
        self.maximumLength = max(20, maximumLength)
        self.firstPieceLength = firstPieceLength
    }

    /// Adds text and returns the pieces it completes.
    public mutating func append(_ text: String) -> [String] {
        buffer += text
        return drain(isFinal: false)
    }

    /// Returns what is left, for the last chunk of an utterance.
    public mutating func finish() -> [String] {
        let pieces = drain(isFinal: true)
        buffer = ""
        hasReleasedPiece = false
        return pieces
    }

    private mutating func drain(isFinal: Bool) -> [String] {
        var pieces: [String] = []
        while let end = nextBreak(isFinal: isFinal) {
            let piece = String(buffer[..<end])
            buffer = String(buffer[end...])
            append(piece, to: &pieces)
        }
        if isFinal {
            append(buffer, to: &pieces)
            buffer = ""
        }
        return pieces
    }

    private mutating func append(_ piece: String, to pieces: inout [String]) {
        let cleaned = SpeechText.clean(piece)
        guard SpeechText.isSpeakable(cleaned) else { return }
        pieces.append(cleaned)
        hasReleasedPiece = true
    }

    /// Where the next piece ends, or `nil` when more text is needed to know.
    private func nextBreak(isFinal: Bool) -> String.Index? {
        var index = buffer.startIndex
        var length = 0
        var lastClause: String.Index?
        var lastSpace: String.Index?
        while index < buffer.endIndex {
            let character = buffer[index]
            let next = buffer.index(after: index)
            length += 1
            if character == "\n" {
                return next
            }
            if Self.sentenceEnds.contains(character) {
                var end = next
                while end < buffer.endIndex,
                    Self.sentenceEnds.contains(buffer[end])
                        || Self.closingMarks.contains(buffer[end])
                {
                    end = buffer.index(after: end)
                }
                switch isSentenceBoundary(at: end, isFinal: isFinal) {
                case .yes: return end
                case .undecided: return nil
                case .no: break
                }
            }
            if Self.clauseBreaks.contains(character) {
                lastClause = next
                if !hasReleasedPiece, length >= firstPieceLength,
                    next < buffer.endIndex, buffer[next].isWhitespace
                {
                    return next
                }
            } else if character.isWhitespace {
                lastSpace = index
            }
            if length >= maximumLength {
                return lastClause ?? lastSpace ?? next
            }
            index = next
        }
        return nil
    }

    private enum Boundary { case yes, no, undecided }

    /// A sentence mark ends a sentence when whitespace follows and the next word does not
    /// start in lower case, which keeps "3.5", "e.g. this" and Turkish ordinals ("5. sınıf")
    /// together.
    private func isSentenceBoundary(at end: String.Index, isFinal: Bool) -> Boundary {
        guard end < buffer.endIndex else { return isFinal ? .yes : .undecided }
        guard buffer[end].isWhitespace else { return .no }
        var index = end
        while index < buffer.endIndex, buffer[index].isWhitespace {
            if buffer[index] == "\n" { return .yes }
            index = buffer.index(after: index)
        }
        guard index < buffer.endIndex else { return isFinal ? .yes : .undecided }
        return buffer[index].isLowercase ? .no : .yes
    }
}

/// Cleans reply text for speaking.
public enum SpeechText {
    /// Removes Markdown markup and collapses whitespace, so the synthesizer does not read
    /// out asterisks or hashes.
    public static func clean(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var lastWasSpace = true
        for character in text {
            if "*_`#~|<>".contains(character) { continue }
            if character.isWhitespace {
                if !lastWasSpace { result.append(" ") }
                lastWasSpace = true
            } else {
                result.append(character)
                lastWasSpace = false
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Whether the text has anything to say: at least one letter or digit.
    public static func isSpeakable(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }
}
