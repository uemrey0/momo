import Foundation
import Testing

@testable import MomoKit

private let duckDuckGoFixture = """
    <!DOCTYPE html>
    <html><head><title>swift at DuckDuckGo</title></head>
    <body>
    <div class="result results_links results_links_deep result--ad">
      <div class="links_main links_deep result__body">
        <h2 class="result__title">
          <a rel="nofollow" class="result__a" href="https://duckduckgo.com/y.js?ad_domain=shop.example&amp;u3=x">Buy Swift now</a>
        </h2>
        <a class="result__snippet" href="https://duckduckgo.com/y.js?ad_domain=shop.example">An ad.</a>
      </div>
    </div>
    <div class="result results_links results_links_deep web-result ">
      <div class="links_main links_deep result__body">
        <h2 class="result__title">
          <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.swift.org%2Fdocumentation%2F%3Fa%3D1%26b%3D2&amp;rut=abc">Swift <b>Documentation</b> &amp; Guides</a>
        </h2>
        <div class="result__extras"><a class="result__url" href="//duckduckgo.com/l/?uddg=x">swift.org</a></div>
        <a class="result__snippet" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.swift.org%2Fdocumentation%2F">The official <b>Swift</b> docs. We&#x27;ll help you get started.</a>
      </div>
    </div>
    <div class="result results_links results_links_deep web-result ">
      <div class="links_main links_deep result__body">
        <h2 class="result__title">
          <a class="result__a" rel="nofollow" href="https://developer.apple.com/swift/">Swift - Apple Developer</a>
        </h2>
        <a class="result__snippet" href="https://developer.apple.com/swift/">Swift is a powerful and intuitive language.</a>
      </div>
    </div>
    <div class="result results_links web-result">
      <h2 class="result__title"><a class="result__a" href="https://developer.apple.com/swift/">Duplicate</a></h2>
    </div>
    </body></html>
    """

