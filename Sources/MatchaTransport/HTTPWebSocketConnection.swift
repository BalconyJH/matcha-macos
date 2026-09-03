import CryptoKit
import Foundation
import Network

/// A WebSocket upgraded from the raw HTTP/1.1 listener.
///
/// `NWProtocolWebSocket` cannot be inserted after an `NWConnection` has already
/// parsed an HTTP request, so Milky's same-port `/event` endpoint uses this small
/// RFC 6455 codec. Client frames are required to be masked; server frames are sent
/// unmasked. Fragmentation and control frames are handled independently from the
/// protocol payloads delivered through `frames`.
public final class HTTPWebSocketConnection: @unchecked Sendable {
    public let path: String
    public let requestHeaders: HTTPHeaders
    public let id: String

    private static let maximumPayloadBytes = 64 * 1024 * 1024
    private static let webSocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    private let connection: NWConnection
    private let onClose: @Sendable () -> Void
    private let lock = NSLock()
    private var buffer: Data
    private var fragmentedOpcode: UInt8?
    private var fragmentedPayload = Data()
    private var frameContinuation: AsyncStream<WebSocketFrame>.Continuation?
    private var isClosed = false

    public let frames: AsyncStream<WebSocketFrame>

    init(
        connection: NWConnection,
        request: HTTPRequest,
        initialData: Data,
        id: String = IDGeneratorShim.short(),
        onClose: @escaping @Sendable () -> Void
    ) {
        self.connection = connection
        self.path = request.path
        requestHeaders = request.headers
        self.id = id
        buffer = initialData
        self.onClose = onClose

        var continuation: AsyncStream<WebSocketFrame>.Continuation!
        frames = AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation = $0 }
        frameContinuation = continuation
    }

    /// The RFC 6455 response for a valid opening request.
    static func openingHandshakeResponse(for request: HTTPRequest) -> Data? {
        guard request.method == "GET",
              request.headers["Upgrade"]?.lowercased() == "websocket",
              request.headers["Connection"]?
              .split(separator: ",")
              .contains(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "upgrade" }) == true,
              request.headers["Sec-WebSocket-Version"] == "13",
              let key = request.headers["Sec-WebSocket-Key"],
              Data(base64Encoded: key)?.count == 16
        else {
            return nil
        }

        let digest = Insecure.SHA1.hash(data: Data((key + webSocketGUID).utf8))
        let accept = Data(digest).base64EncodedString()
        let response = [
            "HTTP/1.1 101 Switching Protocols",
            "Upgrade: websocket",
            "Connection: Upgrade",
            "Sec-WebSocket-Accept: \(accept)",
        ].joined(separator: "\r\n") + "\r\n\r\n"
        return Data(response.utf8)
    }

    func start() {
        guard drainFrames() else { return }
        receive()
    }

    public func send(_ frame: WebSocketFrame) async throws {
        guard !closed else { throw TransportError.notConnected }

        let opcode: UInt8
        switch frame {
        case .text:
            opcode = 0x1
        case .binary:
            opcode = 0x2
        }
        let serialized = Self.serialize(opcode: opcode, payload: frame.data)
        let completion = SendCompletion()
        connection.send(content: serialized, completion: .contentProcessed { error in
            if let error {
                completion.resolve(.failure(.connectFailed(error.localizedDescription)))
            } else {
                completion.resolve(.success(()))
            }
        })
        try await withTaskCancellationHandler {
            try await completion.value()
        } onCancel: {
            completion.resolve(.failure(.cancelled))
            cancel()
        }
    }

    public func close() {
        let payload = Data([0x03, 0xE8])
        close(with: Self.serialize(opcode: 0x8, payload: payload))
    }

    func cancel() {
        finish()
        connection.cancel()
    }

    public var peerDescription: String {
        switch connection.endpoint {
        case let .hostPort(host, port):
            return "\(host):\(port)"
        default:
            return String(describing: connection.endpoint)
        }
    }

    private var closed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isClosed
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                lock.lock()
                buffer.append(data)
                lock.unlock()
                guard drainFrames() else { return }
            }
            if error != nil || complete {
                finish()
                connection.cancel()
                return
            }
            receive()
        }
    }

    /// Returns false once parsing closed the connection.
    private func drainFrames() -> Bool {
        while true {
            let parsed: ParsedFrame?
            do {
                lock.lock()
                defer { lock.unlock() }
                guard let frame = try Self.parseFrame(buffer) else { return !isClosed }
                buffer.removeFirst(frame.consumedBytes)
                parsed = frame
            } catch {
                closeProtocolError()
                return false
            }

            guard let parsed else { return true }
            do {
                try consume(parsed)
            } catch {
                closeProtocolError()
                return false
            }
        }
    }

    private func consume(_ frame: ParsedFrame) throws {
        if frame.opcode >= 0x8 {
            guard frame.isFinal, frame.payload.count <= 125 else {
                throw FrameError.invalidControlFrame
            }
            switch frame.opcode {
            case 0x8:
                try Self.validateClosePayload(frame.payload)
                close(with: Self.serialize(opcode: 0x8, payload: frame.payload))
            case 0x9:
                sendControl(opcode: 0xA, payload: frame.payload)
            case 0xA:
                break
            default:
                throw FrameError.unsupportedOpcode
            }
            return
        }

        switch frame.opcode {
        case 0x0:
            guard fragmentedOpcode != nil else { throw FrameError.unexpectedContinuation }
            fragmentedPayload.append(frame.payload)
            guard fragmentedPayload.count <= Self.maximumPayloadBytes else {
                throw FrameError.payloadTooLarge
            }
            if frame.isFinal {
                let opcode = fragmentedOpcode
                let payload = fragmentedPayload
                fragmentedOpcode = nil
                fragmentedPayload.removeAll(keepingCapacity: false)
                try publish(opcode: opcode, payload: payload)
            }
        case 0x1, 0x2:
            guard fragmentedOpcode == nil else { throw FrameError.unexpectedDataFrame }
            if frame.isFinal {
                try publish(opcode: frame.opcode, payload: frame.payload)
            } else {
                fragmentedOpcode = frame.opcode
                fragmentedPayload = frame.payload
            }
        default:
            throw FrameError.unsupportedOpcode
        }
    }

    private func publish(opcode: UInt8?, payload: Data) throws {
        lock.lock()
        let continuation = frameContinuation
        lock.unlock()
        switch opcode {
        case 0x1:
            guard let text = String(data: payload, encoding: .utf8) else {
                throw FrameError.invalidUTF8
            }
            continuation?.yield(.text(text))
        case 0x2:
            continuation?.yield(.binary(payload))
        default:
            throw FrameError.unsupportedOpcode
        }
    }

    private func sendControl(opcode: UInt8, payload: Data) {
        connection.send(
            content: Self.serialize(opcode: opcode, payload: payload),
            completion: .contentProcessed { _ in }
        )
    }

    private func closeProtocolError() {
        let payload = Data([0x03, 0xEA])
        close(with: Self.serialize(opcode: 0x8, payload: payload))
    }

    private func close(with frame: Data) {
        guard beginClosing() else { return }
        let connection = connection
        connection.send(content: frame, completion: .contentProcessed { _ in
            connection.cancel()
        })
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            connection.cancel()
        }
    }

    private func beginClosing() -> Bool {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return false
        }
        isClosed = true
        let continuation = frameContinuation
        frameContinuation = nil
        lock.unlock()

        continuation?.finish()
        onClose()
        return true
    }

    private func finish() {
        _ = beginClosing()
    }

    private static func parseFrame(_ data: Data) throws -> ParsedFrame? {
        guard data.count >= 2 else { return nil }
        let first = byte(in: data, at: 0)
        let second = byte(in: data, at: 1)
        let isFinal = first & 0x80 != 0
        guard first & 0x70 == 0 else { throw FrameError.unsupportedExtension }

        let opcode = first & 0x0F
        let isControlFrame = opcode >= 0x8
        guard second & 0x80 != 0 else { throw FrameError.unmaskedClientFrame }

        var cursor = 2
        let lengthMarker = second & 0x7F
        guard !isControlFrame || isFinal && lengthMarker <= 125 else {
            throw FrameError.invalidControlFrame
        }

        var payloadLength = UInt64(lengthMarker)
        if lengthMarker == 126 {
            guard data.count >= cursor + 2 else { return nil }
            payloadLength = UInt64(byte(in: data, at: cursor)) << 8
                | UInt64(byte(in: data, at: cursor + 1))
            guard payloadLength >= 126 else { throw FrameError.nonMinimalLength }
            cursor += 2
        } else if lengthMarker == 127 {
            guard data.count >= cursor + 8 else { return nil }
            guard byte(in: data, at: cursor) & 0x80 == 0 else {
                throw FrameError.payloadTooLarge
            }
            payloadLength = 0
            for offset in 0 ..< 8 {
                payloadLength = payloadLength << 8 | UInt64(byte(in: data, at: cursor + offset))
            }
            guard payloadLength > UInt64(UInt16.max) else {
                throw FrameError.nonMinimalLength
            }
            cursor += 8
        }
        guard payloadLength <= UInt64(maximumPayloadBytes) else {
            throw FrameError.payloadTooLarge
        }
        guard data.count >= cursor + 4 else { return nil }
        let maskingKey = (0 ..< 4).map { byte(in: data, at: cursor + $0) }
        cursor += 4

        guard payloadLength <= UInt64(Int.max),
              data.count >= cursor + Int(payloadLength)
        else {
            return nil
        }
        var payload = Array(data[data.index(data.startIndex, offsetBy: cursor) ..< data.index(data.startIndex, offsetBy: cursor + Int(payloadLength))])
        for index in payload.indices {
            payload[index] ^= maskingKey[index % 4]
        }
        return ParsedFrame(
            isFinal: isFinal,
            opcode: opcode,
            payload: Data(payload),
            consumedBytes: cursor + Int(payloadLength)
        )
    }

    private static func validateClosePayload(_ payload: Data) throws {
        guard payload.count != 1 else { throw FrameError.invalidClosePayload }
        guard payload.count >= 2 else { return }

        let code = UInt16(byte(in: payload, at: 0)) << 8
            | UInt16(byte(in: payload, at: 1))
        let isDefinedProtocolCode = (1000 ... 1014).contains(code)
            && ![1004, 1005, 1006].contains(code)
        guard isDefinedProtocolCode || (3000 ... 4999).contains(code) else {
            throw FrameError.invalidClosePayload
        }

        let reason = payload.dropFirst(2)
        guard reason.isEmpty || String(data: reason, encoding: .utf8) != nil else {
            throw FrameError.invalidUTF8
        }
    }

    private static func serialize(opcode: UInt8, payload: Data) -> Data {
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= Int(UInt16.max) {
            frame.append(126)
            frame.append(UInt8((payload.count >> 8) & 0xFF))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            let length = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                frame.append(UInt8((length >> UInt64(shift)) & 0xFF))
            }
        }
        frame.append(payload)
        return frame
    }

    private static func byte(in data: Data, at offset: Int) -> UInt8 {
        data[data.index(data.startIndex, offsetBy: offset)]
    }
}

private struct ParsedFrame {
    var isFinal: Bool
    var opcode: UInt8
    var payload: Data
    var consumedBytes: Int
}

private enum FrameError: Error {
    case invalidControlFrame
    case invalidClosePayload
    case invalidUTF8
    case nonMinimalLength
    case payloadTooLarge
    case unexpectedContinuation
    case unexpectedDataFrame
    case unmaskedClientFrame
    case unsupportedExtension
    case unsupportedOpcode
}
