import Foundation
import NaturalLanguage

/// Text with personal data replaced by placeholders such as `[EMAIL_1]`.
public struct MaskedText: Sendable, Equatable {
    public var text: String
    /// Placeholder → original value.
    public var replacements: [String: String]

    public var isMasked: Bool { !replacements.isEmpty }

    public init(text: String, replacements: [String: String] = [:]) {
        self.text = text
        self.replacements = replacements
    }

    /// Restores the original values in `text` (typically a reply from a remote model).
    public func unmask(_ text: String) -> String {
        guard !replacements.isEmpty else { return text }
        var result = text
        // Longest placeholders first so [NAME_10] is not clobbered by [NAME_1].
        for (placeholder, original) in replacements.sorted(by: { $0.key.count > $1.key.count }) {
            result = result.replacingOccurrences(of: placeholder, with: original)
        }
        return result
    }
}

/// The kinds of personal data the masker recognises.
public enum PersonalDataKind: String, CaseIterable, Sendable {
    case email = "EMAIL"
    case phone = "PHONE"
    case iban = "IBAN"
    case card = "CARD"
    case nationalID = "ID"
    case name = "NAME"
}

/// Replaces personal data with placeholders before text leaves the Mac.
///
/// Recognises email addresses, phone numbers, IBANs (with checksum), payment card numbers
/// (Luhn), Turkish national ID numbers (with checksum) and, optionally, people's names.
public struct PrivacyMasker: Sendable {
    public var masksNames: Bool

    public init(masksNames: Bool = true) {
        self.masksNames = masksNames
    }

    /// Masks `text`, reusing the placeholders already in `existing` so a conversation keeps
    /// consistent placeholders across messages.
    public func mask(_ text: String, continuing existing: [String: String] = [:]) -> MaskedText {
        var replacements = existing
        var originals = Dictionary(
            existing.map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var counters: [String: Int] = [:]
        for placeholder in existing.keys {
            let parts = placeholder.dropFirst().dropLast().split(separator: "_")
            if parts.count == 2, let number = Int(parts[1]) {
                counters[String(parts[0]), default: 0] = max(
                    counters[String(parts[0]), default: 0], number)
            }
        }

        var matches: [(range: Range<String.Index>, kind: PersonalDataKind)] = []
        for (kind, pattern, validate) in Self.patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let nsRange = NSRange(text.startIndex..., in: text)
            for match in regex.matches(in: text, range: nsRange) {
                guard let range = Range(match.range, in: text) else { continue }
                let value = String(text[range])
                guard validate(value) else { continue }
                if !matches.contains(where: { $0.range.overlaps(range) }) {
                    matches.append((range, kind))
                }
            }
        }
        if masksNames {
            for range in Self.personalNames(in: text)
            where !matches.contains(where: { $0.range.overlaps(range) }) {
                matches.append((range, .name))
            }
        }

        var result = text
        for match in matches.sorted(by: { $0.range.lowerBound > $1.range.lowerBound }) {
            let original = String(text[match.range])
            let placeholder: String
            if let known = originals[original] {
                placeholder = known
            } else {
                let next = counters[match.kind.rawValue, default: 0] + 1
                counters[match.kind.rawValue] = next
                placeholder = "[\(match.kind.rawValue)_\(next)]"
                replacements[placeholder] = original
                originals[original] = placeholder
            }
            result.replaceSubrange(match.range, with: placeholder)
        }
        return MaskedText(text: result, replacements: replacements)
    }

    // MARK: - Patterns

    private static let patterns: [(PersonalDataKind, String, @Sendable (String) -> Bool)] = [
        (.email, #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, { _ in true }),
        (.iban, #"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]){11,30}\b"#, isValidIBAN),
        (.card, #"\b(?:\d[ -]?){12,18}\d\b"#, isValidCardNumber),
        (.nationalID, #"\b[1-9]\d{10}\b"#, isValidTurkishID),
        (.phone, #"(?<![\w])\+?\(?\d[\d ()./-]{7,18}\d\b"#, isPlausiblePhone),
    ]

    static func isValidIBAN(_ value: String) -> Bool {
        let compact = value.replacingOccurrences(of: " ", with: "").uppercased()
        guard compact.count >= 15, compact.count <= 34 else { return false }
        let rearranged = compact.dropFirst(4) + compact.prefix(4)
        var remainder = 0
        for character in rearranged {
            let digits: String
            if let digit = character.wholeNumberValue {
                digits = String(digit)
            } else if let ascii = character.asciiValue, character.isLetter {
                digits = String(Int(ascii) - 55)
            } else {
                return false
            }
            for digit in digits {
                remainder = (remainder * 10 + (digit.wholeNumberValue ?? 0)) % 97
            }
        }
        return remainder == 1
    }

    static func isValidCardNumber(_ value: String) -> Bool {
        let digits = value.compactMap(\.wholeNumberValue)
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (offset, digit) in digits.reversed().enumerated() {
            if offset % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }

    static func isValidTurkishID(_ value: String) -> Bool {
        let digits = value.compactMap(\.wholeNumberValue)
        guard digits.count == 11, digits[0] != 0 else { return false }
        let odd = digits[0] + digits[2] + digits[4] + digits[6] + digits[8]
        let even = digits[1] + digits[3] + digits[5] + digits[7]
        let tenth = ((odd * 7 - even) % 10 + 10) % 10
        guard tenth == digits[9] else { return false }
        return digits[0..<10].reduce(0, +) % 10 == digits[10]
    }

    static func isPlausiblePhone(_ value: String) -> Bool {
        let digits = value.filter(\.isNumber)
        guard (10...15).contains(digits.count) else { return false }
        // A bare run of digits is only a phone number when written with a trunk or
        // international prefix; otherwise it is more likely a quantity or an ID.
        if value.allSatisfy(\.isNumber), !value.hasPrefix("0") {
            return false
        }
        // Skip things that look like dates or times ("2026-09-27", "10.10.2026").
        if value.range(of: #"^\d{4}[-./]\d{1,2}[-./]\d{1,2}"#, options: .regularExpression) != nil {
            return false
        }
        if value.range(of: #"^\d{1,2}[-./]\d{1,2}[-./]\d{2,4}$"#, options: .regularExpression)
            != nil
        {
            return false
        }
        return true
    }

    static func personalNames(in text: String) -> [Range<String.Index>] {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var ranges: [Range<String.Index>] = []
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
            options: [.omitPunctuation, .omitWhitespace, .joinNames]
        ) { tag, range in
            if tag == .personalName { ranges.append(range) }
            return true
        }
        return ranges
    }
}

/// Restores placeholders in streamed text, holding back a possible placeholder that is split
/// across chunks.
public struct StreamingUnmasker: Sendable {
    private let masked: MaskedText
    private var pending = ""

    public init(_ masked: MaskedText) {
        self.masked = masked
    }

    /// Feeds a chunk and returns text that is safe to show.
    public mutating func consume(_ chunk: String) -> String {
        guard masked.isMasked else { return chunk }
        pending += chunk
        if let open = pending.lastIndex(of: "["), !pending[open...].contains("]"),
            pending.distance(from: open, to: pending.endIndex) < 16
        {
            let ready = String(pending[..<open])
            pending = String(pending[open...])
            return masked.unmask(ready)
        }
        let ready = pending
        pending = ""
        return masked.unmask(ready)
    }

    /// Returns whatever is still held back.
    public mutating func finish() -> String {
        let rest = masked.unmask(pending)
        pending = ""
        return rest
    }
}
