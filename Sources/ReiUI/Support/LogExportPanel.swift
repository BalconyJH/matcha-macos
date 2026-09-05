import AppKit

/// The narrow AppKit boundary used by the SwiftUI log console for directory choice.
@MainActor
enum LogExportPanel {
    static func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose Log Export Folder"
        panel.message = "A new folder containing the complete log and a summary will be created here."
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        return panel.runModal() == .OK ? panel.url : nil
    }
}
