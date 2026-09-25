import Foundation

/// Serves canned HTTP responses per host, recording request bodies. Each test uses its own
/// host so tests can run in parallel.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        var status: Int = 200
        var body: String
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var queues: [String: [Response]] = [:]
    nonisolated(unsafe) private static var bodies: [String: [String]] = [:]

    /// Returns a session and a unique host whose requests get `responses` in order.
    static func session(responses: [Response]) -> (URLSession, String) {
        let host = "mock-\(UUID().uuidString.lowercased()).test"
        lock.lock()
        queues[host] = responses
        bodies[host] = []
        lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return (URLSession(configuration: configuration), host)
    }

    static func requestBodies(host: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return bodies[host] ?? []
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
        Self.bodies[host, default: []].append(String(decoding: body ?? Data(), as: UTF8.self))
        let response = Self.queues[host]?.isEmpty == false ? Self.queues[host]?.removeFirst() : nil
        Self.lock.unlock()

        let reply = response ?? Response(status: 500, body: "no more mock responses")
        guard let url = request.url,
            let http = HTTPURLResponse(
                url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"])
        else { return }
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Formats SSE `data:` lines.
func sse(_ events: [String], named names: [String]? = nil) -> String {
    events.enumerated().map { index, data in
        if let names { return "event: \(names[index])\ndata: \(data)\n\n" }
        return "data: \(data)\n\n"
    }.joined()
}
