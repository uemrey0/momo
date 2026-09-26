import Foundation

/// Cuts a reply that is still streaming into sentences that can be spoken one by one, so Momo
/// starts talking as soon as the first sentence exists.
///
/// Feed text with ``append(_:)`` as it arrives; it returns every sentence the new text
/// completes, already cleaned for speech (no Markdown, emoji, URLs or code). Call
/// ``flush()`` when the reply ends or pauses for a tool, to get what is left.
///
/// A full stop only ends a sentence when what follows shows it: whitespace and then something
/// that does not continue the sentence. Abbreviations ("Dr.", "e.g.", "örn."), initials,
/// decimals ("3.5"), times ("10.30"), list numbers ("1. ") and Turkish ordinals ("5. gün")
/// keep the sentence going. Line breaks always end one, so list items are spoken one at a
/// time. A sentence that runs very long is cut at a comma so speech never waits too long.
public struct SpeechSentenceSplitter: Sendable {
    /// Past this many characters without an ending, the text is cut at a pause (a comma, a
    /// semicolon or a dash), or at a space.
    public var maximumLength: Int

    private var buffer = ""
    private var isInCodeBlock = false

    public init(maximumLength: Int = 220) {
        self.maximumLength = maximumLength
    }

    /// Adds streamed text and returns the sentences it completes, ready to speak.
    public mutating func append(_ chunk: String) -> [String] {
        buffer += chunk
        return drain(flushing: false)
    }

    /// Returns whatever is left as a last sentence, for the end of a reply or a tool call.
    public mutating func flush() -> [String] {
        let sentences = drain(flushing: true)
        buffer = ""
        return sentences
    }

    /// Flushes when the text so far ends like a finished sentence, for callers that send
    /// whole sentences and should not wait for the next one to start.
    public mutating func flushIfComplete() -> [String] {
        guard !isInCodeBlock,
            let last = buffer.trimmingCharacters(in: .whitespacesAndNewlines).last,
            Self.terminators.contains(last)
        else { return [] }
        return flush()
    }

    /// Forgets everything, for a new reply.
    public mutating func reset() {
        buffer = ""
        isInCodeBlock = false
    }

    // MARK: - Cutting

    private mutating func drain(flushing: Bool) -> [String] {
        var sentences: [String] = []
        while true {
            if isInCodeBlock {
                guard let close = buffer.range(of: "```") else {
                    // Code is never read aloud; keep only what could start the closing fence.
                    buffer = String(buffer.suffix(2))
                    if flushing { buffer = "" }
                    return sentences
                }
                buffer = String(buffer[close.upperBound...])
                isInCodeBlock = false
                continue
            }
            let characters = Array(buffer)
            guard let cut = boundary(in: characters, flushing: flushing) else {
                if flushing {
                    append(String(characters), to: &sentences)
                    buffer = ""
                }
                return sentences
            }
            append(String(characters[..<cut.end]), to: &sentences)
            buffer = String(characters[cut.resume...])
            if cut.opensCodeBlock { isInCodeBlock = true }
        }
    }

    private func append(_ raw: String, to sentences: inout [String]) {
        let text = Self.speakable(raw)
        if !text.isEmpty { sentences.append(text) }
    }

    private struct Cut {
        /// Where the sentence ends (exclusive).
        var end: Int
        /// Where the rest of the text starts.
        var resume: Int
        var opensCodeBlock = false
    }

    private func boundary(in text: [Character], flushing: Bool) -> Cut? {
        var index = 0
        while index < text.count {
            let character = text[index]
            if character == "`" {
                // A code fence ends the sentence before it; wait until it can be recognised.
                if index + 2 < text.count, text[index + 1] == "`", text[index + 2] == "`" {
                    return Cut(end: index, resume: index + 3, opensCodeBlock: true)
                }
                if index + 2 >= text.count, !flushing, text[index...].allSatisfy({ $0 == "`" }) {
                    return nil
                }
            }
            if character.isNewline {
                return Cut(end: index, resume: index + 1)
            }
            if Self.terminators.contains(character),
                let resume = sentenceEnd(at: index, in: text, flushing: flushing)
            {
                return Cut(end: resume, resume: resume)
            }
            if case .waiting = endState(at: index, in: text, flushing: flushing) {
                return nil
            }
            index += 1
        }
        if text.count > maximumLength {
            return longCut(in: text)
        }
        return nil
    }

    private enum EndState {
        case notAnEnd
        case waiting
    }

    /// Whether a terminator at `index` could still end a sentence once more text arrives.
    private func endState(at index: Int, in text: [Character], flushing: Bool) -> EndState {
        guard Self.terminators.contains(text[index]), !flushing else { return .notAnEnd }
        var next = index + 1
        while next < text.count,
            Self.closers.contains(text[next]) || Self.terminators.contains(text[next])
        {
            next += 1
        }
        while next < text.count, text[next].isWhitespace, !text[next].isNewline { next += 1 }
        return next >= text.count ? .waiting : .notAnEnd
    }

