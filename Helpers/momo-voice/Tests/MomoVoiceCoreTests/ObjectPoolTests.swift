import Foundation
import Testing

@testable import MomoVoiceCore

@Suite("Reusing objects from a pool")
struct ObjectPoolTests {
    final class Thing: @unchecked Sendable {
        let number: Int
        var isDirty = false
        init(number: Int) { self.number = number }
    }

    /// Makes numbered things and counts them.
    final class Factory: @unchecked Sendable {
        private let lock = NSLock()
        private var made = 0

        var count: Int { lock.withLock { made } }

        func make() -> Thing {
            lock.withLock {
                made += 1
                return Thing(number: made)
            }
        }
    }

    @Test("reuses an idle object instead of making a new one")
    func reusesIdleObject() async {
        let pool = ObjectPool<Thing>(capacity: 2)
        let factory = Factory()
        let first = await pool.use(making: factory.make) { $0.number }
        let second = await pool.use(making: factory.make) { $0.number }
        #expect(first == 1)
        #expect(second == 1)
        #expect(factory.count == 1)
        #expect(pool.idleCount == 1)
    }

    @Test("never hands one object to two uses at the same time")
    func separatesConcurrentUses() async {
        let pool = ObjectPool<Thing>(capacity: 2)
        let factory = Factory()
        let numbers = await pool.use(making: factory.make) { outer in
            await pool.use(making: factory.make) { inner in [outer.number, inner.number] }
        }
        #expect(numbers == [1, 2])
        #expect(pool.idleCount == 2)
        // Both are idle now, so neither of the next two uses makes another.
        _ = await pool.use(making: factory.make) { _ in
            await pool.use(making: factory.make) { _ in }
        }
        #expect(factory.count == 2)
    }

    @Test("keeps no more idle objects than its capacity")
    func capsIdleObjects() async {
        let pool = ObjectPool<Thing>(capacity: 1)
        let factory = Factory()
        _ = await pool.use(making: factory.make) { _ in
            await pool.use(making: factory.make) { _ in }
        }
        #expect(factory.count == 2)
        #expect(pool.idleCount == 1)
    }

    @Test("resets an object before keeping it")
    func resetsOnCheckIn() async {
        let pool = ObjectPool<Thing>(capacity: 1) { $0.isDirty = false }
        let factory = Factory()
        await pool.use(making: factory.make) { $0.isDirty = true }
        let isDirty = await pool.use(making: factory.make) { $0.isDirty }
        #expect(!isDirty)
    }

    @Test("returns the object when the use throws")
    func returnsObjectAfterError() async {
        struct Failure: Error {}
        let pool = ObjectPool<Thing>(capacity: 1)
        let factory = Factory()
        await #expect(throws: Failure.self) {
            try await pool.use(making: factory.make) { _ in throw Failure() }
        }
        #expect(pool.idleCount == 1)
    }

    @Test("keeps nothing when making an object fails")
    func keepsNothingAfterFailedMake() async {
        struct Failure: Error {}
        let pool = ObjectPool<Thing>(capacity: 1)
        await #expect(throws: Failure.self) {
            try await pool.use(making: { throw Failure() }) { _ in }
        }
        #expect(pool.idleCount == 0)
    }

    @Test("drops idle objects and the ones in use when emptied")
    func removeAllDropsEverything() async {
        let pool = ObjectPool<Thing>(capacity: 2)
        let factory = Factory()
        await pool.use(making: factory.make) { _ in }
        #expect(pool.idleCount == 1)
        await pool.use(making: factory.make) { _ in
            // The files behind it go away while it is in use.
            pool.removeAll()
        }
        #expect(pool.idleCount == 0)
        let number = await pool.use(making: factory.make) { $0.number }
        #expect(number == 2)
    }
}
