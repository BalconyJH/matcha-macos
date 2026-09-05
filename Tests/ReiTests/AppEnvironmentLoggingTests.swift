import Foundation
import ReiCore
import ReiProtocol
import Testing

@testable import ReiLogging
@testable import ReiUI

@Suite("Application Environment Logging", .serialized)
@MainActor
struct AppEnvironmentLoggingTests {
    @Test
    func applicationActionsRecordTypedOutcomesWithoutPrivateValues() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let privateValue = "private-persona-and-peer-id"

        await fixture.environment.createUser(name: privateValue)
        fixture.environment.setActiveUser(privateValue)
        fixture.environment.selectChat(
            Chat(scene: .friend, peerID: privateValue, selfID: privateValue)
        )
        fixture.environment.saveSettings()
        let unavailableAsset = await fixture.environment.ingestAttachment(
            at: fixture.root.appendingPathComponent("private-attachment-name.txt")
        )
        let unreadableURL = fixture.root.appendingPathComponent(
            "private-unreadable-attachment",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: unreadableURL,
            withIntermediateDirectories: false
        )
        let unreadableAsset = await fixture.environment.ingestAttachment(at: unreadableURL)

        fixture.environment.reportAttachmentSelectionFailure(CocoaError(.userCancelled))
        fixture.environment.reportAttachmentSelectionCompleted()

        fixture.environment.settings.reconnectInterval = .nan
        fixture.environment.saveSettings()

        var removalFailed = false
        do {
            try await fixture.environment.removeFriend(privateValue)
        } catch {
            removalFailed = true
        }

        let records = fixture.log.snapshot().records
        #expect(unavailableAsset == nil)
        #expect(unreadableAsset == nil)
        #expect(removalFailed)
        #expect(records.matching(.loadSettings, outcome: .completed).count == 1)
        #expect(records.matching(.createPersona, outcome: .completed).count == 1)
        #expect(records.matching(.selectActivePersona, outcome: .completed).count == 1)
        #expect(records.matching(.selectChat, outcome: .completed).count == 1)
        #expect(records.matching(.saveSettings, outcome: .completed).count == 1)
        #expect(records.matching(.importAttachment, outcome: .unavailable).count == 1)
        #expect(records.matching(.importAttachment, outcome: .returnedError).count == 1)
        #expect(records.matching(.chooseAttachments, outcome: .completed).count == 1)
        #expect(records.matching(.chooseAttachments, outcome: .returnedError).isEmpty)
        #expect(records.matching(.saveSettings, outcome: .returnedError).count == 1)

        let failures = records.matching(.removeFriend, outcome: .returnedError)
        let failure = try #require(failures.only)
        #expect(failure.category == .application)
        #expect(failure.level == .error)
        #expect(failure.fields.errorDomain == "ReiProtocol.PlatformError")

        let rendered = records.map(\.renderedMessage).joined(separator: "\n")
        #expect(!rendered.contains(privateValue))
        #expect(!rendered.contains("private-attachment-name"))
        #expect(!rendered.contains("private-unreadable-attachment"))
    }

    private func makeFixture() throws -> EnvironmentLoggingFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Rei-AppLoggingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let log = AppLog(directory: root, emitUnifiedLog: false)
        let defaultsName = "dev.rei.tests.app-logging.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsName) else {
            throw CocoaError(.fileReadUnknown)
        }
        let environment = AppEnvironment(
            store: try ReiStore(),
            assetStore: try AssetStore(
                directory: root.appendingPathComponent("Assets", isDirectory: true)
            ),
            appLog: log,
            defaults: defaults
        )
        return EnvironmentLoggingFixture(
            root: root,
            defaultsName: defaultsName,
            defaults: defaults,
            log: log,
            environment: environment
        )
    }
}

private enum ExpectedOperationOutcome: String {
    case completed
    case unavailable
    case returnedError
}

extension Array where Element == AppLogRecord {
    fileprivate func matching(
        _ operation: AppLogOperation,
        outcome: ExpectedOperationOutcome
    ) -> [AppLogRecord] {
        filter {
            $0.event == "app.\(operation.rawValue).\(outcome.rawValue)"
                && $0.fields.operation == operation
        }
    }

    fileprivate var only: Element? {
        count == 1 ? first : nil
    }
}

@MainActor
private struct EnvironmentLoggingFixture {
    let root: URL
    let defaultsName: String
    let defaults: UserDefaults
    let log: AppLog
    let environment: AppEnvironment

    func remove() {
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }
}
