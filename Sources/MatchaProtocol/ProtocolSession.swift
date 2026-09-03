import Foundation
import MatchaCore
import MatchaTransport

// MARK: - Session state

/// Where a protocol session currently stands.
///
/// Server and client modes share one vocabulary: `listening` means Matcha is waiting
/// for a peer before it can exchange frames, `ready` means a protocol service is
/// available independently of consumer connections, and `connected` means a live
/// bidirectional socket exists.
public enum SessionState: Sendable, Equatable {
    case idle
    case listening(port: UInt16)
    case ready(port: UInt16)
    case connecting
    case connected(peer: String)
    case failed(String)

    public var displayName: String {
        switch self {
        case .idle:
            return "Disconnected"
        case .listening(let port):
            return "Listening on port \(port)"
        case .ready(let port):
            return "Serving on port \(port)"
        case .connecting:
            return "Connecting"
        case .connected(let peer):
            return "Connected to \(peer)"
        case .failed(let reason):
            return "Connection failed: \(reason)"
        }
    }

    /// Whether stopping the session is the meaningful next action.
    ///
    /// Listening counts as active even with no framework attached: the port is held,
    /// so there is something for the operator to stop.
    public var isActive: Bool {
        switch self {
        case .idle, .failed:
            return false
        case .listening, .ready, .connecting, .connected:
            return true
        }
    }
}

/// The latest WebSocket round-trip measurement for the live session.
///
/// This stays separate from `SessionState`: a missed probe is useful degradation
/// information, but it does not prove that application frames can no longer flow.
public enum RoundTripTimeState: Sendable, Equatable {
    /// There is no connected WebSocket peer to probe yet.
    case unavailable
    /// A peer is connected and the first probe is in flight.
    case measuring
    /// The slowest round trip among all currently connected peers.
    case measured(Duration)
    /// At least one connected peer did not answer the latest probe in time.
    case timedOut
    /// The transport has no persistent request channel whose RTT can be measured.
    case unsupported
}

/// A transport-level failure that does not end the session.
///
/// This is separate from ``TrafficEntry`` because traffic entries contain protocol
/// payloads. A WebHook delivery failure is operational state, not another wire
/// frame, and a later delivery may still succeed without restarting the API server.
public enum SessionDiagnostic: Sendable, Hashable {
    case outboundEventDeliveryFailed
}

/// Why a protocol session could not be started.
public enum ProtocolSessionError: Error, LocalizedError, Sendable {
    case unsupportedTransport(protocolIdentifier: String, transport: TransportMode)

    public var errorDescription: String? {
        switch self {
        case .unsupportedTransport(let identifier, let transport):
            return "Protocol \(identifier) does not support transport \(transport.rawValue)"
        }
    }
}

// MARK: - Traffic log

/// One line in the raw-payload inspector.
///
/// Carries the payload verbatim rather than a rendered form, because the inspector
/// exists for the case where a framework author needs to see exactly what crossed
/// the wire.
public struct TrafficEntry: Identifiable, Sendable {
    public enum Direction: Sendable, Hashable {
        /// A call the framework made.
        case inboundCall
        /// An event or heartbeat Matcha pushed.
        case outboundEvent
        /// Matcha's answer to a call.
        case reply
    }

    public let id: String
    public var direction: Direction
    public var timestamp: Date
    /// Short label for the list: an action name, an event type, or a failure reason.
    public var summary: String
    public var payload: JSONValue

    public init(
        id: String = IDGenerator.requestID(),
        direction: Direction,
        timestamp: Date = .now,
        summary: String,
        payload: JSONValue
    ) {
        self.id = id
        self.direction = direction
        self.timestamp = timestamp
        self.summary = summary
        self.payload = payload
    }
}

// MARK: - Session

