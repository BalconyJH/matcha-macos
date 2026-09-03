import MatchaCore
import MatchaProtocol
import SwiftUI

/// The destination shown in the singleton Settings scene.
public enum MatchaSettingsTab: Hashable, Sendable {
    case connection
    case roles
    case about
}

/// Connection and persona settings.
///
/// The dedicated Settings scene edits a local snapshot. Cancel and closing the
/// window leave the running configuration untouched; Save commits the snapshot once.
@MainActor
public struct SettingsView: View {
    let environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @Binding private var selectedTab: MatchaSettingsTab
    @State private var draft: SettingsDraft
    @State private var isSaving = false

    public init(
        environment: AppEnvironment,
        selectedTab: Binding<MatchaSettingsTab>
    ) {
        self.environment = environment
        _selectedTab = selectedTab
        _draft = State(initialValue: SettingsDraft(environment: environment))
    }

    public var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                ConnectionSettingsTab(
                    settings: $draft.connection,
                    portText: $draft.portText,
                    protocolChoice: $draft.protocolChoice
                )
                    .tabItem { Label("Connection", systemImage: "network") }
                    .tag(MatchaSettingsTab.connection)

                RoleSettingsTab(
                    environment: environment,
                    activeUserID: $draft.activeUserID,
                    botUserID: $draft.botUserID
                )
                    .tabItem { Label("Personas", systemImage: "person.2") }
                    .tag(MatchaSettingsTab.roles)

                AboutTab()
                    .tabItem { Label("About", systemImage: "info.circle") }
                    .tag(MatchaSettingsTab.about)
            }

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    resetDraft()
                    dismiss()
                }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!draft.isValid || isSaving)
            }
            .padding(12)
        }
        .frame(width: 640, height: 560)
        .onAppear(perform: resetDraft)
    }

    private func resetDraft() {
        draft = SettingsDraft(environment: environment)
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            if await commitDraft() { dismiss() }
        }
    }

    private func commitDraft() async -> Bool {
        guard let port = draft.portValidation.value else { return false }
        var connection = draft.connection
        connection.port = port
        environment.settings = connection
        environment.selectedProtocol = draft.protocolChoice

        if let activeUserID = draft.activeUserID,
           activeUserID != environment.activeUserID
        {
            environment.setActiveUser(activeUserID)
        }
        var botChangeSucceeded = true
        if let botUserID = draft.botUserID, botUserID != environment.botUserID {
            botChangeSucceeded = await environment.setBotUser(botUserID)
        }
        let settingsSaved = environment.saveSettings()
        return settingsSaved && botChangeSucceeded
    }
}

@MainActor
private struct SettingsDraft {
    var connection: ConnectionSettings
    var portText: String
    var protocolChoice: ProtocolChoice
    var activeUserID: String?
    var botUserID: String?

    init(environment: AppEnvironment) {
        connection = environment.settings
        portText = String(environment.settings.port)
        protocolChoice = environment.selectedProtocol
        if !protocolChoice.supportedTransports.contains(connection.transport) {
            connection.transport = protocolChoice.supportedTransports[0]
        }
        if connection.transport == .webSocketClient {
            connection.path = protocolChoice.resolvingWebSocketClientPath(connection.path)
        }
        activeUserID = environment.activeUserID
        botUserID = environment.botUserID
    }

    var portValidation: PortValidation {
        PortValidation(text: portText)
    }

    var isValid: Bool {
        portValidation.value != nil
            && (protocolChoice != .milky || connection.milkyWebhookEndpoints != nil)
    }
}

/// Parses a port as a protocol identifier rather than a locale-formatted number.
private struct PortValidation {
    let value: UInt16?
    let message: String?

    init(text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            value = nil
            message = "Enter a port"
            return
        }
        guard trimmed.utf8.allSatisfy({ (48 ... 57).contains($0) }) else {
            value = nil
            message = "The port can contain decimal digits only"
            return
        }

        guard let number = UInt32(trimmed), number >= 1, number <= 65_535 else {
            value = nil
            message = "The port must be between 1 and 65535"
            return
        }

