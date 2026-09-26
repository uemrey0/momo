import Darwin
import Foundation
import MomoLiveProtocol

/// Carries protocol lines to and from the `momo-voice` helper.
@MainActor
public protocol LiveVoiceTransport: AnyObject {
    /// Starts the helper. `onData` receives its standard output as it arrives, and `onExit`
    /// is called once when it ends, both on the main actor.
    func launch(onData: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws
    /// Writes to the helper's standard input.
    func write(_ data: Data) throws
    /// Ends the helper at once.
    func terminate()
}

/// Runs the helper as a child process and talks to it over standard input and output.
@MainActor
public final class ProcessLiveVoiceTransport: LiveVoiceTransport {
    private let executableURL: URL
    private let arguments: [String]
    private var process: Process?
    private var input: Pipe?

    public init(executableURL: URL, arguments: [String] = []) {
        self.executableURL = executableURL
        self.arguments = arguments
    }

    public func launch(onData: @escaping (Data) -> Void, onExit: @escaping (Int32) -> Void) throws {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // Writing to a helper that died must fail with an error, not end Momo with SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        output.fileHandleForReading.readabilityHandler = Self.makeReader(
            Self.relay(onData))
        process.terminationHandler = Self.makeTerminationHandler(Self.relay(onExit))
        try process.run()
        self.process = process
        self.input = input
    }

    public func write(_ data: Data) throws {
        guard let input else { throw LiveVoiceHelperError.notRunning }
        try input.fileHandleForWriting.write(contentsOf: data)
    }

    public func terminate() {
        try? input?.fileHandleForWriting.close()
        if let process, process.isRunning { process.terminate() }
        process = nil
        input = nil
    }

    // These callbacks run on background threads, so they must not inherit main actor
    // isolation.

    private nonisolated static func relay<Value: Sendable>(
        _ handle: @escaping (Value) -> Void
    ) -> @Sendable (Value) -> Void {
        nonisolated(unsafe) let handle = handle
        return { value in Task { @MainActor in handle(value) } }
    }

    private nonisolated static func makeReader(
        _ deliver: @escaping @Sendable (Data) -> Void
    ) -> @Sendable (FileHandle) -> Void {
        { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                deliver(data)
            }
        }
    }

    private nonisolated static func makeTerminationHandler(
        _ exited: @escaping @Sendable (Int32) -> Void
    ) -> @Sendable (Process) -> Void {
        { process in exited(process.terminationStatus) }
    }
}

/// Why the helper could not be used.
public enum LiveVoiceHelperError: LocalizedError, Equatable {
    case notRunning
    case noAnswer
    case incompatible(version: Int)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning: "The voice helper is not running."
        case .noAnswer: "The voice helper did not answer."
        case .incompatible(let version):
            "The voice helper speaks protocol version \(version), but Momo needs version \(liveVoiceProtocolVersion). Update Momo."
        case .failed(let message): message
        }
    }
}

/// What the helper client tells its observers.
public enum LiveVoiceClientMessage: Sendable, Equatable {
    /// An event from the helper.
    case event(LiveVoiceEvent)
    /// The helper went away; `crashed` when nobody asked it to.
    case disconnected(crashed: Bool)
}

/// Starts the `momo-voice` helper, performs the handshake and passes messages both ways.
///
/// Several parts of Momo share one helper (a live session, the model list in Settings), so
/// they ``acquire()`` it while they need it and ``release()`` it afterwards; the helper quits
/// a little after the last one lets go. A helper that dies is started again on the next use.
@MainActor
public final class LiveVoiceHelperClient {
    /// The conversation languages the helper can serve, from its handshake.
    public private(set) var languages: [String] = []
    public var isConnected: Bool { transport != nil && isReady }

    private let makeTransport: () -> any LiveVoiceTransport
    private let handshakeTimeout: Duration
    private let idleDelay: Duration
    private var transport: (any LiveVoiceTransport)?
    private var isReady = false
    private var isQuitting = false
    private var lineBuffer = LiveVoiceLineBuffer()
    private var observers: [UUID: (LiveVoiceClientMessage) -> Void] = [:]
    private var handshake: CheckedContinuation<Void, any Error>?
    private var connecting: Task<Void, any Error>?
    private var users = 0
    private var idleTimer: Task<Void, Never>?

    /// - Parameters:
    ///   - makeTransport: Creates a fresh transport for each launch.
    ///   - handshakeTimeout: How long the helper may take to say it is ready.
    ///   - idleDelay: How long the helper keeps running after the last user let go.
    public init(
        handshakeTimeout: Duration = .seconds(5), idleDelay: Duration = .seconds(20),
        makeTransport: @escaping () -> any LiveVoiceTransport
    ) {
        self.handshakeTimeout = handshakeTimeout
        self.idleDelay = idleDelay
        self.makeTransport = makeTransport
    }

