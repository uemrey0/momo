import Foundation
import Testing

@testable import MomoKit

@Suite("ProcessRunner")
struct ProcessRunnerTests {
    @Test("returns output and the exit status")
    func output() async throws {
        let result = try await ProcessRunner.run(
            "/bin/sh", arguments: ["-c", "echo hello; echo oops >&2; exit 3"])
        #expect(result.status == 3)
        #expect(result.output.contains("hello"))
        #expect(result.output.contains("oops"))
        #expect(!result.timedOut)
    }

    @Test("stops a process that runs past its timeout")
    func timeout() async throws {
        let start = Date()
        let result = try await ProcessRunner.run(
            "/bin/sh", arguments: ["-c", "sleep 30"], timeout: 0.5)
        #expect(result.timedOut)
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test("doesn't wait for background children holding the output open")
    func backgroundChild() async throws {
        let start = Date()
        let result = try await ProcessRunner.run(
            "/bin/sh", arguments: ["-c", "sleep 5 & echo started"], timeout: 20)
        #expect(result.status == 0)
        #expect(result.output.contains("started"))
        #expect(Date().timeIntervalSince(start) < 4)
    }

    @Test("caps the output it keeps")
    func outputLimit() async throws {
        let result = try await ProcessRunner.run(
            "/bin/sh", arguments: ["-c", "yes | head -c 100000"], outputLimit: 1000)
        #expect(result.output.utf8.count == 1000)
        #expect(result.truncated)
    }

    @Test("throws when the executable is missing")
    func missing() async {
        await #expect(throws: (any Error).self) {
            try await ProcessRunner.run("/nonexistent/tool", arguments: [])
        }
    }
}
