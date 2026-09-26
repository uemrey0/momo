import Foundation

/// Fetches a web page and returns its readable text for the model.
///
/// Only `http` and `https` addresses on the public internet are fetched: local names and
/// private network addresses are refused, also after redirects, so a page cannot steer Momo
/// into the user's router or intranet. Downloads stop after ``maximumBytes``.
public struct WebPageReader: Sendable {
    /// A browser-like user agent; many sites refuse unknown clients.
    public static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    /// The most characters returned to the model.
    public static let maximumCharacters = 15_000
    /// The most bytes downloaded.
    public static let maximumBytes = 3 * 1024 * 1024

    private let session: URLSession
    private let timeout: TimeInterval

    public init(session: URLSession = .shared, timeout: TimeInterval = 20) {
        self.session = session
        self.timeout = timeout
    }

    /// A fetched page.
    public struct Page: Sendable, Equatable {
        public var url: URL
        public var title: String?
        public var text: String
    }

    /// Fetches `address` and converts it to text.
    public func read(_ address: String) async throws -> Page {
        let url = try Self.validate(address)
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(
            "text/html,application/xhtml+xml,text/plain,application/json;q=0.9,*/*;q=0.5",
            forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request, delegate: RedirectGuard())
        guard let http = response as? HTTPURLResponse else {
            throw ToolError("The page could not be loaded.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ToolError("The page answered with HTTP \(http.statusCode).")
        }
        let type = (http.mimeType ?? "text/html").lowercased()
        guard Self.isReadable(type) else {
            throw ToolError(
                "This link is not a web page (\(type)). Only HTML, text and JSON can be read.")
        }
        var data = Data()
        var truncated = false
        for try await byte in bytes {
            data.append(byte)
            if data.count >= Self.maximumBytes {
                truncated = true
                break
            }
        }
        let text = Self.decode(data, encodingName: http.textEncodingName)
        var page = Self.page(from: text, mimeType: type, url: http.url ?? url)
        if truncated { page.text += "\n\n[The page was too large; only its beginning was read.]" }
        return page
    }

    /// Converts a downloaded body to a page.
    static func page(from body: String, mimeType: String, url: URL) -> Page {
        if mimeType.contains("json") {
            let pretty =
                (try? JSONSerialization.jsonObject(
                    with: Data(body.utf8), options: [.fragmentsAllowed]))
                .flatMap {
                    try? JSONSerialization.data(
                        withJSONObject: $0,
                        options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed])
                }
                .map { String(decoding: $0, as: UTF8.self) } ?? body
            return Page(url: url, title: nil, text: pretty)
        }
        if mimeType.hasPrefix("text/plain") || mimeType.contains("markdown") {
            return Page(url: url, title: nil, text: body)
        }
        let document = HTMLText.document(from: body)
        return Page(url: url, title: document.title, text: document.text)
    }

    /// The page as tool output, truncated to ``maximumCharacters``.
    public static func format(_ page: Page, limit: Int = maximumCharacters) -> String {
        var header = ["URL: \(page.url.absoluteString)"]
        if let title = page.title { header.insert("Title: \(title)", at: 0) }
        var text = page.text.isEmpty ? "(The page has no readable text.)" : page.text
        if text.count > limit {
            let total = text.count
            text =
                String(text.prefix(limit))
                + "\n\n[Truncated: showing the first \(limit) of \(total) characters.]"
        }
        return header.joined(separator: "\n") + "\n\n" + text
    }

    static func isReadable(_ mimeType: String) -> Bool {
        mimeType.hasPrefix("text/") || mimeType.contains("html") || mimeType.contains("xml")
            || mimeType.contains("json")
    }

    static func decode(_ data: Data, encodingName: String?) -> String {
        if let encodingName {
            let encoding = CFStringConvertIANACharSetNameToEncoding(encodingName as CFString)
            if encoding != kCFStringEncodingInvalidId {
                let native = String.Encoding(
                    rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))
                if native != .utf8, let text = String(data: data, encoding: native) {
                    return text
                }
            }
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        // A page cut off mid-character, or mislabelled: keep what decodes.
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Address checks

    /// Checks that `address` is a public http or https address; adds `https://` when the
    /// scheme is missing.
    public static func validate(_ address: String) throws -> URL {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: withScheme), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty
        else {
            throw ToolError("Only http and https web addresses can be read.")
        }
        guard isPublic(host: host) else {
            throw ToolError("Momo does not read pages on the local network or this Mac.")
        }
        return url
    }

    /// Whether `host` may be on the public internet. Literal private, loopback and link-local
    /// addresses and local names are not.
    static func isPublic(host: String) -> Bool {
        let host = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local")
            || host.hasSuffix(".internal") || host.hasSuffix(".home.arpa")
            || (!host.contains(".") && !host.contains(":"))
        {
            return false
        }
        let parts = host.split(separator: ".").compactMap { UInt8($0) }
        if parts.count == 4, host.split(separator: ".").count == 4 {
            switch (parts[0], parts[1]) {
            case (0, _), (10, _), (127, _), (169, 254), (192, 168): return false
            case (172, 16...31), (100, 64...127): return false
            default: return true
            }
        }
        if host.contains(":") {
            // IPv6: loopback, unspecified, unique local (fc00::/7), link-local (fe80::/10)
            // and IPv4-mapped addresses.
            return
                !(host == "::1" || host == "::" || host.hasPrefix("fc") || host.hasPrefix("fd")
                || host.hasPrefix("fe8") || host.hasPrefix("fe9") || host.hasPrefix("fea")
                || host.hasPrefix("feb") || host.hasPrefix("::ffff:"))
        }
        return true
    }
}

/// Refuses redirects to addresses ``WebPageReader`` would not fetch.
private final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        guard let url = request.url, (try? WebPageReader.validate(url.absoluteString)) != nil
        else { return nil }
        return request
    }
}
