import Foundation
import Network

/// One WebSocket message.
public enum WebSocketFrame: Sendable, Hashable {
    case text(String)
    case binary(Data)

    /// The bytes to send.
    public var data: Data {
        switch self {
        case .text(let t): return Data(t.utf8)
        case .binary(let d): return d
        }
    }

    var opcode: NWProtocolWebSocket.Opcode {
        switch self {
        case .text: return .text
        case .binary: return .binary
        }
    }

    /// UTF-8 text if this frame carries any.
    public var textValue: String? {
        switch self {
        case .text(let t): return t
        case .binary(let d): return String(data: d, encoding: .utf8)
        }
    }
}

/// Why a connection ended.
public enum TransportError: Error, LocalizedError, Sendable {
    case listenFailed(port: UInt16, underlying: String)
    case connectFailed(String)
    case handshakeRejected(reason: String)
    case notConnected
    case cancelled
    case invalidURL(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .listenFailed(let port, let underlying):
            return "Failed to listen on port \(port): \(underlying)"
        case .connectFailed(let reason):
            return "Connection failed: \(reason)"
        case .handshakeRejected(let reason):
            return "Handshake rejected: \(reason)"
        case .notConnected:
            return "Not connected"
        case .cancelled:
            return "Connection cancelled"
        case .invalidURL(let url):
            return "Invalid URL: \(url)"
        case .timedOut:
            return "Connection timed out"
        }
    }
}

/// A single HTTP header, as Network.framework reports it during the WebSocket
/// handshake.
public struct HTTPHeaders: Sendable, Hashable {
    private var storage: [(name: String, value: String)]

    public init(_ pairs: [(name: String, value: String)] = []) {
        storage = pairs
    }

    /// Case-insensitive lookup, per RFC 7230.
    public subscript(name: String) -> String? {
        let target = name.lowercased()
        return storage.first { $0.name.lowercased() == target }?.value
    }

    /// All values for a header name. HTTP permits repeated fields, and framing
    /// headers such as `Content-Length` must be validated as a set rather than by
    /// silently trusting the first one.
    public func values(for name: String) -> [String] {
        let target = name.lowercased()
        return storage.compactMap { pair in
            pair.name.lowercased() == target ? pair.value : nil
        }
    }

    public mutating func add(_ name: String, _ value: String) {
        storage.append((name, value))
    }

    public var all: [(name: String, value: String)] { storage }

    /// The bearer token from an `Authorization` header, if present.
    public var bearerToken: String? {
        guard let raw = self["Authorization"] else { return nil }
        let parts = raw.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return nil }
        return String(parts[1])
    }

    public static func == (lhs: HTTPHeaders, rhs: HTTPHeaders) -> Bool {
        lhs.storage.map { [$0.name, $0.value] } == rhs.storage.map { [$0.name, $0.value] }
    }

    public func hash(into hasher: inout Hasher) {
        for pair in storage {
            hasher.combine(pair.name)
            hasher.combine(pair.value)
        }
    }
}
