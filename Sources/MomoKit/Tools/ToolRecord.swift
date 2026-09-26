import Foundation

/// A compact, provider-neutral record of one tool call and its result, kept in the
/// conversation history so follow-up questions ("delete the second one") still know which
/// items the tools returned.
public struct ToolRecord: Codable, Sendable, Hashable {
    public var name: String
    /// The arguments as compact JSON, possibly shortened.
    public var arguments: String
    /// The tool's output, possibly shortened.
    public var result: String
    public var isError: Bool

    public init(name: String, arguments: String, result: String, isError: Bool = false) {
        self.name = name
        self.arguments = arguments
        self.result = result
        self.isError = isError
    }

    /// The most characters the records of one turn take up, arguments and results included.
    public static let turnBudget = 1_500
    /// The most characters kept of one call's arguments.
    static let argumentLimit = 200

    /// Shortens the tool calls of one turn to fit `budget` characters. Results share what
    /// the names and arguments leave over; when even those don't fit, the oldest calls go.
    public static func compact(_ records: [ToolRecord], budget: Int = turnBudget) -> [ToolRecord] {
        var kept = records.map { record in
            var record = record
            record.arguments = Self.shortened(Self.condensed(record.arguments), to: argumentLimit)
            record.result = Self.condensed(record.result)
            return record
        }
        func fixedCost(_ records: [ToolRecord]) -> Int {
            records.reduce(0) { $0 + $1.name.count + $1.arguments.count }
        }
        while !kept.isEmpty, fixedCost(kept) > budget * 2 / 3 {
            kept.removeFirst()
        }
        guard !kept.isEmpty else { return [] }
        // Share the rest evenly, giving what short results leave unused to the longer ones.
        var remaining = max(0, budget - fixedCost(kept))
        var open = kept.indices.sorted { kept[$0].result.count < kept[$1].result.count }
        while let index = open.first {
            let share = remaining / open.count
            kept[index].result = Self.shortened(kept[index].result, to: share)
            remaining -= kept[index].result.count
            open.removeFirst()
        }
        return kept
    }

    /// Renders records as plain text the model can read as context of the turn they belong
    /// to. Empty when there are none.
    public static func render(_ records: [ToolRecord]) -> String {
        guard !records.isEmpty else { return "" }
        let lines = records.map { record in
            let outcome = record.isError ? "error: \(record.result)" : record.result
            return "- \(record.name) \(record.arguments) → \(outcome)"
        }
        return "Tools used this turn (recorded by Momo for context, not shown to the user):\n"
            + lines.joined(separator: "\n")
    }

    /// Collapses runs of whitespace so records stay dense.
    static func condensed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// `text` cut to at most `limit` characters, ending in an ellipsis when shortened.
    static func shortened(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        guard limit > 1 else { return "" }
        return String(text.prefix(limit - 1)) + "…"
    }
}
