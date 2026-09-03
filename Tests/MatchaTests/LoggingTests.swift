import Foundation
import Testing

@testable import MatchaCore
@testable import MatchaLogging
import MatchaProtocol
import MatchaTransport

@Suite("Application Logging")
struct LoggingTests {
    @Test
    func applicationOperationVocabularyProducesStructuredCategorizedRecords() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }

        for operation in AppLogOperation.allCases {
            fixture.log.record(.operationCompleted(operation))
        }

        let records = fixture.log.snapshot().records
        #expect(records.count == AppLogOperation.allCases.count)
        #expect(Set(records.map(\.event)).count == AppLogOperation.allCases.count)
        #expect(records.allSatisfy { $0.event.hasPrefix("app.") })
        #expect(records.allSatisfy { $0.event.hasSuffix(".completed") })
        #expect(records.map(\.fields.operation) == AppLogOperation.allCases.map(Optional.some))
        #expect(records.allSatisfy { $0.fields.errorDomain == nil })
        #expect(records.allSatisfy { $0.category == .application })
    }

    @Test
    func knownApplicationErrorDomainsRemainDiagnosable() {
        #expect(
            AppLogFailure(StorePersistenceError.missingUser("private-user-id")).domain
                == "MatchaCore.StorePersistenceError"
        )
        #expect(
            AppLogFailure(PlatformError.notPermitted("private reason")).domain
                == "MatchaProtocol.PlatformError"
        )
        #expect(
            AppLogFailure(TransportError.cancelled).domain
                == "MatchaTransport.TransportError"
        )
    }

    @Test
    func concurrentWritesPreserveUniqueMonotonicDiskOrder() async throws {
        let fixture = try makeFixture(maxFileSize: 2 * 1024 * 1024)
        defer { fixture.remove() }
        let writeCount = 200

        let returnedRecords = await withTaskGroup(
            of: AppLogRecord.self,
            returning: [AppLogRecord].self
        ) { group in
            for index in 0 ..< writeCount {
                group.addTask {
                    fixture.log.record(.sessionListening(port: UInt16(index + 1)))
                }
            }

            var records: [AppLogRecord] = []
            for await record in group {
                records.append(record)
            }
            return records
        }

        let persistedRecords = try await exportedRecords(from: fixture)
        let expectedSequences = (1 ... writeCount).map(UInt64.init)
        #expect(persistedRecords.map(\.sequence) == expectedSequences)
        #expect(Set(returnedRecords.map(\.sequence)).count == writeCount)
        #expect(
            Set(persistedRecords.compactMap(\.fields.port))
                == Set((1 ... writeCount).map(UInt16.init))
        )
    }

    @Test
    func pipelinesSharingADirectorySerializeFilesAndDisambiguateSequences() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Matcha-LoggingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstSessionID = UUID()
        let secondSessionID = UUID()
        let first = AppLog(
            directory: root,
            maxFileSize: 2 * 1024 * 1024,
            emitUnifiedLog: false,
            sessionID: firstSessionID
        )
        let second = AppLog(
            directory: root,
            maxFileSize: 2 * 1024 * 1024,
            emitUnifiedLog: false,
            sessionID: secondSessionID
        )

        await withTaskGroup(of: Void.self) { group in
            for port in UInt16(1) ... 100 {
                group.addTask { first.record(.sessionListening(port: port)) }
                group.addTask { second.record(.sessionListening(port: port + 100)) }
            }
        }

        let fixture = LoggingFixture(root: root, log: first)
        let records = try await exportedRecords(from: fixture)
        #expect(records.count == 200)
        #expect(Set(records.map(\.id)).count == 200)
        let recordsBySession = Dictionary(grouping: records, by: \.sessionID)
        #expect(Set(recordsBySession.keys) == [firstSessionID, secondSessionID])
        #expect(
            recordsBySession[firstSessionID]?.map(\.sequence).sorted()
                == (1 ... 100).map(UInt64.init)
        )
        #expect(
            recordsBySession[secondSessionID]?.map(\.sequence).sorted()
                == (1 ... 100).map(UInt64.init)
        )
    }

    @Test
    func rotationExportsRecordsFromOldestToNewest() async throws {
        let fixture = try makeFixture(maxFileSize: 260, maxRotatedFiles: 12)
        defer { fixture.remove() }

        for port in UInt16(1) ... 12 {
            fixture.log.record(.sessionListening(port: port))
        }

        let logFiles = try FileManager.default.contentsOfDirectory(
            at: fixture.log.logDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("Matcha.jsonl") }
        #expect(logFiles.count > 1)

        let records = try await exportedRecords(from: fixture)
        #expect(records.map(\.fields.port) == (1 ... 12).map(UInt16.init))
    }

    @Test
    func runtimeSnapshotRetainsOnlyNewestEntries() throws {
        let fixture = try makeFixture(maxEntries: 5)
        defer { fixture.remove() }

        for port in UInt16(1) ... 12 {
            fixture.log.record(.sessionListening(port: port))
        }

        let snapshot = fixture.log.snapshot()
        #expect(snapshot.records.count == 5)
        #expect(snapshot.records.map(\.sequence) == [8, 9, 10, 11, 12])
        #expect(snapshot.records.map(\.fields.port) == [8, 9, 10, 11, 12])
    }

    @Test
    func snapshotStreamStartsCurrentAndPublishesMutations() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let stream = fixture.log.snapshots()
        var iterator = stream.makeAsyncIterator()

        let initial = try #require(await iterator.next())
        #expect(initial.isEmpty)

        fixture.log.record(.applicationStarted)
        let appended = try #require(await iterator.next())
        #expect(appended.records.map(\.event) == ["application.started"])

        try await fixture.log.clear()
        let cleared = try #require(await iterator.next())
        #expect(cleared.isEmpty)
    }

    @Test
    func clearRemovesRuntimeActiveAndEveryRotationWithoutStaleReappearance() async throws {
        let fixture = try makeFixture(maxFileSize: 220, maxRotatedFiles: 3)
        defer { fixture.remove() }

        for port in UInt16(1) ... 12 {
            fixture.log.record(.sessionListening(port: port))
        }
        let staleRotation = fixture.log.logDirectory.appendingPathComponent("Matcha.jsonl.99")
        try Data("stale".utf8).write(to: staleRotation)
        #expect(!fixture.log.snapshot().isEmpty)

        try await fixture.log.clear()

        let remaining = try FileManager.default.contentsOfDirectory(
            at: fixture.log.logDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("Matcha.jsonl") }
        #expect(remaining.isEmpty)
        #expect(fixture.log.snapshot().isEmpty)

        let firstAfterClear = fixture.log.record(.sessionConnected)
        #expect(firstAfterClear.sequence == 13)
        #expect(fixture.log.snapshot().records.map(\.id) == [firstAfterClear.id])
        #expect(try await exportedRecords(from: fixture).map(\.id) == [firstAfterClear.id])
    }

    @Test
    func exportIncludesDiskHistoryRuntimeWindowAndCounts() async throws {
        let fixture = try makeFixture(maxFileSize: 280, maxEntries: 3)
        defer { fixture.remove() }

        fixture.log.record(.applicationStarted)
        fixture.log.record(
            .connectionRequested(
                protocolKind: .oneBotV12,
                transportKind: .webSocketClient,
                port: 8080
            )
        )
        fixture.log.record(.connectionRejected(.missingBotAccount))
        fixture.log.record(
            .operationReturnedError(
                operation: .sendMessage,
                failure: AppLogFailure(TestFailure.example)
            )
        )

        let exportDirectory = fixture.root.appendingPathComponent("summary-export", isDirectory: true)
        let urls = try await fixture.log.export(to: exportDirectory)
        let logURL = try #require(urls.first { $0.lastPathComponent == "matcha-logs.jsonl" })
        let summaryURL = try #require(urls.first { $0.lastPathComponent == "matcha-log-summary.json" })
        #expect(try Data(contentsOf: logURL).split(separator: 0x0A).count == 4)

        let summary = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: summaryURL)) as? [String: Any]
        )
        #expect(summary["schemaVersion"] as? Int == 1)
        #expect(summary["diskRecordCount"] as? Int == 4)
        #expect(summary["runtimeRecordCount"] as? Int == 3)

        let levelCounts = try #require(summary["runtimeCountsByLevel"] as? [String: Int])
        #expect(levelCounts["notice"] == 1)
        #expect(levelCounts["warning"] == 1)
        #expect(levelCounts["error"] == 1)

        let categoryCounts = try #require(summary["runtimeCountsByCategory"] as? [String: Int])
        #expect(categoryCounts["connection"] == 2)
        #expect(categoryCounts["application"] == 1)
    }

    @Test
    func repeatedExportsCommitIntoDistinctCompleteDirectories() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        fixture.log.record(.applicationStarted)
        let parent = fixture.root.appendingPathComponent("exports", isDirectory: true)

        let firstURLs = try await fixture.log.export(to: parent)
        let firstDirectory = try #require(firstURLs.first?.deletingLastPathComponent())
        let firstLogURL = try #require(
            firstURLs.first { $0.lastPathComponent == "matcha-logs.jsonl" }
        )
        let firstContents = try Data(contentsOf: firstLogURL)

        fixture.log.record(.sessionConnected)
        let secondURLs = try await fixture.log.export(to: parent)
        let secondDirectory = try #require(secondURLs.first?.deletingLastPathComponent())

        #expect(firstDirectory != secondDirectory)
        #expect(try Data(contentsOf: firstLogURL) == firstContents)
        for directory in [firstDirectory, secondDirectory] {
            let names = try Set(
                FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                ).map(\.lastPathComponent)
            )
            #expect(names == ["matcha-logs.jsonl", "matcha-log-summary.json"])
        }
    }

    @Test
    func clearFailureLeavesRuntimeSnapshotIntact() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Matcha-LoggingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("not-a-directory".utf8).write(to: root.appendingPathComponent("Logs"))
        let log = AppLog(directory: root, emitUnifiedLog: false)
        let record = log.record(.applicationStarted)

        var clearFailed = false
        do {
            try await log.clear()
        } catch {
            clearFailed = true
        }

        #expect(clearFailed)
        #expect(log.snapshot().records.map(\.id) == [record.id])
    }

    @Test
    func exportSurfacesUnreadableLogGeneration() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        fixture.log.record(.applicationStarted)
        let activeLog = fixture.log.logDirectory.appendingPathComponent("Matcha.jsonl")
        try FileManager.default.removeItem(at: activeLog)
        try FileManager.default.createDirectory(at: activeLog, withIntermediateDirectories: false)

        var exportFailed = false
        do {
            _ = try await fixture.log.export(
                to: fixture.root.appendingPathComponent("failed-export", isDirectory: true)
            )
        } catch {
            exportFailed = true
        }

        #expect(exportFailed)
    }

    @Test
    func failureDescriptionsPathsAndSecretsNeverReachAnyRecordSink() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let sensitiveDescription = "access_token=hunter2 at /Users/example/private/message.json"
        let safeDomainError = NSError(
            domain: NSCocoaErrorDomain,
            code: 17,
            userInfo: [NSLocalizedDescriptionKey: sensitiveDescription]
        )
        let unsafeDomainError = NSError(
            domain: "Tests.access_token.hunter2.Error",
            code: 23,
            userInfo: [NSLocalizedDescriptionKey: sensitiveDescription]
        )
        let hostShapedDomainError = NSError(
            domain: "api.example.com",
            code: 29,
            userInfo: [NSLocalizedDescriptionKey: sensitiveDescription]
        )

        fixture.log.record(
            .operationReturnedError(
                operation: .sendMessage,
                failure: AppLogFailure(safeDomainError)
            )
        )
        fixture.log.record(.environmentLoadFailed(AppLogFailure(unsafeDomainError)))
        fixture.log.record(.storeObservationFailed(AppLogFailure(hostShapedDomainError)))

        let runtimeText = fixture.log.snapshot().records.map(\.renderedMessage).joined(separator: "\n")
        let diskText = String(
            decoding: try await exportedLogData(from: fixture),
            as: UTF8.self
        )
        let combined = "\(runtimeText)\n\(diskText)".lowercased()
        #expect(!combined.contains("hunter2"))
        #expect(!combined.contains("access_token"))
        #expect(!combined.contains("/users/"))
        #expect(!combined.contains("message.json"))
        #expect(!combined.contains("api.example.com"))
        #expect(combined.contains(NSCocoaErrorDomain.lowercased()))
        #expect(combined.contains("redacted.errordomain"))
    }

    private func makeFixture(
        maxFileSize: Int = 512 * 1024,
        maxRotatedFiles: Int = 5,
        maxEntries: Int = 1000
    ) throws -> LoggingFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Matcha-LoggingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return LoggingFixture(
            root: root,
            log: AppLog(
                directory: root,
                maxFileSize: maxFileSize,
                maxRotatedFiles: maxRotatedFiles,
                maxEntries: maxEntries,
                emitUnifiedLog: false
            )
        )
    }

    private func exportedRecords(from fixture: LoggingFixture) async throws -> [AppLogRecord] {
        let data = try await exportedLogData(from: fixture)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try data.split(separator: 0x0A).map { line in
            try decoder.decode(AppLogRecord.self, from: Data(line))
        }
    }

    private func exportedLogData(from fixture: LoggingFixture) async throws -> Data {
        let directory = fixture.root.appendingPathComponent(
            "export-\(UUID().uuidString)",
            isDirectory: true
        )
        let urls = try await fixture.log.export(to: directory)
        let logURL = try #require(urls.first { $0.lastPathComponent == "matcha-logs.jsonl" })
        return try Data(contentsOf: logURL)
    }
}

private struct LoggingFixture: Sendable {
    let root: URL
    let log: AppLog

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private enum TestFailure: Error {
    case example
}
