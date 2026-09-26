import Foundation

/// Builds a Spotlight query string for `mdfind` from what a model asked for.
public struct SpotlightQuery: Sendable, Equatable {
    /// Words the file name should contain.
    public var name: String?
    /// Words the file's text should contain.
    public var content: String?
    /// A kind from ``kinds``, such as `pdf` or `image`.
    public var kind: String?
    /// Only files changed within this many days.
    public var modifiedWithinDays: Int?

    public init(
        name: String? = nil, content: String? = nil, kind: String? = nil,
        modifiedWithinDays: Int? = nil
    ) {
        self.name = name
        self.content = content
        self.kind = kind
        self.modifiedWithinDays = modifiedWithinDays
    }

    /// The kinds a model may ask for, mapped to Uniform Type Identifiers.
    public static let kinds: [String: String] = [
        "pdf": "com.adobe.pdf",
        "image": "public.image",
        "video": "public.movie",
        "audio": "public.audio",
        "text": "public.text",
        "code": "public.source-code",
        "document": "public.content",
        "spreadsheet": "public.spreadsheet",
        "presentation": "public.presentation",
        "folder": "public.folder",
        "app": "com.apple.application-bundle",
        "archive": "public.archive",
    ]

    /// The query for `mdfind`, or `nil` when nothing was asked for or the kind is unknown.
    public var queryString: String? {
        var clauses: [String] = []
        if let name = Self.cleaned(name) {
            for word in name.split(separator: " ") {
                clauses.append("kMDItemFSName == \"*\(Self.escape(String(word)))*\"cd")
            }
        }
        if let content = Self.cleaned(content) {
            for word in content.split(separator: " ") {
                clauses.append("kMDItemTextContent == \"\(Self.escape(String(word)))*\"cdw")
            }
        }
        if let kind = Self.cleaned(kind)?.lowercased() {
            guard let type = Self.kinds[kind] else { return nil }
            clauses.append("kMDItemContentTypeTree == \"\(type)\"")
        }
        if let days = modifiedWithinDays, days > 0 {
            clauses.append("kMDItemFSContentChangeDate >= $time.today(-\(days))")
        }
        return clauses.isEmpty ? nil : clauses.joined(separator: " && ")
    }

    /// Escapes a value for use inside a quoted Spotlight query string, so `*`, quotes and
    /// backslashes are matched literally.
    public static func escape(_ value: String) -> String {
        var result = ""
        for character in value {
            switch character {
            case "\\", "\"", "*", "'": result += "\\\(character)"
            case "\n", "\r", "\t": result += " "
            default: result.append(character)
            }
        }
        return result
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
