import Foundation

/// Turns HTML into readable plain text for a language model: headings, paragraphs, list items
/// and link text survive; scripts, styles, navigation and footers are dropped; entities are
/// decoded and whitespace is collapsed.
///
/// This is a forgiving scanner, not a full HTML parser: it copes with the markup found on
/// real pages without building a document tree.
public enum HTMLText {
    /// A page's title and readable text.
    public struct Document: Sendable, Equatable {
        public var title: String?
        public var text: String
    }

    /// Elements whose content is never shown as text.
    static let rawTextElements: Set<String> = ["script", "style", "textarea", "title"]
    /// Elements whose content is page chrome or not text.
    static let skippedElements: Set<String> = [
        "head", "nav", "footer", "noscript", "template", "svg", "iframe", "canvas", "button",
        "select", "dialog", "object", "video", "audio", "picture", "map",
    ]
    /// Elements that start a new line.
    static let blockElements: Set<String> = [
        "address", "article", "aside", "blockquote", "dd", "details", "div", "dl", "dt",
        "fieldset", "figcaption", "figure", "header", "hr", "li", "main", "ol", "p", "pre",
        "section", "summary", "table", "tbody", "thead", "tfoot", "tr", "ul", "caption",
        "h1", "h2", "h3", "h4", "h5", "h6", "br",
    ]
    /// Elements that separate paragraphs with a blank line.
    static let paragraphElements: Set<String> = [
        "p", "blockquote", "pre", "table", "ul", "ol", "dl", "figure", "h1", "h2", "h3", "h4",
        "h5", "h6", "article", "section", "header", "main", "aside", "details",
    ]

    /// Converts `html`. When the page has a `<main>` or `<article>` element with enough text,
    /// only that part is used, which leaves out sidebars and other chrome.
    public static func document(from html: String) -> Document {
        let title = title(in: html)
        for element in ["main", "article"] {
            if let content = content(of: element, in: html) {
                let text = convert(content)
                if text.count >= 200 { return Document(title: title, text: text) }
            }
        }
        return Document(title: title, text: convert(html))
    }

    /// Converts an HTML fragment to text.
    public static func text(from html: String) -> String {
        convert(html)
    }

    // MARK: - Conversion

    private static func convert(_ html: String) -> String {
        var output = TextBuilder()
        var skipDepth = 0
        var listDepth = 0
        var index = html.startIndex
        let end = html.endIndex

        while index < end {
            guard let open = html[index...].firstIndex(of: "<") else {
                if skipDepth == 0 { output.append(text: html[index...]) }
                break
            }
            if skipDepth == 0, open > index { output.append(text: html[index..<open]) }
            let rest = html[open...]
            if rest.hasPrefix("<!--") {
                index = rest.range(of: "-->")?.upperBound ?? end
                continue
            }
            guard let tag = Tag(parsing: rest) else {
                // A stray "<" is text.
                if skipDepth == 0 { output.append(text: "<") }
                index = html.index(after: open)
                continue
            }
            index = tag.end
            let name = tag.name

            if !tag.isClosing, rawTextElements.contains(name) {
                // Skip to the matching end tag without looking at the content.
                index = endOfRawText(name, in: html, from: index)
                continue
            }
            if name == "body" {
                // Pages may leave out </head>; the body is always content.
                skipDepth = 0
                continue
            }
            if skippedElements.contains(name) {
                if tag.isClosing {
                    skipDepth = max(0, skipDepth - 1)
                } else if !tag.isSelfClosing {
                    skipDepth += 1
                }
                continue
            }
            guard skipDepth == 0 else { continue }

            switch name {
            case "ul", "ol":
                listDepth = max(0, listDepth + (tag.isClosing ? -1 : 1))
                output.breakLine(blank: listDepth == 0)
            case "li" where !tag.isClosing:
                output.breakLine()
                output.append(
                    raw: String(repeating: "  ", count: max(0, listDepth - 1)) + "- ")
            case "h1", "h2", "h3", "h4", "h5", "h6":
                output.breakLine(blank: true)
                if !tag.isClosing, let level = Int(name.dropFirst()) {
                    output.append(raw: String(repeating: "#", count: level) + " ")
                }
            case "br":
                output.breakLine()
            case "td", "th":
                if !tag.isClosing { output.space() }
            case "img" where !tag.isClosing:
                if let alt = tag.attribute("alt"), !alt.isEmpty {
                    output.append(text: Substring(alt))
                }
            default:
                if blockElements.contains(name) {
                    output.breakLine(blank: paragraphElements.contains(name))
                }
            }
        }
        return output.result
    }

