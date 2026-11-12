import SwiftUI

/// The window: a sidebar and the page beside it. The frame of it (the split, the title bar) is there
/// from the first instant, so the Mac lays the window out once and correctly; what fills it arrives
/// when the saved file has been read (`Boot`). Nothing here may touch the store before then.
struct ContentView: View {
    @State private var isDropTargeted = false
    @State private var decidedAboutAsk = false
    @State private var width: CGFloat = 0
    private var boot: Boot { .shared }
    /// Only ever read once `boot.ready` is true: naming it makes it.
    private var store: BudgetStore { .shared }

    var body: some View {
        NavigationSplitView {
            Group {
                if boot.ready { SidebarView().environment(store) } else { Color.clear }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 300)
        } detail: {
            if boot.ready {
                loaded.environment(store)
            } else {
                // The empty sheet the pages arrive on, a few hundredths of a second later.
                Theme.paper.ignoresSafeArea().onAppear { Launch.mark("empty window appears"); boot.begin() }
            }
        }
        // The question pane is open from the start when there is room for it beside the pages.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0; decideAboutAsk() }
        .onChange(of: boot.ready) { decideAboutAsk() }
        .tint(Theme.accent)
        .overlay {
            if boot.ready, isDropTargeted, !store.accounts.isEmpty {
                DropOverlay().transition(.opacity).allowsHitTesting(false)
            }
        }
        .overlay {
            if boot.ready, store.stage != nil { ShowView().environment(store).transition(.opacity) }
        }
        .overlay(alignment: .bottom) {
            if boot.ready, let toast = store.toast {
                ToastView(toast: toast)
                    .environment(store)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard boot.ready else { return false }
            store.importFiles(urls)
            return true
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.15)) { isDropTargeted = targeted }
        }
    }

    private func decideAboutAsk() {
        guard boot.ready, !decidedAboutAsk, width > 0 else { return }
        decidedAboutAsk = true
        if width >= 1320 { store.showsAsk = true }
    }

    /// The pages, and everything that hangs off them, once there is a store to draw from.
    private var loaded: some View {
            HStack(spacing: 0) {
                Group {
                    if store.accounts.isEmpty {
                        WelcomeView(isDropTargeted: isDropTargeted)
                    } else {
                        VStack(spacing: 0) {
                            BackBar()
                            if let page = store.route.last {
                                switch page {
                                case .place(let name): PlaceView(name: name)
                                case .charges(let filter): ChargesView(filter: filter)
                                case .card(let id): CardPage(id: id)
                                }
                            } else {
                                switch store.selection ?? .overview {
                                case .overview: OverviewView()
                                case .stories: StoriesView()
                                case .places: PlacesView()
                                case .cards: CardsView()
                                case .orders: OrdersView()
                                case .apart: SetApartView()
                                case .transactions: TransactionsView()
                                case .statements: StatementsView()
                                case .review: ReviewView()
                                case .categories, .accounts: SetupView()
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The question pane stays in place when hidden, so a conversation is still there on return.
                if !store.accounts.isEmpty {
                    HStack(spacing: 0) {
                        Divider()
                        // Built once the first page is up (or at once if it is open): it is out of sight until asked for.
                        if store.showsAsk || Boot.shared.drawn {
                            AskView()
                                .frame(width: 380)
                                .background(Theme.paper)
                        }
                    }
                    .frame(width: store.showsAsk ? 381 : 0, alignment: .leading)
                    .clipped()
                    .opacity(store.showsAsk ? 1 : 0)
                    .allowsHitTesting(store.showsAsk)
                }
            }
            .background(Theme.paper)
            .toolbar {
                if !store.accounts.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            withAnimation(.snappy(duration: 0.25)) { store.showsAsk.toggle() }
                        } label: {
                            Label("Ask", systemImage: store.showsAsk ? "bubble.left.and.text.bubble.right.fill" : "bubble.left.and.text.bubble.right")
                        }
                        .help("Ask a question about your spending (⌘K)")
                    }
                }
            }
        // Timed from inside the pass that draws the first page; the pieces held back follow it.
        .overlay(alignment: .topLeading) { FirstPaintProbe().frame(width: 1, height: 1).allowsHitTesting(false).accessibilityHidden(true) }
        .onAppear {
            Launch.mark("window appears")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Launch.mark("one second later (idle)") }
            if Launch.enabled { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { Launch.mark("quitting"); NSApp.terminate(nil) } }
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
        .sheet(item: Binding(get: { store.originalPeek }, set: { store.originalPeek = $0 })) { peek in
            OriginalPeekSheet(peek: peek)
                .tint(Theme.accent)
        }
        .sheet(isPresented: Binding(get: { store.showsStory }, set: { store.showsStory = $0 })) {
            StoryView().tint(Theme.accent)
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
            await DailyPicture.shared.ensureCartoon()
            TonyArt.shared.prepare()
            store.recapIfNewMonth()
            await store.catchUp()
        }
        // Which card each card is, read from its own statements (nothing is sent anywhere).
        .task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            await store.learnCardProducts()
        }
        // Long after the opening: a fresh picture for the Ask pane, seen the next time the app opens.
        .task {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            await AskArt.shared.prepareNext()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            store.refreshDownloads()
            store.retrySorting()
            DailyPicture.shared.retryIfNeeded()
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @Environment(BudgetStore.self) private var store

    private var status: String? {
        if let progress = store.importProgress { return "Reading statements… \(progress.done) of \(progress.total)" }
        if store.isImporting { return "Reading your statement…" }
        if store.isSuggesting { return "Sorting new payees…" }
        return nil
    }

    var body: some View {
        // The rows draw their own selection, in the app's ink blue rather than the Mac's accent color.
        let current: SidebarItem = {
            switch store.selection ?? .overview {
            case .categories: return .accounts
            case let other: return other
            }
        }()
        List {
            Section {
                SidebarRow(item: .overview, title: "Overview", symbol: "chart.pie.fill", current: current)
                SidebarRow(item: .stories, title: "Trips & Events", symbol: "airplane.departure", current: current, count: store.stories.count, quiet: true)
                SidebarRow(item: .places, title: "Payees", symbol: "storefront.fill", current: current)
                // Only there once a credit card's statements are.
                if store.hasCards || store.selection == .cards {
                    SidebarRow(item: .cards, title: "Cards", symbol: "creditcard.fill", current: current)
                }
                // Only there once an order history has been added: a closer look, never a requirement.
                if !store.orderRows.isEmpty || store.selection == .orders {
                    SidebarRow(item: .orders, title: "Amazon", symbol: "shippingbox.fill", current: current)
                }
                // Someone else's money looked after here: followed on its own page, counted nowhere else.
                if store.accounts.contains(where: { $0.apart != nil }) || store.selection == .apart {
                    SidebarRow(item: .apart, title: "Kept Apart", symbol: "tray.full.fill", current: current)
                }
                SidebarRow(item: .transactions, title: "Transactions", symbol: "list.bullet.rectangle.portrait.fill", current: current)
                SidebarRow(item: .statements, title: "Statements", symbol: "doc.text.magnifyingglass", current: current, count: store.sourceFiles.count, quiet: true)
            }
            Section("Fine-Tune") {
                // Only there when there is something to look at.
                if !store.reviewItems.isEmpty || store.selection == .review {
                    SidebarRow(item: .review, title: "Double-Check", symbol: "checkmark.seal.fill", current: current, count: store.reviewItems.count)
                }
                // The count is statements that seem to be missing: the thing most worth noticing.
                SidebarRow(item: .accounts, title: "Setup", symbol: "slider.horizontal.3", current: current,
                           count: store.missingStatements.reduce(0) { $0 + $1.months.count }
                               + store.cardCoverage.filter { $0.accounts.isEmpty && $0.uncoveredPayments > 0 }.count
                               + store.cardCoverage.reduce(0) { $0 + $1.toFind.count })
            }
        }
        .listStyle(.sidebar)
        .disabled(store.accounts.isEmpty)
        .safeAreaInset(edge: .top) {
            // The name is also the way to the story behind it.
            Button { store.showsStory = true } label: { Masthead().contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help("How Spendthrift came to be")
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 10)
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

/// One page in the sidebar. It draws its own selection so the highlight is the app's ink blue.
struct SidebarRow: View {
    private var store: BudgetStore { .shared }
    let item: SidebarItem
    let title: String
    let symbol: String
    let current: SidebarItem
    var count = 0
    /// A count that is only information (how many trips), not something asking for attention.
    var quiet = false
    @State private var hovering = false

    var body: some View {
        let selected = item == current
        Button { store.selection = item } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? Color.white : Theme.accent)
                    .frame(width: 22)
                Text(title).foregroundStyle(selected ? Color.white : Color.primary)
                Spacer(minLength: 4)
                if count > 0 {
                    Text("\(count)")
                        .font(.caption.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(selected ? Color.white.opacity(0.85) : (quiet ? Color.secondary.opacity(0.7) : Color.secondary))
                        .padding(.horizontal, quiet ? 0 : 7).padding(.vertical, quiet ? 0 : 2)
                        .background(quiet || selected ? Color.clear : Color.primary.opacity(0.08), in: .capsule)
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.inkFill : (hovering ? Color.primary.opacity(0.06) : Color.clear), in: .rect(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}

/// The app's name at the top of the sidebar, set like the head of a receipt: the mark, the name,
/// a dashed rule, and what it's for.
struct Masthead: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                ReceiptMark(size: 30)
                Text("Spendthrift")
                    .font(.system(size: 21, weight: .bold, design: .serif))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            ReceiptRule()
            Text("WHERE IT ALL WENT")
                .font(Theme.mono(9.5, .semibold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

// MARK: - Drop overlay & toast

struct DropOverlay: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            VStack(spacing: 12) {
                SpotArt(name: "v-drop", height: 240)
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
                Vignette(name: "v-issue", size: 72)
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
