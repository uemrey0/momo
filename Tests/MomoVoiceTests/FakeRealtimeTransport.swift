import Foundation

@testable import MomoVoice

/// A WebSocket stand-in: records what the session sends and delivers scripted server
/// messages.
final class FakeRealtimeTransport: RealtimeTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [String] = []
    private var inbox: [Result<RealtimeTransportMessage, any Error>] = []
    private var waiter: CheckedContinuation<RealtimeTransportMessage, any Error>?
    private var reply: (@Sendable (String) -> [String])?
    private(set) var isClosed = false

    /// Answers each sent message with server messages, e.g. `session.updated` for
    /// `session.update`.
    func autoReply(_ reply: @escaping @Sendable (String) -> [String]) {
        lock.withLock { self.reply = reply }
    }

    var sentMessages: [String] { lock.withLock { sent } }

    /// The sent messages parsed as JSON objects.
    var sentObjects: [[String: Any]] {
        sentMessages.compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
        }
    }

    func send(_ text: String) async throws {
        let reply = lock.withLock {
            sent.append(text)
            return self.reply
        }
        for message in reply?(text) ?? [] { push(message) }
    }

    func receive() async throws -> RealtimeTransportMessage {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if isClosed {
                lock.unlock()
                continuation.resume(throwing: CancellationError())
            } else if !inbox.isEmpty {
                let next = inbox.removeFirst()
                lock.unlock()
                continuation.resume(with: next)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func close() {
        let waiter = lock.withLock {
            isClosed = true
            defer { self.waiter = nil }
            return self.waiter
        }
        waiter?.resume(throwing: CancellationError())
    }

    /// Delivers a server message.
    func push(_ text: String) {
        deliver(.success(.text(text)))
    }

    /// Delivers a binary server message, as Gemini sends them.
    func pushData(_ text: String) {
        deliver(.success(.data(Data(text.utf8))))
    }

    /// Fails the connection, as a dropped socket or a close frame would.
    func fail(_ error: any Error) {
        deliver(.failure(error))
    }

    private func deliver(_ result: Result<RealtimeTransportMessage, any Error>) {
        lock.lock()
        if let waiter {
            self.waiter = nil
            lock.unlock()
            waiter.resume(with: result)
        } else {
            inbox.append(result)
            lock.unlock()
        }
    }

    /// Waits until at least `count` messages were sent.
    func waitForSent(_ count: Int) async {
        for _ in 0..<400 where sentMessages.count < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Hands out one fake transport and remembers the request.
final class FakeRealtimeTransportFactory: RealtimeTransportFactory, @unchecked Sendable {
    let transport = FakeRealtimeTransport()
    private let lock = NSLock()
    private var failure: (any Error)?
    private var requests: [URLRequest] = []

    init(failure: (any Error)? = nil) {
        self.failure = failure
    }

    var lastRequest: URLRequest? { lock.withLock { requests.last } }

    func connect(_ request: URLRequest) async throws -> any RealtimeTransport {
        let failure = lock.withLock {
            requests.append(request)
            return self.failure
        }
        if let failure { throw failure }
        return transport
    }
}

/// Reads events until one matches. Suites set a time limit, so a missing event fails
/// instead of hanging.
func nextEvent(
    _ events: inout AsyncStream<RealtimeEvent>.Iterator,
    where matches: (RealtimeEvent) -> Bool = { _ in true }
) async -> RealtimeEvent? {
    while let event = await events.next() {
        if matches(event) { return event }
    }
    return nil
}
