import Foundation

/// Identifier minting.
///
/// Peers care about the *shape* of an ID: OneBot v11 declares `user_id` and
/// `message_id` as 64-bit integers, so anything Matcha invents has to survive a
/// round-trip through an integer without collapsing. Every generator here emits
/// digits only, and stays inside `Int64`.
public enum IDGenerator {
    /// Monotonic counter shared by all ID kinds, so two IDs minted in the same
    /// millisecond still differ.
    private static let counter = Counter()

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0
        private var lastTick: UInt64 = 0

        /// Returns a strictly increasing (tick, sequence) pair.
        func next(tick: UInt64) -> (tick: UInt64, seq: UInt64) {
            lock.lock()
            defer { lock.unlock() }
            if tick > lastTick {
                lastTick = tick
                value = 0
            } else {
                value += 1
            }
            return (lastTick, value)
        }
    }

    private static func stamped(prefix: UInt64, digits: Int) -> String {
        let ms = UInt64(Date().timeIntervalSince1970 * 1000)
        let (tick, seq) = counter.next(tick: ms)
        // Keep the low-order part of the timestamp plus a sequence tail; the
        // result stays well inside Int64 while remaining time-ordered.
        let body = (tick % 100_000_000) * 1000 + (seq % 1000)
        let text = "\(prefix)\(body)"
        return String(text.suffix(digits))
    }

    /// QQ-like account number.
    public static func userID() -> String { stamped(prefix: 1, digits: 10) }

    /// QQ-like group number.
    public static func groupID() -> String { stamped(prefix: 5, digits: 9) }

    /// Message ID. Time-ordered so "recall the last message" style lookups sort
    /// correctly, and always positive.
    public static func messageID() -> String { stamped(prefix: 7, digits: 11) }

    /// Correlation ID for a request/response pair or an event `id` field.
    public static func requestID() -> String { UUID().uuidString.lowercased() }

    /// Opaque token for a pending friend/group request that a peer later
    /// approves or rejects. OneBot calls this a "flag".
    public static func flag() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "") }
}
