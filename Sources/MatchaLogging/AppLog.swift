import Darwin
import Foundation
import OSLog
import Synchronization

/// A process-wide-capable logging pipeline whose ownership remains explicit.
///
/// Every record is classified and sanitized before the same value is emitted to
/// unified logging, rotating JSON Lines files, and the bounded runtime snapshot.
public final class AppLog: Sendable {
    private static let activeFileName = "Matcha.jsonl"
    private static let exportedLogFileName = "matcha-logs.jsonl"
    private static let exportedSummaryFileName = "matcha-log-summary.json"
    /// `lockf` coordinates processes but not two file descriptors in one process.
    private static let processFileLock = Mutex(())

    private struct PipelineState: Sendable {
        let logDirectory: URL
        let maxFileSize: Int
        let maxRotatedFiles: Int
        let maxEntries: Int
        var nextSequence: UInt64 = 0
        var records: [AppLogRecord] = []
        var continuations: [UUID: AsyncStream<AppLogSnapshot>.Continuation] = [:]

        var activeFileURL: URL {
            logDirectory.appendingPathComponent(AppLog.activeFileName)
        }

        var lockFileURL: URL {
            logDirectory.appendingPathComponent(".Matcha.lock")
        }

        func rotatedFileURL(index: Int) -> URL {
            logDirectory.appendingPathComponent("\(AppLog.activeFileName).\(index)")
        }
    }

    private struct ExportSource: Sendable {
        let diskData: Data
        let runtimeRecords: [AppLogRecord]
    }

    private struct ExportSummary: Encodable, Sendable {
        let schemaVersion: Int
        let exportedAt: Date
        let diskLogBytes: Int
        let diskRecordCount: Int
        let runtimeRecordCount: Int
        let runtimeCountsByLevel: [String: Int]
        let runtimeCountsByCategory: [String: Int]
        let runtimeRecords: [AppLogRecord]
    }

    private let state: Mutex<PipelineState>
    private let sessionID: UUID
    private let subsystem: String
    private let emitUnifiedLog: Bool

