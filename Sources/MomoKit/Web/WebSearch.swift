import Foundation

/// One web search result.
public struct WebSearchResult: Sendable, Equatable {
    public var title: String
    public var url: URL
    public var snippet: String

    public init(title: String, url: URL, snippet: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }

    /// Numbered results for the model.
    public static func format(_ results: [WebSearchResult]) -> String {
        results.enumerated().map { index, result in
            var lines = ["\(index + 1). \(result.title)", "   \(result.url.absoluteString)"]
            if !result.snippet.isEmpty { lines.append("   \(result.snippet)") }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}

/// Searches the web: with Brave Search when the user entered a key, otherwise (or when Brave
/// fails) with DuckDuckGo's HTML results, which need no key.
public struct WebSearcher: Sendable {
    /// The Keychain account for the Brave Search API key.
    public static let braveKeyID = "brave-search"

    private let braveKey: String?
    private let locale: Locale
    private let session: URLSession

    public init(braveKey: String? = nil, locale: Locale = .current, session: URLSession = .shared) {
        self.braveKey = braveKey?.isEmpty == true ? nil : braveKey
        self.locale = locale
        self.session = session
    }

    /// Returns up to `count` results for `query`.
    public func search(_ query: String, count: Int = 6) async throws -> [WebSearchResult] {
        if let braveKey,
            let request = BraveSearch.request(
                query: query, key: braveKey, count: count, locale: locale),
            let data = try? await data(for: request),
            let results = try? BraveSearch.parse(data), !results.isEmpty
        {
            return Array(results.prefix(count))
        }
        let data = try await data(for: DuckDuckGoSearch.request(query: query, locale: locale))
        let html = String(decoding: data, as: UTF8.self)
        let results = DuckDuckGoSearch.parse(html)
        if results.isEmpty && DuckDuckGoSearch.isChallenge(html) {
            throw ToolError(
                "DuckDuckGo did not return results right now (it may be limiting requests). Try again later, or add a Brave Search key in Momo Settings → Connections."
            )
        }
        return Array(results.prefix(count))
    }

    private func data(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            throw ToolError("The search service answered with HTTP \(status).")
        }
        return data
    }
}

/// DuckDuckGo's JavaScript-free results page.
public enum DuckDuckGoSearch {
    static let endpoint = URL(string: "https://html.duckduckgo.com/html/")

