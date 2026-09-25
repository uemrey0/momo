import Testing

@testable import MomoFace

@Suite("Spring")
struct SpringTests {
    @Test("settles on its target")
    func settlesOnTarget() {
        var spring = Spring(0, stiffness: 140, damping: 16)
        spring.target = 1
        for _ in 0..<600 { spring.step(by: 1.0 / 60.0) }
        #expect(abs(spring.value - 1) < 0.001)
        #expect(spring.isSettled)
    }

    @Test("lightly damped springs overshoot")
    func lightlyDampedSpringOvershoots() {
        var spring = Spring(0, stiffness: 55, damping: 4.5)
        spring.target = 1
        var peak = 0.0
        for _ in 0..<240 {
            spring.step(by: 1.0 / 60.0)
            peak = max(peak, spring.value)
        }
        #expect(peak > 1.2)
    }

    @Test("stays stable across a long frame gap")
    func staysStableAcrossLongGap() {
        var spring = Spring(0, stiffness: 320, damping: 22)
        spring.target = 10
        spring.step(by: 2)
        #expect(spring.value.isFinite)
        #expect(abs(spring.value - 10) < 0.01)
    }

    @Test("ignores non-positive durations")
    func ignoresNonPositiveDurations() {
        var spring = Spring(3)
        spring.target = 5
        spring.step(by: 0)
        spring.step(by: -1)
        #expect(spring.value == 3)
    }
}
