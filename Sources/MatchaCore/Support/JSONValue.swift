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

public extension JSONValue {
    var isNull: Bool { self == .null }

    var boolValue: Bool? {
        switch self {
        case let .bool(b): return b
        // OneBot implementations are loose with booleans on the wire.
        case let .number(n): return n != 0
        case let .string(s):
            switch s.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: return nil
            }
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case let .number(n): return n
        case let .string(s): return Double(s)
        case let .bool(b): return b ? 1 : 0
        default: return nil
        }
    }

    var intValue: Int? {
        guard let d = doubleValue, d.isFinite, d >= -9007199254740992, d <= 9007199254740992 else { return nil }
        return Int(d)
    }

    var int64Value: Int64? {
        guard let d = doubleValue, d.isFinite, d >= -9007199254740992, d <= 9007199254740992 else { return nil }
        return Int64(d)
    }

    /// Numbers stringify because peer IDs cross the wire as either form:
    /// OneBot v11 sends `user_id` as an integer, v12 and Milky as a string.
    var stringValue: String? {
        switch self {
        case let .string(s): return s
        case let .number(n):
            if let i = int64Value, Double(i) == n { return String(i) }
            return String(n)
        case let .bool(b): return b ? "true" : "false"
        default: return nil
        }
    }

    var arrayValue: [JSONValue]? {
        if case let .array(a) = self { return a }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case let .object(o) = self { return o }
        return nil
    }

    /// Member access on an object, `nil` for any other case.
    subscript(key: String) -> JSONValue? {
        guard case let .object(o) = self else { return nil }
        return o[key]
    }

    subscript(index: Int) -> JSONValue? {
        guard case let .array(a) = self, a.indices.contains(index) else { return nil }
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
        case let .bool(b): try c.encode(b)
        case let .number(n):
            // Emit whole numbers without a `.0` tail; OneBot peers expect
            // integral IDs and timestamps to look like integers.
            if let i = int64Value, Double(i) == n { try c.encode(i) } else { try c.encode(n) }
        case let .string(s): try c.encode(s)
        case let .array(a): try c.encode(a)
        case let .object(o): try c.encode(o)
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

public extension JSONValue {
    /// Builds an object, dropping `nil` members so optional fields stay absent
    /// rather than becoming explicit nulls — some peers reject `null` where they
    /// expect a missing key.
    static func compactObject(_ members: [String: JSONValue?]) -> JSONValue {
        .object(members.compactMapValues { $0 })
    }

    init(_ value: Int) { self = .number(Double(value)) }
    init(_ value: Int64) { self = .number(Double(value)) }
    init(_ value: Double) { self = .number(value) }
    init(_ value: Bool) { self = .bool(value) }
    init(_ value: String) { self = .string(value) }
}

// MARK: - Serialization

public extension JSONValue {
    static func decode(from data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }

    func encoded(prettyPrinted: Bool = false) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.withoutEscapingSlashes]
        return try enc.encode(self)
    }

    /// Compact JSON text; used for wire frames.
    func jsonText() throws -> String {
        String(decoding: try encoded(), as: UTF8.self)
    }

    /// Indented JSON text for the raw-event inspector.
    var prettyText: String {
        (try? String(decoding: encoded(prettyPrinted: true), as: UTF8.self)) ?? "<unencodable>"
    }
}
