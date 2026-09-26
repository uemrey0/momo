import Foundation

/// Tools that let Momo search the web and read pages, for current information.
public enum WebTools {
    /// Localized activity labels, set by the app (this module cannot localize).
    public struct Labels: Sendable {
        public var search: String?
        public var read: String?

        public init(search: String? = nil, read: String? = nil) {
            self.search = search
            self.read = read
        }
    }

    public static func all(
        searcher: WebSearcher = WebSearcher(), reader: WebPageReader = WebPageReader(),
        labels: Labels = Labels()
    ) -> [any MomoTool] {
        [webSearch(searcher, label: labels.search), readWebPage(reader, label: labels.read)]
    }

    static func webSearch(_ searcher: WebSearcher, label: String?) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "web_search",
                description:
                    "Search the web for current information: news, facts, prices, opening hours, documentation, anything that may have changed recently. Returns titles, links and snippets; read a result with read_web_page when the snippet is not enough.",
                parameters: JSONSchema.object(
                    [
                        "query": JSONSchema.string("What to search for"),
                        "count": JSONSchema.integer("How many results, from 1 to 10; default 6"),
                    ], required: ["query"]),
                activityLabel: label)
        ) { arguments in
            guard
                let query = arguments["query"]?.stringValue?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !query.isEmpty
            else {
                throw ToolError("A query is required.")
            }
            let count = min(10, max(1, arguments["count"]?.intValue ?? 6))
            let results = try await searcher.search(query, count: count)
            guard !results.isEmpty else { return "No results for “\(query)”." }
            return WebSearchResult.format(results)
        }
    }

    static func readWebPage(_ reader: WebPageReader, label: String?) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "read_web_page",
                description:
                    "Fetch a web page (http or https) and return its readable text. Use it to read a search result or a link the user gives you.",
                parameters: JSONSchema.object(
                    ["url": JSONSchema.string("The page's address")], required: ["url"]),
                activityLabel: label)
        ) { arguments in
            guard let address = arguments["url"]?.stringValue, !address.isEmpty else {
                throw ToolError("A url is required.")
            }
            return WebPageReader.format(try await reader.read(address))
        }
    }
}
