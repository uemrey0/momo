import Foundation
import Testing

@testable import MomoKit

func temporaryStore() -> MomoStore {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("momo-tests-\(UUID().uuidString)")
        .appendingPathComponent("data.json")
    return MomoStore(fileURL: url)
}

/// A value tests can set from `@Sendable` closures.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            stored = newValue
        }
    }
}
