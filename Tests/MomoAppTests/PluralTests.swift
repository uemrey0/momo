import Foundation
import Testing

@testable import MomoApp

@Suite(
    "Plural strings",
    .enabled(if: Bundle.module.preferredLocalizations.first == "en", "needs the English UI"))
struct PluralTests {
    @Test("a count of one uses the singular form")
    func singular() {
        #expect(String(format: L("%lld minutes"), 1) == "1 minute")
        #expect(String(format: L("Starts in %lld minutes."), 1) == "Starts in 1 minute.")
    }

    @Test("other counts use the plural form")
    func plural() {
        #expect(String(format: L("%lld minutes"), 2) == "2 minutes")
        #expect(String(format: L("Starts in %lld minutes."), 5) == "Starts in 5 minutes.")
    }

    @Test("each count in a sentence picks its own form")
    func substitutions() {
        let key: String.LocalizationValue =
            "You have %lld tasks due and %lld events today. Want me to plan your day?"
        #expect(
            String(format: L(key), 1, 2)
                == "You have 1 task due and 2 events today. Want me to plan your day?")
        #expect(
            String(format: L(key), 3, 1)
                == "You have 3 tasks due and 1 event today. Want me to plan your day?")
    }
}
