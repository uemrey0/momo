import Foundation

/// Keeps a few expensive objects that are not thread-safe, such as loaded models, for reuse.
///
/// Each use checks an object out, so two uses at the same time never share one. An idle
/// object is reused; when none is idle, a new one is made, and afterwards it is kept unless
/// `capacity` objects are already idle.
public final class ObjectPool<Object: AnyObject>: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private let reset: @Sendable (Object) -> Void
    private var idle: [Object] = []
    /// Increases on ``removeAll()``, so objects checked out before it are not kept.
    private var generation = 0

    /// - Parameters:
    ///   - capacity: The most idle objects kept.
    ///   - reset: Clears what one use left in an object before it is kept for the next.
    public init(capacity: Int, reset: @escaping @Sendable (Object) -> Void = { _ in }) {
        self.capacity = max(0, capacity)
        self.reset = reset
    }

    /// The number of idle objects.
    public var idleCount: Int { lock.withLock { idle.count } }

    /// Runs `body` with an object no other use holds meanwhile: an idle one, or one from
    /// `make` when none is idle. The object goes back to the pool afterwards, even if `body`
    /// throws.
    public func use<Result>(
        making make: () async throws -> Object, _ body: (Object) async throws -> Result
    ) async rethrows -> Result {
        let (reused, generation) = lock.withLock { (idle.popLast(), self.generation) }
        let object: Object
        if let reused {
            object = reused
        } else {
            object = try await make()
        }
        defer { checkIn(object, generation: generation) }
        return try await body(object)
    }

    /// Drops the idle objects, and the ones in use once they are done, for example because
    /// the files they were loaded from are gone.
    public func removeAll() {
        lock.withLock {
            idle.removeAll()
            generation += 1
        }
    }

    private func checkIn(_ object: Object, generation: Int) {
        reset(object)
        lock.withLock {
            guard generation == self.generation, idle.count < capacity else { return }
            idle.append(object)
        }
    }
}
