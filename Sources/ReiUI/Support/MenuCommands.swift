import SwiftUI

/// Window-local actions exposed to the menu bar through focused values.
///
/// The main scene owns presentation and connection state. Commands only route to
/// whichever Rei window is focused, so a menu item never needs a global window
/// or notification-based back channel.
struct ReiCommandActions {
    var createUser: @MainActor () -> Void
    var createGroup: @MainActor () -> Void
    var toggleConnection: @MainActor () -> Void
    var toggleInspector: @MainActor () -> Void
    var canCreateGroup: Bool
    var isConnected: Bool
    var isInspectorPresented: Bool
}

private struct ReiCommandActionsKey: FocusedValueKey {
    typealias Value = ReiCommandActions
}

extension FocusedValues {
    var reiCommandActions: ReiCommandActions? {
        get { self[ReiCommandActionsKey.self] }
        set { self[ReiCommandActionsKey.self] = newValue }
    }
}

/// Desktop command surface for the main Rei window.
public struct ReiCommands: Commands {
    @FocusedValue(\.reiCommandActions) private var actions

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
                "Rei Project Homepage",
                destination: URL(string: "https://github.com/Kiyorae/rei")!
            )
        }
    }
}
