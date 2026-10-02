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