    private static func endOfRawText(
        _ name: String, in html: String, from index: String.Index
    )
        -> String.Index
    {
        guard
            let close = html.range(
                of: "</\(name)", options: [.caseInsensitive], range: index..<html.endIndex)
        else { return html.endIndex }
        return html[close.upperBound...].firstIndex(of: ">").map(html.index(after:))
            ?? html.endIndex
    }

    static func title(in html: String) -> String? {
        guard let open = html.range(of: "<title", options: .caseInsensitive),
            let start = html[open.upperBound...].firstIndex(of: ">"),
            let close = html.range(
                of: "</title", options: .caseInsensitive,
                range: html.index(after: start)..<html.endIndex)
        else { return nil }
        let title = collapse(
            decodeEntities(String(html[html.index(after: start)..<close.lowerBound])))
        return title.isEmpty ? nil : title
    }

    /// The content between the first opening and the last closing tag of `element`.
    static func content(of element: String, in html: String) -> String? {
        var searchStart = html.startIndex
        // Find "<main" followed by ">" or whitespace, not "<mainframe".
        while let open = html.range(
            of: "<\(element)", options: .caseInsensitive, range: searchStart..<html.endIndex)
        {
            let next = open.upperBound < html.endIndex ? html[open.upperBound] : ">"
            if next == ">" || next.isWhitespace || next == "/" {
                guard let start = html[open.upperBound...].firstIndex(of: ">"),
                    let close = html.range(
                        of: "</\(element)>", options: [.caseInsensitive, .backwards],
                        range: start..<html.endIndex)
                else { return nil }
                return String(html[html.index(after: start)..<close.lowerBound])
            }
            searchStart = open.upperBound
        }
        return nil
    }

    // MARK: - Text

    /// Collapses runs of whitespace into single spaces and trims the ends.
    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Decodes named and numeric character references.
    public static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex
        while let ampersand = text[index...].firstIndex(of: "&") {
            result += text[index..<ampersand]
            let afterAmpersand = text.index(after: ampersand)
            let limit =
                text.index(afterAmpersand, offsetBy: 12, limitedBy: text.endIndex)
                ?? text.endIndex
            if let semicolon = text[afterAmpersand..<limit].firstIndex(of: ";"),
                let decoded = decodeEntity(text[afterAmpersand..<semicolon])
            {
                result += decoded
                index = text.index(after: semicolon)
            } else {
                result += "&"
                index = afterAmpersand
            }
        }
        result += text[index...]
        return result
    }

    private static func decodeEntity(_ name: Substring) -> String? {
        if name.hasPrefix("#") {
            let digits = name.dropFirst()
            let value =
                digits.first == "x" || digits.first == "X"
                ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
            guard let value, value != 0, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
        return namedEntities[String(name)]
    }

    static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "sbquo": "‚",
        "ldquo": "“", "rdquo": "”", "bdquo": "„", "laquo": "«", "raquo": "»", "lsaquo": "‹",
        "rsaquo": "›", "bull": "•", "middot": "·", "copy": "©", "reg": "®", "trade": "™",
        "deg": "°", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "sect": "§",
        "para": "¶", "times": "×", "divide": "÷", "plusmn": "±", "frac12": "½",
        "frac14": "¼", "frac34": "¾", "shy": "", "zwj": "", "zwnj": "", "ensp": " ",
        "emsp": " ", "thinsp": " ", "larr": "←", "rarr": "→", "uarr": "↑", "darr": "↓",
        "hearts": "♥", "check": "✓", "iexcl": "¡", "iquest": "¿", "szlig": "ß",
        "auml": "ä", "ouml": "ö", "uuml": "ü", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü",
        "ccedil": "ç", "Ccedil": "Ç", "eacute": "é", "egrave": "è", "ecirc": "ê",
        "aacute": "á", "agrave": "à", "acirc": "â", "iacute": "í", "oacute": "ó",
        "uacute": "ú", "ntilde": "ñ", "Eacute": "É", "atilde": "ã", "otilde": "õ",
        "scaron": "š", "Scaron": "Š", "oslash": "ø", "aring": "å", "aelig": "æ",
    ]
}

/// An HTML tag found by the scanner.
private struct Tag {
    var name: String
    var isClosing: Bool
    var isSelfClosing: Bool
    var attributes: Substring
    /// Just past the closing `>`.
    var end: String.Index

