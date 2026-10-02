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
    ///
    /// Temporary failures (see `RetryPolicy`) are retried before any of the body has been
    /// passed on, so a retry never repeats text the caller already showed.
    static func streamLines(
        session: URLSession, url: URL, headers: [String: String], body: JSONValue,
        retry: RetryPolicy = .standard
    ) async throws -> AsyncThrowingStream<String, any Error> {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = Data(body.jsonString.utf8)

        let bytes = try await openStream(session: session, request: request, retry: retry)
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

    /// Sends `request` until it gets a 2xx response or a failure that isn't worth retrying.
    private static func openStream(
        session: URLSession, request: URLRequest, retry: RetryPolicy
    ) async throws -> URLSession.AsyncBytes {
        var attempt = 1
        while true {
            let (bytes, response) = try await session.bytes(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            if (200..<300).contains(status) { return bytes }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 64_000 { break }
            }
            let failure = error(status: status, body: data)
            guard RetryPolicy.retryableStatuses.contains(status), attempt < retry.attempts else {
                throw failure
            }
            let requested = http.flatMap { retryAfter(in: $0) }
            if let requested, requested > retry.maximumDelay {
                let seconds = Int(requested.components.seconds)
                throw ProviderError(
                    failure.message
                        + " The provider asked to wait \(seconds) seconds before trying again.")
            }
            try Task.checkCancellation()
            try await retry.sleep(requested ?? retry.backoff(afterAttempt: attempt))
            try Task.checkCancellation()
            attempt += 1
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
        if status == 413 || (status != 429 && isContextOverflow(text)) {
            return ProviderError(
                "This conversation has grown too large for the brain (\(status)). "
                    + "Start a new conversation, or send fewer or smaller attachments. \(detail)")
        }
        switch status {
        case 401, 403:
            return ProviderError(
                "The API key was rejected (\(status)). Check it in Settings. \(detail)")
        case 404:
            return ProviderError("The model or endpoint was not found (404). \(detail)")
        case 429:
            return ProviderError("Rate limit or quota reached (429). Try again shortly. \(detail)")
        case 529:
            return ProviderError("The provider is overloaded (529). Try again shortly. \(detail)")
        case 500...:
            return ProviderError("The provider had a server error (\(status)). \(detail)")
        default:
            return ProviderError("Request failed (\(status)). \(detail)")
        }
    }
}

extension HTTP {
    /// When and how often `streamLines` retries a request that failed with a temporary error.
    struct RetryPolicy: Sendable {
        /// Statuses worth another try: timeouts, rate limits, overload and gateway errors.
        static let retryableStatuses: Set<Int> = [408, 429, 500, 502, 503, 504, 529]
        static let standard = RetryPolicy()

        /// How many requests to make in total.
        var attempts = 3
        /// The wait before the first retry; it doubles for each later one.
        var baseDelay: Duration = .seconds(1)
        /// The longest wait. When the server asks for longer, the request fails instead.
        var maximumDelay: Duration = .seconds(20)
        var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }

        /// Exponential backoff with jitter: between half and all of `baseDelay × 2^(n-1)`.
        func backoff(afterAttempt attempt: Int) -> Duration {
            let full = baseDelay * (1 << (attempt - 1))
            return min(full * Double.random(in: 0.5...1), maximumDelay)
        }
    }

    /// How long a response asks the client to wait, from `retry-after-ms` or `Retry-After`
    /// (seconds or an HTTP date).
    static func retryAfter(in response: HTTPURLResponse, now: Date = Date()) -> Duration? {
        if let value = response.value(forHTTPHeaderField: "retry-after-ms"),
            let milliseconds = Double(value.trimmingCharacters(in: .whitespaces)), milliseconds >= 0
        {
            return .milliseconds(milliseconds)
        }
        guard
            let value = response.value(forHTTPHeaderField: "Retry-After")?
                .trimmingCharacters(in: .whitespaces)
        else { return nil }
        if let seconds = Double(value), seconds >= 0 { return .seconds(seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return .seconds(max(0, date.timeIntervalSince(now)))
    }
}

extension HTTP {
    /// Error fragments providers use when a request doesn't fit the model's context.
    static let contextOverflowHints = [
        "prompt is too long", "context_length_exceeded", "maximum context length",
        "context window", "request too large",
    ]

    /// Whether an error body says the request was larger than the model can take.
    static func isContextOverflow(_ body: String) -> Bool {
        let body = body.lowercased()
        return contextOverflowHints.contains { body.contains($0) }
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
