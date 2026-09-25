import Foundation

/// A JSON value. Used for tool arguments, tool schemas and provider payloads.
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            if value.rounded() == value, abs(value) < 1e15 {
                try container.encode(Int64(value))
            } else {
                try container.encode(value)
            }
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    /// Parses a JSON document. An empty string parses as an empty object, which is how some
    /// models send tool calls without arguments.
    public static func parse(_ text: String) throws -> JSONValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .object([:]) }
        return try JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8))
    }

    /// Compact JSON with sorted keys.
    public var jsonString: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var stringValue: String? {
        switch self {
        case .string(let value): value
        case .number(let value):
            value.rounded() == value ? String(Int64(value)) : String(value)
        case .bool(let value): String(value)
        default: nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let value): value
        case .string(let value): Double(value)
        default: nil
        }
    }

    public var intValue: Int? {
        doubleValue.map { Int($0) }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let value): value
        case .string(let value): ["true", "yes", "1"].contains(value.lowercased())
        default: nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
    public init(nilLiteral: ()) { self = .null }
}

/// Helpers for writing JSON Schemas for tool parameters.
public enum JSONSchema {
    public static func object(
        _ properties: [String: JSONValue] = [:], required: [String] = []
    ) -> JSONValue {
        [
            "type": "object",
            "properties": .object(properties),
            "required": .array(required.map(JSONValue.string)),
        ]
    }

    public static func string(_ description: String) -> JSONValue {
        ["type": "string", "description": .string(description)]
    }

    public static func integer(_ description: String) -> JSONValue {
        ["type": "integer", "description": .string(description)]
    }

    public static func boolean(_ description: String) -> JSONValue {
        ["type": "boolean", "description": .string(description)]
    }

    public static func oneOf(_ values: [String], description: String) -> JSONValue {
        [
            "type": "string", "description": .string(description),
            "enum": .array(values.map(JSONValue.string)),
        ]
    }
}
