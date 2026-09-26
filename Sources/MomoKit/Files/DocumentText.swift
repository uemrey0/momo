import AppKit
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// Reads the text of documents: plain text, Markdown, code, JSON and CSV, PDF, and rich
/// text or Word documents (RTF, DOC, DOCX, ODT). Used for chat attachments, and reusable by
/// any tool that reads files.
public enum DocumentText {
    /// Files larger than this are not read.
    public static let maximumFileSize = 25_000_000
    /// The most characters returned by default; longer documents are cut with a note.
    public static let maximumCharacters = 60_000

    /// The text of the file at `url`, shortened to `limit` characters.
    ///
    /// - Throws: `ToolError` when the file is too large, empty or not a readable document.
    public static func extract(from url: URL, limit: Int = maximumCharacters) throws -> String {
        shortened(try fullText(of: url), to: limit)
    }

    /// The whole text of the file at `url`, for readers that page through long documents.
    /// PDF pages are marked with "[Page n]".
    ///
    /// - Parameter maximumFileSize: Files larger than this are refused.
    /// - Throws: `ToolError` when the file is too large, empty or not a readable document.
    public static func fullText(
        of url: URL, maximumFileSize: Int = maximumFileSize
    ) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        if let size = values.fileSize, size > maximumFileSize {
            throw ToolError(
                "“\(url.lastPathComponent)” is too large to read (over \(maximumFileSize / 1_000_000) MB)."
            )
        }
        let type = values.contentType ?? UTType(filenameExtension: url.pathExtension)
        let text: String
        if type?.conforms(to: .pdf) == true {
            text = try pdfText(at: url)
        } else if let type, richTypes.contains(where: type.conforms(to:)) {
            text = try richText(at: url)
        } else if iWorkExtensions.contains(url.pathExtension.lowercased()) {
            throw ToolError(
                "“\(url.lastPathComponent)” is an iWork file, which Momo can't read directly. Export it as PDF or Word first."
            )
        } else {
            text = try plainText(at: url)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError("“\(url.lastPathComponent)” has no readable text.")
        }
        return trimmed
    }

    /// Whether the file at `url` is an image, judged by its type.
    public static func isImage(_ url: URL) -> Bool {
        let type =
            (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        return type?.conforms(to: .image) == true
    }

    /// Document types read through `NSAttributedString`'s importers.
    static let richTypes: [UTType] = [
        .rtf, .rtfd, .flatRTFD, UTType("com.microsoft.word.doc"),
        UTType("org.openxmlformats.wordprocessingml.document"),
        UTType("org.oasis-open.opendocument.text"),
    ].compactMap { $0 }

    /// Pages, Numbers and Keynote documents, which have no public text importer.
    static let iWorkExtensions: Set<String> = ["pages", "numbers", "key"]

    static func shortened(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit))
            + "\n[… cut here: the document is longer than \(limit) characters]"
    }

    private static func pdfText(at url: URL) throws -> String {
        guard let document = PDFDocument(url: url) else {
            throw ToolError("“\(url.lastPathComponent)” could not be opened as a PDF.")
        }
        if document.isLocked {
            throw ToolError("“\(url.lastPathComponent)” is password protected.")
        }
        let pages = (0..<document.pageCount).map { index in
            "[Page \(index + 1)]\n\(document.page(at: index)?.string ?? "")"
        }
        guard pages.joined().contains(where: \.isLetter) else {
            throw ToolError(
                "“\(url.lastPathComponent)” has no selectable text; it may be a scanned PDF.")
        }
        return pages.joined(separator: "\n\n")
    }

    private static func richText(at url: URL) throws -> String {
        do {
            return try NSAttributedString(url: url, options: [:], documentAttributes: nil).string
        } catch {
            throw ToolError("“\(url.lastPathComponent)” could not be read as a document.")
        }
    }

    private static func plainText(at url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        // Text files have no NUL bytes; anything else is a binary format we can't read.
        guard !data.prefix(8_192).contains(0) else {
            throw ToolError("“\(url.lastPathComponent)” is not a text document Momo can read.")
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        var converted: NSString?
        let encoding = NSString.stringEncoding(
            for: data, encodingOptions: nil, convertedString: &converted,
            usedLossyConversion: nil)
        if encoding != 0, let converted { return converted as String }
        return String(decoding: data, as: UTF8.self)
    }
}
