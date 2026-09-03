import Foundation
import Network

/// One live WebSocket connection, in either direction.
///
/// Wraps `NWConnection` so both the server (accepting a bot framework's forward
/// connection) and the client (dialing out for a OneBot reverse connection) hand back
/// the same object. Frames arrive as an `AsyncStream`, which lets a protocol session
/// consume them with `for await` and get cancellation for free.
public final class WebSocketConnection: @unchecked Sendable {
    /// The request path the peer connected to, e.g. `/onebot/v11`. Empty for
    /// outbound connections.
    public let path: String
    /// Headers the peer sent during the handshake. Adapters read the access token
    /// and self-ID hints from here.
    public let requestHeaders: HTTPHeaders
    public let id: String

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var frameContinuation: AsyncStream<WebSocketFrame>.Continuation?
    private var isClosed = false
    private var didBecomeReady = false
    private var closeHandler: (@Sendable (TransportError?) -> Void)?
    private var pingProbes: [String: PingProbe] = [:]

    /// Frames from the peer. The stream finishes when the connection closes.
    public let frames: AsyncStream<WebSocketFrame>

    init(connection: NWConnection, path: String, requestHeaders: HTTPHeaders, id: String = IDGeneratorShim.short()) {
        self.connection = connection
        self.path = path
        self.requestHeaders = requestHeaders
        self.id = id
        queue = DispatchQueue(label: "matcha.ws.\(id)")

        var continuation: AsyncStream<WebSocketFrame>.Continuation!
        frames = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        frameContinuation = continuation
    }

    /// Called by the server/client once the connection object is fully set up.
    func start(
        onReady: (@Sendable (WebSocketConnection) -> Void)? = nil,
        onClose: (@Sendable (TransportError?) -> Void)? = nil
    ) {
        lock.lock()
        closeHandler = onClose
        lock.unlock()

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                guard markReady() else { return }
                onReady?(self)
                receiveLoop()
            case .failed(let error):
                finish(error: .connectFailed(error.localizedDescription))
                connection.cancel()
            case .cancelled:
                finish(error: nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func markReady() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, !didBecomeReady else { return false }
        didBecomeReady = true
        return true
    }

    private func receiveLoop() {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }

            if let context,
                let meta = context.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata
            {
                switch meta.opcode {
                case .text:
                    if let data, let text = String(data: data, encoding: .utf8) {
                        lock.lock()
                        let c = frameContinuation
                        lock.unlock()
                        c?.yield(.text(text))
                    }
                case .binary:
                    if let data {
                        lock.lock()
                        let c = frameContinuation
                        lock.unlock()
                        c?.yield(.binary(data))
                    }
                case .close:
                    finish(error: nil)
                    connection.cancel()
                    return
                // ping/pong are answered by Network.framework (autoReplyPing).
                case .cont, .ping, .pong:
                    break
                @unknown default:
                    break
                }
            }

            if let error {
                finish(error: .connectFailed(error.localizedDescription))
                connection.cancel()
                return
            }

            guard !isFinished else { return }
            receiveLoop()
        }
    }

    private var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isClosed
    }

    /// Sends a frame, waiting until it has been handed to the network stack.
    public func send(_ frame: WebSocketFrame) async throws {
        if isFinished { throw TransportError.notConnected }
        let meta = NWProtocolWebSocket.Metadata(opcode: frame.opcode)
        let context = NWConnection.ContentContext(identifier: "send", metadata: [meta])

        let completion = SendCompletion()
        connection.send(
            content: frame.data,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { error in
                if let error {
                    completion.resolve(
                        .failure(.connectFailed(error.localizedDescription))
                    )
                } else {
                    completion.resolve(.success(()))
                }
            }
        )
        try await withTaskCancellationHandler {
            try await completion.value()
        } onCancel: {
            completion.resolve(.failure(.cancelled))
            cancelImmediately()
        }
    }

    /// Sends JSON text.
    public func send(json: JSONValueBox) async throws {
        try await send(.text(json.text))
    }

    /// Measures the real WebSocket path with a control-frame Ping/Pong exchange.
    ///
    /// Protocol heartbeats are deliberately not used here: they are application
    /// messages and do not necessarily have a reply. Network.framework associates
    /// this metadata's pong handler with the Ping it sends, so concurrent probes do
    /// not need to consume or correlate application frames.
    public func measureRoundTripTime(timeout: Duration = .seconds(3)) async throws -> Duration {
        guard timeout > .zero else { throw TransportError.timedOut }
        guard !Task.isCancelled else { throw TransportError.cancelled }

        let token = UUID().uuidString
        let probe = PingProbe { [weak self] in
            self?.removePingProbe(token)
        }

        guard registerPingProbe(probe, token: token) else {
            throw TransportError.notConnected
        }

        let startedAt = ContinuousClock.now
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        metadata.setPongHandler(queue) { error in
            if let error {
                probe.resolve(.failure(TransportError.connectFailed(error.localizedDescription)))
            } else {
                probe.resolve(.success(startedAt.duration(to: .now)))
            }
        }
        let context = NWConnection.ContentContext(identifier: "ping-\(token)", metadata: [metadata])
        connection.send(
            content: nil,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { error in
                if let error {
                    probe.resolve(.failure(TransportError.connectFailed(error.localizedDescription)))
                }
            }
        )

        return try await probe.value(timeout: timeout)
    }

    private func removePingProbe(_ token: String) {
        lock.lock()
        pingProbes[token] = nil
        lock.unlock()
    }

    private func registerPingProbe(_ probe: PingProbe, token: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, didBecomeReady else { return false }
        pingProbes[token] = probe
        return true
    }

    public func close() {
        guard !isFinished else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .close)
        meta.closeCode = .protocolCode(.normalClosure)
        let context = NWConnection.ContentContext(identifier: "close", metadata: [meta])
        let connection = connection
        connection.send(
            content: nil,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() }
        )
        queue.asyncAfter(deadline: .now() + 1) { connection.cancel() }
        finish(error: nil)
    }

    private func cancelImmediately() {
        finish(error: .cancelled)
        connection.cancel()
    }

    private func finish(error: TransportError?) {
        lock.lock()
        if isClosed {
            lock.unlock()
            return
        }
        isClosed = true
        let continuation = frameContinuation
        let handler = closeHandler
        let probes = Array(pingProbes.values)
        frameContinuation = nil
        closeHandler = nil
        pingProbes.removeAll()
        lock.unlock()

        continuation?.finish()
        for probe in probes {
            probe.resolve(.failure(error ?? .cancelled))
        }
        handler?(error)
    }

    /// Human-readable peer address, for the connection list in settings.
    public var peerDescription: String {
        switch connection.endpoint {
        case .hostPort(let host, let port):
            return "\(host):\(port)"
        default:
            return String(describing: connection.endpoint)
        }
    }
}

