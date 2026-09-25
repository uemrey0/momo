import Foundation
import Testing

@testable import MomoKit

@Suite("PrivacyMasker")
struct PrivacyMaskerTests {
    let masker = PrivacyMasker(masksNames: false)

    @Test("masks emails, IBANs, cards, phone numbers and national IDs")
    func masksPersonalData() {
        let text = """
            Mail me at emre@example.com, IBAN TR33 0006 1005 1978 6457 8413 26, \
            card 4111 1111 1111 1111, phone +90 532 123 45 67, TC 10000000146.
            """
        let masked = masker.mask(text)
        #expect(!masked.text.contains("emre@example.com"))
        #expect(!masked.text.contains("4111"))
        #expect(!masked.text.contains("532"))
        #expect(!masked.text.contains("10000000146"))
        #expect(!masked.text.contains("TR33"))
        #expect(masked.text.contains("[EMAIL_1]"))
        #expect(masked.unmask(masked.text) == text)
    }

    @Test("leaves dates, years and invalid numbers alone")
    func leavesOrdinaryNumbersAlone() {
        let text = "On 2026-09-27 at 15:00 we sold 12345678901 units in 2025."
        #expect(masker.mask(text).text == text)
    }

    @Test("keeps placeholders consistent across messages")
    func consistentPlaceholders() {
        let first = masker.mask("Write to a@b.co")
        let second = masker.mask("Again a@b.co and c@d.co", continuing: first.replacements)
        #expect(second.text == "Again [EMAIL_1] and [EMAIL_2]")
    }

    @Test("unmasks placeholders split across streamed chunks")
    func streamingUnmask() {
        let masked = masker.mask("Email x@y.com")
        var unmasker = StreamingUnmasker(masked)
        var output = ""
        for chunk in ["I wrote to [EM", "AIL_1", "] for you."] {
            output += unmasker.consume(chunk)
        }
        output += unmasker.finish()
        #expect(output == "I wrote to x@y.com for you.")
    }
}