    /// The single standard pipeline for this application process.
    ///
    /// Its file coordination and sequence state are shared by every producer through
    /// dependency injection from the composition root.
    public static let standard: AppLog = {
        let fileManager = FileManager.default
        let cachesDirectory = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        let bundleIdentifier = Bundle.main.bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 }
            ?? "Matcha"
        return AppLog(
            directory: cachesDirectory.appendingPathComponent(bundleIdentifier, isDirectory: true),
            maxFileSize: 5 * 1024 * 1024,
            maxRotatedFiles: 5,
            maxEntries: 1000,
            emitUnifiedLog: true,
            subsystem: bundleIdentifier
        )
    }()

    init(
        directory: URL,
        maxFileSize: Int = 5 * 1024 * 1024,
        maxRotatedFiles: Int = 5,
        maxEntries: Int = 1000,
        emitUnifiedLog: Bool = false,
        subsystem: String = "MatchaTests",
        sessionID: UUID = UUID()
    ) {
        let logDirectory = directory.appendingPathComponent("Logs", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: logDirectory,
            withIntermediateDirectories: true
        )
        var excludedDirectory = logDirectory
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? excludedDirectory.setResourceValues(resourceValues)
        self.sessionID = sessionID
        self.subsystem = subsystem
        self.emitUnifiedLog = emitUnifiedLog
        state = Mutex(
            PipelineState(
                logDirectory: logDirectory,
                maxFileSize: max(1, maxFileSize),
                maxRotatedFiles: max(1, maxRotatedFiles),
                maxEntries: max(1, maxEntries)
            )
        )
    }

    @discardableResult
    public func record(_ event: AppLogEvent) -> AppLogRecord {
        state.withLock { state in
            state.nextSequence &+= 1
            let record = AppLogRecord(
                sessionID: sessionID,
                sequence: state.nextSequence,
                timestamp: .now,
                event: event
            )

            do {
                let encoded = try Self.encodedLine(record)
                try Self.withExclusiveFileLock(state: state) {
                    try Self.ensureActiveFileExists(state: state)
                    try Self.rotateBeforeWritingIfNeeded(encoded.count, state: state)
                    try Self.write(encoded, to: state.activeFileURL)
                }
            } catch {
                // Logging is diagnostic and must never become a business failure.
            }

            state.records.append(record)
            if state.records.count > state.maxEntries {
                state.records.removeFirst(state.records.count - state.maxEntries)
            }

            if emitUnifiedLog {
                emit(record)
            }
            let snapshot = AppLogSnapshot(records: state.records)
            for continuation in state.continuations.values {
                continuation.yield(snapshot)
            }
            return record
        }
    }

    public func snapshot() -> AppLogSnapshot {
        state.withLock { state in
            AppLogSnapshot(records: state.records)
        }
    }

    /// Observes runtime snapshots with an initial value and newest-one buffering.
    public func snapshots() -> AsyncStream<AppLogSnapshot> {
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            continuation.onTermination = { [weak self] _ in
                self?.removeContinuation(id: id)
            }
            state.withLock { state in
                state.continuations[id] = continuation
                continuation.yield(AppLogSnapshot(records: state.records))
            }
        }
    }

    /// Removes active and rotated files and publishes one empty snapshot.
    public func clear() async throws {
        try await Task.detached(priority: .utility) { [self] in
            try state.withLock { state in
                let fileManager = FileManager.default
                try Self.withExclusiveFileLock(state: state) {
                    let urls = try fileManager.contentsOfDirectory(
                        at: state.logDirectory,
                        includingPropertiesForKeys: nil
                    )
                    for url in urls where Self.isLogFile(url) {
                        try fileManager.removeItem(at: url)
                    }
                }
                state.records.removeAll(keepingCapacity: true)
                let snapshot = AppLogSnapshot(records: [])
                for continuation in state.continuations.values {
                    continuation.yield(snapshot)
                }
            }
        }.value
    }

    /// Exports a consistent disk/runtime snapshot without running file I/O on the
    /// caller's actor.
    public func export(to directory: URL) async throws -> [URL] {
        try await Task.detached(priority: .utility) { [self] in
            try exportSynchronously(to: directory)
        }.value
    }

    var logDirectory: URL {
        state.withLock(\.logDirectory)
    }

    private func removeContinuation(id: UUID) {
        state.withLock { state in
            state.continuations[id] = nil
        }
    }

    private func exportSynchronously(to directory: URL) throws -> [URL] {
        let source = try state.withLock { state in
            ExportSource(
                diskData: try Self.withExclusiveFileLock(state: state) {
                    try Self.readAllData(state: state)
                },
                runtimeRecords: state.records
            )
        }
        let summary = ExportSummary(
            schemaVersion: 1,
            exportedAt: .now,
            diskLogBytes: source.diskData.count,
            diskRecordCount: source.diskData.reduce(into: 0) { count, byte in
                if byte == 0x0A { count += 1 }
            },
            runtimeRecordCount: source.runtimeRecords.count,
            runtimeCountsByLevel: Dictionary(
                grouping: source.runtimeRecords,
                by: { $0.level.rawValue }
            ).mapValues(\.count),
            runtimeCountsByCategory: Dictionary(
                grouping: source.runtimeRecords,
                by: { $0.category.rawValue }
            ).mapValues(\.count),
            runtimeRecords: source.runtimeRecords
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let summaryData = try encoder.encode(summary)

        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let exportID = UUID().uuidString.lowercased()
        let stagingDirectory = directory.appendingPathComponent(
            ".Matcha-Logs-staging-\(exportID)",
            isDirectory: true
        )
        let destinationDirectory = directory.appendingPathComponent(
            "Matcha-Logs-\(exportID)",
            isDirectory: true
        )
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
        var committed = false
        defer {
            if !committed {
                try? fileManager.removeItem(at: stagingDirectory)
            }
        }

        let stagedLogURL = stagingDirectory.appendingPathComponent(Self.exportedLogFileName)
        let stagedSummaryURL = stagingDirectory.appendingPathComponent(Self.exportedSummaryFileName)
        try source.diskData.write(to: stagedLogURL, options: .atomic)
        try summaryData.write(to: stagedSummaryURL, options: .atomic)
        try fileManager.moveItem(at: stagingDirectory, to: destinationDirectory)
        committed = true
        return [
            destinationDirectory.appendingPathComponent(Self.exportedLogFileName),
            destinationDirectory.appendingPathComponent(Self.exportedSummaryFileName),
        ]
    }

    private func emit(_ record: AppLogRecord) {
        let logger = Logger(subsystem: subsystem, category: record.category.rawValue)
        switch record.level {
        case .debug:
            logger.debug("\(record.renderedMessage, privacy: .public)")
        case .info:
            logger.info("\(record.renderedMessage, privacy: .public)")
        case .notice:
            logger.notice("\(record.renderedMessage, privacy: .public)")
        case .warning:
            logger.warning("\(record.renderedMessage, privacy: .public)")
        case .error:
            logger.error("\(record.renderedMessage, privacy: .public)")
        }
    }

    private static func encodedLine(_ record: AppLogRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(record)
        data.append(0x0A)
        return data
    }

    private static func ensureActiveFileExists(state: PipelineState) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: state.logDirectory,
            withIntermediateDirectories: true
        )
        guard !fileManager.fileExists(atPath: state.activeFileURL.path) else {
            return
        }
        guard fileManager.createFile(
            atPath: state.activeFileURL.path,
            contents: nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func rotateBeforeWritingIfNeeded(
        _ byteCount: Int,
        state: PipelineState
    ) throws {
        let fileManager = FileManager.default
        let attributes = try fileManager.attributesOfItem(
            atPath: state.activeFileURL.path
        )
        let currentSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard currentSize > 0, currentSize + byteCount > state.maxFileSize else {
            return
        }

        let oldest = state.rotatedFileURL(index: state.maxRotatedFiles)
        if fileManager.fileExists(atPath: oldest.path) {
            try fileManager.removeItem(at: oldest)
        }
        if state.maxRotatedFiles > 1 {
            for index in stride(
                from: state.maxRotatedFiles - 1,
                through: 1,
                by: -1
            ) {
                let source = state.rotatedFileURL(index: index)
                guard fileManager.fileExists(atPath: source.path) else {
                    continue
                }
                try fileManager.moveItem(
                    at: source,
                    to: state.rotatedFileURL(index: index + 1)
                )
            }
        }
        try fileManager.moveItem(
            at: state.activeFileURL,
            to: state.rotatedFileURL(index: 1)
        )
        guard fileManager.createFile(
            atPath: state.activeFileURL.path,
            contents: nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func write(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private static func readAllData(state: PipelineState) throws -> Data {
        let fileManager = FileManager.default
        var data = Data()
        for index in stride(from: state.maxRotatedFiles, through: 1, by: -1) {
            let url = state.rotatedFileURL(index: index)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            data.append(try Data(contentsOf: url))
        }
        if fileManager.fileExists(atPath: state.activeFileURL.path) {
            data.append(try Data(contentsOf: state.activeFileURL))
        }
        return data
    }

    /// Serializes file mutation across every Matcha process using this cache directory.
    private static func withExclusiveFileLock<Result>(
        state: PipelineState,
        body: () throws -> Result
    ) throws -> Result {
        try processFileLock.withLock { _ in
            try FileManager.default.createDirectory(
                at: state.logDirectory,
                withIntermediateDirectories: true
            )
            let descriptor = state.lockFileURL.withUnsafeFileSystemRepresentation { path in
                guard let path else { return Int32(-1) }
                return Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            }
            guard descriptor >= 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            defer { _ = Darwin.close(descriptor) }
            guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
            return try body()
        }
    }

    private static func isLogFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        guard name == activeFileName || name.hasPrefix("\(activeFileName).") else {
            return false
        }
        if name == activeFileName {
            return true
        }
        return Int(name.dropFirst(activeFileName.count + 1)) != nil
    }
}
