import SwiftUI
import AppKit
import Observation
import CryptoKit
import PDFKit
import UniformTypeIdentifiers

/// The app's single source of truth: the saved library, plus everything derived from it.
@MainActor @Observable
final class BudgetStore {
    static let shared = BudgetStore()

    // Saved
    var library: Library
    var accounts: [Account] { library.accounts }

    // Derived (rebuilt whenever the library changes)
    var transactions: [Transaction] = []
    /// Everything on accounts kept apart from the person's own totals, oldest first.
    var setApart: [Transaction] = []
    var months: [Month] = []
    var reviewItems: [ReviewItem] = []
    private(set) var cardCoverage: [CardCoverage] = []
    private(set) var missingStatements: [MissingStatements] = []
    var domainByName: [String: String] = [:]
    @ObservationIgnored private var spendingByMonth: [Month: [Transaction]] = [:]
    @ObservationIgnored private var dateCache: [String: Date] = [:]
    /// Where each transaction sits in `transactions`, made the first time something asks by id.
    @ObservationIgnored private var indexByID: [UUID: Int]?
    // Worked out when first asked for and kept until the library next changes: pages ask for these
    // every time they redraw.
    @ObservationIgnored var insightCache: [Month: [Insight]] = [:]
    @ObservationIgnored var recurringCache: [RecurringEngine.Recurring]?
    @ObservationIgnored var awardCache: [Month: [Award]] = [:]
    @ObservationIgnored var changeCache: [String: ChangeEngine.Explanation?] = [:]
    @ObservationIgnored var budgetCache: [Month: BudgetEngine.Summary] = [:]
    @ObservationIgnored var reportCache: [ReportPeriod: ReportData] = [:]
    /// Goes up by one every time the library changes and everything derived from it is rebuilt.
    /// Anything worked out from transactions can be kept alongside the revision it was made at.
    @ObservationIgnored private(set) var revision = 0
    @ObservationIgnored var storyCache: (stamp: [Int], stories: [Story])?
    @ObservationIgnored var storyOfEntry: [UUID: Int]?
    /// The charges an order history could explain, kept until the library next changes.
    @ObservationIgnored var orderChargeCache: [OrderMatcher.Charge]?