        value = UInt16(number)
        message = nil
    }
}

// MARK: - Connection

/// Transport, address, and authentication for the selected protocol endpoint.
private struct ConnectionSettingsTab: View {
    @Binding var settings: ConnectionSettings
    @Binding var portText: String
    @Binding var protocolChoice: ProtocolChoice

    var body: some View {
        Form {
            Section("Protocol") {
                Picker("Protocol Standard", selection: protocolBinding) {
                    ForEach(ProtocolChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice)
                    }
                }

                if protocolChoice != .milky {
                    Picker("Connection Mode", selection: transportBinding) {
                        ForEach(protocolChoice.supportedTransports) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .help(connectionModeHelp)
                } else {
                    Text("Matcha serves the Milky API and event WebSocket together. WebHooks below are optional additional event destinations.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Address") {
                TextField("Host", text: binding(\.host))
                    .help(hostHelp)

                LabeledContent("Port") {
                    VStack(alignment: .trailing, spacing: 2) {
                        TextField("Port", text: $portText)
                            .labelsHidden()
                            .monospacedDigit()
                            .multilineTextAlignment(.trailing)
                            .frame(width: 96)

                        if let message = portValidation.message {
                            Text(message)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
                .help(portHelp)

                if settings.transport == .webSocketClient {
                    // Only the dial-out mode has a path to configure: in server modes
                    // the connecting framework chooses the path itself.
                    TextField(
                        "Path",
                        text: binding(\.path),
                        prompt: Text(protocolChoice.webSocketClientDefaultPath ?? "/")
                    )
                }

                LabeledContent(endpointLabel) {
                    HStack(spacing: 6) {
                        Text(endpointText)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button {
                            copy(endpointText)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.borderless)
                        .help("Copy address")
                        .disabled(previewSettings == nil)
                    }
                }

                if settings.transport == .webSocketClient {
                    Text(reverseConnectionHelp)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let eventStream = eventStreamText {
                    LabeledContent("Event Stream URL") {
                        HStack(spacing: 6) {
                            Text(eventStream)
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button {
                                copy(eventStream)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.borderless)
                            .help("Copy event stream URL")
                        }
                    }
                }
            }

            if protocolChoice == .milky {
                Section {
                    ForEach(settings.milkyWebhookURLs.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                TextField(
                                    "http://127.0.0.1:8080/milky/",
                                    text: webhookBinding(at: index)
                                )
                                .textFieldStyle(.roundedBorder)

                                Button(role: .destructive) {
                                    settings.milkyWebhookURLs.remove(at: index)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("Remove WebHook destination")
                            }

                            if !isValidWebhook(at: index) {
                                Text("Enter an absolute HTTP or HTTPS URL")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }

                    Button {
                        settings.milkyWebhookURLs.append("")
                    } label: {
                        Label("Add WebHook Destination", systemImage: "plus")
                    }
                } header: {
                    Text("Event WebHooks")
                } footer: {
                    Text("Optional. Every event is still available from /event and is also POSTed to each destination. nonebot-adapter-milky receives WebHook events at /milky/.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                SecureField("Access Token", text: binding(\.accessToken))
            } header: {
                Text("Authentication")
            } footer: {
                // A listening socket with no token accepts anything that can reach the
                // port, so this tradeoff is stated rather than left to be discovered.
                Text(authenticationHelp)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Behavior") {
                if settings.transport == .webSocketClient {
                    Toggle("Reconnect Automatically", isOn: binding(\.autoReconnect))

                    if settings.autoReconnect {
                        Stepper(value: reconnectSecondsBinding, in: 1 ... 60) {
                            LabeledContent("Reconnect Delay", value: "\(reconnectSecondsBinding.wrappedValue) seconds")
                        }
                    }
                }

                Toggle("Echo Bot-Generated Events", isOn: binding(\.postSelfEvents))
                    .help("When disabled, the bot’s own messages are not sent back to it as events")

                Text("When disabled, actions performed by the bot are not sent back to it as incoming events. This prevents loops caused by the framework receiving its own messages. Enable this when debugging the framework’s sending logic.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Bindings

    /// Writes through the local settings snapshot so summaries update without
    /// changing the live session configuration.
    private func binding<Value>(_ keyPath: WritableKeyPath<ConnectionSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { settings[keyPath: keyPath] = $0 }
        )
    }

    private func webhookBinding(at index: Int) -> Binding<String> {
        Binding(
            get: {
                guard settings.milkyWebhookURLs.indices.contains(index) else { return "" }
                return settings.milkyWebhookURLs[index]
            },
            set: { value in
                guard settings.milkyWebhookURLs.indices.contains(index) else { return }
                settings.milkyWebhookURLs[index] = value
            }
        )
    }

    private func isValidWebhook(at index: Int) -> Bool {
        guard settings.milkyWebhookURLs.indices.contains(index) else { return false }
        return ConnectionSettings.milkyWebhookEndpoint(
            for: settings.milkyWebhookURLs[index]
        ) != nil
    }

    private var transportBinding: Binding<TransportMode> {
        Binding(
            get: { settings.transport },
            set: { mode in
                settings.transport = mode
                if mode == .webSocketClient {
                    adoptRecommendedClientPath()
                }
            }
        )
    }

    /// Changing the protocol can invalidate the transport: Milky runs its protocol
    /// service while OneBot selects a bidirectional WebSocket direction. Snapping to
    /// the first supported mode keeps a stale selection from reaching `connect()`.
    private var protocolBinding: Binding<ProtocolChoice> {
        Binding(
            get: { protocolChoice },
            set: { choice in
                protocolChoice = choice
                if !choice.supportedTransports.contains(settings.transport) {
                    settings.transport = choice.supportedTransports[0]
                }
                if settings.transport == .webSocketClient {
                    adoptRecommendedClientPath()
                }
            }
        )
    }

    private func adoptRecommendedClientPath() {
        settings.path = protocolChoice.resolvingWebSocketClientPath(settings.path)
    }

    /// `reconnectInterval` is a `TimeInterval`, but sub-second retries are not useful
    /// here, so the stepper works in whole seconds.
    private var reconnectSecondsBinding: Binding<Int> {
        Binding(
            get: { max(1, Int(settings.reconnectInterval.rounded())) },
            set: { settings.reconnectInterval = TimeInterval($0) }
        )
    }

    // MARK: Endpoint summary

    private var connectionModeHelp: String {
        return "Choose whether the framework connects to Matcha or Matcha connects to the framework"
    }

    private var hostHelp: String {
        switch settings.transport {
        case .webSocketClient:
            return "The NoneBot address that Matcha connects to"
        case .webSocketServer:
            return "The address where Matcha accepts framework WebSocket connections"
        case .milkyService:
            return "The address where Matcha exposes the Milky protocol service"
        }
    }

    private var portHelp: String {
        switch settings.transport {
        case .milkyService:
            return "Milky uses this Matcha port for both its API and /event WebSocket"
        case .webSocketServer, .webSocketClient:
            return "The WebSocket port"
        }
    }

    private var authenticationHelp: String {
        let base = "Leave this blank to disable authentication. Any program that can reach the port will be able to send and receive messages as any persona. This is why the default host is the local loopback address, 127.0.0.1. Set a token if you use a LAN address."
        guard settings.transport == .milkyService else { return base }
        return base + " Milky uses the same token for API calls, /event WebSocket connections, and outgoing WebHook deliveries."
    }

    private var reverseConnectionHelp: String {
        switch protocolChoice {
        case .oneBotV11:
            return "For a reverse connection, Matcha connects to this address. NoneBot V11 must use ReverseDriver and listen on the same host, port, and path."
        case .oneBotV12:
            return "For a reverse connection, Matcha connects to this address. NoneBot V12 must use an ASGI driver, such as ~fastapi, and listen on the same host, port, and path."
        case .milky:
            return ""
        }
    }

    private var endpointLabel: String {
        switch settings.transport {
        case .webSocketServer:
            return "Framework Connection URL"
        case .webSocketClient:
            return "Matcha Connection URL"
        case .milkyService:
            return "Milky API URL"
        }
    }

    private var endpointText: String {
        guard let settings = previewSettings else { return "Invalid port" }
        switch settings.transport {
        case .webSocketServer:
            return "ws://\(settings.host):\(settings.port)/"
        case .webSocketClient:
            return settings.webSocketURL(
                defaultPath: protocolChoice.webSocketClientDefaultPath ?? "/"
            )?.absoluteString ?? "Invalid address"
        case .milkyService:
            return "http://\(settings.host):\(settings.port)/api/"
        }
    }

    /// Milky shares one listener and port, but the event endpoint has its own URL.
    private var eventStreamText: String? {
        guard let settings = previewSettings,
              settings.transport == .milkyService
        else { return nil }
        return settings.eventStreamURL?.absoluteString
    }

    private var portValidation: PortValidation {
        PortValidation(text: portText)
    }

    private var previewSettings: ConnectionSettings? {
        guard let port = portValidation.value else { return nil }
        var preview = settings
        preview.port = port
        return preview
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

// MARK: - Roles

/// Assigns the two identities that drive a simulation session.
private struct RoleSettingsTab: View {
    let environment: AppEnvironment
    @Binding var activeUserID: String?
    @Binding var botUserID: String?

    @State private var showingNewUser = false

    var body: some View {
        Group {
            if environment.users.isEmpty {
                ContentUnavailableView {
                    Label("No Personas Yet", systemImage: "person.crop.circle.badge.plus")
                } description: {
                    Text("Create a persona, then assign the sending identity and bot account.")
                } actions: {
                    Button("New Persona…", systemImage: "person.badge.plus") {
                        showingNewUser = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                Form {
                    Section {
                        RoleAssignmentRow(
                            title: "Sending Identity",
                            caption: "The identity you use to send messages on the simulated platform",
                            systemImage: "person.fill",
                            users: environment.users,
                            selection: $activeUserID
                        )
                        RoleAssignmentRow(
                            title: "Bot Account",
                            caption: "The account the framework logs in as",
                            systemImage: "cpu",
                            users: environment.users,
                            selection: $botUserID
                        )
                    } header: {
                        Text("Identity Assignment")
                    } footer: {
                        Text(assignmentHint)
                    }

                    Section("Personas") {
                        Button("New Persona…", systemImage: "person.badge.plus") {
                            showingNewUser = true
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .sheet(isPresented: $showingNewUser) {
            NewUserSheet(environment: environment)
        }
        .onChange(of: environment.activeUserID) { _, newValue in
            if activeUserID == nil { activeUserID = newValue }
        }
        .onChange(of: environment.botUserID) { _, newValue in
            if botUserID == nil { botUserID = newValue }
        }
    }

    private var assignmentHint: String {
        if botUserID == nil {
            return "Select a bot account before connecting the framework. The two identities should usually use different personas."
        }
        return "The sending identity represents your actions; the bot account is the protocol self ID."
    }
}

private struct RoleAssignmentRow: View {
    let title: String
    let caption: String
    let systemImage: String
    let users: [User]
    @Binding var selection: String?

    var body: some View {
        LabeledContent {
            Picker(title, selection: $selection) {
                Text("Not Set")
                    .tag(String?.none)
                    .disabled(true)
                ForEach(users) { user in
                    Text("\(user.displayName) · \(user.id)")
                        .tag(user.id as String?)
                }
            }
            .labelsHidden()
            .frame(minWidth: 220)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - About

/// Which protocol versions this build speaks.
private struct AboutTab: View {
    var body: some View {
        Form {
            Section {
                LabeledContent("Matcha for macOS", value: "QQ platform simulator and bot framework debugger")
                LabeledContent("Supported Protocols", value: "OneBot V11 / V12, Milky 1.3")
            } footer: {
                Text("Matcha acts as the chat platform, allowing a bot framework to connect and drive complete conversation flows. All personas and messages are generated locally.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
