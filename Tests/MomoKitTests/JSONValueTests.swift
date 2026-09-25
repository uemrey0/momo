import Foundation
import Testing

@testable import MomoKit

@Suite("JSONValue")
struct JSONValueTests {
    @Test("round-trips objects with mixed values")
    func roundTrips() throws {
        let value: JSONValue = [
            "name": "Momo", "age": 1, "happy": true, "tags": ["a", "b"], "none": nil,
        ]
        let parsed = try JSONValue.parse(value.jsonString)
        #expect(parsed == value)
        #expect(parsed["age"]?.intValue == 1)
        #expect(parsed["happy"]?.boolValue == true)
    }

    @Test("treats empty arguments as an empty object")
    func emptyArguments() throws {
        #expect(try JSONValue.parse("  ") == .object([:]))
    }

    @Test("encodes whole numbers without a fraction")
    func wholeNumbers() {
        #expect(JSONValue.number(3).jsonString == "3")
        #expect(JSONValue.number(2.5).jsonString == "2.5")
    }
}
