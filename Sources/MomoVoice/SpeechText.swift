import Foundation
import NaturalLanguage

/// Prepares assistant replies for speech.
public enum SpeechText {
    /// Removes Markdown so it is not read aloud ("asterisk asterisk…").
    public static func plain(fromMarkdown text: String) -> String {
        var result = text
        let replacements: [(String, String)] = [
            (#"```[\s\S]*?```"#, " "),  // code blocks are not worth reading
            (#"`([^`]*)`"#, "$1"),
            (#"!\[[^\]]*\]\([^)]*\)"#, ""),  // images
            (#"\[([^\]]+)\]\([^)]*\)"#, "$1"),  // links keep their text
            (#"(\*\*|__)(.+?)\1"#, "$2"),
            (#"(?<![\w*])[*_]([^*_\n]+)[*_](?![\w*])"#, "$1"),
            (#"(?m)^\s{0,3}#{1,6}\s*"#, ""),
            (#"(?m)^\s*[-*+]\s+"#, ""),
            (#"(?m)^\s*>\s?"#, ""),
            (#"~~(.+?)~~"#, "$1"),
            (#"https?://\S+"#, ""),
        ]
        for (pattern, template) in replacements {
            result = result.replacingOccurrences(
                of: pattern, with: template, options: .regularExpression)
        }
        return result.replacingOccurrences(
            of: #"[ \t]{2,}"#, with: " ", options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The dominant language of `text` as a BCP 47 code ("tr", "en"), if it can tell.
    public static func language(of text: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage?.rawValue
    }
}

/// A short spoken answer to a yes-or-no question.
public enum SpokenAnswer: Sendable, Equatable {
    case yes
    case no
}

extension SpeechText {
    /// Words that mean yes, in English and Turkish, folded (lower case, no diacritics).
    static let yesWords: Set<String> = [
        "yes", "yeah", "yep", "yup", "sure", "okay", "ok", "alright", "evet", "tamam", "olur",
        "tabii", "tabi", "peki",
    ]
    /// Words that mean no, including negations, folded.
    static let noWords: Set<String> = [
        "no", "nope", "nah", "cancel", "stop", "not", "dont", "hayir", "iptal", "vazgec", "yok",
        "dur", "istemiyorum",
    ]
    static let yesPhrases = ["go ahead", "do it", "all right"]

    /// Reads a short spoken reply ("yes", "sure", "evet", "no", "cancel", "vazgeç") as yes or
    /// no. Returns `nil` when the reply is unclear or says both ("not sure").
    public static func answer(in transcript: String) -> SpokenAnswer? {
        let folded = transcript.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en")
        )
        .replacingOccurrences(of: "ı", with: "i")  // Turkish dotless i has no diacritic to fold
        .replacingOccurrences(of: "\u{2019}", with: "")
        .replacingOccurrences(of: "'", with: "")
        let words = Set(
            folded.components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty })
        let saysYes =
            !words.isDisjoint(with: yesWords) || yesPhrases.contains { folded.contains($0) }
        let saysNo = !words.isDisjoint(with: noWords)
        switch (saysYes, saysNo) {
        case (true, false): return .yes
        case (false, true): return .no
        default: return nil
        }
    }
}

/// Recognises the wake phrase in a running transcript.
public struct WakeWordDetector: Sendable {
    /// Words that count as the name, including common mishearings.
    public var names: [String]

    public init(names: [String] = ["momo", "mo mo", "momoo", "momu", "mömö"]) {
        self.names = names
    }

    /// Whether the transcript mentions Momo as a word, like "hey Momo" or "Momo,".
    public func matches(_ transcript: String) -> Bool {
        let folded = transcript.folding(options: [.caseInsensitive], locale: nil)
        return names.contains { name in
            folded.range(
                of: #"(^|[^\p{L}])"# + NSRegularExpression.escapedPattern(for: name)
                    + #"($|[^\p{L}])"#, options: .regularExpression) != nil
        }
    }

    /// The part of the transcript after the wake phrase, e.g. "Hey Momo, what time is it" →
    /// "what time is it". Empty when nothing follows.
    public func command(in transcript: String) -> String {
        let folded = transcript.folding(options: [.caseInsensitive], locale: nil)
        for name in names {
            if let range = folded.range(
                of: NSRegularExpression.escapedPattern(for: name), options: .regularExpression)
            {
                let offset = folded.distance(from: folded.startIndex, to: range.upperBound)
                let rest = transcript.dropFirst(offset)
                return rest.trimmingCharacters(
                    in: .whitespacesAndNewlines.union(.punctuationCharacters))
            }
        }
        return ""
    }
}
