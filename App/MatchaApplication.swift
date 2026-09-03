import AppKit
import MatchaLogging
import MatchaUI
import SwiftUI

@main
@MainActor
struct MatchaApplication: App {
    @State private var selectedSettingsTab: MatchaSettingsTab = .connection

    private let appLog: AppLog
    private let launchState: LaunchState

    init() {
        let appLog = AppLog.standard
        appLog.record(.applicationStarted)
        self.appLog = appLog
        launchState = LaunchState.load(appLog: appLog)
    }

    var body: some Scene {
        Window("Matcha", id: "main") {
            switch launchState {
            case .ready(let environment):
                RootView(
                    environment: environment,
                    selectedSettingsTab: $selectedSettingsTab
                )
            case .failed(let failure):
                StartupFailureView(failure: failure)
            }
        }
        .defaultSize(width: 1_320, height: 820)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultLaunchBehavior(.presented)
        .commands {
            MatchaCommands()
            LogConsoleCommands()
        }

        Window("Log Console", id: LogConsoleWindow.id) {
            LogConsoleView(log: appLog)
        }
        .defaultSize(width: 980, height: 640)
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)

        Settings {
            switch launchState {
            case .ready(let environment):
                SettingsView(
                    environment: environment,
                    selectedTab: $selectedSettingsTab
                )
            case .failed:
                ContentUnavailableView(
                    "Settings Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(
                        "The app environment could not be initialized, so settings cannot be read or saved.")
                )
                .frame(width: 460, height: 240)
            }
        }
    }
}

@MainActor
private enum LaunchState {
    case ready(AppEnvironment)
    case failed(StartupFailure)

    static func load(appLog: AppLog) -> LaunchState {
        do {
            let environment = try AppEnvironment.standard(appLog: appLog)
            appLog.record(.environmentLoaded)
            return .ready(environment)
        } catch {
            appLog.record(.environmentLoadFailed(AppLogFailure(error)))
            return .failed(StartupFailure(error: error))
        }
    }
}

private struct StartupFailure {
    let summary: String
    let diagnostic: String

    init(error: any Error) {
        summary =
            "Matcha could not open its local data or asset directory. Make sure the Application Support directory is writable, then relaunch the app."
        diagnostic = error.localizedDescription
    }
}

private struct StartupFailureView: View {
    let failure: StartupFailure

    var body: some View {
        ContentUnavailableView {
            Label("Matcha Couldn’t Start", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            VStack(spacing: 8) {
                Text(failure.summary)
                Text(failure.diagnostic)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
            .frame(maxWidth: 520)
        } actions: {
            Button("Copy Diagnostic Information") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(failure.diagnostic, forType: .string)
            }
            Button("Quit", role: .cancel) {
                NSApp.terminate(nil)
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .containerBackground(.thickMaterial, for: .window)
    }
}
