import Foundation

/// A dynamic JSON tree.
///
/// Both OneBot and Milky describe their payloads loosely: an action's parameters
/// are whatever that action documents, and unknown fields must survive a
/// round-trip so the raw-event inspector can show exactly what came over the
/// wire. `Codable` structs alone cannot express that, so the wire layer parses
/// into `JSONValue` and each protocol reads the fields it knows.
public enum JSONValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Reading

extension JSONValue {
    public var isNull: Bool { self == .null }

    public var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        // OneBot implementations are loose with booleans on the wire.
        case .number(let n): return n != 0
        case .string(let s):
            switch s.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default: return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        case .bool(let b): return b ? 1 : 0
        default: return nil
        }
    }

    public var intValue: Int? {
        guard let d = doubleValue, d.isFinite, d >= -9_007_199_254_740_992, d <= 9_007_199_254_740_992 else {
            return nil
        }
        return Int(d)
    }

    public var int64Value: Int64? {
        guard let d = doubleValue, d.isFinite, d >= -9_007_199_254_740_992, d <= 9_007_199_254_740_992 else {
            return nil
        }
        return Int64(d)
    }

    /// Numbers stringify because peer IDs cross the wire as either form:
    /// OneBot v11 sends `user_id` as an integer, v12 and Milky as a string.
    public var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let n):
            if let i = int64Value, Double(i) == n { return String(i) }
            return String(n)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// Member access on an object, `nil` for any other case.
    public subscript(key: String) -> JSONValue? {
        guard case .object(let o) = self else { return nil }
        return o[key]
    }

    public subscript(index: Int) -> JSONValue? {
        guard case .array(let a) = self, a.indices.contains(index) else { return nil }
        return a[index]
    }
}

// MARK: - Codable

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let d = try? c.decode(Double.self) {
            self = .number(d)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unrecognized JSON value")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n):
            // Emit whole numbers without a `.0` tail; OneBot peers expect
            // integral IDs and timestamps to look like integers.
            if let i = int64Value, Double(i) == n { try c.encode(i) } else { try c.encode(n) }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

// MARK: - Literals

extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
}

extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .number(value) }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}

extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

// MARK: - Building

extension JSONValue {
    /// Builds an object, dropping `nil` members so optional fields stay absent
    /// rather than becoming explicit nulls — some peers reject `null` where they
    /// expect a missing key.
    public static func compactObject(_ members: [String: JSONValue?]) -> JSONValue {
        .object(members.compactMapValues { $0 })
    }

    public init(_ value: Int) { self = .number(Double(value)) }
    public init(_ value: Int64) { self = .number(Double(value)) }
    public init(_ value: Double) { self = .number(value) }
    public init(_ value: Bool) { self = .bool(value) }
    public init(_ value: String) { self = .string(value) }
}

// MARK: - Serialization

extension JSONValue {
    public static func decode(from data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    public func encoded(prettyPrinted: Bool = false) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting =
            prettyPrinted ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.withoutEscapingSlashes]
        return try enc.encode(self)
    }

    /// Compact JSON text; used for wire frames.
    public func jsonText() throws -> String {
        String(decoding: try encoded(), as: UTF8.self)
    }

    /// Indented JSON text for the raw-event inspector.
    public var prettyText: String {
        (try? String(decoding: encoded(prettyPrinted: true), as: UTF8.self)) ?? "<unencodable>"
    }
}
