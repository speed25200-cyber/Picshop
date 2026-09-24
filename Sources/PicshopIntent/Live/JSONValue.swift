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

    /// Strict RFC 8259: no trailing commas or garbage, no NaN or Inf, no
    /// duplicate keys, no lone surrogates. Hand-written rather than JSONDecoder,
    /// which accepts trailing commas on Linux and differs by platform.
    public static func parse(_ text: String) throws -> JSONValue {
        var parser = StrictJSONParser(bytes: Array(text.utf8))
        return try parser.document()
    }

    /// Parses UTF-8 bytes, as they come off the wire.
    public static func parse(bytes: [UInt8]) throws -> JSONValue {
        var parser = StrictJSONParser(bytes: bytes)
        return try parser.document()
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

/// Why a text is not strict JSON, with the byte offset.
public struct JSONParseError: Error, Sendable, Equatable {
    public var offset: Int
    public var reason: String

    public init(offset: Int, reason: String) {
        self.offset = offset
        self.reason = reason
    }
}

/// Recursive descent over UTF-8 bytes, following the RFC 8259 grammar exactly.
struct StrictJSONParser {
    private let bytes: [UInt8]
    private var index = 0
    private var depth = 0
    private static let maxDepth = 256

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func document() throws -> JSONValue {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard index == bytes.count else { throw fail("trailing characters") }
        return value
    }

    private func fail(_ reason: String) -> JSONParseError {
        JSONParseError(offset: index, reason: reason)
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D: index += 1
            default: return
            }
        }
    }

    private mutating func parseValue() throws -> JSONValue {
        guard index < bytes.count else { throw fail("unexpected end") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try parseNumber())
        default: throw fail("unexpected character")
        }
    }

    private mutating func expect(_ word: String) throws {
        for byte in word.utf8 {
            guard index < bytes.count, bytes[index] == byte else { throw fail("invalid literal") }
            index += 1
        }
    }

    private mutating func enter() throws {
        depth += 1
        if depth > Self.maxDepth { throw fail("nested too deeply") }
    }

    private mutating func parseObject() throws -> JSONValue {
        try enter()
        defer { depth -= 1 }
        index += 1
        var object: [String: JSONValue] = [:]
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .object(object)
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw fail("expected a key") }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw fail("expected ':'") }
            index += 1
            skipWhitespace()
            let value = try parseValue()
            guard object.updateValue(value, forKey: key) == nil else { throw fail("duplicate key") }
            skipWhitespace()
            guard index < bytes.count else { throw fail("unterminated object") }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
                continue
            }
            guard bytes[index] == UInt8(ascii: "}") else { throw fail("expected ',' or '}'") }
            index += 1
            return .object(object)
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        try enter()
        defer { depth -= 1 }
        index += 1
        var array: [JSONValue] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return .array(array)
        }
        while true {
            skipWhitespace()
            array.append(try parseValue())
            skipWhitespace()
            guard index < bytes.count else { throw fail("unterminated array") }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
                continue
            }
            guard bytes[index] == UInt8(ascii: "]") else { throw fail("expected ',' or ']'") }
            index += 1
            return .array(array)
        }
    }

    private mutating func parseNumber() throws -> Double {
        let start = index
        if bytes[index] == UInt8(ascii: "-") { index += 1 }
        guard index < bytes.count, isDigit(bytes[index]) else { throw fail("invalid number") }
        if bytes[index] == UInt8(ascii: "0") {
            index += 1
            if index < bytes.count, isDigit(bytes[index]) { throw fail("leading zero") }
        } else {
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            guard index < bytes.count, isDigit(bytes[index]) else { throw fail("invalid fraction") }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") { index += 1 }
            guard index < bytes.count, isDigit(bytes[index]) else { throw fail("invalid exponent") }
            while index < bytes.count, isDigit(bytes[index]) { index += 1 }
        }
        let literal = String(decoding: bytes[start..<index], as: UTF8.self)
        guard let value = Double(literal), value.isFinite else { throw fail("number out of range") }
        return value
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private mutating func parseString() throws -> String {
        index += 1
        var scalars = String.UnicodeScalarView()
        var runStart = index
        while true {
            guard index < bytes.count else { throw fail("unterminated string") }
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                appendRun(from: runStart, to: index, into: &scalars)
                index += 1
                return String(scalars)
            }
            if byte < 0x20 { throw fail("control character in string") }
            if byte == UInt8(ascii: "\\") {
                appendRun(from: runStart, to: index, into: &scalars)
                index += 1
                guard index < bytes.count else { throw fail("unterminated escape") }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): scalars.append("\"")
                case UInt8(ascii: "\\"): scalars.append("\\")
                case UInt8(ascii: "/"): scalars.append("/")
                case UInt8(ascii: "b"): scalars.append("\u{08}")
                case UInt8(ascii: "f"): scalars.append("\u{0C}")
                case UInt8(ascii: "n"): scalars.append("\n")
                case UInt8(ascii: "r"): scalars.append("\r")
                case UInt8(ascii: "t"): scalars.append("\t")
                case UInt8(ascii: "u"):
                    let unit = try hex4()
                    if (0xD800...0xDBFF).contains(unit) {
                        guard index + 1 < bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") else { throw fail("lone surrogate") }
                        index += 2
                        let low = try hex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw fail("lone surrogate") }
                        let value = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                        guard let scalar = Unicode.Scalar(value) else { throw fail("invalid escape") }
                        scalars.append(scalar)
                    } else {
                        guard let scalar = Unicode.Scalar(unit) else { throw fail("lone surrogate") }
                        scalars.append(scalar)
                    }
                default:
                    throw fail("invalid escape")
                }
                runStart = index
                continue
            }
            index += 1
        }
    }

    private mutating func hex4() throws -> UInt32 {
        guard index + 4 <= bytes.count else { throw fail("short unicode escape") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = bytes[index]
            let digit: UInt32
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(byte - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(byte - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(byte - UInt8(ascii: "A") + 10)
            default: throw fail("invalid unicode escape")
            }
            value = value * 16 + digit
            index += 1
        }
        return value
    }

    /// Unescaped bytes are copied as UTF-8 (an invalid sequence becomes U+FFFD).
    private func appendRun(from start: Int, to end: Int, into scalars: inout String.UnicodeScalarView) {
        guard start < end else { return }
        scalars.append(contentsOf: String(decoding: bytes[start..<end], as: UTF8.self).unicodeScalars)
    }
}
