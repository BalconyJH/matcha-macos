import SwiftUI

/// Scene identity shared by the log-console window and its menu command.
public enum LogConsoleWindow {
    public static let id = "log-console"
}

/// Global command for opening the app-wide log console.
///
/// This deliberately uses `openWindow` instead of the main window's focused-value
/// command channel: diagnostics remain available no matter which Matcha window is
/// currently focused.
public struct LogConsoleCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    public init() {}

    public var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Log Console") {
                openWindow(id: LogConsoleWindow.id)
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
        }
    }
}
