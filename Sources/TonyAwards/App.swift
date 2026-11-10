import SwiftUI
import AppKit


struct TonyAwardsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("The Tony Awards", id: "main") {
            ContentView()
                .environment(BudgetStore.shared)
                .frame(minWidth: 920, minHeight: 620)
        }
        .defaultSize(width: 1140, height: 780)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Statement…") { BudgetStore.shared.presentOpenPanel() }
                    .keyboardShortcut("o")
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
                Button("Transactions") { BudgetStore.shared.selection = .transactions }.keyboardShortcut("3")
                Button("Year in Review") { BudgetStore.shared.selection = .report }.keyboardShortcut("4")
                Button("Ask the Academy") { BudgetStore.shared.selection = .ask }.keyboardShortcut("5")
                Divider()
                Button("Double-Check") { BudgetStore.shared.selection = .review }.keyboardShortcut("6")
                Button("Categories") { BudgetStore.shared.selection = .categories }.keyboardShortcut("7")
                Button("Accounts") { BudgetStore.shared.selection = .accounts }.keyboardShortcut("8")
            }
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