    /// The transactions with these ids, oldest first.
    func transactions(withIDs ids: some Sequence<UUID>) -> [Transaction] {
        if indexByID == nil {
            indexByID = Dictionary(transactions.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
        return Set(ids).compactMap { indexByID?[$0] }.sorted().map { transactions[$0] }
    }

    // UI state
    /// The sidebar section. Set directly, it is a fresh start; links inside pages use `navigate`.
    var selection: SidebarItem? = .overview {
        didSet { if !isNavigating { route = []; overviewDetail = nil; history = [] } }
    }
    /// Pages opened over the section, the last one in front.
    var route: [Route] = []
    /// Where Back leads, most recent last.
    var history: [Location] = []
    @ObservationIgnored var isNavigating = false
    /// The month and the year the Overview is showing (nil: the latest). Kept here, not in the page,
    /// so stepping into a charge or a payee and back returns to the same stretch.
    var overviewMonth: Month?
    var overviewPeriod: ReportPeriod?
    /// Which of the Overview's cards has been stepped into, if any. Nil is the summary itself.
    var overviewDetail: OverviewDetail?
    enum OverviewDetail: String { case flow, spending, income, investing, recurring, budgets }
    /// What is typed in the box on the Places page, and the stretch of time it looks at (kept while a place is open).
    var placeSearch = ""
    var placeSpan = PlacesView.Span.all
    /// True while the story of how the app came to be is open.
    var showsStory = false
    /// Non-nil while a charge's original statement is open over the window.
    var originalPeek: OriginalPeek?
    /// Which file the Statements page shows, and the charge to point at in it.
    var statementFocus: StatementFocus?
    @ObservationIgnored var linkedByLastAdd = 0
    /// The question pane on the right, available from every page.
    var showsAsk = false
    /// The show that plays over the window during a big import: the work, then the premiere.
    enum Stage { case working, premiere }
    var stage: Stage? { didSet { if stage == nil { premiereMonth = nil } } }
    /// Set while the premiere on screen is the recap of one month, not of a first import.
    var premiereMonth: Month?

    /// The month that just ended, if there is anything in it to look back on.
    var lastFullMonth: Month? {
        let previous = Month(date: .now).adding(-1)
        if months.contains(previous) { return previous }
        // Statements run behind the calendar: otherwise, the newest month that isn't the newest of all.
        return months.dropLast().last
    }

    func playRecap(of month: Month) {
        premiereMonth = month
        withAnimation(.easeInOut(duration: 0.4)) { stage = .premiere }
    }

    /// The first time the app is opened in a new month, the month just ended gets its recap.
    func recapIfNewMonth() {
        let key = "recappedMonth"
        let previous = Month(date: .now).adding(-1)
        guard stage == nil, !isImporting else { return }
        // Someone who has no statements yet has nothing to look back on; start counting from here.
        guard !accounts.isEmpty, spending(in: previous).count >= 5 else {
            if accounts.isEmpty { UserDefaults.standard.set(previous.key, forKey: key) }
            return
        }
        guard UserDefaults.standard.string(forKey: key) != previous.key, ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] == nil else { return }
        UserDefaults.standard.set(previous.key, forKey: key)
        playRecap(of: previous)
    }
    var transactionFilter = TransactionFilter()
    /// What is typed in the box on the Transactions page (kept while a payee opened from it is on screen).
    var transactionSearch = ""
    /// The Overview looks at one month or at a whole year; the same page either way.
    /// The Overview opens on the long view (the last twelve months); a single month is one click away.
    var overviewShowsYear = ProcessInfo.processInfo.environment["SPENDTHRIFT_MONTH"] == nil
    var pendingImports: [PendingImport] = []
    /// Something the person must be told at launch (e.g. data restored from a backup).
    var startupNotice: String?
    /// Non-nil while the "New Category" sheet is up.
    var categoryEditor: CategoryEditorRequest?
    var toast: Toast?
    var isSuggesting = false
    var isImporting = false
    var downloadCandidates: [URL] = []
    /// Checked each time: Apple Intelligence can be switched on (or finish downloading) while the app is open.
    var aiAvailable: Bool { CategorySuggester.isAvailable }
    /// Files from the last import that couldn't be added.
    var importIssues: [ImportIssue] = []
    /// "Reading 5 of 18" while several statements are being read.
    var importProgress: (done: Int, total: Int)?
    let paths = BudgetPaths()
    @ObservationIgnored var saveTask: Task<Void, Never>?
    @ObservationIgnored private var saveFailureShown = false
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored var aiAttempted: Set<String> = []
    @ObservationIgnored var cloudAttempted: Set<String> = []
    @ObservationIgnored var autoAttempted: Set<URL> = []
    @ObservationIgnored var downloadsWatcher: DispatchSourceFileSystemObject?
    @ObservationIgnored var downloadsDebounce: Task<Void, Never>?
    @ObservationIgnored var relearnKeys: Set<String> = []
    @ObservationIgnored var relearnTask: Task<Void, Never>?
    @ObservationIgnored var lastImport: (entries: Set<UUID>, accounts: Set<UUID>, hashes: Set<String>)?

    // State the store's other files work on (stored properties have to live in the class itself).
    /// What order-history exports said was inside each order, and which charge paid for which.
    var orders = OrderBook()
    /// The order items laid out for the Orders page: dated, searchable, each knowing its charge.
    var orderRows: [OrderRow] = []
    var orderSearch = ""
    /// The stretch of order history on screen, whose orders, and (after a click on the ring) which category.
    var orderScope = OrderScope.all
    var orderWho: String?
    /// The kind of thing clicked on the ring ("Baby & Kids"), when the page is narrowed to one.
    var orderKind: String?
    /// One order on show by itself (arrived at from a charge), until the person clears it.
    var orderOnly: String?
    var orderChargeList: [OrderCharge] = []
    /// The first names on the order histories that were added ("Ana", "Sam").
    var orderPeople: [String] = []
    /// True while the model is reading product listings.
    var isReadingOrders = false
    var orderCoverage = OrderCoverage()
    @ObservationIgnored var isFindingLogos = false
    var isFindingStories = false
    var isLookingUp = false
    /// True while payees are being compared for tidying.
    var isTidying = false
    /// A sort asked for while payees were being tidied waits for the tidy-up to end, then runs once.
    @ObservationIgnored var sortAfterTidy = false
    @ObservationIgnored var isLearningFacts = false
    /// Goes up when a kept summary has been checked or rewritten, so the card showing it redraws.
    var readsChecked = 0
    /// True once "since you last looked" has been put away for this sitting.
    var sinceDismissed = false
    @ObservationIgnored var isGuessing = false
    var isFindingDiscoveries = false
    /// Calendar years being read right now.
    var readingYears: Set<Int> = []
    /// Places being worked out from what the person said about them.
    var explaining: Set<String> = []

    private init() {
        Launch.mark("store begins")
        _ = Self.launchedAt   // a static is only set when first read: read it now, so it is the moment of launch
        let (loaded, result) = Library.load(paths: paths)
        library = loaded
        Launch.mark("library read (\(loaded.entries.count) entries)")
        CustomCategories.set(library.customCategories ?? [])
        splitWiresByRecipient()
        Launch.mark("wires split")
        joinSplitBankAccounts()
        Launch.mark("accounts joined")
        rebuild()
        Launch.mark("rebuilt")
        switch result {
        case .restoredFromBackup(let date):
            let when = date.map { " from \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
            startupNotice = "Your saved data couldn't be opened, so I restored the backup\(when). Anything added after that needs to be dropped in again. The damaged file was kept."
        case .unreadable:
            startupNotice = "Your saved data couldn't be opened and there was no backup to restore, so this is a fresh start. The damaged file was kept in the data folder. Dropping your statements in again will rebuild everything."
        case .fresh, .loaded: break
        }
        if Library.recoveredOnLoad > 0, startupNotice == nil {
            let n = Library.recoveredOnLoad
            startupNotice = "\(n) \(n == 1 ? "line belonged" : "lines belonged") to an account that was damaged in the saved file. Nothing was deleted: \(n == 1 ? "it was" : "they were") put in an account called Recovered, where you can move or remove \(n == 1 ? "it" : "them")."
        }
        refreshDownloads()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BudgetStore.shared.saveNow(); BudgetStore.shared.saveOrdersNow(); CloudSpend.shared.saveNow(); BudgetStore.noteSeen() }
        }
        Task { await sortRemaining() }
        Task { await notePeriodsIfNeeded() }
        Task { await loadOrders() }
        Launch.mark("store ready")
    }

