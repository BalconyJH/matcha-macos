import AppKit
import MatchaLogging
import SwiftUI

/// A live, searchable view of Matcha's structured application log.
///
/// Protocol payload traffic remains in `TrafficInspectorView`; this utility window
/// presents operational diagnostics emitted through `AppLog` instead.
@MainActor
public struct LogConsoleView: View {
    @State private var model: LogConsoleModel
    @State private var query = ""
    @State private var excludedLevels: Set<String> = []
    @State private var excludedCategories: Set<String> = []
    @State private var selection: AppLogRecord.ID?
    @State private var showingClearConfirmation = false
    @FocusState private var searchIsFocused: Bool

    public init(log: AppLog) {
        _model = State(initialValue: LogConsoleModel(log: log))
    }

    public var body: some View {
        VStack(spacing: 0) {
            actionBar

            Divider()

            NavigationSplitView {
                listPane
                    .navigationSplitViewColumnWidth(min: 340, ideal: 440, max: 620)
            } detail: {
                detailPane
            }
            .navigationSplitViewStyle(.balanced)

            Divider()

            statusBar
        }
        .frame(minWidth: 760, minHeight: 480)
        .task {
            await model.observeSnapshots()
        }
        .onChange(of: filteredRecords.map(\.id)) {
            guard selection != nil, selectedRecord == nil else { return }
            selection = nil
        }
        .confirmationDialog(
            "Clear All Logs?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) {
                selection = nil
                Task { await model.clear() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes all saved logs and current records. Exported files are not affected.")
        }
        .alert(
            "Log Operation Failed",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }

    // MARK: - Window chrome

    private var actionBar: some View {
        HStack(spacing: 10) {
            Label("Log Console", systemImage: "terminal")
                .font(.headline)

            Text("\(filteredRecords.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.quaternary, in: .capsule)
                .accessibilityLabel("Showing \(filteredRecords.count) logs")

            Spacer(minLength: 12)

            Button("Copy Selected", systemImage: "doc.on.doc") {
                if let selectedRecord {
                    copyToPasteboard(selectedRecord.prettyJSON)
                    model.note("Selected log copied")
                }
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .keyboardShortcut("c", modifiers: [.command, .option])
            .help("Copy selected log (⌥⌘C)")
            .disabled(selectedRecord == nil)

            Button("Copy Filtered Results", systemImage: "doc.on.doc.fill") {
                copyToPasteboard(filteredRecords.map(\.consoleLine).joined(separator: "\n"))
                model.note("Copied \(filteredRecords.count) filtered results")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .help("Copy current filtered results (⇧⌘C)")
            .disabled(filteredRecords.isEmpty)

            Button("Export Complete Log", systemImage: "square.and.arrow.up") {
                chooseExportDirectory()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .help("Export complete log (⇧⌘E)")
            .disabled(model.isExporting)

            Button("Clear Logs", systemImage: "trash", role: .destructive) {
                showingClearConfirmation = true
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .keyboardShortcut(.delete, modifiers: [.command, .shift])
            .help("Clear all logs (⇧⌘⌫)")
            .disabled(model.isClearing)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 42)
    }

    private var statusBar: some View {
        HStack(spacing: 7) {
            if model.isExporting || model.isClearing {
                ProgressView()
                    .controlSize(.small)
            }

            Text(model.statusMessage ?? defaultStatusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 8)

            Text("\(model.records.count) total")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
    }

    private var defaultStatusMessage: String {
        if model.isExporting { return "Exporting complete log…" }
        if model.isClearing { return "Clearing logs…" }
        if hasActiveFilters { return "Filters applied" }
        return "Live updates"
    }

    // MARK: - List and filtering

    private var listPane: some View {
        VStack(spacing: 0) {
            filterBar

            Divider()

            if model.records.isEmpty {
                noLogsView
            } else if filteredRecords.isEmpty {
                noMatchesView
            } else {
                List(filteredRecords, selection: $selection) { record in
                    LogConsoleRow(record: record)
                        .tag(record.id)
                        .contextMenu {
                            Button("Copy Log") {
                                copyToPasteboard(record.prettyJSON)
                                model.note("Selected log copied")
                            }

                            Button("Copy Message") {
                                copyToPasteboard(record.renderedMessage)
                                model.note("Log message copied")
                            }
                        }
                }
                .listStyle(.inset)
            }
        }
    }

    private var filterBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Button {
                    searchIsFocused = true
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.plain)
                .keyboardShortcut("f", modifiers: .command)
                .help("Search logs (⌘F)")

                TextField("Search events, messages, categories, or levels", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchIsFocused)

                if !query.isEmpty {
                    Button("Clear Search", systemImage: "xmark.circle.fill") {
                        query = ""
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(.quaternary, in: .rect(cornerRadius: 7))

            HStack(spacing: 8) {
                levelFilterMenu
                categoryFilterMenu

                Spacer(minLength: 0)

                Button("Reset Filters", systemImage: "arrow.counterclockwise") {
                    resetFilters()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Reset search, level, and category filters")
                .disabled(!hasActiveFilters)
            }
        }
        .padding(10)
    }

    private var levelFilterMenu: some View {
        Menu {
            if availableLevels.isEmpty {
                Text("No Levels")
            } else {
                ForEach(availableLevels, id: \.self) { level in
                    Toggle(
                        level.displayLabel,
                        isOn: inclusionBinding(level.token, excluded: $excludedLevels)
                    )
                }

                Divider()

                Button("Select All") { excludedLevels.removeAll() }
                    .disabled(excludedLevels.isEmpty)
                Button("Deselect All") { excludedLevels = Set(availableLevels.map(\.token)) }
                    .disabled(availableLevels.allSatisfy { excludedLevels.contains($0.token) })
            }
        } label: {
            Label(levelFilterLabel, systemImage: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var categoryFilterMenu: some View {
        Menu {
            if availableCategories.isEmpty {
                Text("No Categories")
            } else {
                ForEach(availableCategories, id: \.self) { category in
                    Toggle(
                        category.displayLabel,
                        isOn: inclusionBinding(category.token, excluded: $excludedCategories)
                    )
                }

                Divider()

                Button("Select All") { excludedCategories.removeAll() }
                    .disabled(excludedCategories.isEmpty)
                Button("Deselect All") {
                    excludedCategories = Set(availableCategories.map(\.token))
                }
                .disabled(availableCategories.allSatisfy {
                    excludedCategories.contains($0.token)
                })
            }
        } label: {
            Label(categoryFilterLabel, systemImage: "tag")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var filteredRecords: [AppLogRecord] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        return model.records
            .filter { record in
                let level = record.levelToken
                let category = record.categoryToken
                guard !excludedLevels.contains(level),
                      !excludedCategories.contains(category)
                else { return false }

                guard !normalizedQuery.isEmpty else { return true }
                return record.searchText.contains(normalizedQuery)
            }
            .sorted {
                if $0.sequence != $1.sequence { return $0.sequence > $1.sequence }
                return $0.timestamp > $1.timestamp
            }
    }

    private var availableLevels: [LogFilterOption] {
        uniqueOptions(model.records.map { record in
            LogFilterOption(
                token: record.levelToken,
                displayLabel: record.levelDisplayLabel,
                sortOrder: record.levelSortOrder
            )
        })
        .sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            return $0.displayLabel.localizedStandardCompare($1.displayLabel) == .orderedAscending
        }
    }

    private var availableCategories: [LogFilterOption] {
        uniqueOptions(model.records.map { record in
            LogFilterOption(
                token: record.categoryToken,
                displayLabel: record.categoryDisplayLabel,
                sortOrder: 0
            )
        })
        .sorted {
            $0.displayLabel.localizedStandardCompare($1.displayLabel) == .orderedAscending
        }
    }

    private var levelFilterLabel: String {
        filterLabel(
            noun: "Levels",
            options: availableLevels,
            excluded: excludedLevels
        )
    }

    private var categoryFilterLabel: String {
        filterLabel(
            noun: "Categories",
            options: availableCategories,
            excluded: excludedCategories
        )
    }

    private var hasActiveFilters: Bool {
        !query.isEmpty || !excludedLevels.isEmpty || !excludedCategories.isEmpty
    }

    private func filterLabel(
        noun: String,
        options: [LogFilterOption],
        excluded: Set<String>
    ) -> String {
        guard !options.isEmpty else { return noun }
        let selected = options.filter { !excluded.contains($0.token) }
        if selected.count == options.count { return "All \(noun)" }
        if selected.isEmpty { return "No \(noun)" }
        if selected.count == 1 { return selected[0].displayLabel }
        return "\(selected.count)/\(options.count) \(noun)"
    }

    private func inclusionBinding(
        _ token: String,
        excluded: Binding<Set<String>>
    ) -> Binding<Bool> {
        Binding(
            get: { !excluded.wrappedValue.contains(token) },
            set: { isIncluded in
                if isIncluded {
                    excluded.wrappedValue.remove(token)
                } else {
                    excluded.wrappedValue.insert(token)
                }
            }
        )
    }

    private func uniqueOptions(_ options: [LogFilterOption]) -> [LogFilterOption] {
        var seen: Set<String> = []
        return options.filter { seen.insert($0.token).inserted }
    }

    private func resetFilters() {
        query = ""
        excludedLevels.removeAll()
        excludedCategories.removeAll()
    }

    // MARK: - Empty and detail states

    private var noLogsView: some View {
        ContentUnavailableView {
            Label("No Logs", systemImage: "terminal")
        } description: {
            Text("Structured diagnostic records generated while the app runs will appear here.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMatchesView: some View {
        ContentUnavailableView {
            Label("No Matching Logs", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text("Adjust the search text, log levels, or categories.")
        } actions: {
            Button("Reset Filters", action: resetFilters)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var detailPane: some View {
        if let selectedRecord {
            LogConsoleDetail(record: selectedRecord) {
                copyToPasteboard(selectedRecord.prettyJSON)
                model.note("Selected log copied")
            }
        } else {
            ContentUnavailableView {
                Label("Select a Log", systemImage: "doc.text.magnifyingglass")
            } description: {
                Text("Details include the time, level, category, event, message, and structured fields.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var selectedRecord: AppLogRecord? {
        guard let selection else { return nil }
        return filteredRecords.first { $0.id == selection }
    }

    // MARK: - Actions

    private func chooseExportDirectory() {
        guard let directory = LogExportPanel.chooseDirectory() else { return }
        Task { await model.export(to: directory) }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}
