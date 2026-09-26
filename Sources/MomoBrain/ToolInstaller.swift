import CryptoKit
import Foundation
import MomoKit

/// A command line tool Momo can download for the user, so they can use their subscription
/// without Terminal. Only official releases are used, and every download is checked against
/// the checksum GitHub publishes for it.
public enum ManagedTool: String, CaseIterable, Sendable {
    case gemini, codex

    /// The GitHub repository that publishes the tool.
    var repository: String {
        switch self {
        case .gemini: "google-gemini/gemini-cli"
        case .codex: "openai/codex"
        }
    }

    /// The release asset for this Mac.
    var assetName: String {
        #if arch(arm64)
            switch self {
            case .gemini: "gemini-darwin-arm64-unsigned.zip"
            case .codex: "codex-aarch64-apple-darwin.tar.gz"
            }
        #else
            switch self {
            case .gemini: "gemini-darwin-x64-unsigned.zip"
            case .codex: "codex-x86_64-apple-darwin.tar.gz"
            }
        #endif
    }

    /// The executable's name inside the archive.
    var archivedName: String {
        switch self {
        case .gemini: "gemini"
        case .codex: String(assetName.dropLast(".tar.gz".count))
        }
    }

    /// Where Momo keeps its copy.
    public var installedURL: URL {
        ToolInstaller.toolsDirectory.appendingPathComponent(rawValue)
    }

    /// Momo's copy, if it has downloaded one.
    public var installed: URL? {
        FileManager.default.isExecutableFile(atPath: installedURL.path) ? installedURL : nil
    }
}

/// Downloads and installs ``ManagedTool``s into Momo's own folder.
public enum ToolInstaller {
    /// `~/Library/Application Support/Momo/Tools`
    public static var toolsDirectory: URL {
        let base =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("Momo/Tools", isDirectory: true)
    }

    /// A release asset: where to download it and its expected SHA-256 checksum.
    struct Asset: Equatable {
        var url: URL
        var sha256: String
        var size: Int
    }

    /// Downloads, verifies and installs `tool`, reporting download progress from 0 to 1.
    /// Returns the installed executable.
    @discardableResult
    public static func install(
        _ tool: ManagedTool, session: URLSession = .shared,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> URL {
        let asset = try await latestAsset(for: tool, session: session)
        let archive = try await Downloader.download(
            asset.url, expectedSize: asset.size, progress: progress)
        defer { try? FileManager.default.removeItem(at: archive) }
        guard try sha256(of: archive) == asset.sha256 else {
            throw ProviderError("The download was damaged. Please try again.")
        }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("momo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await extract(archive, name: tool.assetName, into: folder)

        let extracted = folder.appendingPathComponent(tool.archivedName)
        guard FileManager.default.fileExists(atPath: extracted.path) else {
            throw ProviderError("The download didn't contain \(tool.archivedName).")
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: extracted.path)
        // Apple silicon only runs signed code. Some official builds are published unsigned;
        // a local ad-hoc signature lets them run without weakening anything else.
        if !(await run("/usr/bin/codesign", ["--verify", extracted.path])) {
            guard await run("/usr/bin/codesign", ["--sign", "-", "--force", extracted.path]) else {
                throw ProviderError("Momo couldn't prepare \(tool.rawValue) to run.")
            }
        }
        try FileManager.default.createDirectory(
            at: toolsDirectory, withIntermediateDirectories: true)
        let destination = tool.installedURL
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: extracted, to: destination)
        return destination
    }

    /// Finds the asset for this Mac in the tool's latest release.
    static func latestAsset(for tool: ManagedTool, session: URLSession) async throws -> Asset {
        guard
            let url = URL(string: "https://api.github.com/repos/\(tool.repository)/releases/latest")
        else { throw ProviderError("Invalid release address.") }
        let release = try await HTTP.getJSON(
            session: session, url: url, headers: ["Accept": "application/vnd.github+json"],
            timeout: 15)
        return try asset(named: tool.assetName, in: release)
    }

    static func asset(named name: String, in release: JSONValue) throws -> Asset {
        guard
            let item = release["assets"]?.arrayValue?.first(where: {
                $0["name"]?.stringValue == name
            }),
            let address = item["browser_download_url"]?.stringValue,
            let url = URL(string: address), url.scheme == "https",
            url.host() == "github.com",
            let digest = item["digest"]?.stringValue, digest.hasPrefix("sha256:")
        else {
            throw ProviderError("No download for this Mac was found in the latest release.")
        }
        return Asset(
            url: url, sha256: String(digest.dropFirst("sha256:".count)).lowercased(),
            size: item["size"]?.intValue ?? 0)
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func extract(_ archive: URL, name: String, into folder: URL) async throws {
        let succeeded =
            name.hasSuffix(".zip")
            ? await run("/usr/bin/ditto", ["-x", "-k", archive.path, folder.path])
            : await run("/usr/bin/tar", ["-xzf", archive.path, "-C", folder.path])
        guard succeeded else { throw ProviderError("Momo couldn't unpack the download.") }
    }

    private static func run(_ executable: String, _ arguments: [String]) async -> Bool {
        await ToolCommand.succeeds(URL(fileURLWithPath: executable), arguments)
    }
}

/// Downloads a file to a temporary location, reporting progress.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let expectedSize: Int
    private let progress: @Sendable (Double) -> Void
    private var continuation: CheckedContinuation<URL, any Error>?

    private init(expectedSize: Int, progress: @escaping @Sendable (Double) -> Void) {
        self.expectedSize = expectedSize
        self.progress = progress
    }

    static func download(
        _ url: URL, expectedSize: Int, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let downloader = Downloader(expectedSize: expectedSize, progress: progress)
        let session = URLSession(
            configuration: .ephemeral, delegate: downloader, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                downloader.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : Int64(expectedSize)
        guard total > 0 else { return }
        progress(min(1, Double(totalBytesWritten) / Double(total)))
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The file at `location` disappears when this method returns, so move it first.
        let kept = FileManager.default.temporaryDirectory
            .appendingPathComponent("momo-download-\(UUID().uuidString)")
        do {
            let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                throw ProviderError("The download failed (\(status)).")
            }
            try FileManager.default.moveItem(at: location, to: kept)
            continuation?.resume(returning: kept)
        } catch {
            continuation?.resume(throwing: error)
        }
        continuation = nil
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?
    ) {
        guard let error else { return }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
