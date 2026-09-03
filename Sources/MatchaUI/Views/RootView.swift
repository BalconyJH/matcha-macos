import MatchaProtocol
import SwiftUI

/// The singleton main window: a stable conversation sidebar, a wide chat canvas,
/// and an optional protocol inspector.
@MainActor
public struct RootView: View {
    let environment: AppEnvironment
    @Binding private var selectedSettingsTab: MatchaSettingsTab

    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showingInspector = true
    @State private var showingNewUser = false
    @State private var showingAddFriend = false
    @State private var showingNewGroup = false

    public init(
        environment: AppEnvironment,
        selectedSettingsTab: Binding<MatchaSettingsTab>
    ) {
        self.environment = environment
        _selectedSettingsTab = selectedSettingsTab
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(
                environment: environment,
                selectedSettingsTab: $selectedSettingsTab
            )
            .navigationSplitViewColumnWidth(min: 230, ideal: 280, max: 420)
        } detail: {
            ChatView(environment: environment)
                .inspector(isPresented: $showingInspector) {
                    TrafficInspectorView(
                        environment: environment,
                        close: { showingInspector = false }
                    )
                    .inspectorColumnWidth(min: 300, ideal: 400, max: 620)
                }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                ConnectionStatusButton(environment: environment)
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarSpacer(.fixed)

            ToolbarItem {
                Menu {
                    Button("New Persona…", systemImage: "person.badge.plus") {
                        showingNewUser = true
                    }

                    Button("Add Friend…", systemImage: "person.badge.plus") {
                        showingAddFriend = true
                    }
                    .disabled(environment.addableFriendUsers.isEmpty)

                    Button("New Group…", systemImage: "person.3") {
                        showingNewGroup = true
                    }
                    .disabled(environment.users.isEmpty)
                } label: {
                    Label("New", systemImage: "plus")
                }
                .help("Create a persona, add a friend, or create a group")
            }

            ToolbarSpacer(.fixed)

            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showingInspector.toggle()
                } label: {
                    Label(
                        showingInspector ? "Hide Raw Events" : "Show Raw Events",
                        systemImage: "sidebar.trailing"
                    )
                }
                .help(showingInspector ? "Hide Raw Events (⌥⌘I)" : "Show Raw Events (⌥⌘I)")

                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Connection and persona settings (⌘,)")
            }
        }
        .sheet(isPresented: $showingNewUser) {
            NewUserSheet(environment: environment)
        }
        .sheet(isPresented: $showingAddFriend) {
            UserSelectionSheet(environment: environment, purpose: .friend)
        }
        .sheet(isPresented: $showingNewGroup) {
            NewGroupSheet(environment: environment)
        }
        .alert(
            "Something Went Wrong",
            isPresented: Binding(
                get: { environment.lastError != nil },
                set: { if !$0 { environment.lastError = nil } }
            )
        ) {
            Button("OK") { environment.lastError = nil }
        } message: {
            Text(environment.lastError ?? "")
        }
        .focusedSceneValue(\.matchaCommandActions, commandActions)
        .frame(minWidth: 980, minHeight: 620)
    }

    private var commandActions: MatchaCommandActions {
        MatchaCommandActions(
            createUser: { showingNewUser = true },
            createGroup: { showingNewGroup = true },
            toggleConnection: toggleConnection,
            toggleInspector: { showingInspector.toggle() },
            canCreateGroup: !environment.users.isEmpty,
            isConnected: environment.sessionState.isActive,
            isInspectorPresented: showingInspector
        )
    }

    private func toggleConnection() {
        Task {
            if environment.sessionState.isActive {
                await environment.disconnect()
            } else {
                await environment.connect()
            }
        }
    }
}

/// Connect/disconnect control that also exposes the current session state.
private struct ConnectionStatusButton: View {
    let environment: AppEnvironment

    var body: some View {
        Button {
            Task {
                if environment.sessionState.isActive {
                    await environment.disconnect()
                } else {
                    await environment.connect()
                }
            }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(indicatorColor)
                    .frame(width: 7, height: 7)
                Text(protocolChoice.shortDisplayName)
                    .font(.callout)
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(statusText)
                    .font(.callout)
                    .monospacedDigit()
            }
        }
        .accessibilityLabel("\(protocolChoice.shortDisplayName), \(statusText)")
        .accessibilityHint(environment.sessionState.isActive ? "Disconnect" : "Connect")
        .help(helpText)
    }

    private var indicatorColor: Color {
        switch environment.sessionState {
        case .connected where environment.roundTripTimeState == .timedOut:
            return .orange
        case .connected:
            return .green
        case .ready:
            return .green
        case .listening, .connecting: return .orange
        case .failed: return .red
        case .idle: return .secondary
        }
    }

    private var protocolChoice: ProtocolChoice {
        environment.activeProtocolChoice ?? environment.selectedProtocol
    }

    private var transportMode: TransportMode {
        environment.activeTransportMode ?? environment.settings.transport
    }

    private var statusText: String {
        switch environment.sessionState {
        case .idle:
            return "Not Connected"
        case .listening(let port):
            return "Listening on :\(port)"
        case .ready(let port):
            return "Serving on :\(port)"
        case .connecting:
            return "Connecting"
        case .failed:
            return "Connection Failed"
        case .connected:
            guard supportsRoundTripTime else {
                return "Serving"
            }
            switch environment.roundTripTimeState {
            case .measured(let duration): return durationLabel(duration)
            case .timedOut: return "Ping Timed Out"
            case .measuring, .unavailable: return "Measuring"
            case .unsupported: return "RTT —"
            }
        }
    }

    private var helpText: String {
        var components = [
            protocolChoice.displayName,
            transportMode.displayName,
            environment.sessionState.displayName,
        ]

        if case .measured(let duration) = environment.roundTripTimeState,
            supportsRoundTripTime
        {
            components.append("RTT \(durationLabel(duration))")
        } else if !supportsRoundTripTime, environment.sessionState.isActive {
            components.append("Milky serves independent API and event endpoints without a single connection RTT")
        }

        components.append(environment.sessionState.isActive ? "Click to Disconnect (⇧⌘K)" : "Click to Connect (⇧⌘K)")
        return components.joined(separator: " · ")
    }

    private var supportsRoundTripTime: Bool {
        transportMode == .webSocketServer || transportMode == .webSocketClient
    }

    private func durationLabel(_ duration: Duration) -> String {
        let components = duration.components
        let milliseconds =
            Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        guard milliseconds >= 1 else { return "<1 ms" }
        return "\(Int(milliseconds.rounded())) ms"
    }
}
