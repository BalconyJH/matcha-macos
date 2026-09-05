import Foundation
import Network

/// Accepts WebSocket connections from bot frameworks.
///
/// This is the forward direction in OneBot terms: the framework dials Rei, the
/// protocol implementation's WebSocket server.
/// Built on `NWListener` with `NWProtocolWebSocket`, which performs the RFC 6455
/// server handshake itself — the `clientRequestHandler` is the hook where a
/// connection is authenticated or refused before it is ever established.
public final class WebSocketServer: @unchecked Sendable {
    /// Decides whether an incoming handshake is allowed.
    ///
    /// Returning a rejection makes Network.framework fail the handshake, so a bot
    /// with a bad token sees an HTTP-level refusal instead of a silently dead
    /// connection.
    public typealias Authenticator = @Sendable (_ path: String, _ headers: HTTPHeaders) -> Authorization

    public enum Authorization: Sendable {
        case accept
        case reject(reason: String)
    }

    public let host: String
    public let port: UInt16
    private let authenticator: Authenticator
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "rei.ws.server")
    private let lock = NSLock()
    private var startup: ListenerStartup?
    private var connectionContinuation: AsyncStream<WebSocketConnection>.Continuation?
    /// Paths captured per pending connection: the handshake handler runs before
    /// `newConnectionHandler`, so the request line is recorded here and claimed
    /// when the connection surfaces.
    private var pendingHandshakes: [(path: String, headers: HTTPHeaders)] = []
    private var liveConnections: [String: WebSocketConnection] = [:]

    /// Connections as they are accepted.
    public let connections: AsyncStream<WebSocketConnection>

    public init(
        host: String = "127.0.0.1",
        port: UInt16,
        authenticator: @escaping Authenticator = { _, _ in .accept }
    ) {
        self.host = host
        self.port = port
        self.authenticator = authenticator

        var continuation: AsyncStream<WebSocketConnection>.Continuation!
        connections = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        connectionContinuation = continuation
    }

    public func start() async throws {
        let parameters = NWParameters.tcp
        // Bot frameworks commonly run on the same machine as Rei.
        parameters.includePeerToPeer = false

        let options = NWProtocolWebSocket.Options()
        options.autoReplyPing = true
        options.setClientRequestHandler(queue) { [weak self] subprotocols, headerPairs in
            guard let self else {
                return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil)
            }
            var headers = HTTPHeaders(headerPairs)
            // Network.framework reports proposed subprotocols separately from the
            // additional headers even though they originate in the standard
            // `Sec-WebSocket-Protocol` request header. Normalize them into the same
            // view used by authenticators and connection diagnostics.
            if headers["Sec-WebSocket-Protocol"] == nil, !subprotocols.isEmpty {
                headers.add("Sec-WebSocket-Protocol", subprotocols.joined(separator: ", "))
            }
            // Network.framework does not expose the request target directly. Keep a
            // best-effort lookup for platform-provided pseudo-headers and otherwise
            // report `/`; routing is owned by the single configured implementation.
            let path = Self.requestPath(from: headers)

            switch authenticator(path, headers) {
            case .accept:
                lock.lock()
                pendingHandshakes.append((path, headers))
                lock.unlock()
                return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
            case .reject:
                return NWProtocolWebSocket.Response(status: .reject, subprotocol: nil)
            }
        }
        parameters.defaultProtocolStack.applicationProtocols.insert(options, at: 0)

        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw TransportError.listenFailed(port: port, underlying: "Invalid port")
        }
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(host),
            port: nwPort
        )

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters)
        } catch {
            throw TransportError.listenFailed(port: port, underlying: error.localizedDescription)
        }

        let startup = ListenerStartup()
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            switch state {
            case .ready:
                startup.resolve(.success(()))
                self?.startupDidFinish(startup)
            case .failed(let error):
                let failure = TransportError.listenFailed(
                    port: self?.port ?? 0,
                    underlying: error.localizedDescription
                )
                startup.resolve(.failure(failure))
                if let listener {
                    self?.listenerDidEnd(listener)
                }
            case .cancelled:
                startup.resolve(.failure(.cancelled))
                if let listener {
                    self?.listenerDidEnd(listener)
                }
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self, weak listener] nwConnection in
            guard let self, let listener else {
                nwConnection.cancel()
                return
            }
            lock.lock()
            guard self.listener === listener, let continuation = connectionContinuation else {
                lock.unlock()
                nwConnection.cancel()
                return
            }
            let handshake = pendingHandshakes.isEmpty ? nil : pendingHandshakes.removeFirst()
            lock.unlock()

            let connection = WebSocketConnection(
                connection: nwConnection,
                path: handshake?.path ?? "/",
                requestHeaders: handshake?.headers ?? HTTPHeaders()
            )
            // `newConnectionHandler` runs after the WebSocket handshake has been
            // accepted. Server-side Network.framework connections do not reliably
            // emit another `.ready` transition after this point, so publish the
            // accepted connection once its receive lifecycle has been installed.
            lock.lock()
            liveConnections[connection.id] = connection
            lock.unlock()
            let connectionID = connection.id
            connection.start(onClose: { [weak self] _ in
                self?.removeConnection(connectionID)
            })
            if case .terminated = continuation.yield(connection) {
                connection.close()
            }
        }

        let listenerInstalled = lock.withLock {
            guard self.listener == nil, connectionContinuation != nil else { return false }
            self.listener = listener
            self.startup = startup
            return true
        }
        guard listenerInstalled else {
            listener.cancel()
            throw TransportError.listenFailed(port: port, underlying: "Listener has already started or stopped")
        }
        listener.start(queue: queue)

        do {
            try await startup.value()
        } catch {
            listenerDidEnd(listener)
            listener.cancel()
            throw error
        }
    }

    public func stop() {
        lock.lock()
        let listener = listener
        self.listener = nil
        let startup = startup
        self.startup = nil
        let continuation = connectionContinuation
        connectionContinuation = nil
        pendingHandshakes.removeAll()
        let connections = liveConnections
        liveConnections.removeAll()
        lock.unlock()

        listener?.cancel()
        startup?.resolve(.failure(.cancelled))
        for connection in connections.values { connection.close() }
        continuation?.finish()
    }

    private func listenerDidEnd(_ endingListener: NWListener) {
        lock.lock()
        guard listener === endingListener else {
            lock.unlock()
            return
        }
        listener = nil
        let startup = startup
        self.startup = nil
        let continuation = connectionContinuation
        connectionContinuation = nil
        pendingHandshakes.removeAll()
        let connections = liveConnections
        liveConnections.removeAll()
        lock.unlock()

        startup?.resolve(.failure(.cancelled))
        for connection in connections.values { connection.close() }
        continuation?.finish()
    }

    private func removeConnection(_ id: String) {
        lock.lock()
        liveConnections[id] = nil
        lock.unlock()
    }

    private func startupDidFinish(_ completedStartup: ListenerStartup) {
        lock.lock()
        if startup === completedStartup { startup = nil }
        lock.unlock()
    }

    /// Pulls the path out of the handshake.
    ///
    /// Network.framework does not expose the request target as a normal property.
    /// Read a synthetic `:path`-style entry if a platform version provides one and
    /// otherwise default to `/`. Adapters treat an unknown path as "the single
    /// configured protocol", so this is a routing convenience, not a requirement.
    private static func requestPath(from headers: HTTPHeaders) -> String {
        for candidate in [":path", "path", "Request-Path", "X-Request-Path"] {
            if let value = headers[candidate], !value.isEmpty { return value }
        }
        return "/"
    }
}
