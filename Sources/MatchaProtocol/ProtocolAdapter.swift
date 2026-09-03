import Foundation
import MatchaCore
import MatchaTransport

/// Protocol-specific metadata for a WebSocket connection Matcha initiates.
///
/// The operator owns the remote host, port, access token, and retry policy. The
/// implementation supplies only wire-level details: a useful default request path plus the
/// headers and subprotocols its protocol requires during the opening handshake.
public struct WebSocketClientHandshake: Sendable, Hashable {
    public var defaultPath: String
    public var headers: HTTPHeaders
    public var subprotocols: [String]

    public init(
        defaultPath: String = "/",
        headers: [(name: String, value: String)] = [],
        subprotocols: [String] = []
    ) {
        self.defaultPath = defaultPath
        self.headers = HTTPHeaders(headers)
        self.subprotocols = subprotocols
    }
}

/// What a protocol implementation must provide.
///
/// OneBot and Milky are peers here: neither is the base case the other extends.
/// A protocol implementation is a pure translator in two directions — inbound wire calls become
/// `PlatformCommand`s, and outbound `DomainEvent`s become wire events — and it
/// owns nothing else. All state lives in the store, all mutation goes through
/// `PlatformService`.
///
/// Because Milky dispatches on a URL path over HTTP while OneBot dispatches on an
/// `action` field over a socket, the contract is written in terms of *calls* and
/// *events* rather than frames, and each implementation decides how those reach the wire.
public protocol ProtocolImplementation: AnyObject, Sendable {
    /// Stable identifier used in settings, e.g. `onebot.v11`.
    static var identifier: String { get }
    /// Display name, e.g. `OneBot V11 Standard`.
    static var displayName: String { get }
    /// Which transports this protocol can speak.
    static var supportedTransports: Set<TransportMode> { get }

    /// Metadata used when Matcha dials a WebSocket application endpoint.
    var webSocketClientHandshake: WebSocketClientHandshake { get }

    /// The bot account this implementation represents. Events for other personas are
    /// not forwarded.
    var selfID: String { get }

    /// Handles one inbound call from the connected framework.
    ///
    /// Implementations do not throw for protocol-level failures: an unsupported action or a
    /// bad parameter is a normal response with a non-zero return code, which is what
    /// the framework expects to receive.
    func handle(call: ProtocolCall) async -> ProtocolReply

    /// Shapes a semantic reply into this protocol's wire envelope. OneBot uses
    /// `echo` for correlation; implementations without correlation ignore it.
    func envelope(for reply: ProtocolReply, echo: JSONValue?) -> JSONValue

    /// Translates a domain event into wire frames.
    ///
    /// Returning an empty array means this protocol has no representation for the
    /// event — the ordinary way an implementation declines, since the protocols cover
    /// different ground. One event may also produce several frames.
    func encode(event: DomainEvent) async -> [OutboundFrame]

    /// Frames to send immediately after a framework connects, such as OneBot's
    /// lifecycle meta-event. Milky has no such concept and returns nothing.
    func handshakeFrames() async -> [OutboundFrame]

    /// Periodic frames, if the protocol defines a heartbeat. `nil` disables the timer.
    var heartbeatInterval: TimeInterval? { get }
    func heartbeatFrame() async -> OutboundFrame?
}

extension ProtocolImplementation {
    /// Whether this implementation can be paired with a transport at the session boundary.
    public func supports(_ transport: TransportMode) -> Bool {
        Self.supportedTransports.contains(transport)
    }

    public var webSocketClientHandshake: WebSocketClientHandshake { WebSocketClientHandshake() }
    public func handshakeFrames() async -> [OutboundFrame] { [] }
    public var heartbeatInterval: TimeInterval? { nil }
    public func heartbeatFrame() async -> OutboundFrame? { nil }
}

/// Compatibility alias for the earlier, consumer-side terminology.
@available(*, deprecated, renamed: "ProtocolImplementation")
public typealias ProtocolAdapter = ProtocolImplementation

