import Foundation
import MomoKit

extension URL {
    /// Creates a URL from a literal that is known to be valid.
    init(literal: StaticString) {
        guard let url = URL(string: "\(literal)") else {
            preconditionFailure("Invalid URL literal: \(literal)")
        }
        self = url
    }
}

/// Small helpers for JSON-over-HTTP providers.
enum HTTP {
    /// Sends a JSON POST and returns the response body as a stream of lines.
    static func streamLines(
        session: URLSession, url: URL, headers: [String: String], body: JSONValue
    ) async throws -> AsyncThrowingStream<String, any Error> {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = Data(body.jsonString.utf8)

        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(status) {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 64_000 { break }
            }
            throw error(status: status, body: data)
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Sends a GET and decodes JSON, with a short timeout. Used for availability checks.
    static func getJSON(
        session: URLSession, url: URL, headers: [String: String] = [:], timeout: TimeInterval = 2
    ) async throws -> JSONValue {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw error(status: status, body: data) }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Turns an HTTP error into a message the user can act on.
    static func error(status: Int, body: Data) -> ProviderError {
        let text = String(decoding: body, as: UTF8.self)
        let parsed = try? JSONValue.parse(text)
        let detail =
            parsed?["error"]?["message"]?.stringValue ?? parsed?["error"]?.stringValue
            ?? parsed?["message"]?.stringValue ?? String(text.prefix(300))
        switch status {
        case 401, 403:
            return ProviderError(
                "The API key was rejected (\(status)). Check it in Settings. \(detail)")
        case 404:
            return ProviderError("The model or endpoint was not found (404). \(detail)")
        case 429:
            return ProviderError("Rate limit or quota reached (429). Try again shortly. \(detail)")
        case 500...:
            return ProviderError("The provider had a server error (\(status)). \(detail)")
        default:
            return ProviderError("Request failed (\(status)). \(detail)")
        }
    }
}

/// Parses Server-Sent Events from a stream of lines.
///
/// `URLSession.AsyncBytes.lines` drops blank lines, so events cannot be delimited by them.
/// Every provider Momo talks to sends one `data:` line per event, so each data line completes
/// an event, named by the most recent `event:` line.
struct ServerSentEventParser {
    struct Event: Equatable {
        var name: String?
        var data: String
    }

    private var name: String?

    /// Feeds one line; returns an event when the line carries data.
    mutating func consume(_ line: String) -> Event? {
        if line.isEmpty || line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }
        switch field {
        case "event":
            name = String(value)
        case "data":
            let event = Event(name: name, data: String(value))
            name = nil
            return event
        default:
            break
        }
        return nil
    }
}
