import Foundation

/// Cancellation-aware completion for one Network.framework write.
///
/// `NWConnection` normally invokes `.contentProcessed` after cancellation, but the
/// async caller must not depend on a peer draining the socket or on that callback
/// arriving. Resolving this one-shot directly on task cancellation guarantees that a
/// stopped protocol session cannot retain a suspended checked continuation.
final class SendCompletion: @unchecked Sendable {
    private typealias Continuation = CheckedContinuation<Void, any Error>

    private let lock = NSLock()
    private var continuation: Continuation?
    private var result: Result<Void, TransportError>?

    func value() async throws {
        try await withCheckedThrowingContinuation { continuation in
            install(continuation)
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