    /// A client for the helper executable at `url`.
    public convenience init(executableURL url: URL) {
        self.init { ProcessLiveVoiceTransport(executableURL: url) }
    }

    /// Whether the helper can run on this Mac: macOS 15 or later on Apple silicon.
    public static var isSupportedOnThisMac: Bool {
        guard
            ProcessInfo.processInfo.isOperatingSystemAtLeast(
                OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
        else { return false }
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    /// Registers `handler` for messages; keep the token and pass it to ``removeObserver(_:)``.
    public func addObserver(_ handler: @escaping (LiveVoiceClientMessage) -> Void) -> UUID {
        let token = UUID()
        observers[token] = handler
        return token
    }

    public func removeObserver(_ token: UUID) {
        observers[token] = nil
    }

    /// Marks the helper as in use, so it keeps running.
    public func acquire() {
        users += 1
        idleTimer?.cancel()
        idleTimer = nil
    }

    /// Lets go of the helper; it quits after a while when nobody uses it.
    public func release() {
        users = max(0, users - 1)
        guard users == 0, transport != nil else { return }
        idleTimer?.cancel()
        let delay = idleDelay
        idleTimer = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, self.users == 0 else { return }
            self.disconnect()
        }
    }

    /// Starts the helper if needed and waits for its handshake.
    public func connect() async throws {
        if isConnected { return }
        if let connecting { return try await connecting.value }
        let task = Task { try await self.launchAndGreet() }
        connecting = task
        defer { connecting = nil }
        try await task.value
    }

    private func launchAndGreet() async throws {
        let transport = makeTransport()
        self.transport = transport
        isReady = false
        isQuitting = false
        lineBuffer = LiveVoiceLineBuffer()
        do {
            try transport.launch(
                onData: { [weak self, weak transport] data in
                    guard let self, let transport, transport === self.transport else { return }
                    self.received(data)
                },
                onExit: { [weak self, weak transport] _ in
                    guard let self, let transport, transport === self.transport else { return }
                    self.exited()
                })
            let timeout = handshakeTimeout
            let timer = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled else { return }
                self?.finishHandshake(.failure(LiveVoiceHelperError.noAnswer))
            }
            defer { timer.cancel() }
            try await withCheckedThrowingContinuation { continuation in
                handshake = continuation
                do {
                    try send(.hello(version: liveVoiceProtocolVersion))
                } catch {
                    finishHandshake(.failure(error))
                }
            }
        } catch {
            transport.terminate()
            if self.transport === transport { self.transport = nil }
            throw error
        }
    }

    private func finishHandshake(_ result: Result<Void, any Error>) {
        let continuation = handshake
        handshake = nil
        continuation?.resume(with: result)
    }

    /// Sends a command to a running helper.
    public func send(_ command: LiveVoiceCommand) throws {
        guard let transport else { throw LiveVoiceHelperError.notRunning }
        try transport.write(LiveVoiceCoding.line(command))
    }

    /// Asks the helper to quit and lets it go.
    public func disconnect() {
        idleTimer?.cancel()
        idleTimer = nil
        guard let transport else { return }
        isQuitting = true
        try? send(.quit)
        self.transport = nil
        isReady = false
        finishHandshake(.failure(LiveVoiceHelperError.notRunning))
        // Give it a moment to leave on its own before ending it.
        Task {
            try? await Task.sleep(for: .seconds(2))
            transport.terminate()
        }
        broadcast(.disconnected(crashed: false))
    }

    /// Ends the helper at once, for a helper that is stuck: it may be busy with a command
    /// and not read `quit` until it is done, which for a start that timed out means opening
    /// the microphone while another engine already uses it.
    public func terminate() {
        idleTimer?.cancel()
        idleTimer = nil
        guard let transport else { return }
        isQuitting = true
        self.transport = nil
        isReady = false
        transport.terminate()
        finishHandshake(.failure(LiveVoiceHelperError.notRunning))
        broadcast(.disconnected(crashed: false))
    }

    private func received(_ data: Data) {
        for line in lineBuffer.append(data) {
            guard let event = try? LiveVoiceCoding.decode(LiveVoiceEvent.self, from: line) else {
                continue
            }
            if case .ready(let version, let languages) = event {
                guard version == liveVoiceProtocolVersion else {
                    finishHandshake(.failure(LiveVoiceHelperError.incompatible(version: version)))
                    continue
                }
                self.languages = languages
                isReady = true
                finishHandshake(.success(()))
            }
            broadcast(.event(event))
        }
    }

    private func exited() {
        let crashed = !isQuitting
        transport = nil
        isReady = false
        finishHandshake(.failure(LiveVoiceHelperError.failed("The voice helper quit.")))
        broadcast(.disconnected(crashed: crashed))
    }

    private func broadcast(_ message: LiveVoiceClientMessage) {
        for handler in observers.values { handler(message) }
    }
}
