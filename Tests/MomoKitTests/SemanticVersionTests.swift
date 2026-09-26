import Testing

@testable import MomoKit

@Suite("SemanticVersion")
struct SemanticVersionTests {
    @Test("parses tags leniently")
    func parses() {
        #expect(SemanticVersion("v1.2.3")?.description == "1.2.3")
        #expect(SemanticVersion("0.2")?.description == "0.2.0")
        #expect(SemanticVersion("1.0.0-beta.2")?.prerelease == "beta.2")
        #expect(SemanticVersion("latest") == nil)
        #expect(SemanticVersion("1.2.3.4") == nil)
    }

    @Test("orders versions and pre-releases")
    func orders() throws {
        let versions = ["0.1.0", "0.1.1", "0.2.0-beta.2", "0.2.0-beta.10", "0.2.0", "1.0.0"]
            .compactMap(SemanticVersion.init)
        #expect(versions == versions.sorted())
        #expect(try #require(SemanticVersion("v1.10.0")) > #require(SemanticVersion("1.9.9")))
        #expect(!(try #require(SemanticVersion("1.0.0")) < #require(SemanticVersion("v1.0.0"))))
    }
}