private let articleFixture = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <title>Brewing Tea &amp; Coffee | Example News</title>
      <style>body { color: red; } p > a { }</style>
      <script>var x = "<p>not text</p>"; if (a < b) {}</script>
    </head>
    <body>
      <nav><a href="/">Home</a> <a href="/news">News</a></nav>
      <header><p>Site banner</p></header>
      <main>
        <article>
          <h1>How to brew  tea</h1>
          <p>Tea is <a href="/tea">wonderful</a>.   It&rsquo;s been brewed for
             centuries &mdash; since at least 1000&nbsp;BC.</p>
          <!-- an HTML comment with <p>markup</p> -->
          <h2>Steps</h2>
          <ul>
            <li>Boil water</li>
            <li>Add leaves<ul><li>Green: 80&#176;C</li><li>Black: 95&#xB0;C</li></ul></li>
          </ul>
          <p>Line one<br>Line two</p>
          <img src="cup.png" alt="A cup of tea">
          <p>Math: 3 < 5 and a&b stay readable, as does &unknown; text.</p>
          <p>Enough text is here so that the main element is used as the readable part of the
          page rather than the whole document with its navigation and banner.</p>
        </article>
      </main>
      <aside>Related links</aside>
      <footer><p>Copyright 2026</p></footer>
      <script src="app.js"></script>
    </body>
    </html>
    """

@Suite("Web search")
struct WebSearchTests {
    @Test("reads DuckDuckGo results, skipping ads and duplicates")
    func duckDuckGo() {
        let results = DuckDuckGoSearch.parse(duckDuckGoFixture)
        #expect(results.count == 2)
        #expect(results[0].title == "Swift Documentation & Guides")
        #expect(results[0].url.absoluteString == "https://www.swift.org/documentation/?a=1&b=2")
        #expect(results[0].snippet == "The official Swift docs. We'll help you get started.")
        #expect(results[1].url.absoluteString == "https://developer.apple.com/swift/")
        #expect(results[1].snippet == "Swift is a powerful and intuitive language.")

        let formatted = WebSearchResult.format(results)
        #expect(formatted.hasPrefix("1. Swift Documentation & Guides\n   https://www.swift.org"))
        #expect(formatted.contains("2. Swift - Apple Developer"))
    }

    @Test("resolves DuckDuckGo redirect links")
    func redirects() {
        #expect(
            DuckDuckGoSearch.targetURL(
                from: "//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa%20b&amp;rut=1")?
                .absoluteString == "https://example.com/a%20b")
        #expect(DuckDuckGoSearch.targetURL(from: "https://duckduckgo.com/y.js?ad=1") == nil)
        #expect(DuckDuckGoSearch.targetURL(from: "javascript:alert(1)") == nil)
        #expect(
            DuckDuckGoSearch.targetURL(from: "http://example.org/x")?.absoluteString
                == "http://example.org/x")
    }

    @Test("builds the DuckDuckGo request with a region from the locale")
    func duckDuckGoRequest() throws {
        let request = DuckDuckGoSearch.request(
            query: "hava durumu & rüzgar", locale: Locale(identifier: "tr_TR"))
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://html.duckduckgo.com/html/")
        let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
        #expect(body == "q=hava+durumu+%26+r%C3%BCzgar&kl=tr-tr")
        #expect(DuckDuckGoSearch.region(for: Locale(identifier: "en_GB")) == "uk-en")
        #expect(DuckDuckGoSearch.region(for: Locale(identifier: "en_US")) == "us-en")
        #expect(DuckDuckGoSearch.region(for: Locale(identifier: "en")) == "wt-wt")
        #expect(DuckDuckGoSearch.isChallenge(#"<div class="anomaly-modal__title">"#))
    }

    @Test("builds Brave requests and reads their results")
    func brave() throws {
        let request = try #require(
            BraveSearch.request(
                query: "news", key: "secret", count: 30, locale: Locale(identifier: "tr_TR")))
        let url = try #require(request.url?.absoluteString)
        #expect(url.hasPrefix("https://api.search.brave.com/res/v1/web/search?"))
        #expect(url.contains("q=news") && url.contains("count=20"))
        #expect(url.contains("country=TR") && url.contains("search_lang=tr"))
        #expect(request.value(forHTTPHeaderField: "X-Subscription-Token") == "secret")
        let unsupported = try #require(
            BraveSearch.request(query: "x", key: "k", count: 5, locale: Locale(identifier: "is_IS"))
        )
        #expect(unsupported.url?.absoluteString.contains("country") == false)

        let json = #"""
            {"web":{"results":[{"title":"Swift &amp; you","url":"https://swift.org","description":"The <strong>Swift</strong> language"},{"title":"no url"}]}}
            """#
        let results = try BraveSearch.parse(Data(json.utf8))
        #expect(
            results == [
                WebSearchResult(
                    title: "Swift & you", url: URL(string: "https://swift.org")!,
                    snippet: "The Swift language")
            ])
    }
}

@Suite("Reading web pages")
struct WebPageTests {
    @Test("turns an article into readable text")
    func article() {
        let document = HTMLText.document(from: articleFixture)
        #expect(document.title == "Brewing Tea & Coffee | Example News")
        let text = document.text
        #expect(
            text.hasPrefix(
                "# How to brew tea\n\nTea is wonderful. It’s been brewed for centuries — since at least 1000 BC."
            ))
        #expect(
            text.contains(
                "## Steps\n\n- Boil water\n- Add leaves\n  - Green: 80°C\n  - Black: 95°C"))
        #expect(text.contains("Line one\nLine two"))
        #expect(text.contains("A cup of tea"))
        #expect(text.contains("Math: 3 < 5 and a&b stay readable, as does &unknown; text."))
        for hidden in [
            "not text", "color: red", "Home", "Site banner", "Copyright", "markup", "Related",
        ] {
            #expect(!text.contains(hidden), "\(hidden) should be dropped")
        }
    }

    @Test("uses the whole page when there is no main content element")
    func wholePage() {
        let html = """
            <html><head><title>T</title><body><div>First</div><div>Second <b>bold</b></div>
            <table><tr><td>A</td><td>B</td></tr></table><footer>Foot</footer></body></html>
            """
        let document = HTMLText.document(from: html)
        #expect(document.title == "T")
        // The missing </head> does not hide the body.
        #expect(document.text == "First\nSecond bold\n\nA B")
    }

    @Test("decodes entities")
    func entities() {
        #expect(
            HTMLText.decodeEntities("a &amp; b &lt;c&gt; &#8364; &#x1F600; &copy;")
                == "a & b <c> € 😀 ©")
        #expect(HTMLText.decodeEntities("AT&T & &#0; &;") == "AT&T & &#0; &;")
    }

    @Test("formats pages, JSON and plain text, and truncates long ones")
    func formatting() throws {
        let url = try #require(URL(string: "https://example.com/data"))
        let json = WebPageReader.page(
            from: #"{"b":1,"a":[true]}"#, mimeType: "application/json", url: url)
        #expect(json.text.contains("\"a\" : ["))
        let plain = WebPageReader.page(from: "just <text>", mimeType: "text/plain", url: url)
        #expect(plain.text == "just <text>")

        let long = WebPageReader.Page(
            url: url, title: "Long", text: String(repeating: "a", count: 20))
        let output = WebPageReader.format(long, limit: 10)
        #expect(output.hasPrefix("Title: Long\nURL: https://example.com/data\n\naaaaaaaaaa\n\n"))
        #expect(output.hasSuffix("[Truncated: showing the first 10 of 20 characters.]"))
        #expect(WebPageReader.isReadable("application/xhtml+xml"))
        #expect(!WebPageReader.isReadable("image/png"))
        #expect(
            WebPageReader.decode(Data([0x63, 0x61, 0x66, 0xE9]), encodingName: "iso-8859-1")
                == "café")
    }

    @Test("reads only public http and https addresses")
    func addresses() throws {
        #expect(
            try WebPageReader.validate("example.com/a").absoluteString == "https://example.com/a")
        #expect(try WebPageReader.validate("http://93.184.216.34/").host == "93.184.216.34")
        for refused in [
            "file:///etc/passwd", "ftp://example.com", "http://localhost:8080", "http://127.0.0.1",
            "http://192.168.1.1/admin", "http://10.0.0.5", "http://172.20.1.1",
            "http://169.254.169.254",
            "http://[::1]/", "http://[fd00::1]/", "http://printer.local", "http://router",
        ] {
            #expect(throws: ToolError.self, "\(refused) should be refused") {
                try WebPageReader.validate(refused)
            }
        }
        #expect(WebPageReader.isPublic(host: "fcbarcelona.com"))
        #expect(WebPageReader.isPublic(host: "172.32.0.1"))
    }

    @Test("offers both tools with the labels the app gives them")
    func tools() async {
        let tools = WebTools.all(labels: .init(search: "Searching", read: "Reading"))
        #expect(tools.map(\.definition.name) == ["web_search", "read_web_page"])
        #expect(tools.map(\.definition.activityLabel) == ["Searching", "Reading"])
        #expect(tools.allSatisfy { !$0.definition.requiresConfirmation })
        let toolbox = Toolbox(tools)
        let missing = await toolbox.execute(ToolCall(id: "1", name: "web_search", arguments: "{}"))
        #expect(missing.isError)
        let local = await toolbox.execute(
            ToolCall(id: "2", name: "read_web_page", arguments: #"{"url":"http://localhost"}"#))
        #expect(local.isError && local.output.contains("local network"))
    }
}
