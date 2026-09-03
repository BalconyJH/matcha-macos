import Foundation
import Network

/// An HTTP request as parsed off the wire.
public struct HTTPRequest: Sendable {
    public var method: String
    /// Path with the query string removed.
    public var path: String
    public var query: [String: String]
    public var headers: HTTPHeaders
    public var body: Data

    public init(method: String, path: String, query: [String: String], headers: HTTPHeaders, body: Data) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }

    /// Bearer token from the `Authorization` header, falling back to an
    /// `access_token` query parameter — both forms are used in this ecosystem.
    public var accessToken: String? {
        headers.bearerToken ?? query["access_token"]
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var reason: String
    public var headers: [(name: String, value: String)]
    public var body: Data

    public init(
        status: Int = 200, reason: String? = nil, headers: [(name: String, value: String)] = [], body: Data = Data()
    ) {
        self.status = status
        self.reason = reason ?? HTTPResponse.defaultReason(for: status)
        self.headers = headers
        self.body = body
    }

    public static func json(_ data: Data, status: Int = 200) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: [("Content-Type", "application/json; charset=utf-8")],
            body: data
        )
    }

    public static func text(_ string: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(
            status: status,
            headers: [("Content-Type", "text/plain; charset=utf-8")],
            body: Data(string.utf8)
        )
    }

    public static func empty(status: Int) -> HTTPResponse {
        HTTPResponse(status: status)
    }

    static func defaultReason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 415: return "Unsupported Media Type"
        case 426: return "Upgrade Required"
        case 431: return "Request Header Fields Too Large"
        case 500: return "Internal Server Error"
        default: return "Status \(status)"
        }
    }

    func serialized(closeConnection: Bool = false) -> Data {
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        var sawContentLength = false
        var sawConnection = false
        for header in headers {
            if header.name.lowercased() == "content-length" { sawContentLength = true }
            if header.name.lowercased() == "connection" { sawConnection = true }
            head += "\(header.name): \(header.value)\r\n"
        }
        if !sawContentLength {
            head += "Content-Length: \(body.count)\r\n"
        }
        if !sawConnection {
            head += "Connection: \(closeConnection ? "close" : "keep-alive")\r\n"
        }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(body)
        return out
    }
}

/// A minimal HTTP/1.1 server.
///
/// Needed for two jobs: serving cached media to peers that fetch attachments over
/// HTTP, and hosting protocols whose API surface is HTTP rather than WebSocket
/// (Milky's action calls). Only what those two require is implemented —
/// keep-alive, `Content-Length` bodies, and byte-range-free responses. No
/// chunked transfer encoding, no HTTP/2.
public final class HTTPServer: @unchecked Sendable {
    public typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse
    public typealias WebSocketUpgradeHandler = @Sendable (HTTPRequest) -> WebSocketUpgradeDecision

    public enum WebSocketUpgradeDecision: Sendable {
        /// Complete the RFC 6455 handshake and publish the upgraded connection.
        case accept
        /// Answer the upgrade request as ordinary HTTP, usually with 401 or 403.
        case reject(HTTPResponse)
        /// Let the ordinary HTTP handler route this request.
        case decline
    }

    /// Guards against a hostile or buggy peer sending an unbounded body.
    public static let maxBodyBytes = 64 * 1024 * 1024
    public static let maxHeaderBytes = 64 * 1024