/// Binds one protocol implementation to its endpoint transport and runs traffic.
///
/// The implementation knows nothing about sockets and the transports know nothing about
/// protocols; this is the only place the two meet. Inbound frames become
/// `ProtocolCall`s, domain events become `OutboundFrame`s, and every connected peer
/// receives the same events.
///
/// Wire envelopes belong to the protocol implementation. The session owns only
/// correlation transport, passing OneBot's optional `echo` through without knowing
/// the concrete response shape.
public actor ProtocolSession {
    public typealias Envelope = @Sendable (ProtocolReply, JSONValue?) -> JSONValue

    private let implementation: any ProtocolImplementation
    private let platform: PlatformService
    private let settings: ConnectionSettings

    public private(set) var state: SessionState = .idle
    public private(set) var roundTripTime: RoundTripTimeState = .unavailable

    private var stateSubscribers: [String: AsyncStream<SessionState>.Continuation] = [:]
    private var roundTripTimeSubscribers: [String: AsyncStream<RoundTripTimeState>.Continuation] = [:]
    private var trafficSubscribers: [String: AsyncStream<TrafficEntry>.Continuation] = [:]
    private var diagnosticSubscribers: [String: AsyncStream<SessionDiagnostic>.Continuation] = [:]

    private var webSocketServer: WebSocketServer?
    private var webSocketClient: WebSocketClient?
    private var milkyServer: HTTPServer?
    private var webhookClients: [HTTPWebhookClient] = []

    /// Sockets that have completed the WebSocket upgrade but not the protocol-level
    /// handshake. They are closed by teardown and are never visible to event fan-out.
    private var pendingConnections: [String: WebSocketConnection] = [:]
    private var connections: [String: WebSocketConnection] = [:]
    private var eventConnections: [String: HTTPWebSocketConnection] = [:]
    private var acceptTasks: [Task<Void, Never>] = []
    private var connectionTasks: [String: Task<Void, Never>] = [:]
    private var heartbeatTasks: [String: Task<Void, Never>] = [:]
    private var roundTripTimeTasks: [String: Task<Void, Never>] = [:]
    private var roundTripTimes: [String: Duration] = [:]
    private var timedOutConnections: Set<String> = []
    private var eventTask: Task<Void, Never>?
    /// Invalidates work that suspended in an earlier start/stop lifecycle.
    private var transportGeneration: UInt64 = 0

    private static let roundTripTimeInterval: Duration = .seconds(10)
    private static let roundTripTimeTimeout: Duration = .seconds(3)

    public init(
        implementation: any ProtocolImplementation,
        platform: PlatformService,
        settings: ConnectionSettings
    ) {
        self.implementation = implementation
        self.platform = platform
        self.settings = settings
    }

    @available(*, deprecated, message: "Use init(implementation:platform:settings:)")
    public init(
        adapter: any ProtocolImplementation,
        platform: PlatformService,
        settings: ConnectionSettings,
        envelope: @escaping Envelope
    ) {
        self.init(
            implementation: adapter,
            platform: platform,
            settings: settings
        )
    }

    // MARK: - Observation

    /// State changes, starting with the current state so a subscriber attaching late
    /// is not left blank until something moves.
    public func stateUpdates() -> AsyncStream<SessionState> {
        let token = IDGenerator.requestID()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            stateSubscribers[token] = continuation
            continuation.yield(state)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeStateSubscriber(token) }
            }
        }
    }

    public func trafficLog() -> AsyncStream<TrafficEntry> {
        let token = IDGenerator.requestID()
        return AsyncStream(bufferingPolicy: .unbounded) { continuation in
            trafficSubscribers[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeTrafficSubscriber(token) }
            }
        }
    }

    /// Operational failures that leave the session usable, such as one rejected
    /// WebHook delivery. Unlike state updates, diagnostics are edge-triggered.
    public func diagnostics() -> AsyncStream<SessionDiagnostic> {
        let token = IDGenerator.requestID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            diagnosticSubscribers[token] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeDiagnosticSubscriber(token) }
            }
        }
    }

    /// RTT updates, starting with the current value and retaining only the newest
    /// sample when a UI subscriber is temporarily busy.
    public func roundTripTimeUpdates() -> AsyncStream<RoundTripTimeState> {
        let token = IDGenerator.requestID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            roundTripTimeSubscribers[token] = continuation
            continuation.yield(roundTripTime)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeRoundTripTimeSubscriber(token) }
            }
        }
    }

    private func removeStateSubscriber(_ token: String) { stateSubscribers[token] = nil }
    private func removeRoundTripTimeSubscriber(_ token: String) { roundTripTimeSubscribers[token] = nil }
    private func removeTrafficSubscriber(_ token: String) { trafficSubscribers[token] = nil }
    private func removeDiagnosticSubscriber(_ token: String) { diagnosticSubscribers[token] = nil }

    private func setState(_ newState: SessionState) {
        guard newState != state else { return }
        state = newState
        for continuation in stateSubscribers.values {
            continuation.yield(newState)
        }
    }

    private func setRoundTripTime(_ newValue: RoundTripTimeState) {
        guard newValue != roundTripTime else { return }
        roundTripTime = newValue
        for continuation in roundTripTimeSubscribers.values {
            continuation.yield(newValue)
        }
    }

    private func log(_ entry: TrafficEntry) {
        for continuation in trafficSubscribers.values {
            continuation.yield(entry)
        }
    }

    private func report(_ diagnostic: SessionDiagnostic) {
        for continuation in diagnosticSubscribers.values {
            continuation.yield(diagnostic)
        }
    }

    // MARK: - Lifecycle

    public func start() async throws {
        // Only the transports are reset, never the observation streams: the app
        // subscribes to `stateUpdates()` and `trafficLog()` before calling `start()`,
        // and finishing those here would end them before the first frame arrived.
        teardownTransports()
        let generation = transportGeneration

        guard implementation.supports(settings.transport) else {
            throw ProtocolSessionError.unsupportedTransport(
                protocolIdentifier: type(of: implementation).identifier,
                transport: settings.transport
            )
        }

        do {
            switch settings.transport {
            case .webSocketServer:
                try await startWebSocketServer(generation: generation)
            case .webSocketClient:
                try startWebSocketClient(generation: generation)
            case .milkyService:
                try await startMilkyServer(generation: generation)
            }

            guard generation == transportGeneration else {
                throw TransportError.cancelled
            }
            try await startEventFanOut(generation: generation)
        } catch {
            if generation == transportGeneration {
                teardownTransports()
            }
            throw error
        }
    }

    public func stop() async {
        teardownTransports()

        // `.idle` is published before the streams close so a subscriber's last value
        // reflects a stopped session rather than whatever it was doing when it stopped.
        setState(.idle)
        for continuation in stateSubscribers.values { continuation.finish() }
        stateSubscribers.removeAll()
        for continuation in roundTripTimeSubscribers.values { continuation.finish() }
        roundTripTimeSubscribers.removeAll()
        for continuation in trafficSubscribers.values { continuation.finish() }
        trafficSubscribers.removeAll()
        for continuation in diagnosticSubscribers.values { continuation.finish() }
        diagnosticSubscribers.removeAll()
    }

    /// Cancels every task and closes every listener, leaving the observation streams
    /// intact so this is reusable from both `start()` and `stop()`.
    private func teardownTransports() {
        transportGeneration &+= 1

        eventTask?.cancel()
        eventTask = nil

        for task in acceptTasks { task.cancel() }
        acceptTasks.removeAll()
        for task in connectionTasks.values { task.cancel() }
        connectionTasks.removeAll()
        for task in heartbeatTasks.values { task.cancel() }
        heartbeatTasks.removeAll()
        for task in roundTripTimeTasks.values { task.cancel() }
        roundTripTimeTasks.removeAll()
        roundTripTimes.removeAll()
        timedOutConnections.removeAll()
        setRoundTripTime(.unavailable)

        for connection in pendingConnections.values { connection.close() }
        pendingConnections.removeAll()
        for connection in connections.values { connection.close() }
        connections.removeAll()

        webSocketServer?.stop()
        webSocketServer = nil
        webSocketClient?.stop()
        webSocketClient = nil
        milkyServer?.stop()
        milkyServer = nil
        webhookClients.removeAll()
        for connection in eventConnections.values { connection.close() }
        eventConnections.removeAll()
    }

    // MARK: - WebSocket server mode

    /// Listens for a framework to dial in. OneBot calls this a forward connection.
    private func startWebSocketServer(generation: UInt64) async throws {
        let server = WebSocketServer(
            host: settings.host,
            port: settings.port,
            authenticator: Self.authenticator(token: settings.accessToken)
        )
        webSocketServer = server
        do {
            try await server.start()
        } catch {
            if webSocketServer === server { webSocketServer = nil }
            throw error
        }
        guard generation == transportGeneration, webSocketServer === server else {
            server.stop()
            throw TransportError.cancelled
        }
        setState(.listening(port: settings.port))

        acceptTasks.append(
            Task { [weak self] in
                for await connection in server.connections {
                    guard !Task.isCancelled, let self else {
                        connection.close()
                        return
                    }
                    await self.adopt(connection, generation: generation)
                }
            })
    }

    /// The handshake gate for every inbound WebSocket connection.
    ///
    /// This runs before a connection exists and is the only check on the accept path,
    /// so it is written to fail closed: a missing header, a non-Bearer scheme, or a
    /// token that does not match is a rejection, and only an exact match accepts. The
    /// comparison is over the whole string because a prefix match would accept any
    /// token that merely starts with the secret.
    ///
    /// An empty configured token means the operator turned authentication off, which
    /// is why `ConnectionSettings.host` defaults to loopback.
    private static func authenticator(token: String) -> WebSocketServer.Authenticator {
        { _, headers in
            guard !token.isEmpty else { return .accept }
            guard
                let presented = headers.bearerToken
                    ?? headers["Sec-WebSocket-Protocol"].flatMap(Self.tokenFromSubprotocol)
            else {
                return .reject(reason: "Missing Access Token")
            }
            guard presented == token else {
                return .reject(reason: "Access Token mismatch")
            }
            return .accept
        }
    }

    /// OneBot implementations that cannot set headers pass the token as a
    /// `Sec-WebSocket-Protocol` entry of the form `token.<value>`. Accepting that form
    /// keeps browser-based frameworks usable without widening what counts as a match.
    private static func tokenFromSubprotocol(_ raw: String) -> String? {
        for entry in raw.split(separator: ",") {
            let trimmed = entry.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("token.") {
                return String(trimmed.dropFirst("token.".count))
            }
        }
        return nil
    }

    // MARK: - WebSocket client mode

    /// Dials the framework's own WebSocket server. OneBot calls this a reverse
    /// connection because the protocol implementation initiates it.
    private func startWebSocketClient(generation: UInt64) throws {
        let handshake = implementation.webSocketClientHandshake
        guard let url = settings.webSocketURL(defaultPath: handshake.defaultPath) else {
            throw TransportError.invalidURL("\(settings.host):\(settings.port)\(settings.path)")
        }

        let client = WebSocketClient(
            configuration: .init(
                url: url,
                headers: handshake.headers.all,
                accessToken: settings.accessToken.isEmpty ? nil : settings.accessToken,
                subprotocols: handshake.subprotocols,
                reconnectInterval: settings.autoReconnect ? settings.reconnectInterval : nil
            )
        )
        webSocketClient = client
        setState(.connecting)

        acceptTasks.append(
            Task { [weak self] in
                for await update in client.updates {
                    guard !Task.isCancelled, let self else { return }
                    guard await self.transportGeneration == generation else {
                        if case .connected(let connection) = update { connection.close() }
                        return
                    }
                    switch update {
                    case .connected(let connection):
                        await adopt(connection, generation: generation)
                    case .failed(let error):
                        await setState(.failed(error.localizedDescription))
                    case .reconnecting(let seconds):
                        await noteReconnect(after: seconds)
                    }
                }
            })

        client.start()
    }

    private func noteReconnect(after seconds: TimeInterval) {
        setState(.connecting)
        log(
            TrafficEntry(
                direction: .outboundEvent,
                summary: "Reconnecting in \(Int(seconds)) seconds",
                payload: ["reconnect_after": .number(seconds)]
            )
        )
    }

    // MARK: - Milky service

    /// Serves the Milky protocol endpoint.
    ///
    /// `/api/*` and `/event` are invariant capabilities of the implementation.
    /// WebHook destinations are additional event sinks and never disable `/event`.
    private func startMilkyServer(generation: UInt64) async throws {
        let token = settings.accessToken
        guard let webhookEndpoints = settings.milkyWebhookEndpoints else {
            let invalidValue =
                settings.milkyWebhookURLs.first {
                    ConnectionSettings.milkyWebhookEndpoint(for: $0) == nil
                } ?? ""
            throw TransportError.invalidURL(invalidValue)
        }
        let webhooks = webhookEndpoints.map { endpoint in
            HTTPWebhookClient(
                configuration: .init(
                    url: endpoint,
                    accessToken: token.isEmpty ? nil : token
                )
            )
        }

        let upgradeHandler: HTTPServer.WebSocketUpgradeHandler = { request in
            Self.milkyEventUpgrade(request: request, token: token)
        }
        let api = HTTPServer(
            host: settings.host,
            port: settings.port,
            webSocketUpgradeHandler: upgradeHandler,
            handler: { [weak self] request in
                guard let self else { return .empty(status: 503) }
                return await handle(request: request)
            }
        )
        milkyServer = api
        do {
            try await api.start()
        } catch {
            if milkyServer === api { milkyServer = nil }
            throw error
        }
        guard generation == transportGeneration, milkyServer === api else {
            api.stop()
            throw TransportError.cancelled
        }
        webhookClients = webhooks
        setState(.ready(port: settings.port))
        // The event socket is push-only; its ping does not describe API request
        // latency, so the session does not present it as service RTT.
        setRoundTripTime(.unsupported)

        acceptTasks.append(
            Task { [weak self] in
                for await connection in api.webSocketConnections {
                    guard !Task.isCancelled, let self else {
                        connection.close()
                        return
                    }
                    // Push-only: Milky sends nothing up this socket, so the connection is
                    // registered for fan-out without a receive loop.
                    await self.adoptEventStream(connection, generation: generation)
                }
            })
    }

    private static func milkyEventUpgrade(
        request: HTTPRequest,
        token: String
    ) -> HTTPServer.WebSocketUpgradeDecision {
        guard request.path == "/event" else { return .decline }
        guard request.method == "GET" else {
            return .reject(.text("/event only accepts GET", status: 405))
        }
        guard token.isEmpty || request.accessToken == token else {
            return .reject(
                .json(errorBody(retcode: -403, message: "Access Token validation failed"), status: 401)
            )
        }
        return .accept
    }

    /// Routes one HTTP request.
    private func handle(request: HTTPRequest) async -> HTTPResponse {
        guard isAuthorized(request) else {
            return .json(Self.errorBody(retcode: -403, message: "Access Token validation failed"), status: 401)
        }

        if request.path == "/event" {
            return .json(
                Self.errorBody(retcode: -400, message: "/event requires a WebSocket upgrade"),
                status: 426
            )
        }

        guard request.method == "POST", request.path.hasPrefix("/api/") else {
            return .json(Self.errorBody(retcode: -404, message: "Path not found: \(request.path)"), status: 404)
        }

        let name = String(request.path.dropFirst("/api/".count))
        guard !name.isEmpty else {
            return .json(Self.errorBody(retcode: -404, message: "No API name specified"), status: 404)
        }

        // Milky params are the bare request body, so a non-JSON content type cannot be
        // interpreted at all. An empty body is fine: many APIs take no parameters.
        let contentType = request.headers["Content-Type"]?.lowercased() ?? ""
        if !request.body.isEmpty, !contentType.contains("json") {
            return .json(Self.errorBody(retcode: -400, message: "Request body must be application/json"), status: 415)
        }

        let parameters: JSONValue
        if request.body.isEmpty {
            parameters = .object([:])
        } else if let decoded = try? JSONValue.decode(from: request.body) {
            parameters = decoded
        } else {
            // The route and media type are valid; malformed parameters are a Milky
            // action failure, represented in the protocol envelope over HTTP 200.
            return .json(Self.errorBody(retcode: -400, message: "Request body is not valid JSON"))
        }

        log(TrafficEntry(direction: .inboundCall, summary: name, payload: parameters))

        let reply = await implementation.handle(call: ProtocolCall(name: name, parameters: parameters))
        let body = implementation.envelope(for: reply, echo: nil)
        log(TrafficEntry(direction: .reply, summary: "\(name) → \(reply.retcode)", payload: body))

        guard let data = try? body.encoded() else {
            return .json(Self.errorBody(retcode: -500, message: "Failed to serialize response"), status: 500)
        }
        return .json(data, status: reply.httpStatus)
    }

    private func isAuthorized(_ request: HTTPRequest) -> Bool {
        guard !settings.accessToken.isEmpty else { return true }
        // Milky permits the query fallback only on `/event`, where some WebSocket
        // clients cannot set custom headers. API calls authenticate exclusively with
        // `Authorization: Bearer …`.
        guard let presented = request.headers.bearerToken else { return false }
        return presented == settings.accessToken
    }

    private static func errorBody(retcode: Int, message: String) -> Data {
        let payload: JSONValue = [
            "status": "failed",
            "retcode": .number(Double(retcode)),
            "message": .string(message),
        ]
        return (try? payload.encoded()) ?? Data()
    }

    // MARK: - Connections

    /// Takes on a bidirectional connection: handshake, heartbeat, then receive.
    private func adopt(_ connection: WebSocketConnection, generation: UInt64) async {
        guard !Task.isCancelled, generation == transportGeneration else {
            connection.close()
            return
        }
        pendingConnections[connection.id] = connection

        // Keep the socket out of `connections` until every protocol handshake frame
        // has been sent. `handshakeFrames()` is async, so this actor can re-enter and
        // broadcast a domain event while it is suspended; registering first would let
        // that event overtake OneBot v12's mandatory first `meta.connect` frame.
        let handshakeFrames = await implementation.handshakeFrames()
        guard canPromote(connection, generation: generation) else {
            abandonPending(connection)
            return
        }
        for frame in handshakeFrames {
            guard await send(frame, to: connection, generation: generation),
                canPromote(connection, generation: generation)
            else {
                abandonPending(connection)
                return
            }
        }

        pendingConnections[connection.id] = nil
        connections[connection.id] = connection
        setState(.connected(peer: connection.peerDescription))
        startHeartbeat(on: connection)
        startRoundTripTimeMonitoring(on: connection)

        connectionTasks[connection.id] = Task { [weak self] in
            for await frame in connection.frames {
                guard let self else { return }
                await receive(frame, from: connection, generation: generation)
            }
            // The stream finishing is the connection closing.
            await self?.release(connection.id, generation: generation)
        }
    }

    /// Takes on a push-only connection, as Milky's `/event` stream is.
    private func adoptEventStream(
        _ connection: HTTPWebSocketConnection,
        generation: UInt64
    ) async {
        guard !Task.isCancelled, generation == transportGeneration else {
            connection.close()
            return
        }
        eventConnections[connection.id] = connection

        connectionTasks[connection.id] = Task { [weak self] in
            // Nothing is expected inbound; draining the stream is how the close is
            // observed.
            for await _ in connection.frames {}
            await self?.releaseEventConnection(connection.id, generation: generation)
        }
    }

    private func releaseEventConnection(_ id: String, generation: UInt64) {
        guard generation == transportGeneration else { return }
        eventConnections[id] = nil
        connectionTasks[id]?.cancel()
        connectionTasks[id] = nil
        if generation == transportGeneration,
            connections.isEmpty,
            eventConnections.isEmpty,
            milkyServer != nil
        {
            setMilkyIdleState()
        }
    }

    private func release(_ id: String, generation: UInt64) {
        guard generation == transportGeneration else { return }
        pendingConnections[id]?.close()
        pendingConnections[id] = nil
        connections[id] = nil
        connectionTasks[id]?.cancel()
        connectionTasks[id] = nil
        heartbeatTasks[id]?.cancel()
        heartbeatTasks[id] = nil
        roundTripTimeTasks[id]?.cancel()
        roundTripTimeTasks[id] = nil
        roundTripTimes[id] = nil
        timedOutConnections.remove(id)
        refreshRoundTripTimeState()

        // Server modes go back to waiting; a dial-out session reports the drop and
        // lets `WebSocketClient` handle retrying.
        if generation == transportGeneration, connections.isEmpty, eventConnections.isEmpty {
            switch settings.transport {
            case .webSocketServer, .milkyService:
                if webSocketServer != nil || milkyServer != nil {
                    if settings.transport == .milkyService {
                        setMilkyIdleState()
                    } else {
                        setState(.listening(port: settings.port))
                    }
                }
            case .webSocketClient:
                if webSocketClient != nil {
                    setState(settings.autoReconnect ? .connecting : .idle)
                }
            }
        }
    }

    private func setMilkyIdleState() {
        setState(.ready(port: settings.port))
    }

    private func canPromote(_ connection: WebSocketConnection, generation: UInt64) -> Bool {
        !Task.isCancelled
            && generation == transportGeneration
            && pendingConnections[connection.id] === connection
    }

    private func abandonPending(_ connection: WebSocketConnection) {
        if pendingConnections[connection.id] === connection {
            pendingConnections[connection.id] = nil
        }
        connection.close()
    }

    /// Decodes one inbound frame as an action call and answers it.
    private func receive(
        _ frame: WebSocketFrame,
        from connection: WebSocketConnection,
        generation: UInt64
    ) async {
        guard generation == transportGeneration,
            connections[connection.id] === connection
        else { return }
        guard let text = frame.textValue else { return }
        guard let payload = try? JSONValue.decode(from: Data(text.utf8)),
            let action = payload["action"]?.stringValue
        else {
            log(
                TrafficEntry(
                    direction: .inboundCall,
                    summary: "Unparseable frame",
                    payload: .string(text)
                )
            )
            return
        }

        let echo = payload["echo"]
        let parameters = payload["params"] ?? payload["data"] ?? .object([:])
        log(TrafficEntry(direction: .inboundCall, summary: action, payload: payload))

        let reply = await implementation.handle(
            call: ProtocolCall(name: action, parameters: parameters, echo: echo)
        )
        guard generation == transportGeneration,
            connections[connection.id] === connection
        else { return }
        // The transport owns correlation: the implementation never sees `echo`, and the
        // envelope closure splices it back on.
        let response = implementation.envelope(for: reply, echo: echo)
        log(TrafficEntry(direction: .reply, summary: "\(action) → \(reply.retcode)", payload: response))
        await send(OutboundFrame(payload: response), to: connection, generation: generation)
    }

    private func startHeartbeat(on connection: WebSocketConnection) {
        guard let interval = implementation.heartbeatInterval, interval > 0 else { return }
        let id = connection.id
        let generation = transportGeneration
        heartbeatTasks[id] = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self else { return }
                guard let frame = await implementation.heartbeatFrame() else { continue }
                await sendHeartbeat(frame, connectionID: id, generation: generation)
            }
        }
    }

    private func sendHeartbeat(
        _ frame: OutboundFrame,
        connectionID: String,
        generation: UInt64
    ) async {
        guard generation == transportGeneration,
            let connection = connections[connectionID]
        else { return }
        await send(frame, to: connection, generation: generation)
    }

    // MARK: - Round-trip time

    /// Probes the WebSocket control channel independently from protocol heartbeats.
    /// OneBot's JSON heartbeat has no acknowledgement and therefore cannot measure
    /// latency; WebSocket Ping/Pong has exactly the required request/response shape.
    private func startRoundTripTimeMonitoring(on connection: WebSocketConnection) {
        guard settings.transport != .milkyService else {
            setRoundTripTime(.unsupported)
            return
        }

        let id = connection.id
        roundTripTimes[id] = nil
        timedOutConnections.remove(id)
        refreshRoundTripTimeState()

        roundTripTimeTasks[id]?.cancel()
        roundTripTimeTasks[id] = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let duration = try await connection.measureRoundTripTime(
                        timeout: Self.roundTripTimeTimeout
                    )
                    guard !Task.isCancelled, let self else { return }
                    await recordRoundTripTime(duration, connectionID: id)
                } catch let error as TransportError {
                    guard !Task.isCancelled, let self else { return }
                    switch error {
                    case .cancelled:
                        return
                    case .notConnected:
                        // An accepted server-side socket can be adopted just before
                        // Network.framework reports `.ready`. Keep the UI in
                        // measuring state and retry promptly instead of showing a
                        // false timeout for the first interval.
                        do {
                            try await Task.sleep(for: .milliseconds(250))
                        } catch {
                            return
                        }
                        continue
                    case .timedOut:
                        await recordRoundTripTimeTimeout(connectionID: id)
                    default:
                        // A failed control-frame send is treated as a degraded probe.
                        // The connection's receive loop remains authoritative about
                        // whether the peer has actually disconnected.
                        await recordRoundTripTimeTimeout(connectionID: id)
                    }
                } catch {
                    guard !Task.isCancelled, let self else { return }
                    await recordRoundTripTimeTimeout(connectionID: id)
                }

                do {
                    try await Task.sleep(for: Self.roundTripTimeInterval)
                } catch {
                    return
                }
            }
        }
    }

    private func recordRoundTripTime(_ duration: Duration, connectionID: String) {
        guard connections[connectionID] != nil else { return }
        roundTripTimes[connectionID] = duration
        timedOutConnections.remove(connectionID)
        refreshRoundTripTimeState()
    }

    private func recordRoundTripTimeTimeout(connectionID: String) {
        guard connections[connectionID] != nil else { return }
        roundTripTimes[connectionID] = nil
        timedOutConnections.insert(connectionID)
        refreshRoundTripTimeState()
    }

    private func refreshRoundTripTimeState() {
        guard settings.transport != .milkyService else {
            setRoundTripTime(.unsupported)
            return
        }

        let connectionIDs = Set(connections.keys)
        guard !connectionIDs.isEmpty else {
            setRoundTripTime(.unavailable)
            return
        }
        guard timedOutConnections.isDisjoint(with: connectionIDs) else {
            setRoundTripTime(.timedOut)
            return
        }

        let samples = connectionIDs.compactMap { roundTripTimes[$0] }
        guard samples.count == connectionIDs.count, let slowest = samples.max() else {
            setRoundTripTime(.measuring)
            return
        }
        setRoundTripTime(.measured(slowest))
    }

    // MARK: - Event fan-out

    /// Subscribes once and mirrors every event to every live connection.
    private func startEventFanOut(generation: UInt64) async throws {
        // Register with PlatformService before `start()` returns. Creating a Task
        // first and subscribing inside it leaves a race where the operator's first
        // event can be published before the task gets scheduled.
        let events = await platform.events()
        guard generation == transportGeneration else {
            throw TransportError.cancelled
        }
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in events {
                if Task.isCancelled { return }
                await broadcast(event, generation: generation)
            }
        }
    }

    private func broadcast(_ event: DomainEvent, generation: UInt64) async {
        guard generation == transportGeneration else { return }
        let frames = await implementation.encode(event: event)
        guard generation == transportGeneration else { return }
        // Empty means this protocol has no representation for the event. That is the
        // ordinary way an implementation declines, since the protocols cover different
        // ground, so it is not logged as a problem.
        guard !frames.isEmpty else { return }

        let targets = Array(connections.values)
        let eventTargets = Array(eventConnections.values)
        let webhookTargets = webhookClients
        for frame in frames {
            log(
                TrafficEntry(
                    direction: .outboundEvent,
                    summary: Self.summary(of: frame),
                    payload: frame.payload
                )
            )
            for connection in targets {
                await send(frame, to: connection, generation: generation, logging: false)
            }
            for connection in eventTargets {
                await send(frame, to: connection, generation: generation, logging: false)
            }
            for webhookTarget in webhookTargets {
                await send(frame, to: webhookTarget, generation: generation, logging: false)
            }
        }
    }

    /// Writes one frame, dropping the connection if the write fails.
    @discardableResult
    private func send(
        _ frame: OutboundFrame,
        to connection: WebSocketConnection,
        generation: UInt64,
        logging: Bool = true
    ) async -> Bool {
        guard generation == transportGeneration,
            pendingConnections[connection.id] === connection
                || connections[connection.id] === connection
        else { return false }
        guard let text = try? frame.payload.jsonText() else { return false }
        if logging {
            log(
                TrafficEntry(
                    direction: .outboundEvent,
                    summary: Self.summary(of: frame),
                    payload: frame.payload
                )
            )
        }
        do {
            try await connection.send(.text(text))
            return generation == transportGeneration
        } catch {
            release(connection.id, generation: generation)
            return false
        }
    }

    /// Writes one event to a WebSocket upgraded from Milky's HTTP listener.
    @discardableResult
    private func send(
        _ frame: OutboundFrame,
        to connection: HTTPWebSocketConnection,
        generation: UInt64,
        logging: Bool = true
    ) async -> Bool {
        guard generation == transportGeneration,
            eventConnections[connection.id] === connection
        else { return false }
        guard let text = try? frame.payload.jsonText() else { return false }
        if logging {
            log(
                TrafficEntry(
                    direction: .outboundEvent,
                    summary: Self.summary(of: frame),
                    payload: frame.payload
                )
            )
        }
        do {
            try await connection.send(.text(text))
            return generation == transportGeneration
        } catch {
            releaseEventConnection(connection.id, generation: generation)
            connection.close()
            return false
        }
    }

    /// Delivers one Milky event without implying a persistent connection. A failed
    /// delivery is reported separately from raw traffic, while the API listener
    /// remains active and subsequent events can still succeed.
    @discardableResult
    private func send(
        _ frame: OutboundFrame,
        to client: HTTPWebhookClient,
        generation: UInt64,
        logging: Bool = true
    ) async -> Bool {
        guard generation == transportGeneration,
            settings.transport == .milkyService,
            !webhookClients.isEmpty,
            let data = try? frame.payload.encoded()
        else { return false }
        if logging {
            log(
                TrafficEntry(
                    direction: .outboundEvent,
                    summary: Self.summary(of: frame),
                    payload: frame.payload
                )
            )
        }
        do {
            try await client.post(data)
            return generation == transportGeneration
        } catch is CancellationError {
            return false
        } catch {
            guard generation == transportGeneration else { return false }
            report(.outboundEventDeliveryFailed)
            return false
        }
    }

    /// A readable label for the inspector, taken from whichever field the protocol
    /// names its event type in.
    private static func summary(of frame: OutboundFrame) -> String {
        let payload = frame.payload
        if let type = payload["event_type"]?.stringValue { return type }
        if let type = payload["post_type"]?.stringValue {
            let detail =
                payload["message_type"]?.stringValue
                ?? payload["notice_type"]?.stringValue
                ?? payload["meta_event_type"]?.stringValue
                ?? payload["request_type"]?.stringValue
            return detail.map { "\(type).\($0)" } ?? type
        }
        if let type = payload["type"]?.stringValue {
            let detail = payload["detail_type"]?.stringValue
            return detail.map { "\(type).\($0)" } ?? type
        }
        if payload["retcode"] != nil { return "Response" }
        return frame.eventName ?? "Event"
    }
}
