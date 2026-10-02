import Foundation
import MomoKit
import Testing

@testable import MomoApp

@MainActor
@Suite("Update checker")
struct UpdateCheckerTests {
    private static func release(
        _ tag: String, draft: Bool = false, prerelease: Bool? = nil
    ) -> UpdateChecker.PublishedRelease {
        UpdateChecker.PublishedRelease(
            tag: tag, url: URL(literal: "https://github.com/uemrey0/momo/releases"),
            isDraft: draft, isPrerelease: prerelease ?? tag.contains("-"))
    }

    private static func offer(
        _ current: String, _ releases: [UpdateChecker.PublishedRelease]
    ) throws -> String? {
        let version = try #require(SemanticVersion(current))
        return UpdateChecker.update(for: version, among: releases)?.version
    }

    @Test("a beta user is offered a newer beta")
    func betaSeesNewerBeta() throws {
        let releases = [
            Self.release("v0.2.0-beta.3"), Self.release("v0.2.0-beta.2"),
            Self.release("v0.1.0"),
        ]
        #expect(try Self.offer("0.2.0-beta.2", releases) == "0.2.0-beta.3")
    }

    @Test("a beta user is offered a newer stable release")
    func betaSeesNewerStable() throws {
        let releases = [Self.release("v0.2.0"), Self.release("v0.2.0-beta.3")]
        #expect(try Self.offer("0.2.0-beta.2", releases) == "0.2.0")
    }

    @Test("a stable user is never offered a pre-release")
    func stableIgnoresPrereleases() throws {
        let releases = [
            Self.release("v0.3.0-beta.1"), Self.release("v0.2.1", prerelease: true),
            Self.release("v0.2.0"),
        ]
        #expect(try Self.offer("0.1.0", releases) == "0.2.0")
        #expect(try Self.offer("0.2.0", releases) == nil)
    }

    @Test("drafts are ignored")
    func draftsIgnored() throws {
        let releases = [Self.release("v0.3.0", draft: true), Self.release("v0.2.0-beta.3")]
        #expect(try Self.offer("0.2.0-beta.2", releases) == "0.2.0-beta.3")
        #expect(try Self.offer("0.2.0", releases) == nil)
    }

    @Test("an equal or older version offers nothing")
    func equalOrOlderOffersNothing() throws {
        #expect(try Self.offer("0.2.0-beta.2", [Self.release("v0.2.0-beta.2")]) == nil)
        #expect(
            try Self.offer("0.2.0-beta.2", [Self.release("v0.2.0-beta.1"), Self.release("v0.1.0")])
                == nil)
        #expect(try Self.offer("0.2.0", [Self.release("v0.2.0"), Self.release("v0.1.0")]) == nil)
        #expect(try Self.offer("0.2.0", []) == nil)
    }

    @Test("GitHub's release list is parsed, keeping draft and pre-release flags")
    func parsesList() throws {
        let json = """
            [{"tag_name": "v0.2.0-beta.2", "html_url": "https://example.com/b2", \
            "draft": false, "prerelease": true},
             {"tag_name": "v0.3.0", "html_url": "https://example.com/d", "draft": true}]
            """
        let releases = try #require(UpdateChecker.parseReleases(Data(json.utf8)))
        #expect(releases.map(\.tag) == ["v0.2.0-beta.2", "v0.3.0"])
        #expect(releases.map(\.isPrerelease) == [true, false])
        #expect(releases.map(\.isDraft) == [false, true])
        #expect(UpdateChecker.parseReleases(Data("nope".utf8)) == nil)
    }

    @Test("a failed check is not recorded, so it is retried")
    func failedCheckNotRecorded() async throws {
        let defaults = try #require(
            UserDefaults(suiteName: "momo-update-tests-\(UUID().uuidString)"))
        let checker = UpdateChecker(
            settings: AppSettings(defaults: defaults), defaults: defaults,
            currentVersion: "0.2.0-beta.2"
        ) { _ in throw URLError(.notConnectedToInternet) }
        await checker.check()
        #expect(defaults.object(forKey: "lastUpdateCheck") == nil)
        guard case .failed = checker.status else {
            Issue.record("Expected a failure, got \(checker.status)")
            return
        }
    }

    @Test("a successful check is recorded and reports the update")
    func successfulCheck() async throws {
        let defaults = try #require(
            UserDefaults(suiteName: "momo-update-tests-\(UUID().uuidString)"))
        let body = Data(
            #"[{"tag_name": "v0.2.0-beta.3", "html_url": "https://example.com/b3", "prerelease": true}]"#
                .utf8)
        let checker = UpdateChecker(
            settings: AppSettings(defaults: defaults), defaults: defaults,
            currentVersion: "0.2.0-beta.2"
        ) { request in
            #expect(request.url?.path == "/repos/uemrey0/momo/releases")
            let url = try #require(request.url)
            let response = try #require(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (body, response)
        }
        await checker.check()
        #expect(defaults.object(forKey: "lastUpdateCheck") != nil)
        #expect(checker.status == .updateAvailable)
        #expect(checker.availableUpdate?.version == "0.2.0-beta.3")
    }
}