    public let host: String
    public let port: UInt16
    private let handler: Handler
    private let webSocketUpgradeHandler: WebSocketUpgradeHandler?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "matcha.http.server")
    private let lock = NSLock()
    private var startup: ListenerStartup?
    /// Live sessions, held so a connection is not torn down the moment the accept
    /// handler returns. Entries are dropped when their connection closes.
    private var sessions: [String: Session] = [:]
    private var webSocketContinuation: AsyncStream<HTTPWebSocketConnection>.Continuation?

    /// WebSocket connections upgraded by `webSocketUpgradeHandler`.
    public let webSocketConnections: AsyncStream<HTTPWebSocketConnection>

    public init(
        host: String = "127.0.0.1",
        port: UInt16,
        webSocketUpgradeHandler: WebSocketUpgradeHandler? = nil,
        handler: @escaping Handler
    ) {
        self.host = host
        self.port = port
        self.webSocketUpgradeHandler = webSocketUpgradeHandler
        self.handler = handler

        var continuation: AsyncStream<HTTPWebSocketConnection>.Continuation!
        webSocketConnections = AsyncStream(bufferingPolicy: .unbounded) {
            continuation = $0
        }
        webSocketContinuation = continuation
    }

    public func start() async throws {
        let parameters = NWParameters.tcp

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

        listener.newConnectionHandler = { [weak self, weak listener] connection in
            guard let self, let listener else {
                connection.cancel()
                return
            }

            let token = IDGeneratorShim.short()
            let session = Session(
                connection: connection,
                queue: queue,
                handler: handler,
                webSocketUpgradeHandler: webSocketUpgradeHandler,
                onUpgrade: { [weak self] connection in
                    guard let self else {
                        connection.cancel()
                        return false
                    }
                    lock.lock()
                    let continuation = webSocketContinuation
                    lock.unlock()
                    guard let continuation else {
                        connection.cancel()
                        return false
                    }
                    if case .terminated = continuation.yield(connection) {
                        connection.cancel()
                        return false
                    }
                    return true
                },
                onClose: { [weak self] in
                    guard let self else { return }
                    lock.lock()
                    sessions[token] = nil
                    lock.unlock()
                }
            )
            lock.lock()
            guard self.listener === listener, webSocketContinuation != nil else {
                lock.unlock()
                connection.cancel()
                return
            }
            sessions[token] = session
            lock.unlock()
            connection.start(queue: queue)
            session.run()
        }
        let listenerInstalled = lock.withLock {
            guard self.listener == nil, webSocketContinuation != nil else { return false }
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
        let live = sessions
        sessions.removeAll()
        let continuation = webSocketContinuation
        webSocketContinuation = nil
        lock.unlock()
        listener?.cancel()
        startup?.resolve(.failure(.cancelled))
        for session in live.values {
            session.cancel()
        }
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
        let continuation = webSocketContinuation
        webSocketContinuation = nil
        let live = sessions
        sessions.removeAll()
        lock.unlock()

        startup?.resolve(.failure(.cancelled))
        for session in live.values {
            session.cancel()
        }
        continuation?.finish()
    }

    private func startupDidFinish(_ completedStartup: ListenerStartup) {
        lock.lock()
        if startup === completedStartup { startup = nil }
        lock.unlock()
    }

    /// One keep-alive connection, processing request/response pairs in wire order.
    ///
    /// HTTP parsing and WebSocket frames must never own the socket concurrently.
    /// `State.upgrading` is therefore a one-way handoff: once the 101 response has
    /// been queued, the HTTP receive loop cannot run again and all leftover bytes are
    /// transferred to `HTTPWebSocketConnection`.
    private final class Session: @unchecked Sendable {
        private enum State {
            case http
            case handling
            case upgrading
            case webSocket
            case closed
        }

        private enum ParseResult {
            case incomplete
            case request(HTTPRequest, consumedBytes: Int)
            case reject(HTTPResponse)
        }

        private let connection: NWConnection
        private let queue: DispatchQueue
        private let handler: Handler
        private let webSocketUpgradeHandler: WebSocketUpgradeHandler?
        private let onUpgrade: @Sendable (HTTPWebSocketConnection) -> Bool
        /// Runs when the connection ends, so the server can forget this session.
        private let onClose: @Sendable () -> Void
        private var buffer = Data()
        private var state = State.http
        private var closeAfterResponse = false
        private var didNotifyClose = false
        private var upgradedConnection: HTTPWebSocketConnection?
        private var handlerTask: Task<Void, Never>?

        init(
            connection: NWConnection,
            queue: DispatchQueue,
            handler: @escaping Handler,
            webSocketUpgradeHandler: WebSocketUpgradeHandler?,
            onUpgrade: @escaping @Sendable (HTTPWebSocketConnection) -> Bool,
            onClose: @escaping @Sendable () -> Void
        ) {
            self.connection = connection
            self.queue = queue
            self.handler = handler
            self.webSocketUpgradeHandler = webSocketUpgradeHandler
            self.onUpgrade = onUpgrade
            self.onClose = onClose
        }

        func run() {
            receive()
        }

        func cancel() {
            queue.async { [self] in
                guard state != .closed else { return }
                handlerTask?.cancel()
                handlerTask = nil
                let previousState = state
                state = .closed
                let webSocket = upgradedConnection
                upgradedConnection = nil
                if let webSocket {
                    if previousState == .webSocket {
                        webSocket.close()
                    } else {
                        webSocket.cancel()
                    }
                } else {
                    connection.cancel()
                }
                notifyClose()
            }
        }

        private func receive() {
            guard state == .http else { return }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
                [weak self] data, _, isComplete, error in
                guard let self, state == .http else { return }
                if let data, !data.isEmpty {
                    buffer.append(data)
                    processBufferedRequest()
                }
                if error != nil || isComplete {
                    switch state {
                    case .handling:
                        closeAfterResponse = true
                    case .http, .upgrading:
                        finishAndCancel()
                    case .webSocket, .closed:
                        break
                    }
                    return
                }
                if state == .http { receive() }
            }
        }

        private func processBufferedRequest() {
            guard state == .http else { return }

            switch Self.parse(buffer) {
            case .incomplete:
                return
            case .reject(let response):
                sendAndClose(response)
            case .request(let request, let consumed):
                buffer.removeFirst(consumed)

                if request.headers["Upgrade"]?.lowercased() == "websocket",
                    let webSocketUpgradeHandler
                {
                    switch webSocketUpgradeHandler(request) {
                    case .accept:
                        upgrade(request)
                    case .reject(let response):
                        sendAndClose(response)
                    case .decline:
                        handle(request)
                    }
                } else {
                    handle(request)
                }
            }
        }

        private func handle(_ request: HTTPRequest) {
            state = .handling
            let requestWantsClose =
                request.headers["Connection"]?
                .split(separator: ",")
                .contains(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "close" }) == true

            let handler = handler
            let queue = queue
            handlerTask = Task { [weak self] in
                let response = await handler(request)
                guard !Task.isCancelled else { return }
                queue.async { [weak self] in
                    self?.send(response, closeConnection: requestWantsClose)
                }
            }
        }

        private func send(_ response: HTTPResponse, closeConnection: Bool) {
            guard state == .handling else { return }
            handlerTask = nil
            let shouldClose = closeConnection || closeAfterResponse
            connection.send(
                content: response.serialized(closeConnection: shouldClose),
                completion: .contentProcessed { [weak self] error in
                    guard let self else { return }
                    queue.async { [weak self] in
                        guard let self, state == .handling else { return }
                        if error != nil || shouldClose {
                            finishAndCancel()
                            return
                        }
                        state = .http
                        processBufferedRequest()
                        if state == .http { receive() }
                    }
                }
            )
        }

        private func sendAndClose(_ response: HTTPResponse) {
            guard state == .http else { return }
            state = .handling
            connection.send(
                content: response.serialized(closeConnection: true),
                completion: .contentProcessed { [weak self] _ in
                    guard let self else { return }
                    queue.async { [weak self] in self?.finishAndCancel() }
                }
            )
        }

        private func upgrade(_ request: HTTPRequest) {
            guard let response = HTTPWebSocketConnection.openingHandshakeResponse(for: request) else {
                sendAndClose(.text("Invalid WebSocket handshake request", status: 400))
                return
            }

            state = .upgrading
            let initialData = buffer
            buffer.removeAll(keepingCapacity: false)
            let webSocket = HTTPWebSocketConnection(
                connection: connection,
                request: request,
                initialData: initialData,
                onClose: { [weak self] in
                    guard let self else { return }
                    queue.async { [weak self] in self?.webSocketDidClose() }
                }
            )
            upgradedConnection = webSocket
            connection.send(
                content: response,
                completion: .contentProcessed { [weak self] error in
                    guard let self else {
                        webSocket.cancel()
                        return
                    }
                    queue.async { [weak self] in
                        guard let self, state == .upgrading, error == nil else {
                            webSocket.cancel()
                            return
                        }
                        guard onUpgrade(webSocket) else {
                            finishAndCancel()
                            return
                        }
                        state = .webSocket
                        webSocket.start()
                    }
                }
            )
        }

        private func webSocketDidClose() {
            guard state != .closed else {
                notifyClose()
                return
            }
            state = .closed
            handlerTask?.cancel()
            handlerTask = nil
            upgradedConnection = nil
            notifyClose()
        }

        private func finishAndCancel() {
            guard state != .closed else {
                notifyClose()
                return
            }
            let previousState = state
            state = .closed
            handlerTask?.cancel()
            handlerTask = nil
            let webSocket = upgradedConnection
            upgradedConnection = nil
            if let webSocket {
                if previousState == .webSocket {
                    webSocket.close()
                } else {
                    webSocket.cancel()
                }
            } else {
                connection.cancel()
            }
            notifyClose()
        }

        private func notifyClose() {
            guard !didNotifyClose else { return }
            didNotifyClose = true
            onClose()
        }

        /// Returns a complete request, an explicit rejection, or the fact that more
        /// bytes are needed. Invalid framing is never reinterpreted as another request.
        private static func parse(_ data: Data) -> ParseResult {
            let separator = Data("\r\n\r\n".utf8)
            guard let headerEnd = data.range(of: separator) else {
                return data.count > HTTPServer.maxHeaderBytes
                    ? .reject(.text("HTTP headers too large", status: 431))
                    : .incomplete
            }
            guard data.distance(from: data.startIndex, to: headerEnd.lowerBound) <= HTTPServer.maxHeaderBytes else {
                return .reject(.text("HTTP headers too large", status: 431))
            }
            let headerData = data[data.startIndex..<headerEnd.lowerBound]
            guard let headerText = String(data: headerData, encoding: .utf8) else {
                return .reject(.text("HTTP headers are not valid UTF-8", status: 400))
            }

            var lines = headerText.components(separatedBy: "\r\n")
            guard let requestLine = lines.first else {
                return .reject(.text("Missing HTTP request line", status: 400))
            }
            lines.removeFirst()

            let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 3,
                parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0"
            else {
                return .reject(.text("Invalid HTTP request line", status: 400))
            }
            let method = String(parts[0]).uppercased()
            let target = String(parts[1])

            var headers = HTTPHeaders()
            for line in lines where !line.isEmpty {
                guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else {
                    return .reject(.text("Invalid HTTP header field", status: 400))
                }
                let name = String(line[line.startIndex..<colon])
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers.add(name, value)
            }

            guard headers.values(for: "Transfer-Encoding").isEmpty else {
                return .reject(.text("Transfer-Encoding is not supported", status: 400))
            }

            let contentLengths = headers.values(for: "Content-Length")
            let parsedLengths = contentLengths.compactMap { raw -> Int? in
                guard !raw.isEmpty,
                    raw.utf8.allSatisfy({ (48...57).contains($0) })
                else { return nil }
                return Int(raw)
            }
            guard parsedLengths.count == contentLengths.count,
                Set(parsedLengths).count <= 1
            else {
                return .reject(.text("Invalid or conflicting Content-Length", status: 400))
            }
            let bodyLength = parsedLengths.first ?? 0
            guard bodyLength <= HTTPServer.maxBodyBytes else {
                return .reject(.text("HTTP request body too large", status: 413))
            }
            let bodyStart = headerEnd.upperBound
            let available = data.distance(from: bodyStart, to: data.endIndex)
            guard available >= bodyLength else { return .incomplete }

            let body = Data(data[bodyStart..<data.index(bodyStart, offsetBy: bodyLength)])
            let consumed = data.distance(from: data.startIndex, to: bodyStart) + bodyLength

            // Split the target into path and query.
            var path = target
            var query: [String: String] = [:]
            if let questionMark = target.firstIndex(of: "?") {
                path = String(target[target.startIndex..<questionMark])
                let queryString = String(target[target.index(after: questionMark)...])
                for pair in queryString.split(separator: "&") {
                    let kv = pair.split(separator: "=", maxSplits: 1)
                    guard let key = kv.first?.removingPercentEncoding else { continue }
                    let value = kv.count > 1 ? (kv[1].removingPercentEncoding ?? "") : ""
                    query[String(key)] = value
                }
            }

            let request = HTTPRequest(
                method: method,
                path: path.removingPercentEncoding ?? path,
                query: query,
                headers: headers,
                body: body
            )
            return .request(request, consumedBytes: consumed)
        }
    }
}
