import Foundation
import Testing

@testable import MomoBrain

@Suite("CommandRunner")
struct CommandRunnerTests {
    private static let shell = URL(fileURLWithPath: "/bin/sh")

    private static func collect(
        _ executable: URL, _ arguments: [String], input: String? = nil
    ) async throws -> [String] {
        var lines: [String] = []
        for try await line in CommandRunner.lines(
            executable: executable, arguments: arguments, input: input)
        {
            lines.append(line)
        }
        return lines
    }

    @Test("streams output lines and feeds the input")
    func output() async throws {
        let lines = try await Self.collect(Self.shell, ["-c", "cat; echo done"], input: "a\nb\n")
        #expect(lines == ["a", "b", "done"])
    }

    @Test("reports a non-zero exit status with standard error")
    func exitStatus() async throws {
        do {
            _ = try await Self.collect(Self.shell, ["-c", "echo nope >&2; exit 3"])
            Issue.record("Expected a failure")
        } catch let failure as CommandRunner.Failure {
            #expect(failure.status == 3)
            #expect(failure.signal == nil)
            #expect(failure.standardError.contains("nope"))
        }
    }

    @Test("reports a command killed by a signal as a failure naming the signal")
    func crash() async throws {
        do {
            _ = try await Self.collect(Self.shell, ["-c", "echo partial; kill -SEGV $$"])
            Issue.record("Expected a failure")
        } catch let failure as CommandRunner.Failure {
            #expect(failure.signal == SIGSEGV)
            #expect(failure.signalDescription?.contains("signal \(SIGSEGV)") == true)
            #expect(
                CLIPrompt.describe(failure, tool: "Codex").contains("signal \(SIGSEGV)"))
        }
    }

    @Test("fails without crashing when the command exits before reading its input")
    func unreadInput() async throws {
        let input = String(repeating: "x", count: 2_000_000)
        await #expect(throws: ProviderError.self) {
            _ = try await Self.collect(URL(fileURLWithPath: "/usr/bin/true"), [], input: input)
        }
    }

    @Test("prefers the command's own failure over the unread input")
    func failureBeforeInput() async throws {
        let input = String(repeating: "x", count: 2_000_000)
        do {
            _ = try await Self.collect(
                Self.shell, ["-c", "echo expired >&2; exit 2"], input: input)
            Issue.record("Expected a failure")
        } catch let failure as CommandRunner.Failure {
            #expect(failure.status == 2)
            #expect(failure.standardError.contains("expired"))
        }
    }

    @Test("finishes cleanly when cancelled")
    func cancel() async throws {
        let start = Date()
        let task = Task {
            try await Self.collect(
                Self.shell, ["-c", "echo started; exec sleep 30"],
                input: String(repeating: "x", count: 1_000_000))
        }
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        _ = try await task.value
        #expect(Date().timeIntervalSince(start) < 10)
    }
}
