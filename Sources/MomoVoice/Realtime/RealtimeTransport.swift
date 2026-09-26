import Foundation

/// Opens realtime connections with `URLSessionWebSocketTask`.
public struct URLSessionRealtimeTransportFactory: RealtimeTransportFactory {
    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func connect(_ request: URLRequest) async throws -> any RealtimeTransport {
        let task = session.webSocketTask(with: request)
        // Audio deltas are small, but session events echo the whole configuration.
        task.maximumMessageSize = 16 * 1024 * 1024
        task.resume()
        return URLSessionRealtimeTransport(task: task)
    }
}

/// A realtime connection over `URLSessionWebSocketTask`. The handshake runs in the
/// background; its failure surfaces from the first ``send(_:)`` or ``receive()``.
final class URLSessionRealtimeTransport: RealtimeTransport {
    let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(_ text: String) async throws {
        do {
            try await task.send(.string(text))
        } catch {
            throw mapped(error)
        }
    }

    func receive() async throws -> RealtimeTransportMessage {
        do {
            switch try await task.receive() {
            case .string(let text): return .text(text)
            case .data(let data): return .data(data)
            @unknown default: return .text("")
            }
        } catch {
            throw mapped(error)
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }

    private func mapped(_ error: any Error) -> any Error {
        let reason = task.closeReason.map { String(decoding: $0, as: UTF8.self) } ?? ""
        let status = (task.response as? HTTPURLResponse)?.statusCode
        return Self.map(
            error, closeCode: task.closeCode == .invalid ? nil : task.closeCode.rawValue,
            closeReason: reason, handshakeStatus: status)
    }

    /// Turns a socket failure into a ``CloudVoiceError``, or `CancellationError` when Momo
    /// closed the socket itself.
    static func map(
        _ error: any Error, closeCode: Int?, closeReason: String, handshakeStatus: Int?
    ) -> any Error {
        let nsError = error as NSError
        let code =
            (error as? URLError)?.code
            ?? (nsError.domain == NSURLErrorDomain
                ? URLError.Code(rawValue: nsError.code) : .unknown)
        if code == .cancelled || error is CancellationError {
            return CancellationError()
        }
        if let handshakeStatus, handshakeStatus >= 400 {
            return CloudVoiceError.http(status: handshakeStatus, body: Data())
        }
        if let closeCode {
            return RealtimeErrors.closed(code: closeCode, reason: closeReason)
        }
        switch code {
        case .timedOut:
            return RealtimeErrors.timedOut
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed:
            return RealtimeErrors.noConnection
        case .userAuthenticationRequired:
            return CloudVoiceError(status: 401, "The API key was rejected. Check it in Settings.")
        default:
            if nsError.domain == NSPOSIXErrorDomain, nsError.code == 57 {
                // "Socket is not connected": the server went away.
                return RealtimeErrors.noConnection
            }
            return CloudVoiceError(
                "The live voice connection failed: \(error.localizedDescription)")
        }
    }
}
