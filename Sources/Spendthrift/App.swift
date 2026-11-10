import SwiftUI
import AppKit


struct SpendthriftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Spendthrift", id: "main") {
            ContentView()
                .environment(BudgetStore.shared)
                .frame(minWidth: 920, minHeight: 620)
        }
        // Wide enough for the pages and the question pane side by side.
        .defaultSize(width: 1480, height: 900)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Statement…") { BudgetStore.shared.presentOpenPanel() }
                    .keyboardShortcut("o")
            }
            // About tells the story of the app rather than showing the standard small panel.
            CommandGroup(replacing: .appInfo) {
                Button("About Spendthrift") { BudgetStore.shared.showsStory = true }
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Updater.shared.checkFromMenu() }
            }
            CommandGroup(replacing: .help) {
                Button("Show My Data in Finder") { NSWorkspace.shared.activateFileViewerSelecting([BudgetStore.shared.paths.libraryFile]) }
                Button("Save a Backup to the Desktop") { BudgetStore.shared.backUpToDesktop() }
            }
            CommandMenu("Go") {
                Button("Overview") { BudgetStore.shared.selection = .overview }.keyboardShortcut("1")
                Button("Cash Flow") { BudgetStore.shared.selection = .cashflow }.keyboardShortcut("2")
                Button("Trips & Events") { BudgetStore.shared.selection = .stories }.keyboardShortcut("3")
                Button("Transactions") { BudgetStore.shared.selection = .transactions }.keyboardShortcut("4")
                Button("Find a Payee…") { BudgetStore.shared.selection = .places }.keyboardShortcut("f")
                Divider()
                Button("Ask a Question") { BudgetStore.shared.showsAsk.toggle() }.keyboardShortcut("k")
                Button("Last Month's Recap") { if let month = BudgetStore.shared.lastFullMonth { BudgetStore.shared.playRecap(of: month) } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Divider()
                Button("Double-Check") { BudgetStore.shared.selection = .review }.keyboardShortcut("5")
                Button("Accounts") { BudgetStore.shared.selection = .accounts }.keyboardShortcut("6")
                Button("Categories") { BudgetStore.shared.selection = .categories }.keyboardShortcut("7")
            }
        }

        // Spendthrift → Settings… (⌘,)
        Settings {
            SettingsView()
                .environment(BudgetStore.shared)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Files dropped on the Dock icon (or opened with Tally).
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            BudgetStore.shared.importFiles(urls)
            NSApp.activate()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