/// A lock-protected one-shot continuation shared by the Pong, send, timeout,
/// cancellation, and connection-close paths. Exactly one of them is allowed to win.
private final class PingProbe: @unchecked Sendable {
    private typealias Continuation = CheckedContinuation<Duration, any Error>

    private let lock = NSLock()
    private let completion: @Sendable () -> Void
    private var continuation: Continuation?
    private var completedResult: Result<Duration, any Error>?
    private var timeoutTask: Task<Void, Never>?

    init(completion: @escaping @Sendable () -> Void) {
        self.completion = completion
    }

    func value(timeout: Duration) async throws -> Duration {
        let task = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            self?.resolve(.failure(TransportError.timedOut))
        }
        setTimeoutTask(task)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                install(continuation)
            }
        } onCancel: {
            resolve(.failure(TransportError.cancelled))
        }
    }

    func resolve(_ result: Result<Duration, any Error>) {
        lock.lock()
        guard completedResult == nil else {
            lock.unlock()
            return
        }
        completedResult = result
        let continuation = continuation
        self.continuation = nil
        let timeoutTask = timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        timeoutTask?.cancel()
        continuation?.resume(with: result)
        completion()
    }

    private func install(_ continuation: Continuation) {
        lock.lock()
        if let completedResult {
            lock.unlock()
            continuation.resume(with: completedResult)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    private func setTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        if completedResult == nil {
            timeoutTask = task
            lock.unlock()
        } else {
            lock.unlock()
            task.cancel()
        }
    }
}

/// Minimal JSON text carrier, so `MatchaTransport` need not import the model layer
/// just to send a payload.
public struct JSONValueBox: Sendable {
    public let text: String
    public init(text: String) { self.text = text }
}

/// Short random identifiers for connections and log correlation.
public enum IDGeneratorShim {
    public static func short() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }
}
