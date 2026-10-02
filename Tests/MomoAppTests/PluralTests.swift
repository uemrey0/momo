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

    @Test("a count next to a text argument still picks its form")
    func mixedArguments() {
        let key: String.LocalizationValue =
            "Momo left out %d damaged items. A copy of the original file is at %@."
        #expect(
            String(format: L(key), 1, "/tmp/a")
                == "Momo left out 1 damaged item. A copy of the original file is at /tmp/a.")
        #expect(
            String(format: L(key), 2, "/tmp/a")
                == "Momo left out 2 damaged items. A copy of the original file is at /tmp/a.")
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
