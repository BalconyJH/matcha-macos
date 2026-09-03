import SwiftUI

/// Window-local actions exposed to the menu bar through focused values.
///
/// The main scene owns presentation and connection state. Commands only route to
/// whichever Matcha window is focused, so a menu item never needs a global window
/// or notification-based back channel.
struct MatchaCommandActions {
    var createUser: @MainActor () -> Void
    var createGroup: @MainActor () -> Void
    var toggleConnection: @MainActor () -> Void
    var toggleInspector: @MainActor () -> Void
    var canCreateGroup: Bool
    var isConnected: Bool
    var isInspectorPresented: Bool
}

private struct MatchaCommandActionsKey: FocusedValueKey {
    typealias Value = MatchaCommandActions
}

extension FocusedValues {
    var matchaCommandActions: MatchaCommandActions? {
        get { self[MatchaCommandActionsKey.self] }
        set { self[MatchaCommandActionsKey.self] = newValue }
    }
}

/// Desktop command surface for the main Matcha window.
public struct MatchaCommands: Commands {
    @FocusedValue(\.matchaCommandActions) private var actions

    public init() {}

    public var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Persona…") {
                actions?.createUser()
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(actions == nil)

            Button("New Group…") {
                actions?.createGroup()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(actions?.canCreateGroup != true)
        }

        CommandMenu("Simulation") {
            Button(actions?.isConnected == true ? "Disconnect" : "Connect") {
                actions?.toggleConnection()
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(actions == nil)

            Divider()

            Button(actions?.isInspectorPresented == true ? "Hide Raw Events" : "Show Raw Events") {
                actions?.toggleInspector()
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(actions == nil)
        }

        CommandGroup(after: .help) {
            Link(
                "Matcha Project Homepage",
                destination: URL(string: "https://github.com/BalconyJH/matcha-macos")!
            )
        }
    }
}
