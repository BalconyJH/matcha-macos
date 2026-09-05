import Foundation
import ReiLogging
import SwiftUI

struct LogConsoleRow: View {
    let record: AppLogRecord

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: record.levelSymbolName)
                .foregroundStyle(record.levelTint)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.eventIdentifier)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)

                    Text(record.categoryDisplayLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: .capsule)
                }

                Text(record.renderedMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            Text(record.timestamp, format: .dateTime.hour().minute().second())
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
        .help(record.renderedMessage)
    }
}

struct LogConsoleDetail: View {
    let record: AppLogRecord
    let copy: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: record.levelSymbolName)
                    .foregroundStyle(record.levelTint)
                Text(record.eventIdentifier)
                    .font(.headline)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Button("Copy Complete Record", systemImage: "doc.on.doc", action: copy)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Copy complete JSON")
            }
            .padding(.horizontal, 12)
            .frame(height: 42)

            Divider()

            ScrollView([.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 16) {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                        metadataRow("Time", record.timestamp.formatted(date: .abbreviated, time: .standard))
                        metadataRow("Session", record.sessionID.uuidString)
                        metadataRow("Sequence", String(describing: record.sequence))
                        metadataRow("Level", record.levelDisplayLabel)
                        metadataRow("Category", record.categoryDisplayLabel)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Message")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(record.renderedMessage)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Complete Record")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(record.prettyJSON)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func metadataRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
            Text(value)
                .textSelection(.enabled)
        }
        .font(.callout)
    }
}

struct LogFilterOption: Hashable {
    var token: String
    var displayLabel: String
    var sortOrder: Int
}

extension AppLogRecord {
    var levelToken: String {
        level.rawValue
    }

    var categoryToken: String {
        category.rawValue
    }

    var categoryDisplayLabel: String {
        switch categoryToken {
        case "lifecycle": return "Lifecycle"
        case "persistence": return "Persistence"
        case "application": return "Application"
        case "connection": return "Connection"
        default: return humanizedIdentifier(categoryToken)
        }
    }

    var levelDisplayLabel: String {
        switch levelToken {
        case "trace": return "Trace"
        case "debug": return "Debug"
        case "info", "information": return "Info"
        case "notice": return "Notice"
        case "warning", "warn": return "Warning"
        case "error": return "Error"
        case "critical", "fault": return "Critical"
        default: return humanizedIdentifier(levelToken)
        }
    }

    var levelSortOrder: Int {
        switch levelToken {
        case "trace": return 0
        case "debug": return 1
        case "info", "information": return 2
        case "notice": return 3
        case "warning", "warn": return 4
        case "error": return 5
        case "critical", "fault": return 6
        default: return 7
        }
    }

    var searchText: String {
        [
            eventIdentifier,
            renderedMessage,
            levelToken,
            levelDisplayLabel,
            categoryToken,
            categoryDisplayLabel,
            sessionID.uuidString,
        ]
        .joined(separator: "\n")
        .lowercased()
    }

    var consoleLine: String {
        let timestampText = timestamp.formatted(date: .numeric, time: .standard)
        return
            "\(timestampText) [\(levelDisplayLabel)] [\(categoryDisplayLabel)] \(eventIdentifier) — \(renderedMessage)"
    }

    var prettyJSON: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return consoleLine }
        return String(decoding: data, as: UTF8.self)
    }
}

extension AppLogRecord {
    fileprivate var eventIdentifier: String {
        event
    }

    fileprivate var levelSymbolName: String {
        switch levelToken {
        case "trace": return "point.3.filled.connected.trianglepath.dotted"
        case "debug": return "ladybug"
        case "warning", "warn": return "exclamationmark.triangle"
        case "error", "critical", "fault": return "exclamationmark.octagon"
        default: return "info.circle"
        }
    }

    fileprivate var levelTint: Color {
        switch levelToken {
        case "warning", "warn": return .orange
        case "error", "critical", "fault": return .red
        case "info", "information", "notice": return .blue
        default: return .secondary
        }
    }
}

private func humanizedIdentifier(_ rawValue: String) -> String {
    let separators = CharacterSet(charactersIn: "._-/")
    let separated = rawValue.unicodeScalars.map { scalar -> String in
        separators.contains(scalar) ? " " : String(scalar)
    }
    let normalized = separated.joined()

    var result = ""
    for character in normalized {
        if character.isUppercase, result.last?.isWhitespace == false {
            result.append(" ")
        }
        result.append(character)
    }
    return result.split(whereSeparator: \.isWhitespace)
        .map { $0.prefix(1).uppercased() + String($0.dropFirst()) }
        .joined(separator: " ")
}
