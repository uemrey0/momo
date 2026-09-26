import Foundation

/// Serves canned HTTP responses per host and records the requests. Each test uses its own
/// host so tests can run in parallel.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        var status: Int
        var body: Data

        init(status: Int = 200, body: String) {
            self.status = status
            self.body = Data(body.utf8)
        }
    }

    /// A request as the server saw it.
    struct Recorded {
        var request: URLRequest
        var body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var queues: [String: [Response]] = [:]
    nonisolated(unsafe) private static var recorded: [String: [Recorded]] = [:]

    /// Returns a session and a base URL whose requests get `responses` in order.
    static func session(responses: [Response]) -> (URLSession, URL) {
        let host = "mock-\(UUID().uuidString.lowercased()).test"
        lock.lock()
        queues[host] = responses
        recorded[host] = []
        lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let url = URL(string: "https://\(host)/v1") ?? URL(fileURLWithPath: "/")
        return (URLSession(configuration: configuration), url)
    }

    static func requests(for url: URL) -> [Recorded] {
        lock.lock()
        defer { lock.unlock() }
        return recorded[url.host() ?? ""] ?? []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let host = request.url?.host() ?? ""
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            body = data
        }
        Self.lock.lock()
        Self.recorded[host, default: []].append(Recorded(request: request, body: body ?? Data()))
        let response = Self.queues[host]?.isEmpty == false ? Self.queues[host]?.removeFirst() : nil
        Self.lock.unlock()

        let reply = response ?? Response(status: 500, body: "no more mock responses")
        guard let url = request.url,
            let http = HTTPURLResponse(
                url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"])
        else { return }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
