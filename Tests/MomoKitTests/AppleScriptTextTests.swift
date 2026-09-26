import Foundation
import Testing

@testable import MomoKit

@Suite("AppleScriptText")
struct AppleScriptTextTests {
    @Test("wraps plain text in quotes")
    func plain() {
        #expect(AppleScriptText.literal("Hello, Ayşe 👋") == "\"Hello, Ayşe 👋\"")
    }

    @Test("escapes quotes and backslashes so text can't break out")
    func escapes() {
        let attack = #"hi" & (do shell script "rm -rf ~") & ""#
        let literal = AppleScriptText.literal(attack)
        #expect(literal == #""hi\" & (do shell script \"rm -rf ~\") & \"""#)
        #expect(AppleScriptText.literal(#"C:\path"#) == #""C:\\path""#)
    }

    @Test("escapes line breaks and tabs and drops other control characters")
    func controlCharacters() {
        #expect(AppleScriptText.literal("a\nb\r\tc\u{0}d\u{7}") == #""a\nb\r\tcd""#)
    }

    @Test("builds lists")
    func lists() {
        #expect(AppleScriptText.list(["a", "b\""]) == #"{"a", "b\""}"#)
        #expect(AppleScriptText.list([]) == "{}")
    }

    @Test("reads osascript errors")
    func errors() {
        let denied = AppleScriptText.parseError(
            "0:45: execution error: Not authorized to send Apple events to Mail. (-1743)\n")
        #expect(denied.message == "Not authorized to send Apple events to Mail.")
        #expect(denied.code == -1743)
        let syntax = AppleScriptText.parseError(
            "12:20: syntax error: Expected end of line but found identifier. (-2741)")
        #expect(syntax.message == "Expected end of line but found identifier.")
        #expect(syntax.code == -2741)
        let plain = AppleScriptText.parseError("Something odd")
        #expect(plain.message == "Something odd")
        #expect(plain.code == nil)
    }
}
