import Foundation
import MomoKit

/// What a finished process printed and how it ended.
struct ProcessOutput: Sendable {
    /// The exit status, or the signal number when the process was killed.
    var status: Int32
    /// Standard output and standard error, interleaved, decoded as UTF-8.
    var output: String
    /// Whether the process was stopped because it ran past its timeout.
    var timedOut: Bool
    /// Whether output beyond the byte limit was dropped.
    var truncated: Bool
}

/// Runs command line tools off the main thread with a timeout and a cap on the output kept.
enum ProcessRunner {
    /// Runs `executable` and waits for it to finish, at most `timeout` seconds.
    static func run(
        _ executable: String, arguments: [String], currentDirectory: URL? = nil,
        timeout: TimeInterval = 60, outputLimit: Int = 1_000_000
    ) async throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        let run = RunState(outputLimit: outputLimit)

        return try await withCheckedThrowingContinuation { continuation in
            run.start(continuation)
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    handle.readabilityHandler = nil
                    run.reachedEndOfOutput()
                } else {
                    run.append(chunk)
                }
            }
            process.terminationHandler = { process in
                run.exited(status: process.terminationStatus)
                // A background child may keep the pipe open; don't wait for it forever.
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    run.reachedEndOfOutput()
                }
            }
            do {
                try process.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                run.fail(error)
                return
            }
            let processID = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard process.isRunning else { return }
                run.markTimedOut()
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if process.isRunning { kill(processID, SIGKILL) }
                }
            }
        }
    }
}

/// Collects output and resumes the caller once the process exited and its output ended.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private let outputLimit: Int
    private var data = Data()
    private var truncated = false
    private var timedOut = false
    private var status: Int32?
    private var outputEnded = false
    private var continuation: CheckedContinuation<ProcessOutput, any Error>?

    init(outputLimit: Int) {
        self.outputLimit = outputLimit
    }

    func start(_ continuation: CheckedContinuation<ProcessOutput, any Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func append(_ chunk: Data) {
        lock.withLock {
            let room = outputLimit - data.count
            if room >= chunk.count {
                data.append(chunk)
            } else {
                if room > 0 { data.append(chunk.prefix(room)) }
                truncated = true
            }
        }
    }

    func markTimedOut() {
        lock.withLock { timedOut = true }
    }

    func exited(status: Int32) {
        lock.withLock { self.status = status }
        finishIfDone()
    }

    func reachedEndOfOutput() {
        lock.withLock { outputEnded = true }
        finishIfDone()
    }

    func fail(_ error: any Error) {
        let continuation = lock.withLock {
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(throwing: error)
    }

    private func finishIfDone() {
        let result: (CheckedContinuation<ProcessOutput, any Error>, ProcessOutput)? =
            lock.withLock {
                guard let status, outputEnded, let continuation else { return nil }
                self.continuation = nil
                let output = ProcessOutput(
                    status: status, output: String(decoding: data, as: UTF8.self),
                    timedOut: timedOut, truncated: truncated)
                return (continuation, output)
            }
        if let (continuation, output) = result { continuation.resume(returning: output) }
    }
}