    /// If the terminator at `index` ends a sentence, the index just after it (and any
    /// closing quotes or brackets).
    private func sentenceEnd(at index: Int, in text: [Character], flushing: Bool) -> Int? {
        var end = index + 1
        while end < text.count,
            Self.closers.contains(text[end]) || Self.terminators.contains(text[end])
        {
            end += 1
        }
        guard end < text.count else { return flushing ? end : nil }
        guard text[end].isWhitespace else { return nil }
        if text[end].isNewline { return end }
        var next = end
        while next < text.count, text[next].isWhitespace, !text[next].isNewline { next += 1 }
        guard next < text.count else { return flushing ? end : nil }
        if text[next].isNewline { return end }
        guard text[index] == "." else { return end }
        return fullStopEnds(at: index, followedBy: text[next], in: text) ? end : nil
    }

    /// Decides whether a full stop ends a sentence, from the word before it and the character
    /// after the space.
    private func fullStopEnds(
        at index: Int, followedBy next: Character, in text: [Character]
    )
        -> Bool
    {
        // "5. gün", "Dr. med", "vs. others": a lower-case continuation keeps the sentence.
        if next.isLowercase { return false }
        var start = index
        while start > 0,
            text[start - 1].isLetter || text[start - 1].isNumber || text[start - 1] == "."
        {
            start -= 1
        }
        let word = String(text[start..<index])
        let folded = word.lowercased()
        if Self.titles.contains(folded) { return false }
        if word.count == 1, let letter = word.first, letter.isUppercase { return false }
        if folded.contains("."), folded.allSatisfy({ $0.isLetter || $0 == "." }) {
            // Dotted abbreviations such as "e.g" and "T.C".
            return false
        }
        if !word.isEmpty, word.allSatisfy(\.isNumber) {
            // A list number at the start of a line: "1. Buy milk".
            let before = text[..<start].reversed().prefix { !$0.isNewline }
            if before.allSatisfy({ $0.isWhitespace || $0 == "*" || $0 == "-" }) { return false }
        }
        return true
    }

    /// Cuts an overlong sentence at its last pause, or failing that its last space.
    private func longCut(in text: [Character]) -> Cut? {
        let limit = min(text.count, maximumLength)
        let minimum = min(40, limit / 2)
        for index in stride(from: limit - 1, through: minimum, by: -1)
        where Self.pauses.contains(text[index]) && index + 1 < text.count
            && text[index + 1].isWhitespace
        {
            return Cut(end: index + 1, resume: index + 1)
        }
        for index in stride(from: limit - 1, through: minimum, by: -1) where text[index] == " " {
            return Cut(end: index, resume: index + 1)
        }
        return nil
    }

    private static let terminators: Set<Character> = [".", "!", "?", "…", "。", "！", "？"]
    private static let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "»", "*", "_"]
    private static let pauses: Set<Character> = [",", ";", "—", "–", ":"]
    /// Abbreviations that never end a sentence, lower case, in English and Turkish.
    private static let titles: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "st", "sr", "jr", "no", "nr", "vs", "approx", "dept",
        "fig", "vol", "mt", "sn", "doç", "doc", "yrd", "av", "op", "bkz", "örn", "ör", "cad",
        "sok", "mah", "apt", "tel", "yy", "hz", "müh", "uzm",
    ]

    // MARK: - Cleaning

    /// `raw` as it should be spoken: without Markdown, code, links, emoji and table
    /// syntax. Empty when nothing speakable is left.
    public static func speakable(_ raw: String) -> String {
        var text = raw
        // Table separator rows and pipes.
        if text.range(of: #"^\s*\|?\s*:?-{2,}"#, options: .regularExpression) != nil { return "" }
        text = text.replacingOccurrences(
            of: #"^\s*(\d+[.)]|[-*+•])\s+"#, with: "", options: .regularExpression)
        text = SpeechText.plain(fromMarkdown: text)
        text = text.replacingOccurrences(
            of: #"\s*\|\s*"#, with: ", ", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"(\*\*|__|`|\*)"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"www\.\S+"#, with: "", options: .regularExpression)
        text = removingEmoji(from: text)
        text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        text = text.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: ",;:")))
        guard text.contains(where: { $0.isLetter || $0.isNumber }) else { return "" }
        return text
    }

    /// `text` without emoji (and their joiners, variation selectors and skin tones), keeping
    /// digits, "#" and "*", which are technically emoji too.
    public static func removingEmoji(from text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let properties = scalar.properties
            let isEmoji =
                properties.isEmojiPresentation || properties.isEmojiModifier
                || scalar.value == 0x200D || scalar.value == 0xFE0F || scalar.value == 0x20E3
                || (properties.isEmoji && scalar.value >= 0x2100)
                || (0x1F1E6...0x1F1FF).contains(scalar.value)
            if !isEmoji { scalars.append(scalar) }
        }
        return String(scalars)
    }
}