    /// Parses the tag at the start of `text`, which begins with "<". Returns `nil` when it is
    /// not a tag (such as "a < b").
    init?(parsing text: Substring) {
        var index = text.index(after: text.startIndex)
        guard index < text.endIndex else { return nil }
        let isClosing = text[index] == "/"
        if isClosing { index = text.index(after: index) }
        // Declarations and processing instructions (<!DOCTYPE>, <?xml?>) are skipped as tags
        // with an empty name.
        let isDeclaration = !isClosing && (text[index] == "!" || text[index] == "?")
        guard isDeclaration || text[index].isLetter else { return nil }
        let nameStart = index
        while index < text.endIndex,
            text[index].isLetter || text[index].isNumber
                || text[index] == "-" || text[index] == ":"
        {
            index = text.index(after: index)
        }
        let name = isDeclaration ? "" : text[nameStart..<index].lowercased()
        // Find the closing ">", ignoring any inside quoted attribute values.
        let attributesStart = index
        var quote: Character?
        while index < text.endIndex {
            let character = text[index]
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                break
            }
            index = text.index(after: index)
        }
        guard index < text.endIndex else { return nil }
        self.name = name
        self.isClosing = isClosing
        self.attributes = text[attributesStart..<index]
        self.isSelfClosing = attributes.hasSuffix("/")
        self.end = text.index(after: index)
    }

    /// The decoded value of an attribute.
    func attribute(_ name: String) -> String? {
        HTMLAttributes.value(of: name, in: attributes)
    }
}

/// Reads attribute values from the inside of a tag.
enum HTMLAttributes {
    static func value(of name: String, in attributes: Substring) -> String? {
        var index = attributes.startIndex
        while index < attributes.endIndex {
            // Skip to the next attribute name.
            while index < attributes.endIndex,
                attributes[index].isWhitespace || attributes[index] == "/"
            {
                index = attributes.index(after: index)
            }
            let nameStart = index
            while index < attributes.endIndex, !attributes[index].isWhitespace,
                attributes[index] != "=", attributes[index] != ">"
            {
                index = attributes.index(after: index)
            }
            let attributeName = attributes[nameStart..<index].lowercased()
            while index < attributes.endIndex, attributes[index].isWhitespace {
                index = attributes.index(after: index)
            }
            var value = ""
            if index < attributes.endIndex, attributes[index] == "=" {
                index = attributes.index(after: index)
                while index < attributes.endIndex, attributes[index].isWhitespace {
                    index = attributes.index(after: index)
                }
                if index < attributes.endIndex,
                    attributes[index] == "\"" || attributes[index] == "'"
                {
                    let quote = attributes[index]
                    let start = attributes.index(after: index)
                    let close = attributes[start...].firstIndex(of: quote) ?? attributes.endIndex
                    value = String(attributes[start..<close])
                    index = close < attributes.endIndex ? attributes.index(after: close) : close
                } else {
                    let start = index
                    while index < attributes.endIndex, !attributes[index].isWhitespace {
                        index = attributes.index(after: index)
                    }
                    value = String(attributes[start..<index])
                }
            }
            if attributeName == name { return HTMLText.decodeEntities(value) }
            if index == nameStart { index = attributes.index(after: index) }
        }
        return nil
    }
}

/// Builds text with collapsed whitespace and at most one blank line between blocks.
private struct TextBuilder {
    private var output = ""
    /// Line breaks requested since the last text: 1 for a new line, 2 for a blank line.
    private var pendingBreaks = 0
    private var pendingSpace = false

    mutating func append(text: Substring) {
        let decoded = HTMLText.decodeEntities(String(text))
        let words = decoded.split(whereSeparator: \.isWhitespace)
        let startsWithSpace = decoded.first?.isWhitespace ?? false
        let endsWithSpace = decoded.last?.isWhitespace ?? false
        guard !words.isEmpty else {
            if !decoded.isEmpty { pendingSpace = true }
            return
        }
        flush(space: pendingSpace || startsWithSpace)
        output += words.joined(separator: " ")
        pendingSpace = endsWithSpace
    }

    /// Appends text as is, such as a list marker.
    mutating func append(raw: String) {
        flush(space: pendingSpace)
        output += raw
        pendingSpace = false
    }

    /// Separates the next text with a space, unless it starts a line.
    mutating func space() {
        pendingSpace = true
    }

    mutating func breakLine(blank: Bool = false) {
        guard !output.isEmpty else { return }
        pendingBreaks = max(pendingBreaks, blank ? 2 : 1)
        pendingSpace = false
    }

    private mutating func flush(space: Bool) {
        if pendingBreaks > 0 {
            output += String(repeating: "\n", count: pendingBreaks)
            pendingBreaks = 0
        } else if space, let last = output.last, !last.isWhitespace {
            output += " "
        }
    }

    var result: String {
        // Keep leading indentation (nested lists), drop trailing spaces.
        output.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in String(line.reversed().drop(while: \.isWhitespace).reversed()) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