    // MARK: - Persistence

    func changed() {
        rebuild()
        scheduleSave()
    }

    /// For a change that alters nothing any page works out from the charges (a kept sentence, a
    /// note of what was asked): written to disk, but nothing is rebuilt.
    func savedOnly() { scheduleSave() }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            // Writing the file takes long enough to feel if it holds up the window, so a copy is
            // written from another thread. One queue, so two saves can never land out of order.
            let snapshot = library, paths = paths
            Self.saving.async {
                let saved = snapshot.save(paths: paths)
                Task { @MainActor in BudgetStore.shared.noteSave(succeeded: saved) }
            }
        }
    }

    /// One toast when saving fails (and again only after a save has worked in between), not one per change.
    func noteSave(succeeded: Bool) {
        if succeeded { saveFailureShown = false; return }
        guard !saveFailureShown else { return }
        saveFailureShown = true
        showToast("Your changes could not be saved to disk. Check that the disk has room. Quitting now would lose them.", symbol: "exclamationmark.triangle.fill")
    }

    nonisolated private static let saving = DispatchQueue(label: "spendthrift.save", qos: .utility)

    /// Writes everything to disk right now (before quitting to install an update).
    func saveForQuit() { saveNow() }

    /// Writes the library before returning, after any save already under way.
    func saveNow() {
        saveTask?.cancel()
        let snapshot = library, paths = paths
        let saved = Self.saving.sync { snapshot.save(paths: paths) }
        noteSave(succeeded: saved)
    }

    /// Writes the order history before returning, after any save already under way. Never writes an
    /// empty book: it may simply not have been read yet, and the file on disk is the only copy.
    func saveOrdersNow() {
        OrderBook.flushSaves()
        guard !orders.items.isEmpty else { return }
        orders.save(to: paths.ordersFile)
        OrderBook.flushSaves()
    }

    // MARK: - Deriving what the screens show

    /// Card issuers we can match between "paid from checking" and "statements added".
    static let issuers: [(name: String, words: [String])] = [
        ("Chase", ["chase"]), ("American Express", ["american express", "amex"]), ("Citi", ["citi"]),
        ("Capital One", ["capital one"]), ("Coinbase", ["coinbase"]), ("Discover", ["discover"]),
        ("Apple Card", ["apple card"]), ("Barclays", ["barclays"]), ("Bank of America", ["bank of america"]),
        ("Wells Fargo", ["wells fargo"]), ("Synchrony", ["synchrony"]), ("U.S. Bank", ["u.s. bank", "us bank"]),
    ]
    /// Whole words only: "Citizens Bank" is not Citi, and a purchase is not a Chase.
    private static let issuerTable = PhraseTable(issuers.flatMap { issuer in issuer.words.map { ($0, issuer.name) } })
    static func issuer(in text: String) -> String? { issuerTable.firstMatch(in: text) }

    private func rebuild() {
        let accountNames = Dictionary(library.accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        func date(_ s: String) -> Date? {
            if let cached = dateCache[s] { return cached }
            guard let parsed = DateParsing.parse(s, format: "yyyy-MM-dd") else { return nil }
            dateCache[s] = parsed
            return parsed
        }
        let day = { (d: Date) in Int(d.timeIntervalSinceReferenceDate / 86_400) }

        // Which days each card issuer's statements cover. A payment to a card counts as a plain
        // transfer only if that card's purchases are here too; otherwise the payment is the only
        // record of the spending, and has to count.
        var cardAccount: [UUID: String] = [:]
        for a in library.accounts {
            let lower = a.name.lowercased()
            if !lower.contains("checking"), !lower.contains("savings"), let issuer = Self.issuer(in: a.name) { cardAccount[a.id] = issuer }
        }
        var cardDays: [String: Set<Int>] = [:]
        var cardSpend: [String: Double] = [:]
        for e in library.entries {
            guard let issuer = cardAccount[e.accountID], let d = date(e.date) else { continue }
            cardDays[issuer, default: []].insert(day(d))
            if e.amount > 0 { cardSpend[issuer, default: 0] += e.amount }
        }
        let tie = reconcileCards(cardAccount: cardAccount, cardDays: cardDays)
        var coverage = tie.cards

        var list: [Transaction] = []
        list.reserveCapacity(library.entries.count)
        // Accounts kept apart (someone else's money looked after here) are built the same way but
        // never join the main list, so no total anywhere in the app can pick them up by accident.
        let apartAccounts = Set(library.accounts.filter { $0.apart != nil }.map(\.id))
        var apartList: [Transaction] = []
        // Oldest first. Sorting where each line goes is far cheaper than sorting the finished lines.
        let when = library.entries.map { date($0.date) }
        let order = library.entries.indices.filter { when[$0] != nil }.sorted { (when[$0]!, $0) < (when[$1]!, $1) }
        for index in order {
            let e = library.entries[index]
            guard let date = when[index] else { continue }
            let info = library.merchants[e.merchantKey]
            let unchecked = info?.isUnconfirmedGuess ?? true
            var category = e.override ?? info?.category ?? .unsorted
            // A payment to a card is a plain transfer only when it ties to that card's statements;
            // otherwise the payment is the only record of the spending, and has to count.
            if tie.covered[e.id] == false { category = .uncoveredCards }
            list.append(Transaction(
                id: e.id, date: date, month: Month(isoDay: e.date) ?? Month(date: date), description: e.description, amount: e.amount,
                merchant: info?.name ?? KeywordExtractor.displayName(for: e.description), merchantKey: e.merchantKey,
                category: category,
                account: accountNames[e.accountID] ?? "", accountID: e.accountID,
                source: e.override != nil ? .user : (info?.source ?? .ai),
                needsCheck: e.override == nil && unchecked, isOverride: e.override != nil))
            if let note = e.note, !note.isEmpty { list[list.count - 1].note = note }
            if apartAccounts.contains(e.accountID) { apartList.append(list.removeLast()) }
        }
        setApart = apartList
        for issuer in coverage.keys {
            coverage[issuer]?.statementSpend = cardSpend[issuer] ?? 0
            coverage[issuer]?.accounts = library.accounts.filter { cardAccount[$0.id] == issuer }.map(\.name)
        }
        cardCoverage = coverage.values.sorted { $0.paid > $1.paid }
        var domains: [String: String] = [:]
        for info in library.merchants.values { if let d = info.domain, !d.isEmpty { domains[info.name] = d } }
        domainByName = domains
        transactions = list
        indexByID = nil
        storyCache = nil; storyOfEntry = nil
        revision += 1
        orderChargeCache = nil
        insightCache = [:]; recurringCache = nil; awardCache = [:]; reportCache = [:]
        changeCache = [:]; budgetCache = [:]
        months = Array(Set(list.map(\.month))).sorted()
        spendingByMonth = Dictionary(grouping: list.filter(\.countsAsSpending), by: \.month)

        // Which months is each account missing? A hole in the middle of an account that's normally
        // busy, or an account that has fallen more than a month behind the others.
        var missing: [MissingStatements] = []
        let byAccount = Dictionary(grouping: list, by: \.accountID)
        for account in library.accounts {
            guard let txns = byAccount[account.id] else { continue }
            var counts = Dictionary(grouping: txns, by: \.month).mapValues(\.count)
            // A month a statement covers is not missing, even if nothing was bought in it.
            for key in account.statementMonths ?? [] { if let m = Month(key: key), counts[m] == nil { counts[m] = 0 } }
            let covered = counts.keys.sorted()
            guard covered.count >= 2, let first = covered.first, let last = covered.last else { continue }
            var gaps: [Month] = []
            let busy = counts.values.filter { $0 > 0 }.sorted()
            let typical = busy.isEmpty ? 0 : busy[busy.count / 2]
            // A busy account, or a quiet one that shows up nearly every month (a card with one
            // subscription on it): either way a hole in the middle is a statement that was skipped.
            let span = Calendar.current.dateComponents([.month], from: first.firstDay, to: last.firstDay).month.map { $0 + 1 } ?? covered.count
            if typical >= 3 || (covered.count >= 6 && Double(covered.count) / Double(max(span, 1)) >= 0.8) {
                var m = first.adding(1)
                while m < last { if counts[m] == nil { gaps.append(m) }; m = m.adding(1) }
            }
            if let newest = months.last {
                var m = last.adding(1)
                while m < newest, gaps.count < 12 { gaps.append(m); m = m.adding(1) }
            }
            if !gaps.isEmpty { missing.append(MissingStatements(accountID: account.id, account: account.name, months: gaps)) }
        }
        missingStatements = missing

        var items: [ReviewItem] = []
        for (key, txns) in Dictionary(grouping: list.filter(\.needsCheck), by: \.merchantKey) {
            guard let info = library.merchants[key] else { continue }
            items.append(ReviewItem(key: key, info: info, count: txns.count, total: txns.reduce(0) { $0 + $1.amount }))
        }
        reviewItems = items.sorted { abs($0.total) > abs($1.total) }
    }

    // MARK: - Toasts

    func showToast(_ message: String, symbol: String, offersUndo: Bool = false) {
        toastTask?.cancel()
        withAnimation(.spring(duration: 0.35)) { toast = Toast(message: message, symbol: symbol, offersUndo: offersUndo) }
        toastTask = Task {
            try? await Task.sleep(for: .seconds(offersUndo ? 8 : 4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { toast = nil }
        }
    }

    // MARK: - Analytics

    func spending(in month: Month) -> [Transaction] { spendingByMonth[month] ?? [] }

    func totalSpent(in month: Month) -> Double {
        spending(in: month).reduce(0) { $0 + $1.amount }
    }

    func categoryTotals(in month: Month) -> [(category: Category, total: Double)] {
        Dictionary(grouping: spending(in: month), by: \.category)
            .map { ($0.key, $0.value.reduce(0) { $0 + $1.amount }) }
            .filter { $0.1 > 0.005 }
            .sorted { $0.1 > $1.1 }
    }

    func topMerchants(in month: Month, limit: Int = 5) -> [(key: String, name: String, category: Category, total: Double, count: Int)] {
        typealias Row = (key: String, name: String, category: Category, total: Double, count: Int)
        var rows: [Row] = []
        for (key, txns) in Dictionary(grouping: spending(in: month), by: \.merchantKey) {
            let total = txns.reduce(0.0) { $0 + $1.amount }
            if total > 0 { rows.append((key, txns[0].merchant, txns[0].category, total, txns.count)) }
        }
        rows.sort { $0.total > $1.total }
        return Array(rows.prefix(limit))
    }

}
