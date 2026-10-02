import Foundation

/// Why a store could not use its file as it was. The app tells the user about it.
public enum StoreProblem: Sendable, Equatable {
    /// The file could not be read. It was moved to `backup` and the store started over empty.
    /// Without a backup the file is left alone and the store refuses to write over it.
    case unreadable(backup: URL?)
    /// `count` items could not be read and were left out. The file was copied to `backup`
    /// first. Without a backup the store refuses to write, which would drop them for good.
    case skippedItems(count: Int, backup: URL?)
    /// A newer Momo wrote the file in format `version`. It can be read but not changed.
    case newerVersion(Int)

    /// The copy of the original file, if one was made.
    public var backup: URL? {
        switch self {
        case .unreadable(let backup), .skippedItems(_, let backup): backup
        case .newerVersion: nil
        }
    }

    /// Why writing would lose data, or `nil` when writing is safe.
    func writeError(for fileURL: URL) -> ToolError? {
        switch self {
        case .newerVersion(let version):
            ToolError(
                "\(fileURL.lastPathComponent) was saved by a newer version of Momo (format "
                    + "\(version)). Update Momo before changing it.")
        case .unreadable(nil), .skippedItems(_, nil):
            ToolError(
                "Momo can't read all of \(fileURL.path) and couldn't back it up, so it won't "
                    + "write over it. Move or fix the file, then try again.")
        case .unreadable, .skippedItems:
            nil
        }
    }
}

/// Counts the list elements a decode skipped because they were damaged.
final class SkippedElements: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        stored += 1
    }
}

extension CodingUserInfoKey {
    /// A ``SkippedElements`` that lossy lists report skipped elements to.
    static let skippedElements: CodingUserInfoKey = {
        guard let key = CodingUserInfoKey(rawValue: "momo.skippedElements") else {
            preconditionFailure("Invalid user info key")
        }
        return key
    }()
}

/// Reading and backing up the JSON files Momo's stores keep.
enum StoreFile {
    /// A decoder for store files that reports skipped elements to `skipped`.
    static func decoder(counting skipped: SkippedElements) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.userInfo[.skippedElements] = skipped
        return decoder
    }

    /// Moves the file at `url` aside, or copies it when `keepingOriginal`, to
    /// `<name>.<label>-<date>.<extension>` in the same folder, and returns the new location.
    static func backUp(_ url: URL, label: String, keepingOriginal: Bool) throws -> URL {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let name = url.deletingPathExtension().lastPathComponent
        let pathExtension = url.pathExtension
        let folder = url.deletingLastPathComponent()
        var backup = folder.appendingPathComponent("\(name).\(label)-\(stamp)")
            .appendingPathExtension(pathExtension)
        var attempt = 1
        while FileManager.default.fileExists(atPath: backup.path) {
            attempt += 1
            backup = folder.appendingPathComponent("\(name).\(label)-\(stamp)-\(attempt)")
                .appendingPathExtension(pathExtension)
        }
        if keepingOriginal {
            try FileManager.default.copyItem(at: url, to: backup)
        } else {
            try FileManager.default.moveItem(at: url, to: backup)
        }
        return backup
    }

    /// The backups ``backUp(_:label:keepingOriginal:)`` made of `url`: files named
    /// `<name>.corrupt-*.<extension>` or `<name>.backup-*.<extension>` in its folder, oldest
    /// first.
    static func backups(of url: URL) -> [URL] {
        let name = url.deletingPathExtension().lastPathComponent
        let suffix = url.pathExtension.isEmpty ? "" : ".\(url.pathExtension)"
        let folder = url.deletingLastPathComponent()
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return files.filter { file in
            file.hasSuffix(suffix)
                && ["corrupt", "backup"].contains { file.hasPrefix("\(name).\($0)-") }
        }
        .sorted()
        .map { folder.appendingPathComponent($0) }
    }
}

/// An exclusive `flock` on `<file>.lock` next to a store file, shared by every process that
/// writes the file (the app and `momo-mcp`), so their reload, change and write never overlap.
///
/// Waiting blocks the calling thread, so callers should not run on the Swift concurrency pool.
struct StoreFileLock {
    /// How long ``acquire(for:timeout:)`` waits for another process before giving up.
    static let defaultTimeout: TimeInterval = 10

    private let descriptor: Int32

    /// The lock file for `fileURL`.
    static func lockURL(for fileURL: URL) -> URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent(fileURL.lastPathComponent + ".lock")
    }

    /// Takes the lock for `fileURL`, creating the lock file if needed. Throws when another
    /// process still holds it after `timeout`.
    static func acquire(
        for fileURL: URL, timeout: TimeInterval = defaultTimeout
    ) throws -> StoreFileLock {
        let lockURL = lockURL(for: fileURL)
        try FileManager.default.createDirectory(
            at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else {
            throw ToolError(
                "Momo can't open \(lockURL.path) to save its data: "
                    + String(cString: strerror(errno)))
        }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let error = errno
            guard error == EWOULDBLOCK || error == EINTR else {
                close(descriptor)
                throw ToolError(
                    "Momo can't lock \(lockURL.path) to save its data: "
                        + String(cString: strerror(error)))
            }
            guard Date() < deadline else {
                close(descriptor)
                throw ToolError(
                    "Another Momo process has been saving \(fileURL.lastPathComponent) for too "
                        + "long. Try again in a moment.")
            }
            usleep(2_000)
        }
        return StoreFileLock(descriptor: descriptor)
    }

    /// Releases the lock. Closing the descriptor would release it too, as would the process
    /// ending.
    func release() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

/// One element of a lossy list: `nil` when it couldn't be decoded.
struct Lossy<Value: Decodable>: Decodable {
    var value: Value?

    init(from decoder: any Decoder) throws {
        // Decoding through a container keeps the decoder's strategies, such as for dates.
        if let value = try? decoder.singleValueContainer().decode(Value.self) {
            self.value = value
        } else {
            value = nil
            (decoder.userInfo[.skippedElements] as? SkippedElements)?.increment()
        }
    }
}

extension KeyedDecodingContainer {
    /// Decodes an array, skipping elements that cannot be read, so one damaged entry never
    /// hides the rest. A missing array is empty; a value that isn't an array throws.
    func lossyList<T: Decodable>(_ type: T.Type, _ key: Key) throws -> [T] {
        try decodeIfPresent([Lossy<T>].self, forKey: key)?.compactMap(\.value) ?? []
    }

    /// Like ``lossyList(_:_:)``, but a value that isn't an array is empty too.
    func lossy<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        (try? lossyList(type, key)) ?? []
    }
}
