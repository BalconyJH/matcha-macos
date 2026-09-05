import Foundation

/// One-shot bridge from `NWListener`'s callback state machine to async startup.
///
/// Binding a listener is asynchronous. Treating `listener.start(queue:)` as success
/// makes an occupied port look healthy until a peer fails to connect, so both server
/// transports wait for `.ready` before publishing their listening state.
final class ListenerStartup: @unchecked Sendable {
    private typealias Continuation = CheckedContinuation<Void, any Error>

    private let lock = NSLock()
    private var continuation: Continuation?
    private var result: Result<Void, TransportError>?

    func value() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                install(continuation)
            }
        } onCancel: {
            resolve(.failure(.cancelled))
        }
    }

    func resolve(_ result: Result<Void, TransportError>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(with: result.mapError { $0 as any Error })
    }

    private func install(_ continuation: Continuation) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result.mapError { $0 as any Error })
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }
}
