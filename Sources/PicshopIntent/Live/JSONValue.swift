import Foundation

/// Any JSON value. Tool inputs, tool results and request bodies are built from
/// it so their bytes are the same on every platform: `serialized()` sorts
/// object keys by UTF-8 bytes and prints numbers in one fixed way.
public enum JSONValue: Sendable, Hashable, Codable, ExpressibleByNilLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([String: JSONValue])

    // MARK: Literals

    public init(nilLiteral: ()) { self = .null }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }

    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        var object: [String: JSONValue] = [:]
        for (key, value) in elements { object[key] = value }
        self = .object(object)
    }

    // MARK: Access

    public subscript(key: String) -> JSONValue? {
        guard case .object(let object) = self else { return nil }
        return object[key]
    }

    public var string: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var double: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }

    public var int: Int? {
        guard case .number(let value) = self else { return nil }
        return Int(exactly: value)
    }

    public var bool: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public var array: [JSONValue]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    public var object: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    // MARK: Codable

    public init(from decoder: Decoder) throws {
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
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    // MARK: Text

    /// Strict RFC 8259.
    public static func parse(_ text: String) throws -> JSONValue {
        // Phase 0: JSONDecoder as is; phase 1 adds the strictness checks.
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    /// Deterministic, byte-identical on Darwin and Linux.
    public func serialized() -> String {
        var out = ""
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        switch self {
        case .null:
            out += "null"
        case .bool(let value):
            out += value ? "true" : "false"
        case .number(let value):
            out += JSONValue.format(value)
        case .string(let value):
            JSONValue.writeString(value, into: &out)
        case .array(let values):
            out += "["
            for (index, value) in values.enumerated() {
                if index > 0 { out += "," }
                value.write(into: &out)
            }
            out += "]"
        case .object(let object):
            out += "{"
            let keys = object.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            for (index, key) in keys.enumerated() {
                if index > 0 { out += "," }
                JSONValue.writeString(key, into: &out)
                out += ":"
                object[key]?.write(into: &out)
            }
            out += "}"
        }
    }

    private static func format(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value == value.rounded(), abs(value) < 9_007_199_254_740_992 { return String(Int64(value)) }
        return "\(value)"
    }

    private static func writeString(_ value: String, into out: inout String) {
        out += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    let hex = String(scalar.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}
