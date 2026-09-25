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

/// A voice, described without AVFoundation types so the choice can be tested.
public struct VoiceDescriptor: Sendable, Hashable, Identifiable {
    public enum Quality: Int, Sendable, Comparable {
        case standard = 1
        case enhanced = 2
        case premium = 3

        public static func < (lhs: Quality, rhs: Quality) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var id: String
    public var name: String
    /// BCP 47 language tag, e.g. "tr-TR".
    public var language: String
    public var quality: Quality

    public init(id: String, name: String, language: String, quality: Quality) {
        self.id = id
        self.name = name
        self.language = language
        self.quality = quality
    }

    /// Picks the voice to use for `language`: the user's choice when it speaks that
    /// language, otherwise the best-quality voice for it, preferring the user's region.
    public static func best(
        for language: String, among voices: [VoiceDescriptor], preferredID: String? = nil,
        preferredRegion: String? = Locale.current.region?.identifier
    ) -> VoiceDescriptor? {
        let base = language.split(separator: "-").first.map(String.init)?.lowercased() ?? language
        let matching = voices.filter {
            $0.language.lowercased().hasPrefix(base + "-") || $0.language.lowercased() == base
        }
        if let preferredID, let chosen = matching.first(where: { $0.id == preferredID }) {
            return chosen
        }
        return matching.max { lhs, rhs in
            if lhs.quality != rhs.quality { return lhs.quality < rhs.quality }
            let lhsRegion = lhs.language.hasSuffix("-\(preferredRegion ?? "")")
            let rhsRegion = rhs.language.hasSuffix("-\(preferredRegion ?? "")")
            if lhsRegion != rhsRegion { return !lhsRegion }
            return lhs.name > rhs.name
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