/// Which network role Matcha assumes for the selected protocol implementation.
public enum TransportMode: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Matcha (the OneBot implementation) listens and the framework connects.
    /// OneBot calls this a forward WebSocket connection.
    case webSocketServer
    /// Matcha dials the framework's WebSocket server. OneBot calls this a reverse
    /// WebSocket connection.
    case webSocketClient
    /// Matcha runs the Milky protocol service. `/api/*` and `/event` are always
    /// available; configured WebHook destinations are additional event sinks.
    case milkyService

    public var id: String { rawValue }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        if ["httpServer", "milkyWebSocket", "milkyWebhook"].contains(rawValue) {
            self = .milkyService
            return
        }
        guard let value = Self(rawValue: rawValue) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unknown transport mode: \(rawValue)"
            )
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var displayName: String {
        switch self {
        case .webSocketServer: return "WebSocket Server (Forward Connection)"
        case .webSocketClient: return "WebSocket Client (Reverse Connection)"
        case .milkyService: return "Milky Protocol Service"
        }
    }

    /// Source-compatible spellings for callers compiled against the earlier model.
    @available(*, deprecated, renamed: "milkyService")
    public static var httpServer: TransportMode { .milkyService }

    @available(*, deprecated, renamed: "milkyService")
    public static var milkyWebSocket: TransportMode { .milkyService }

    @available(*, deprecated, renamed: "milkyService")
    public static var milkyWebhook: TransportMode { .milkyService }
}

/// One inbound call from the framework.
///
/// `name` is the action to perform, however the protocol expressed it: OneBot reads
/// it from the `action` field of a socket frame, Milky from the URL path. Keeping
/// the two identical here is what lets the protocols sit side by side.
public struct ProtocolCall: Sendable {
    public var name: String
    public var parameters: JSONValue
    /// Correlation token to echo back. OneBot uses it; Milky, being
    /// request/response over HTTP, has none.
    public var echo: JSONValue?

    public init(name: String, parameters: JSONValue, echo: JSONValue? = nil) {
        self.name = name
        self.parameters = parameters
        self.echo = echo
    }

    /// Reads a parameter, accepting either a string or a number for IDs — the two
    /// protocols disagree on which, and implementations are loose in practice.
    public func id(_ key: String) -> String? {
        parameters[key]?.stringValue
    }

    public func string(_ key: String) -> String? {
        parameters[key]?.stringValue
    }

    public func int(_ key: String) -> Int? {
        parameters[key]?.intValue
    }

    public func int64(_ key: String) -> Int64? {
        parameters[key]?.int64Value
    }

    public func bool(_ key: String) -> Bool? {
        parameters[key]?.boolValue
    }

    public func array(_ key: String) -> [JSONValue]? {
        parameters[key]?.arrayValue
    }
}

/// The result of a call, ready for the implementation to shape into its wire envelope.
public struct ProtocolReply: Sendable {
    /// Protocol-specific return code. Zero means success in both protocols.
    public var retcode: Int
    public var data: JSONValue
    /// Human-readable failure text.
    public var message: String
    /// HTTP status, for protocols served over HTTP. Milky answers `200` for
    /// everything except auth, unknown routes, and bad content types.
    public var httpStatus: Int

    public var isSuccess: Bool { retcode == 0 }

    public init(retcode: Int = 0, data: JSONValue = .object([:]), message: String = "", httpStatus: Int = 200) {
        self.retcode = retcode
        self.data = data
        self.message = message
        self.httpStatus = httpStatus
    }

    public static func success(_ data: JSONValue = .object([:])) -> ProtocolReply {
        ProtocolReply(data: data)
    }
}

/// A frame to push to the framework.
public struct OutboundFrame: Sendable {
    public var payload: JSONValue
    /// Set for protocols that name their event stream, such as SSE's `event:` line.
    public var eventName: String?

    public init(payload: JSONValue, eventName: String? = nil) {
        self.payload = payload
        self.eventName = eventName
    }
}
