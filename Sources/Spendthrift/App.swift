import SwiftUI
import AppKit


struct SpendthriftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Spendthrift", id: "main") {
            ContentView()
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
            GoMenu()
        }

        // Spendthrift → Settings… (⌘,)
        Settings {
            // (Not before the store exists: naming it here would make it at once, on the main thread.)
            if Boot.shared.ready { SettingsView().environment(BudgetStore.shared) }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Files dropped on the Dock icon (or opened with Spendthrift).
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            BudgetStore.shared.importFiles(urls)
            NSApp.activate()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// The Go menu: every section the sidebar can show, by the same names. Amazon, Kept Apart and Double-Check
/// appear when the sidebar has them.
struct GoMenu: Commands {
    private var store: BudgetStore { .shared }

    var body: some Commands {
        CommandMenu("Go") {
            Button("Overview") { store.selection = .overview }.keyboardShortcut("1")
            Button("Money In and Out") { store.stepInto(.flow) }.keyboardShortcut("2")
            Button("Trips & Events") { store.selection = .stories }.keyboardShortcut("3")
            Button("Transactions") { store.selection = .transactions }.keyboardShortcut("4")
            Button("Find a Payee…") { store.selection = .places }.keyboardShortcut("f")
            if Boot.shared.ready, !store.orderRows.isEmpty {
                Button("Amazon") { store.selection = .orders }.keyboardShortcut("8")
            }
            if Boot.shared.ready, store.accounts.contains(where: { $0.apart != nil }) {
                Button("Kept Apart") { store.selection = .apart }
            }
            Button("Statements") { store.selection = .statements }.keyboardShortcut("9")
            Divider()
            Button("Ask a Question") { store.showsAsk.toggle() }.keyboardShortcut("k")
            Button("Last Month's Recap") { if let month = store.lastFullMonth { store.playRecap(of: month) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Divider()
            Button("Double-Check") { store.selection = .review }.keyboardShortcut("5")
            Button("Setup") { store.selection = .accounts }.keyboardShortcut("6")
            Button("Setup: Categories") { store.selection = .categories }.keyboardShortcut("7")
        }
    }
}
