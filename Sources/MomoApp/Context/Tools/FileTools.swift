import AppKit
import Foundation
import MomoKit
import PDFKit

/// Tools that find, read and tidy the user's files. Places that hold secrets are refused by
/// ``FilePathPolicy``.
enum FileTools {
    static func all(policy: FilePathPolicy = FilePathPolicy()) -> [any MomoTool] {
        [
            findFiles(policy), readFile(policy), listFolder(policy), revealInFinder(policy),
            moveToTrash(policy),
        ]
    }

    // MARK: - Finding

    static func findFiles(_ policy: FilePathPolicy) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "find_files",
                description:
                    "Search the user's files with Spotlight by name, text content, kind and date. Use it when the user asks where a file is or wants to find documents; then read_file, reveal_in_finder or move_to_trash with the returned paths. Give at least one of name, content or kind.",
                parameters: JSONSchema.object([
                    "name": JSONSchema.string("Words the file name contains"),
                    "content": JSONSchema.string("Words the file's text contains"),
                    "kind": JSONSchema.oneOf(
                        SpotlightQuery.kinds.keys.sorted(), description: "Kind of file"),
                    "modified_within_days": JSONSchema.integer(
                        "Only files changed in the last N days"),
                    "folder": JSONSchema.string(
                        "Folder to search in, e.g. ~/Documents; defaults to the home folder"),
                    "limit": JSONSchema.integer("Maximum results, 1 to 50, default 20"),
                ]),
                activityLabel: L("Searching your files"))
        ) { arguments in
            let query = SpotlightQuery(
                name: arguments["name"]?.stringValue, content: arguments["content"]?.stringValue,
                kind: arguments["kind"]?.stringValue,
                modifiedWithinDays: arguments["modified_within_days"]?.intValue)
            guard let queryString = query.queryString else {
                throw ToolError(
                    "Give a name, content or a known kind (\(SpotlightQuery.kinds.keys.sorted().joined(separator: ", ")))."
                )
            }
            let folder = policy.resolve(arguments["folder"]?.stringValue ?? "~")
            try check(policy.verdictForReading(folder))
            let limit = min(50, max(1, arguments["limit"]?.intValue ?? 20))
            let result = try await ProcessRunner.run(
                "/usr/bin/mdfind", arguments: ["-onlyin", folder.path, queryString], timeout: 20)
            guard result.status == 0 else {
                throw ToolError("Spotlight search failed: \(result.output.prefix(300))")
            }
            let searchesLibrary = folder.path.contains("/Library")
            let paths = result.output.split(separator: "\n").map(String.init).filter { path in
                let url = URL(fileURLWithPath: path)
                guard policy.verdictForReading(url).isAllowed else { return false }
                // Caches, containers and hidden folders drown out what the user means.
                if !searchesLibrary, path.contains("/Library/") { return false }
                return !path.contains("/.")
            }
            guard !paths.isEmpty else { return "No matching files." }
            var lines = paths.prefix(limit).map { describe(URL(fileURLWithPath: $0)) }
            if paths.count > limit {
                lines.append("… and \(paths.count - limit) more. Narrow the search to see them.")
            }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Reading

    static func readFile(_ policy: FilePathPolicy) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "read_file",
                description:
                    "Read a file's text: plain text, Markdown, code, JSON, CSV, PDF, RTF and Word documents. Use it to summarise, answer questions about or translate a file. Long files are cut; pass offset to continue where the previous read stopped.",
                parameters: JSONSchema.object(
                    [
                        "path": JSONSchema.string("The file's path, e.g. ~/Documents/notes.md"),
                        "offset": JSONSchema.integer(
                            "Characters to skip from the start, to read further in a long file"),
                        "max_characters": JSONSchema.integer(
                            "How much to return, 1000 to 60000, default 20000"),
                    ], required: ["path"]),
                activityLabel: L("Reading a file"))
        ) { arguments in
            guard let path = arguments["path"]?.stringValue else {
                throw ToolError("A path is required.")
            }
            let url = policy.resolve(path)
            try check(policy.verdictForReading(url))
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
                throw ToolError("There is no file at \(url.path).")
            }
            if isFolder.boolValue, url.pathExtension.lowercased() != "rtfd" {
                throw ToolError("That's a folder. Use list_folder to see what's inside.")
            }
            let text = try await Task.detached(priority: .userInitiated) {
                try extractText(from: url)
            }.value
            let offset = max(0, arguments["offset"]?.intValue ?? 0)
            let limit = min(60_000, max(1000, arguments["max_characters"]?.intValue ?? 20_000))
            guard offset < text.count else {
                return text.isEmpty ? "The file has no text." : "The file ends before that offset."
            }
            let rest = text.dropFirst(offset)
            var output = String(rest.prefix(limit))
            if rest.count > limit {
                output +=
                    "\n… (\(rest.count - limit) more characters; read again with offset \(offset + limit))"
            }
            return output
        }
    }

    /// Reads a document's text, choosing the reader by file type.
    static func extractText(from url: URL) throws -> String {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let fileExtension = url.pathExtension.lowercased()
        switch fileExtension {
        case "pdf":
            guard size < 200_000_000, let document = PDFDocument(url: url) else {
                throw ToolError("I couldn't open that PDF.")
            }
            if document.isLocked { throw ToolError("That PDF is password protected.") }
            var pages: [String] = []
            for index in 0..<document.pageCount {
                let text = document.page(at: index)?.string ?? ""
                pages.append("[Page \(index + 1)]\n\(text)")
            }
            let text = pages.joined(separator: "\n\n")
            let hasText = text.contains { $0.isLetter }
            return hasText ? text : "The PDF has no selectable text (it may be scanned)."
        case "rtf", "rtfd", "doc", "docx", "odt", "wordml":
            let types: [String: NSAttributedString.DocumentType] = [
                "rtf": .rtf, "rtfd": .rtfd, "doc": .docFormat, "docx": .officeOpenXML,
                "odt": .openDocument, "wordml": .wordML,
            ]
            var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
            if let type = types[fileExtension] { options[.documentType] = type }
            let document = try NSAttributedString(
                url: url, options: options, documentAttributes: nil)
            return document.string
        case "pages", "numbers", "key":
            throw ToolError(
                "Momo can't read iWork files directly. Ask the user to export it as PDF or Word.")
        default:
            guard size < 20_000_000 else {
                throw ToolError("That file is too large to read (\(OutputText.byteCount(size))).")
            }
            let data = try Data(contentsOf: url)
            if data.prefix(8192).contains(0) {
                throw ToolError("That looks like a binary file, not text.")
            }
            if let text = String(data: data, encoding: .utf8) { return text }
            var encoding = String.Encoding.utf8
            if let text = try? String(contentsOf: url, usedEncoding: &encoding) { return text }
            return String(data: data, encoding: .isoLatin1) ?? ""
        }
    }

    // MARK: - Folders

    static func listFolder(_ policy: FilePathPolicy) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "list_folder",
                description:
                    "List what is inside a folder (folders first, with sizes and dates). Use it to browse, e.g. ~/Downloads or ~/Desktop.",
                parameters: JSONSchema.object(
                    [
                        "path": JSONSchema.string("The folder, e.g. ~/Downloads"),
                        "include_hidden": JSONSchema.boolean(
                            "Also list hidden items, default false"),
                    ], required: ["path"]),
                activityLabel: L("Looking in a folder"))
        ) { arguments in
            let url = policy.resolve(arguments["path"]?.stringValue ?? "~")
            try check(policy.verdictForReading(url))
            var options: FileManager.DirectoryEnumerationOptions = []
            if arguments["include_hidden"]?.boolValue != true {
                options.insert(.skipsHiddenFiles)
            }
            let keys: [URLResourceKey] = [
                .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .isPackageKey,
            ]
            let items: [URL]
            do {
                items = try FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: keys, options: options)
            } catch {
                throw ToolError("I couldn't open \(url.path): \(error.localizedDescription)")
            }
            let visible = items.filter { policy.verdictForReading($0).isAllowed }
            guard !visible.isEmpty else { return "\(url.path) is empty." }
            let sorted = visible.sorted { lhs, rhs in
                let lhsFolder = isFolder(lhs)
                let rhsFolder = isFolder(rhs)
                if lhsFolder != rhsFolder { return lhsFolder }
                return lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent)
                    == .orderedAscending
            }
            var lines = ["\(url.path) (\(visible.count) items):"]
            lines += sorted.prefix(200).map { describe($0, nameOnly: true) }
            if sorted.count > 200 { lines.append("… and \(sorted.count - 200) more.") }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: - Finder

    static func revealInFinder(_ policy: FilePathPolicy) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "reveal_in_finder",
                description: "Show a file or folder selected in a Finder window.",
                parameters: JSONSchema.object(
                    ["path": JSONSchema.string("The item's path")], required: ["path"]),
                activityLabel: L("Showing it in Finder"))
        ) { arguments in
            let url = policy.resolve(arguments["path"]?.stringValue ?? "")
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ToolError("There is nothing at \(url.path).")
            }
            await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            return "Showed \(url.lastPathComponent) in Finder."
        }
    }

    static func moveToTrash(_ policy: FilePathPolicy) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "move_to_trash",
                description:
                    "Move one file or folder to the Trash (the user can put it back from there). Use the exact path from find_files or list_folder.",
                parameters: JSONSchema.object(
                    ["path": JSONSchema.string("The item's path")], required: ["path"]),
                requiresConfirmation: true, activityLabel: L("Moving to the Trash")),
            summary: { arguments in
                let path = policy.resolve(arguments["path"]?.stringValue ?? "").path
                return String(format: L("Move “%@” to the Trash"), path)
            }
        ) { arguments in
            let url = policy.resolve(arguments["path"]?.stringValue ?? "")
            try check(policy.verdictForTrashing(url))
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ToolError("There is nothing at \(url.path).")
            }
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return "Moved \(url.path) to the Trash."
        }
    }

    // MARK: - Helpers

    private static func check(_ verdict: FilePathPolicy.Verdict) throws {
        if case .denied(let reason) = verdict { throw ToolError(reason) }
    }

    private static func isFolder(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        return values?.isDirectory == true && values?.isPackage != true
    }

    /// "~/Documents/a.pdf — 1.2 MB — modified 2026-09-20 14:03"
    private static func describe(_ url: URL, nameOnly: Bool = false) -> String {
        let values = try? url.resourceValues(forKeys: [
            .fileSizeKey, .contentModificationDateKey, .isDirectoryKey, .isPackageKey,
        ])
        var parts = [nameOnly ? url.lastPathComponent : url.path]
        if isFolder(url) {
            parts[0] += "/"
        } else if let size = values?.fileSize {
            parts.append(OutputText.byteCount(Int64(size)))
        }
        if let modified = values?.contentModificationDate {
            parts.append("modified \(FlexibleDate.format(modified))")
        }
        return parts.joined(separator: " — ")
    }
}
