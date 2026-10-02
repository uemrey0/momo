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
        /// The signal that ended the command, when something other than Momo stopped it.
        var signal: Int32? = nil

        /// The signal's name and number, such as "Segmentation fault, signal 11".
        var signalDescription: String? {
            signal.map { "\(String(cString: strsignal($0))), signal \($0)" }
        }
    }

    /// Writes input to commands off the Swift concurrency pool, since a write blocks until
    /// the command reads it.
    private static let inputQueue = DispatchQueue(
        label: "momo.command-runner.input", qos: .userInitiated, attributes: .concurrent)

    /// Streams standard output lines. Finishes with `Failure` when the command exits with a
    /// non-zero status or is killed by a signal, and with `ProviderError` when it exits
    /// before taking all of its input. Cancelling the stream terminates the process and
    /// finishes the stream cleanly.
    static func lines(
        executable: URL, arguments: [String], input: String?, workingDirectory: URL? = nil,
        environment extraEnvironment: [String: String] = [:], closesInput: Bool = true
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
            // Writing to a command that already exited must fail with an error, not end Momo
            // with SIGPIPE.
            _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

            let buffer = LockedValue(Data())
            let errors = LockedValue(Data())
            let cancelled = LockedValue(false)
            let inputError = LockedValue<(any Error)?>(nil)
            let writing = DispatchGroup()
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
                // The readability handler may not have seen the last of standard error yet, so
                // read it to the end before a failure reports it.
                let errorRest = stderr.fileHandleForReading.readDataToEndOfFile()
                errors.withLock { data in
                    if data.count < 32_000 { data.append(errorRest) }
                }
                let status = process.terminationStatus
                let killed = process.terminationReason == .uncaughtSignal
                // The input writer fails soon after the command exits; wait for it so a failed
                // write is reported only when the command itself didn't fail.
                writing.notify(queue: inputQueue) {
                    if cancelled.withLock({ $0 }) {
                        continuation.finish()
                    } else if status != 0 || killed {
                        let message = errors.withLock { String(decoding: $0, as: UTF8.self) }
                        continuation.finish(
                            throwing: Failure(
                                status: status, standardError: message,
                                signal: killed ? status : nil))
                    } else if let error = inputError.withLock({ $0 }) {
                        continuation.finish(
                            throwing: ProviderError(
                                "\(executable.lastPathComponent) stopped before reading the whole "
                                    + "request (\(error.localizedDescription))."))
                    } else {
                        continuation.finish()
                    }
                }
            }
            continuation.onTermination = { _ in
                guard process.isRunning else { return }
                cancelled.withLock { $0 = true }
                process.terminate()
            }

            writing.enter()
            do {
                try process.run()
            } catch {
                writing.leave()
                continuation.finish(throwing: error)
                return
            }
            inputQueue.async {
                defer { writing.leave() }
                do {
                    if let input {
                        try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
                    }
                } catch {
                    inputError.withLock { $0 = error }
                }
                if closesInput { try? stdin.fileHandleForWriting.close() }
            }
        }
    }
}
