import MatchaCore
import MatchaProtocol
import SwiftUI

/// The raw protocol inspector.
///
/// Shown in the window's inspector column. Lists what crossed the wire, newest
/// first, and prints the selected entry's payload as indented JSON. This is the view
/// a framework author reads when a call did not do what they expected, so it shows
/// the payload verbatim rather than a summarised form.
struct TrafficInspectorView: View {
    let environment: AppEnvironment
    let close: () -> Void

    @State private var selection: TrafficEntry.ID?
    @State private var query = ""
    @State private var directionFilter: DirectionFilter = .all
    @State private var clearedBefore: Date?
    @Namespace private var directionFilterGlassNamespace

    var body: some View {
        VStack(spacing: 0) {
            inspectorHeader

            Divider()

            filterBar

            Divider()

            if visibleEntries.isEmpty {
                emptyState
                    .frame(maxHeight: .infinity)
            } else {
                entryList

                Divider()

                payloadPane
                    .frame(minHeight: 160, idealHeight: 220)
            }
        }
    }

    private var inspectorHeader: some View {
        HStack(spacing: 8) {
            Label("Raw Events", systemImage: "curlybraces.square")
                .font(.headline)

            Text("\(visibleEntries.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: .capsule)
                .accessibilityLabel("Showing \(visibleEntries.count) events")

            Spacer(minLength: 0)

            Button("Hide Raw Events", systemImage: "sidebar.trailing", action: close)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help("Hide Raw Events (⌥⌘I)")
        }
        .padding(.horizontal, 10)
        .frame(height: 40)
    }

    // MARK: - Filtering

    private var filterBar: some View {
        VStack(spacing: 8) {
            NativeSearchField(
                text: $query,
                prompt: "Search event summaries",
                accessibilityLabel: "Search raw events"
            )
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .help("Filter by summary")

            HStack(spacing: 8) {
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(DirectionFilter.allCases) { option in
                            directionButton(option)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button("Clear View", systemImage: "eraser") {
                    // Mark rather than delete: entries stay in the shared log for
                    // anything else reading it.
                    clearedBefore = .now
                    selection = nil
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .frame(width: 28, height: 28)
                .help("Hide all current events; use Show All to restore them")
                .disabled(visibleEntries.isEmpty)
            }
        }
        .padding(10)
    }

    private func directionButton(_ option: DirectionFilter) -> some View {
        let isSelected = directionFilter == option

        return Button {
            guard !isSelected else { return }
            withAnimation(.snappy(duration: 0.22, extraBounce: 0)) {
                directionFilter = option
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: option.symbolName)
                    .foregroundStyle(
                        isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(option.tint)
                    )
                    .frame(width: 14)

                if isSelected {
                    Text(option.label)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .transition(.blurReplace.combined(with: .opacity))
                }
            }
            .font(.caption)
            .lineLimit(1)
            .frame(width: isSelected ? 84 : 32, height: 28)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(
            isSelected ? .regular.tint(option.tint).interactive() : .regular.interactive(),
            in: .capsule
        )
        .glassEffectID(option.id, in: directionFilterGlassNamespace)
        .glassEffectTransition(.matchedGeometry)
        .accessibilityLabel(option.label)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .help("Show \(option.label.lowercased()) events only")
    }

    private var visibleEntries: [TrafficEntry] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return environment.traffic.filter { entry in
            if let clearedBefore, entry.timestamp <= clearedBefore { return false }
            guard directionFilter.matches(entry) else { return false }
            guard !text.isEmpty else { return true }
            return entry.summary.lowercased().contains(text)
        }
    }

    // MARK: - List

    private var entryList: some View {
        List(visibleEntries, selection: $selection) { entry in
            TrafficRow(entry: entry)
                .tag(entry.id)
                .contextMenu {
                    Button("Copy JSON") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.payload.prettyText, forType: .string)
                    }
                }
        }
        .listStyle(.inset)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Events", systemImage: "curlybraces.square")
        } description: {
            if environment.traffic.isEmpty {
                Text("Raw messages sent to and from the bot framework will appear here after it connects.")
            } else {
                Text("No events match the current filters.")
            }
        } actions: {
            if !environment.traffic.isEmpty {
                Button("Show All", action: reset)
            }
        }
    }

    // MARK: - Payload

    @ViewBuilder
    private var payloadPane: some View {
        if let entry = selectedEntry {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(entry.summary)
                        .font(.callout)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.payload.prettyText, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy JSON")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                Divider()

                ScrollView([.vertical, .horizontal]) {
                    Text(entry.payload.prettyText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                }
                .background(.background.secondary)
            }
        } else {
            Text("Select an event to view its raw payload")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var selectedEntry: TrafficEntry? {
        guard let selection else { return nil }
        return visibleEntries.first { $0.id == selection }
    }

    /// Drops every filter, including the clear marker, so the whole log is visible again.
    private func reset() {
        query = ""
        directionFilter = .all
        clearedBefore = nil
    }
}

// MARK: - Row

/// One wire event: direction glyph, time, and summary.
private struct TrafficRow: View {
    let entry: TrafficEntry

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.symbolName)
                .foregroundStyle(entry.tint)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.summary)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 1)
        .help(entry.summary)
    }
}

// MARK: - Direction filter

/// Segmented filter over the entry direction.
private enum DirectionFilter: String, CaseIterable, Identifiable {
    case all
    case inbound
    case outbound

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .inbound: return "Received"
        case .outbound: return "Sent"
        }
    }

    var symbolName: String {
        switch self {
        case .all: return "tray.full"
        case .inbound: return "tray.and.arrow.down"
        case .outbound: return "paperplane"
        }
    }

    var tint: Color {
        switch self {
        case .all: return .gray
        case .inbound: return .blue
        case .outbound: return .green
        }
    }

    /// Replies count as outbound: they are what Matcha wrote back to the framework.
    func matches(_ entry: TrafficEntry) -> Bool {
        switch self {
        case .all: return true
        case .inbound: return entry.direction == .inboundCall
        case .outbound: return entry.direction != .inboundCall
        }
    }
}

// MARK: - Presentation

extension TrafficEntry {
    fileprivate var symbolName: String {
        switch direction {
        case .inboundCall: return "arrow.down.circle"
        case .outboundEvent: return "arrow.up.circle"
        case .reply: return isFailedReply ? "exclamationmark.circle" : "arrowshape.turn.up.left.circle"
        }
    }

    /// Red marks a reply that carried a non-zero return code, which is the thing
    /// worth spotting while scanning the log.
    fileprivate var tint: Color {
        if isFailedReply { return .red }
        switch direction {
        case .inboundCall: return .blue
        case .outboundEvent: return .green
        case .reply: return .secondary
        }
    }

    /// Read from the payload rather than tracked separately, because the envelope
    /// carries the code the framework actually received. Both protocols use zero for
    /// success, and Milky adds an `ok` flag alongside it.
    fileprivate var isFailedReply: Bool {
        guard direction == .reply else { return false }
        if let retcode = payload["retcode"]?.intValue, retcode != 0 { return true }
        if let ok = payload["ok"]?.boolValue, !ok { return true }
        return false
    }
}
