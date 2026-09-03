import Foundation

/// Everything the operator configures about one peer connection.
///
/// Deliberately protocol-neutral: which implementation is active is a separate choice, and
/// the same host/port/token settings apply whether the traffic ends up as OneBot
/// frames or Milky requests. `ProtocolSession` reads this once in `start()`, so
/// edits to a running session take effect on the next restart rather than half-way
/// through a live connection.
public struct ConnectionSettings: Codable, Sendable, Hashable {
    /// Conventional high port for this ecosystem, and above the privileged range so
    /// Matcha never needs elevation to listen.
    public static let defaultPort: UInt16 = 5700
    public static let defaultMilkyWebhookURL = "http://127.0.0.1:8080/milky/"

    public var transport: TransportMode

    /// The peer address: which host to dial in client mode, and the address shown to
    /// the local interface to bind in server modes.
    ///
    /// Loopback by default because this is a control surface for the whole simulated
    /// platform and `accessToken` is empty by default. Handing out a LAN address for
    /// an unauthenticated endpoint would let anything on the network send messages as
    /// any persona. Changing this field to a routable address is the operator declaring
    /// they want that exposure, and it should be paired with a token.
    public var host: String

    public var port: UInt16

    /// Request path for the dial-out URL, e.g. `/onebot/v11/ws`. An empty value
    /// asks the selected implementation for its recommended path. Ignored in server modes,
    /// where the framework picks the path it connects to.
    public var path: String

    /// Shared secret checked on every inbound connection and request. Empty means no
    /// authentication, which is why `host` defaults to loopback.
    public var accessToken: String

    /// Application endpoints that receive copies of every Milky event. These are
    /// additive: `/event` remains available to WebSocket consumers at the same time.
    public var milkyWebhookURLs: [String]

    public var autoReconnect: Bool

    /// Seconds between dial-out attempts. Only consulted when `autoReconnect` is on.
    public var reconnectInterval: TimeInterval

    /// Whether a bot is told about activity it caused itself. Off matches how a real
    /// platform behaves; on is useful when debugging a framework's own sends.
    public var postSelfEvents: Bool

    public init(
        transport: TransportMode = .webSocketServer,
        host: String = "127.0.0.1",
        port: UInt16 = ConnectionSettings.defaultPort,
        path: String = "",
        accessToken: String = "",
        milkyWebhookURLs: [String] = [],
        autoReconnect: Bool = true,
        reconnectInterval: TimeInterval = 3,
        postSelfEvents: Bool = false
    ) {
        self.transport = transport
        self.host = host
        self.port = port
        self.path = path
        self.accessToken = accessToken
        self.milkyWebhookURLs = milkyWebhookURLs
        self.autoReconnect = autoReconnect
        self.reconnectInterval = reconnectInterval
        self.postSelfEvents = postSelfEvents
    }

    // MARK: - Derived endpoints

    /// The URL to dial in `webSocketClient` mode, using `/` when no implementation context
    /// is available.
    public var webSocketURL: URL? {
        webSocketURL(defaultPath: "/")
    }

    /// Builds the dial-out URL with an implementation-provided path when the operator left
    /// the path blank. An explicit `/` remains an explicit root-path choice.
    public func webSocketURL(defaultPath: String) -> URL? {
        var components = URLComponents()
        components.scheme = "ws"
        components.host = host
        components.port = Int(port)
        // URLComponents rejects a path that is neither empty nor rooted.
        let configuredPath = path.trimmingCharacters(in: .whitespaces)
        let fallbackPath = defaultPath.trimmingCharacters(in: .whitespaces)
        let resolvedPath = configuredPath.isEmpty ? fallbackPath : configuredPath
        components.path = resolvedPath.isEmpty || resolvedPath == "/"
            ? ""
            : (resolvedPath.hasPrefix("/") ? resolvedPath : "/" + resolvedPath)
        return components.url
    }

    /// Milky serves `/api/:api` and `/event` from the same HTTP server and port.
    public var eventStreamURL: URL? {
        var components = URLComponents()
        components.scheme = "ws"
        components.host = host
        components.port = Int(port)
        components.path = "/event"
        return components.url
    }

    public var milkyWebhookEndpoints: [URL]? {
        var endpoints: [URL] = []
        for value in milkyWebhookURLs {
            guard let endpoint = Self.milkyWebhookEndpoint(for: value) else { return nil }
            endpoints.append(endpoint)
        }
        return endpoints
    }

    public static func milkyWebhookEndpoint(for rawValue: String) -> URL? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false,
              components.port.map({ (1 ... Int(UInt16.max)).contains($0) }) ?? true
        else { return nil }
        return components.url
    }

    /// Compatibility surface for the earlier single-destination settings model.
    @available(*, deprecated, message: "Use milkyWebhookURLs")
    public var milkyWebhookURL: String {
        get { milkyWebhookURLs.first ?? "" }
        set { milkyWebhookURLs = newValue.isEmpty ? [] : [newValue] }
    }

    @available(*, deprecated, message: "Use milkyWebhookEndpoints")
    public var milkyWebhookEndpoint: URL? {
        milkyWebhookURLs.first.flatMap(Self.milkyWebhookEndpoint(for:))
    }

    private enum CodingKeys: String, CodingKey {
        case transport
        case host
        case port
        case path
        case accessToken
        case milkyWebhookURLs
        case milkyWebhookURL
        case autoReconnect
        case reconnectInterval
        case postSelfEvents
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let persistedTransport = try container.decodeIfPresent(String.self, forKey: .transport)
            ?? TransportMode.webSocketServer.rawValue
        if ["httpServer", "milkyWebSocket", "milkyWebhook"].contains(persistedTransport) {
            transport = .milkyService
        } else if let decoded = TransportMode(rawValue: persistedTransport) {
            transport = decoded
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .transport,
                in: container,
                debugDescription: "Unknown transport mode: \(persistedTransport)"
            )
        }
        host = try container.decodeIfPresent(String.self, forKey: .host) ?? "127.0.0.1"
        port = try container.decodeIfPresent(UInt16.self, forKey: .port) ?? Self.defaultPort
        path = try container.decodeIfPresent(String.self, forKey: .path) ?? ""
        accessToken = try container.decodeIfPresent(String.self, forKey: .accessToken) ?? ""
        if let destinations = try container.decodeIfPresent(
            [String].self,
            forKey: .milkyWebhookURLs
        ) {
            milkyWebhookURLs = destinations
        } else if persistedTransport == "milkyWebhook" {
            let destination = try container.decodeIfPresent(String.self, forKey: .milkyWebhookURL)
                ?? Self.defaultMilkyWebhookURL
            milkyWebhookURLs = destination.isEmpty ? [] : [destination]
        } else {
            milkyWebhookURLs = []
        }
        autoReconnect = try container.decodeIfPresent(Bool.self, forKey: .autoReconnect) ?? true
        reconnectInterval = try container.decodeIfPresent(
            TimeInterval.self,
            forKey: .reconnectInterval
        ) ?? 3
        postSelfEvents = try container.decodeIfPresent(Bool.self, forKey: .postSelfEvents) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(transport, forKey: .transport)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(path, forKey: .path)
        try container.encode(accessToken, forKey: .accessToken)
        try container.encode(milkyWebhookURLs, forKey: .milkyWebhookURLs)
        try container.encode(autoReconnect, forKey: .autoReconnect)
        try container.encode(reconnectInterval, forKey: .reconnectInterval)
        try container.encode(postSelfEvents, forKey: .postSelfEvents)
    }
}
