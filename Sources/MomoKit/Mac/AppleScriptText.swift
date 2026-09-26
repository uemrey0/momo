import Foundation

/// Builds AppleScript source safely from untrusted text.
///
/// Values from a model or the user must never be pasted into a script as they are: a stray
/// quote would end the string and let the rest run as code. Always wrap them with
/// ``literal(_:)``.
public enum AppleScriptText {
    /// Returns `text` as an AppleScript string literal, quotes included, with backslashes,
    /// quotes and control characters escaped.
    public static func literal(_ text: String) -> String {
        var result = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                // Other control characters have no escape in AppleScript; drop them.
                if scalar.properties.generalCategory == .control { continue }
                result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    /// Returns the strings as an AppleScript list literal, e.g. `{"a", "b"}`.
    public static func list(_ items: [String]) -> String {
        "{" + items.map(literal).joined(separator: ", ") + "}"
    }

    /// Reads an `osascript` error such as `execution error: Not authorized to send Apple
    /// events to Mail. (-1743)` and returns its message and code.
    public static func parseError(_ output: String) -> (message: String, code: Int?) {
        var text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop the "12:40: " source position.
        if let range = text.range(of: #"^\d+:\d+: "#, options: .regularExpression) {
            text.removeSubrange(range)
        }
        for prefix in ["execution error: ", "syntax error: "] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        var code: Int?
        if text.hasSuffix(")"), let open = text.lastIndex(of: "(") {
            let number = text[text.index(after: open)..<text.index(before: text.endIndex)]
            if let value = Int(number) {
                code = value
                text = String(text[..<open]).trimmingCharacters(in: .whitespaces)
            }
        }
        return (text, code)
    }
}
