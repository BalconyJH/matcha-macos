import Foundation
import MatchaLogging
import Observation

@Observable
@MainActor
final class LogConsoleModel {
    private let log: AppLog

    var records: [AppLogRecord] = []
    var isExporting = false
    var isClearing = false
    var statusMessage: String?
    var errorMessage: String?

    init(log: AppLog) {
        self.log = log
    }

    func observeSnapshots() async {
        apply(log.snapshot())
        let snapshots = log.snapshots()
        for await snapshot in snapshots {
            guard !Task.isCancelled else { return }
            apply(snapshot)
        }
    }

    func clear() async {
        guard !isClearing else { return }
        isClearing = true
        statusMessage = "Clearing logs…"
        errorMessage = nil
        defer { isClearing = false }

        do {
            try await log.clear()
            apply(log.snapshot())
            statusMessage = "Logs cleared"
        } catch {
            log.record(
                .operationReturnedError(
                    operation: .clearLogs,
                    failure: AppLogFailure(error)
                )
            )
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    func export(to directory: URL) async {
        guard !isExporting else { return }
        isExporting = true
        statusMessage = "Exporting complete log…"
        errorMessage = nil
        defer { isExporting = false }

        do {
            let exportedURLs = try await log.export(to: directory)
            log.record(.operationCompleted(.exportLogs))
            if exportedURLs.count == 1, let exportedURL = exportedURLs.first {
                statusMessage = "Exported \(exportedURL.lastPathComponent)"
            } else {
                let destination = exportedURLs.first?.deletingLastPathComponent() ?? directory
                statusMessage = "Exported \(exportedURLs.count) files to \(destination.path(percentEncoded: false))"
            }
        } catch {
            log.record(
                .operationReturnedError(
                    operation: .exportLogs,
                    failure: AppLogFailure(error)
                )
            )
            statusMessage = nil
            errorMessage = error.localizedDescription
        }
    }

    func note(_ message: String) {
        statusMessage = message
    }

    private func apply(_ snapshot: AppLogSnapshot) {
        records = snapshot.records
    }
}
