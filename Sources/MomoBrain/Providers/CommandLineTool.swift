import Foundation

/// Finds command line tools the user installed. Apps launched from Finder get a minimal
/// `PATH`, so this checks common install locations and falls back to the login shell.
public enum CommandLocator {
    /// Directories where npm, Homebrew and friends usually put executables.
    static var candidateDirectories: [String] {
        let home = NSHomeDirectory()
        return [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "\(home)/.local/bin",
            "\(home)/.npm-global/bin", "\(home)/.bun/bin", "\(home)/.volta/bin",
            "\(home)/Library/pnpm", "\(home)/.yarn/bin",
        ]
    }

    /// Returns the path of an executable, or `nil` when it is not installed.
    public static func locate(_ name: String) -> URL? {
        for directory in candidateDirectories + searchPath.split(separator: ":").map(String.init) {
            let path = (directory as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    /// The user's login shell `PATH`, so child processes (often Node scripts) find their
    /// interpreters. Cached after the first call.
    public static var searchPath: String {
        cachedPath.withLock { cached in
            if let cached { return cached }
            let path = readLoginShellPath() ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
            let merged = (candidateDirectories + path.split(separator: ":").map(String.init))
                .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                .joined(separator: ":")
            cached = merged
            return merged
        }
    }

    private static let cachedPath = LockedValue<String?>(nil)

    private static func readLoginShellPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-c", "printf %s \"$PATH\""]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning {
            process.terminate()
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let path = String(decoding: data, as: UTF8.self)
        return path.isEmpty ? nil : path
    }
}

/// A value protected by a lock, usable from any thread.
final class LockedValue<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// Runs a command, feeds it input and streams its output line by line.
enum CommandRunner {
    struct Failure: Error {
        var status: Int32
        var standardError: String
    }

    /// Streams standard output lines. Finishes with `Failure` when the command exits with a
    /// non-zero status. Cancelling the stream terminates the process.
    static func lines(
        executable: URL, arguments: [String], input: String?, workingDirectory: URL? = nil,
        environment extraEnvironment: [String: String] = [:]
    ) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = CommandLocator.searchPath
            environment["NO_COLOR"] = "1"
            environment.merge(extraEnvironment) { _, new in new }
            process.environment = environment
            if let workingDirectory {
                try? FileManager.default.createDirectory(
                    at: workingDirectory, withIntermediateDirectories: true)
                process.currentDirectoryURL = workingDirectory
            }

            let stdout = Pipe()
            let stderr = Pipe()
            let stdin = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = stdin

            let buffer = LockedValue(Data())
            let errors = LockedValue(Data())
            stdout.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else { return }
                let lines: [String] = buffer.withLock { data in
                    data.append(chunk)
                    var lines: [String] = []
                    while let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
                        lines.append(
                            String(decoding: data[data.startIndex..<newline], as: UTF8.self))
                        data.removeSubrange(data.startIndex...newline)
                    }
                    return lines
                }
                for line in lines { continuation.yield(line) }
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                errors.withLock { data in
                    if data.count < 32_000 { data.append(chunk) }
                }
            }
            process.terminationHandler = { process in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                let rest = buffer.withLock { data -> String in
                    data.append(stdout.fileHandleForReading.readDataToEndOfFile())
                    defer { data = Data() }
                    return String(decoding: data, as: UTF8.self)
                }
                for line in rest.split(separator: "\n") { continuation.yield(String(line)) }
                if process.terminationStatus == 0 || process.terminationReason == .uncaughtSignal {
                    continuation.finish()
                } else {
                    let message = errors.withLock { String(decoding: $0, as: UTF8.self) }
                    continuation.finish(
                        throwing: Failure(
                            status: process.terminationStatus, standardError: message))
                }
            }

            do {
                try process.run()
                if let input {
                    stdin.fileHandleForWriting.write(Data(input.utf8))
                }
                try? stdin.fileHandleForWriting.close()
            } catch {
                continuation.finish(throwing: error)
            }
            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }
        }
    }
}