    /// A POST request for `query`, with a region hint from `locale`.
    public static func request(query: String, locale: Locale) -> URLRequest {
        // The endpoint is a constant, valid URL.
        var request = URLRequest(url: endpoint ?? URL(fileURLWithPath: "/"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(WebPageReader.userAgent, forHTTPHeaderField: "User-Agent")
        if let language = locale.language.languageCode?.identifier {
            request.setValue("\(language),en;q=0.8", forHTTPHeaderField: "Accept-Language")
        }
        let body = [("q", query), ("kl", region(for: locale))]
            .map { "\($0)=\(formEncode($1))" }
            .joined(separator: "&")
        request.httpBody = Data(body.utf8)
        return request
    }

    /// DuckDuckGo's region code (`kl`), such as `tr-tr` or `us-en`; `wt-wt` means no region.
    static func region(for locale: Locale) -> String {
        guard let region = locale.region?.identifier.lowercased(), region.count == 2,
            let language = locale.language.languageCode?.identifier.lowercased()
        else { return "wt-wt" }
        switch region {
        case "gb": return "uk-en"
        case "us", "au", "ca", "ie", "in", "nz", "za", "sg", "ph", "my":
            return "\(region)-en"
        default: return "\(region)-\(language)"
        }
    }

    static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        return (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)
            .replacingOccurrences(of: "%20", with: "+")
    }

    /// Reads the results from the HTML page, skipping ads.
    public static func parse(_ html: String) -> [WebSearchResult] {
        var results: [WebSearchResult] = []
        var current: (title: String, url: URL)?
        var snippet = ""

        func finish() {
            if let current {
                results.append(
                    WebSearchResult(title: current.title, url: current.url, snippet: snippet))
            }
            current = nil
            snippet = ""
        }

        for element in elements(in: html) {
            if element.classes.contains("result__a") {
                finish()
                guard let href = element.href, let url = targetURL(from: href) else { continue }
                let title = HTMLText.text(from: element.content)
                guard !title.isEmpty else { continue }
                current = (title, url)
            } else if element.classes.contains("result__snippet"), current != nil {
                snippet = HTMLText.text(from: element.content)
            }
        }
        finish()
        var seen = Set<URL>()
        return results.filter { seen.insert($0.url).inserted }
    }

    /// Whether the page is a bot check instead of results.
    static func isChallenge(_ html: String) -> Bool {
        html.contains("anomaly-modal") || html.contains("challenge-form")
    }

    /// Resolves DuckDuckGo's redirect links (`//duckduckgo.com/l/?uddg=<target>`) to the real
    /// address. Ads (`y.js`) and non-web links return `nil`.
    public static func targetURL(from href: String) -> URL? {
        let decoded = HTMLText.decodeEntities(href)
        let absolute = decoded.hasPrefix("//") ? "https:" + decoded : decoded
        guard let components = URLComponents(string: absolute) else { return nil }
        if let host = components.host, host.hasSuffix("duckduckgo.com") {
            guard components.path.hasPrefix("/l/"),
                let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value
            else { return nil }
            return webURL(target)
        }
        return webURL(absolute)
    }

    private static func webURL(_ string: String) -> URL? {
        guard let url = URL(string: string), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https", url.host != nil
        else { return nil }
        return url
    }

    /// An element with a class attribute and its inner HTML.
    struct Element {
        var classes: Set<String>
        var href: String?
        var content: String
    }

    /// The `<a>`, `<div>` and `<td>` elements that carry result classes, in document order.
    static func elements(in html: String) -> [Element] {
        guard
            let expression = try? NSRegularExpression(
                pattern:
                    #"<(a|div|td|span)\b([^>]*\bclass\s*=\s*["'][^"']*result__(?:a|snippet)\b[^"']*["'][^>]*)>"#,
                options: [.caseInsensitive])
        else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return expression.matches(in: html, range: range).compactMap { match in
            guard let whole = Range(match.range, in: html),
                let nameRange = Range(match.range(at: 1), in: html),
                let attributesRange = Range(match.range(at: 2), in: html)
            else { return nil }
            let name = html[nameRange].lowercased()
            let attributes = html[attributesRange]
            let classes = Set(
                (HTMLAttributes.value(of: "class", in: attributes) ?? "")
                    .split(whereSeparator: \.isWhitespace).map(String.init))
            let close =
                html.range(
                    of: "</\(name)>", options: .caseInsensitive,
                    range: whole.upperBound..<html.endIndex)?.lowerBound ?? html.endIndex
            return Element(
                classes: classes, href: HTMLAttributes.value(of: "href", in: attributes),
                content: String(html[whole.upperBound..<close]))
        }
    }
}

/// The Brave Search API, used when the user entered their own key.
public enum BraveSearch {
    /// Countries and languages Brave accepts; other values would make it reject the request.
    static let countries: Set<String> = [
        "AR", "AU", "AT", "BE", "BR", "CA", "CL", "DK", "FI", "FR", "DE", "HK", "IN", "ID", "IT",
        "JP", "KR", "MY", "MX", "NL", "NZ", "NO", "PL", "PT", "PH", "RU", "SA", "ZA", "ES", "SE",
        "CH", "TW", "TR", "GB", "US",
    ]
    static let languages: Set<String> = [
        "ar", "da", "de", "en", "es", "fi", "fr", "it", "ja", "ko", "nl", "nb", "pl", "ru", "sv",
        "tr",
    ]

    public static func request(
        query: String, key: String, count: Int, locale: Locale
    )
        -> URLRequest?
    {
        var components = URLComponents(string: "https://api.search.brave.com/res/v1/web/search")
        var items = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "count", value: String(min(20, max(1, count)))),
        ]
        if let country = locale.region?.identifier.uppercased(), countries.contains(country) {
            items.append(URLQueryItem(name: "country", value: country))
        }
        if let language = locale.language.languageCode?.identifier.lowercased(),
            languages.contains(language)
        {
            items.append(URLQueryItem(name: "search_lang", value: language))
        }
        components?.queryItems = items
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(key, forHTTPHeaderField: "X-Subscription-Token")
        return request
    }

    public static func parse(_ data: Data) throws -> [WebSearchResult] {
        let json = try JSONValue.parse(String(decoding: data, as: UTF8.self))
        return (json["web"]?["results"]?.arrayValue ?? []).compactMap { result in
            guard let title = result["title"]?.stringValue,
                let address = result["url"]?.stringValue, let url = URL(string: address)
            else { return nil }
            return WebSearchResult(
                title: HTMLText.text(from: title), url: url,
                snippet: HTMLText.text(from: result["description"]?.stringValue ?? ""))
        }
    }
}
