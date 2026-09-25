import Foundation
import Testing

@testable import MomoKit

@Suite("FlexibleDate")
struct FlexibleDateTests {
    @Test(
        "parses the formats models produce",
        arguments: [
            "2026-09-27T15:00:00Z", "2026-09-27T15:00:00+03:00", "2026-09-27T15:00",
            "2026-09-27 15:00", "2026-09-27",
        ])
    func parses(_ text: String) {
        #expect(FlexibleDate.parse(text) != nil)
    }

    @Test("rejects nonsense")
    func rejects() {
        #expect(FlexibleDate.parse("next tuesday-ish") == nil)
    }
}
