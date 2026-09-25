/// A type-erased random number generator, so the engine can take any generator (a seeded one
/// in tests, the system one in the app).
struct AnyRandomNumberGenerator: RandomNumberGenerator {
    private var base: any RandomNumberGenerator

    init(_ base: some RandomNumberGenerator) {
        self.base = base
    }

    mutating func next() -> UInt64 {
        base.next()
    }
}
