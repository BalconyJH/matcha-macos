import Foundation
import Network

/// Dials out to a bot framework's WebSocket server.
///
/// In OneBot this is the reverse direction: Matcha is the protocol implementation,
/// so it connects to the framework and both actions and events flow over the one
/// socket. Reconnection lives here rather than in the implementation, so a protocol never
/// has to think about the socket coming and going.
public final class WebSocketClient: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var url: URL
        /// Extra handshake headers. Protocols advertise their identity here
        /// (`X-Self-ID` for OneBot v11, a `User-Agent` for v12).
        public var headers: [(name: String, value: String)]
        /// Sent as `Authorization: Bearer …` when non-empty.
        public var accessToken: String?
        public var subprotocols: [String]
        /// Seconds between reconnect attempts; `nil` disables reconnection.
        public var reconnectInterval: TimeInterval?

        public init(
            url: URL,
            headers: [(name: String, value: String)] = [],
            accessToken: String? = nil,
            subprotocols: [String] = [],
            reconnectInterval: TimeInterval? = 3
        ) {
            self.url = url
            self.headers = headers
            self.accessToken = accessToken
            self.subprotocols = subprotocols
            self.reconnectInterval = reconnectInterval
        }
    }

    public enum Update: Sendable {
        case connected(WebSocketConnection)
        case failed(TransportError)
        /// Emitted before a reconnect attempt, so the UI can show progress.
        case reconnecting(afterSeconds: TimeInterval)
    }

    private let configuration: Configuration
    private let queue = DispatchQueue(label: "matcha.ws.client")
    private let lock = NSLock()
    private var updateContinuation: AsyncStream<Update>.Continuation?
    private var current: WebSocketConnection?
    private var explicitlyClosed = false
    private var reconnectWorkItem: DispatchWorkItem?
    /// Invalidates connection attempts and timers that raced with a later start/stop.
    private var generation: UInt64 = 0

    /// Connection lifecycle updates.
    public let updates: AsyncStream<Update>

    public init(configuration: Configuration) {
        self.configuration = configuration
        var continuation: AsyncStream<Update>.Continuation!
        updates = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        updateContinuation = continuation
    }

    public func start() {
        lock.lock()
        generation &+= 1
        let generation = generation
        explicitlyClosed = false
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        let previous = current
        current = nil
        lock.unlock()

        previous?.close()
        connect(generation: generation)
    }

    private func connect(generation: UInt64) {
        lock.lock()
        let shouldConnect =
            !explicitlyClosed
            && generation == self.generation
            && updateContinuation != nil
        lock.unlock()
        guard shouldConnect else { return }

        guard configuration.url.host != nil else {
            emit(.failed(.invalidURL(configuration.url.absoluteString)))
            return
        }
        let scheme = configuration.url.scheme?.lowercased()
        guard scheme == "ws" || scheme == "wss",
            configuration.url.port.map({ (1...Int(UInt16.max)).contains($0) }) ?? true
        else {
            emit(.failed(.invalidURL(configuration.url.absoluteString)))
            return
        }
        let isTLS = scheme == "wss"

        let parameters = isTLS ? NWParameters.tls : NWParameters.tcp
        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true

        // The handshake carries the protocol's identity headers plus auth.
        var headers = configuration.headers
        if let token = configuration.accessToken, !token.isEmpty {
            headers.append((name: "Authorization", value: "Bearer \(token)"))
        }
        var path = configuration.url.path.isEmpty ? "/" : configuration.url.path
        if let query = configuration.url.query, !query.isEmpty {
            path += "?\(query)"
        }
        options.setAdditionalHeaders(headers)
        if !configuration.subprotocols.isEmpty {
            options.setSubprotocols(configuration.subprotocols)
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)

        let endpoint = NWEndpoint.url(configuration.url)
        let nwConnection = NWConnection(to: endpoint, using: parameters)

        let connection = WebSocketConnection(
            connection: nwConnection,
            path: path,
            requestHeaders: HTTPHeaders(headers)
        )

        // `WebSocketConnection` is the single owner of NWConnection's state handler.
        // Installing another handler here would overwrite its receive lifecycle and
        // leave the client permanently stuck in the connecting state.
        let connectionID = connection.id
        lock.lock()
        guard !explicitlyClosed,
            generation == self.generation,
            updateContinuation != nil
        else {
            lock.unlock()
            connection.close()
            return
        }
        let previous = current
        current = connection
        connection.start(
            onReady: { [weak self] connection in
                self?.connectionDidBecomeReady(connection, generation: generation)
            },
            onClose: { [weak self] error in
                self?.connectionDidClose(connectionID, generation: generation, error: error)
            }
        )
        lock.unlock()
        previous?.close()
    }

    private func connectionDidBecomeReady(
        _ connection: WebSocketConnection,
        generation: UInt64
    ) {
        lock.lock()
        let isCurrent =
            !explicitlyClosed
            && generation == self.generation
            && current?.id == connection.id
        lock.unlock()
        if isCurrent { emit(.connected(connection)) }
    }

    private func connectionDidClose(
        _ id: String,
        generation: UInt64,
        error: TransportError?
    ) {
        lock.lock()
        guard generation == self.generation, current?.id == id else {
            lock.unlock()
            return
        }
        current = nil
        lock.unlock()

        if let error {
            emit(.failed(error))
        }
        scheduleReconnect(generation: generation)
    }

    private func scheduleReconnect(generation: UInt64) {
        lock.lock()
        let interval = configuration.reconnectInterval
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        guard !explicitlyClosed,
            generation == self.generation,
            updateContinuation != nil,
            let interval,
            interval > 0
        else {
            lock.unlock()
            return
        }

        let item = DispatchWorkItem { [weak self] in
            self?.connect(generation: generation)
        }
        reconnectWorkItem = item
        lock.unlock()

        emit(.reconnecting(afterSeconds: interval))
        queue.asyncAfter(deadline: .now() + interval, execute: item)
    }

    public func stop() {
        lock.lock()
        generation &+= 1
        explicitlyClosed = true
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
        let connection = current
        current = nil
        let continuation = updateContinuation
        updateContinuation = nil
        lock.unlock()

        connection?.close()
        continuation?.finish()
    }

    private func emit(_ update: Update) {
        lock.lock()
        let continuation = updateContinuation
        lock.unlock()
        continuation?.yield(update)
    }
}
