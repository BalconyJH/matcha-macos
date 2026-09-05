import Foundation

public struct AppLogRecord: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    /// Identifies one pipeline lifetime; `sequence` is monotonic within this session.
    public let sessionID: UUID
    public let sequence: UInt64
    public let timestamp: Date
    public let level: AppLogLevel
    public let category: AppLogCategory
    /// Stable event identifier written to every sink.
    public let event: String
    public let fields: AppLogFields

    init(
        id: UUID = UUID(),
        sessionID: UUID,
        sequence: UInt64,
        timestamp: Date,
        event: AppLogEvent
    ) {
        self.id = id
        self.sessionID = sessionID
        self.sequence = sequence
        self.timestamp = timestamp
        level = event.level
        category = event.category
        self.event = event.identifier
        fields = event.fields
    }

    public var renderedMessage: String {
        ([event] + fields.renderedComponents).joined(separator: " ")
    }
}

public struct AppLogSnapshot: Hashable, Sendable {
    /// Records in ascending sequence order, oldest first.
    public let records: [AppLogRecord]

    init(records: [AppLogRecord]) {
        self.records = records
    }

    public var latestSequence: UInt64? {
        records.last?.sequence
    }

    public var isEmpty: Bool {
        records.isEmpty
    }
}
