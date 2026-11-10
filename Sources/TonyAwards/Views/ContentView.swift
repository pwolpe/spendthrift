import SwiftUI

struct ContentView: View {
    @Environment(BudgetStore.self) private var store
    @State private var isDropTargeted = false

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
        } detail: {
            Group {
                if store.accounts.isEmpty {
                    WelcomeView(isDropTargeted: isDropTargeted)
                } else {
                    switch store.selection ?? .overview {
                    case .overview: OverviewView()
                    case .cashflow: CashFlowView()
                    case .stories: StoriesView()
                    case .transactions: TransactionsView()
                    case .report: OverviewView()
                    case .ask: AskView()
                    case .review: ReviewView()
                    case .categories: CategoriesView()
                    case .accounts: AccountsView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(Theme.accent)
        .overlay {
            if isDropTargeted && !store.accounts.isEmpty {
                DropOverlay().transition(.opacity).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                ToastView(toast: toast)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            store.importFiles(urls)
            return true
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.15)) { isDropTargeted = targeted }
        }
        .sheet(item: Binding(get: { store.pendingImports.first }, set: { _ in })) { pending in
            ImportSheet(pending: pending)
                .id(pending.id)
                .tint(Theme.accent)
        }
        .sheet(item: Binding(get: { store.categoryEditor }, set: { store.categoryEditor = $0 })) { request in
            CategoryEditorSheet(request: request)
                .tint(Theme.accent)
        }
        .alert("A heads-up about your data", isPresented: Binding(get: { store.startupNotice != nil }, set: { if !$0 { store.startupNotice = nil } })) {
            Button("OK") { store.startupNotice = nil }
        } message: {
            Text(store.startupNotice ?? "")
        }
        .sheet(isPresented: Binding(get: { !store.importIssues.isEmpty }, set: { if !$0 { store.importIssues = [] } })) {
            ImportIssuesSheet(issues: store.importIssues)
                .tint(Theme.accent)
        }
        .sheet(isPresented: Binding(get: { Updater.shared.isPresented }, set: { Updater.shared.isPresented = $0 })) {
            UpdateSheet().tint(Theme.accent)
        }
        .task {
            Updater.shared.start()
            store.watchDownloads()
            DebugHooks.startIfRequested()
            await DailyTony.shared.ensureCartoon()
            TonyArt.shared.prepare()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshDownloads()
            store.retrySorting()
            DailyTony.shared.retryIfNeeded()
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(BudgetStore.self) private var store

    private var status: String? {
        if let progress = store.importProgress { return "Reading statements… \(progress.done) of \(progress.total)" }
        if store.isImporting { return "Reading your statement…" }
        if store.isSuggesting { return "Sorting new places…" }
        return nil
    }

    var body: some View {
        @Bindable var store = store
        List(selection: $store.selection) {
            Section {
                Label("Overview", systemImage: "sparkles.rectangle.stack.fill")
                    .tag(SidebarItem.overview)
                Label("Cash Flow", systemImage: "arrow.left.arrow.right.circle.fill")
                    .tag(SidebarItem.cashflow)
                Label("Trips & Events", systemImage: "airplane.departure")
                    .badge(Text(store.stories.isEmpty ? "" : "\(store.stories.count)").foregroundStyle(.tertiary))
                    .tag(SidebarItem.stories)
                Label("Transactions", systemImage: "list.bullet.rectangle.portrait.fill")
                    .tag(SidebarItem.transactions)
                Label("Ask the Academy", systemImage: "bubble.left.and.text.bubble.right.fill")
                    .tag(SidebarItem.ask)
            }
            Section("Housekeeping") {
                Label("Double-Check", systemImage: "checkmark.seal.fill")
                    .badge(store.reviewItems.count)
                    .tag(SidebarItem.review)
                Label("Categories", systemImage: "square.grid.2x2.fill")
                    .tag(SidebarItem.categories)
                Label("Accounts", systemImage: "creditcard.fill")
                    .badge(Text("\(store.accounts.count)").foregroundStyle(.tertiary))
                    .tag(SidebarItem.accounts)
            }
        }
        .disabled(store.accounts.isEmpty)
        .safeAreaInset(edge: .top) {
            HStack(spacing: 10) {
                TonyAvatar(size: 38)
                VStack(alignment: .leading, spacing: 0) {
                    Text("The Tony Awards").font(.system(.headline, design: .serif))
                    Text("Excellence in spending").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                if let status {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(status).font(.callout).foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                }
                if let release = Updater.shared.available {
                    Button { Updater.shared.isPresented = true } label: {
                        Label("Version \(release.version) is ready", systemImage: "arrow.down.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                Button {
                    store.presentOpenPanel()
                } label: {
                    Label("Add Statement", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.glass)
                .help("Or just drag a statement anywhere onto this window")
            }
            .padding(14)
            .animation(.default, value: status)
        }
    }
}

// MARK: - Drop overlay & toast

struct DropOverlay: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            VStack(spacing: 12) {
                TonyFigure(height: 240)
                Text("Drop it right here")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                Text("I'll read it, sort it and add it up.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .ignoresSafeArea()
    }
}

struct ToastView: View {
    private var store: BudgetStore { .shared }   // not from the environment: menus and sheets don't always pass it down
    let toast: Toast

    var body: some View {
        HStack(spacing: 12) {
            Label {
                Text(toast.message).font(.body.weight(.medium))
            } icon: {
                Image(systemName: toast.symbol).foregroundStyle(.tint)
            }
            if toast.offersUndo {
                Button("Undo") { store.undoLastImport() }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
        }
        .padding(.leading, 20)
        .padding(.trailing, toast.offersUndo ? 10 : 20)
        .padding(.vertical, toast.offersUndo ? 8 : 12)
        .glassEffect(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.12), radius: 16, y: 6)
        .frame(maxWidth: 620)
    }
}

/// One clear list of what couldn't be added and what to do about it.
struct ImportIssuesSheet: View {
    private var store: BudgetStore { .shared }   // not from the environment: menus and sheets don't always pass it down
    let issues: [ImportIssue]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                TonyAvatar(size: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(issues.count == 1 ? "I couldn't add one file" : "I couldn't add \(issues.count) files")
                        .font(.title2.weight(.bold))
                    Text("Everything else went in fine. Nothing here was changed.")
                        .foregroundStyle(.secondary)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(issues) { issue in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "doc.badge.ellipsis").font(.title3).foregroundStyle(Theme.caution).frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(issue.file).font(.body.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                                Text(issue.reason).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)
            HStack {
                Spacer()
                Button("OK") { store.importIssues = [] }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .padding(26)
        .frame(width: 520)
    }
}
