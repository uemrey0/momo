import Foundation
import MomoBrain

/// Keeps the images and files brains and tools make in Momo's own folder, so they stay in the
/// conversation even when the tool that made them cleans up.
@MainActor
enum ArtifactStore {
    /// `~/Library/Application Support/Momo/Artifacts`
    static var folder: URL {
        AppSettings.supportDirectory.appendingPathComponent("Artifacts", isDirectory: true)
    }

    /// Copies the artifact into ``folder`` and returns the copy, or the original when it is
    /// already there or can't be copied.
    static func keep(_ artifact: ChatArtifact) -> ChatArtifact {
        let source = artifact.url.standardizedFileURL
        guard !source.path.hasPrefix(folder.standardizedFileURL.path),
            FileManager.default.fileExists(atPath: source.path)
        else { return artifact }
        let day = Self.dayFormatter.string(from: Date())
        let destinationFolder = folder.appendingPathComponent(day, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: destinationFolder, withIntermediateDirectories: true)
            let destination = uniqueURL(
                for: source.lastPathComponent, in: destinationFolder)
            try FileManager.default.copyItem(at: source, to: destination)
            return ChatArtifact(url: destination, kind: artifact.kind)
        } catch {
            return artifact
        }
    }

    private static func uniqueURL(for name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = "\(base) \(counter)" + (ext.isEmpty ? "" : ".\(ext)")
            candidate = folder.appendingPathComponent(numbered)
            counter += 1
        }
        return candidate
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
