import Testing

@testable import MomoApp

@Suite("IdleTimeSampler")
struct IdleTimeSamplerTests {
    @Test("reads the system at most once per interval and counts up in between")
    func throttlesReadings() {
        var sampler = IdleTimeSampler()
        var reads = 0
        let read: () -> Double = {
            reads += 1
            return 10
        }
        #expect(sampler.idleSeconds(now: 100, read: read) == 10)
        #expect(sampler.idleSeconds(now: 100.25, read: read) == 10.25)
        #expect(sampler.idleSeconds(now: 100.5, read: read) == 10.5)
        #expect(reads == 1)
        #expect(sampler.idleSeconds(now: 100 + sampler.interval, read: read) == 10)
        #expect(reads == 2)
    }

    @Test("a fresh reading picks up the user coming back")
    func freshReadingWins() {
        var sampler = IdleTimeSampler()
        _ = sampler.idleSeconds(now: 0) { 300 }
        let later = sampler.idleSeconds(now: sampler.interval) { 0.2 }
        #expect(later == 0.2)
    }

    @Test("stays below the one-second wake-up threshold")
    func intervalIsShortEnoughToWakeUp() {
        #expect(IdleTimeSampler().interval < 1)
    }

    @Test("rereads when the clock goes backwards")
    func backwardsClock() {
        var sampler = IdleTimeSampler()
        _ = sampler.idleSeconds(now: 50) { 5 }
        #expect(sampler.idleSeconds(now: 40) { 7 } == 7)
    }
}
