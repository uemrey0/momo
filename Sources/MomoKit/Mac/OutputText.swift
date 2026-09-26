import Foundation

/// Helpers for text that tools hand back to a model.
public enum OutputText {
    /// Shortens `text` to at most `limit` characters, noting how much was left out.
    public static func truncate(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let omitted = text.count - limit
        return String(text.prefix(limit)) + "\n… (\(omitted) more characters not shown)"
    }

    /// A file size for people and models, e.g. "12 KB" or "3.4 MB".
    public static func byteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
