import SwiftUI
import AppKit
import Observation
import CryptoKit
import UniformTypeIdentifiers

/// The app's single source of truth: the saved library, plus everything derived from it.
@MainActor @Observable
final class BudgetStore {
    static let shared = BudgetStore()

    // Saved
    private var library: Library
    var accounts: [Account] { library.accounts }

    // Derived (rebuilt whenever the library changes)
    private(set) var transactions: [Transaction] = []
    private(set) var months: [Month] = []
    private(set) var reviewItems: [ReviewItem] = []
    private(set) var cardCoverage: [CardCoverage] = []
    private(set) var missingStatements: [MissingStatements] = []
    private(set) var domainByName: [String: String] = [:]
    @ObservationIgnored private var spendingByMonth: [Month: [Transaction]] = [:]
    @ObservationIgnored private var dateCache: [String: Date] = [:]

    // UI state
    var selection: SidebarItem? = .overview { didSet { if placeFocus != nil { placeFocus = nil }; if chargesFocus != nil { chargesFocus = nil } } }
    /// Non-nil while a plain list of charges is open (one month of dining, one trip…): where a click
    /// in an answer lands. A place opened from it sits on top, and Back returns here.
    var chargesFocus: TransactionFilter?
    /// Non-nil while one place's page is open over whatever page was showing.
    var placeFocus: String?
    /// What is typed in the box on the Places page, and the stretch of time it looks at (kept while a place is open).
    var placeSearch = ""
    var placeSpan = PlacesView.Span.all
    /// True while the story of how the app came to be is open.
    var showsStory = false
    /// Non-nil while a charge's original statement is open over the window.
    var originalPeek: OriginalPeek?
    /// Which file the Statements page shows, and the charge to point at in it.
    var statementFocus: StatementFocus?
    @ObservationIgnored private var linkedByLastAdd = 0
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
    /// The Overview looks at one month or at a whole year; the same page either way.
    var overviewShowsYear = ProcessInfo.processInfo.environment["SPENDTHRIFT_YEAR"] != nil
    var pendingImports: [PendingImport] = []
    /// Something Tony must be told at launch (e.g. data restored from a backup).
    var startupNotice: String?
    /// Non-nil while the "New Category" sheet is up.
    var categoryEditor: CategoryEditorRequest?
    var toast: Toast?
    private(set) var isSuggesting = false
    private(set) var isImporting = false
    private(set) var downloadCandidates: [URL] = []
    /// Checked each time: Apple Intelligence can be switched on (or finish downloading) while the app is open.
    var aiAvailable: Bool { CategorySuggester.isAvailable }
    /// Files from the last import that couldn't be added.
    var importIssues: [ImportIssue] = []
    /// "Reading 5 of 18" while several statements are being read.
    private(set) var importProgress: (done: Int, total: Int)?
    /// Kept for views that wait on the first load; the library loads instantly at launch.
    let hasLoadedTransactions = true

    let paths = BudgetPaths()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var aiAttempted: Set<String> = []
    @ObservationIgnored private var cloudAttempted: Set<String> = []
    @ObservationIgnored private var autoAttempted: Set<URL> = []
    @ObservationIgnored private var downloadsWatcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var downloadsDebounce: Task<Void, Never>?
    @ObservationIgnored private var relearnKeys: Set<String> = []
    @ObservationIgnored private var relearnTask: Task<Void, Never>?
    @ObservationIgnored private var lastImport: (entries: Set<UUID>, accounts: Set<UUID>, hashes: Set<String>)?

    private init() {
        let (loaded, result) = Library.load(paths: paths)
        library = loaded
        CustomCategories.set(library.customCategories ?? [])
        splitWiresByRecipient()
        rebuild()
        switch result {
        case .restoredFromBackup(let date):
            let when = date.map { " from \($0.formatted(date: .abbreviated, time: .omitted))" } ?? ""
            startupNotice = "Your saved data couldn't be opened, so I restored the backup\(when). Anything added after that needs to be dropped in again. The damaged file was kept."
        case .unreadable:
            startupNotice = "Your saved data couldn't be opened and there was no backup to restore, so this is a fresh start. The damaged file was kept in the data folder. Dropping your statements in again will rebuild everything."
        case .fresh, .loaded: break
        }
        refreshDownloads()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { BudgetStore.shared.saveNow() }
        }
        Task { await sortRemaining() }
        Task { await notePeriodsIfNeeded() }
        Task { await loadOrders() }
    }

    // MARK: - Orders

    /// What order-history exports said was inside each order, and which charge paid for which.
    private(set) var orders = OrderBook()
    /// The order items laid out for the Orders page: dated, searchable, each knowing its charge.
    private(set) var orderRows: [OrderRow] = []
    var orderSearch = ""
    /// The stretch of order history on screen, whose orders, and (after a click on the ring) which category.
    var orderScope = OrderScope.all
    var orderWho: String?
    var orderCategory: Category?
    var orderList = OrderList.orders

    enum OrderScope: Hashable { case all, year(Int), month(Month) }
    enum OrderList: String, CaseIterable, Identifiable { case orders = "Orders", items = "Items"; var id: String { rawValue } }

    struct OrderRow: Identifiable {
        let id: Int
        let item: OrderItem
        let date: Date
        let month: Month
        /// What it is in plain words (the model's reading of the listing), or the listing itself until it's read.
        let name: String
        let category: Category
        /// What it cost after any refund on its order, in cents.
        let net: Int
        /// Name, listing and category squeezed to letters and digits, for finding.
        let haystack: String
        /// The card charge that paid for it, when one was found.
        let charge: UUID?
    }

    /// The first names on the order histories that were added ("Paul", "Jessica").
    private(set) var orderPeople: [String] = []
    /// True while the model is reading product listings.
    private(set) var isReadingOrders = false

    /// How far the order history reaches, set against the charges it could explain.
    struct OrderCoverage {
        var through: Date?
        var charges = 0, itemized = 0
        /// Charges at these shops made after the last order on file: waiting for a newer export.
        var newer = 0
    }

    private(set) var orderCoverage = OrderCoverage()

    private func refreshOrderRows() {
        var charge: [Int: UUID] = [:]
        for (id, match) in orders.matches {
            guard let uuid = UUID(uuidString: id) else { continue }
            for i in match.items { charge[i] = uuid }
        }
        // A refund comes off every item of its order in proportion.
        var ordered: [String: Int] = [:]
        for item in orders.items { ordered[item.orderID, default: 0] += max(0, item.cents) }
        let refunds = orders.refunds ?? [:], sorted = orders.sorted ?? [:]
        var dates: [String: Date] = [:]
        orderRows = orders.items.enumerated().compactMap { i, item in
            let parsed = dates[item.date] ?? DateParsing.parse(item.date, format: "yyyy-MM-dd")
            guard let date = parsed else { return nil }
            dates[item.date] = date
            let read = sorted[item.name]
            let category = read.map { Category($0.category) } ?? item.roughCategory
            let name = read?.name ?? item.name
            var net = item.cents
            if let back = refunds[item.orderID], let whole = ordered[item.orderID], whole > 0 {
                net = max(0, item.cents - Int((Double(item.cents) * Double(min(back, whole)) / Double(whole)).rounded()))
            }
            return OrderRow(id: i, item: item, date: date, month: Month(date: date), name: name, category: category, net: net,
                            haystack: [name, item.name, category.rawValue, item.who ?? ""].map(PlacesView.squeeze).joined(separator: " "),
                            charge: charge[i])
        }
        orderPeople = Array(Set(orders.items.compactMap(\.who))).sorted()
        var coverage = OrderCoverage()
        let last = orders.items.map(\.date).max()
        coverage.through = last.flatMap { DateParsing.parse($0, format: "yyyy-MM-dd") }
        for c in orderCharges {
            coverage.charges += 1
            if orders.matches[c.id.uuidString] != nil { coverage.itemized += 1 } else if let last, c.date > last { coverage.newer += 1 }
        }
        orderCoverage = coverage
    }

    /// What a charge paid for, if an order on file explains it. Nil for every other charge,
    /// which is most of them: order history is extra detail, never something the app leans on.
    func orderDetail(for id: Transaction.ID) -> (items: [OrderItem], kind: OrderMatch.Kind)? {
        guard let match = orders.matches[id.uuidString] else { return nil }
        let items = orders.items(for: id)
        return items.isEmpty ? nil : (items, match.kind)
    }

    /// Why a charge from one of these shops has no items, in a sentence. Nil when there is nothing
    /// to say: no order history at all, or a charge from somewhere order histories don't cover.
    func orderGap(for t: Transaction) -> String? {
        guard !orders.items.isEmpty, t.amount > 0, orders.matches[t.id.uuidString] == nil,
              OrderMatcher.shop(of: t.description) != nil, let through = orderCoverage.through else { return nil }
        if t.date > through {
            return "Newer than your order history, which runs through \(through.formatted(.dateTime.month(.abbreviated).day().year())). Add a fresh one and the items will appear here."
        }
        return "No order on file adds up to this charge. A gift balance may have paid part of it, or it was ordered on another account."
    }

    private func loadOrders() async {
        let file = paths.ordersFile
        let saved = await Task.detached { OrderBook.load(file) }.value
        guard !saved.items.isEmpty else { return }
        orders = saved
        refreshOrderRows()
        await rematchOrders()   // statements may have been added since the orders were last lined up
        await readOrderListings()
    }

    /// The charges an order export could explain: spending at the shops it covers.
    private var orderCharges: [OrderMatcher.Charge] {
        library.entries.compactMap { entry in
            guard entry.amount > 0, let shop = OrderMatcher.shop(of: entry.description) else { return nil }
            return .init(id: entry.id, date: entry.date, cents: Int((entry.amount * 100).rounded()), shop: shop)
        }
    }

    /// Lines the charges up with the orders again (new statements or a new export can both change the answer).
    func rematchOrders() async {
        guard !orders.items.isEmpty else { return }
        let charges = orderCharges, items = orders.items, file = paths.ordersFile
        let matches = await Task.detached { OrderMatcher.match(charges, to: items) }.value
        guard items == orders.items else { return }   // another export arrived meanwhile; its own pass will follow
        guard matches != orders.matches || orderRows.isEmpty else { return }
        orders.matches = matches
        refreshOrderRows()
        let book = orders
        Task.detached { book.save(to: file) }
    }

    /// Has the model read every product listing it hasn't yet: what each thing is, and its budget category.
    /// Newest first, a few requests at a time; each answer is kept as it arrives, so stopping loses nothing.
    func readOrderListings() async {
        guard CloudAI.isEnabled, !isReadingOrders else { return }
        let done = orders.sorted ?? [:]
        var seen: Set<String> = [], unread: [String] = []
        for item in orders.items.reversed() where done[item.name] == nil && seen.insert(item.name).inserted { unread.append(item.name) }
        guard !unread.isEmpty else { return }
        isReadingOrders = true
        defer { isReadingOrders = false }
        let batches = stride(from: 0, to: unread.count, by: 50).map { Array(unread[$0..<min($0 + 50, unread.count)]) }
        let file = paths.ordersFile
        var failures = 0
        await withTaskGroup(of: [String: OrderBook.ItemSort]?.self) { group in
            var next = 0
            func start() { if next < batches.count { let batch = batches[next]; next += 1; group.addTask { await ItemSorter.sort(batch) } } }
            for _ in 0..<6 { start() }
            for await answer in group {
                if let answer, !answer.isEmpty {
                    orders.sorted = (orders.sorted ?? [:]).merging(answer) { _, new in new }
                    refreshOrderRows()
                    let book = orders
                    Task.detached { book.save(to: file) }
                } else {
                    failures += 1
                }
                if failures < 3 { start() }   // the model is down or out of credit: stop asking
            }
        }
        if ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] != nil {
            print("DEBUG ORDERS read \(orders.sorted?.count ?? 0) listings, \(failures) failed requests")
        }
    }

    /// For tests: add files and return when they're in.
    func importFilesAndWait(_ urls: [URL]) async { await importFilesAsync(urls) }

    /// For tests: how the charges at these shops matched, and whether every exact match adds up.
    func orderReport() -> [String] {
        var tally: [String: (count: Int, total: Double)] = [:]
        var wrong = 0
        for entry in library.entries where entry.amount > 0 {
            guard let shop = OrderMatcher.shop(of: entry.description) else { continue }
            let match = orders.matches[entry.id.uuidString]
            let key = "\(shop.rawValue) \(match?.kind.rawValue ?? "unmatched")"
            tally[key, default: (0, 0)].count += 1
            tally[key, default: (0, 0)].total += entry.amount
            if let match, match.kind == .exact,
               match.items.reduce(0, { $0 + orders.items[$1].cents }) != Int((entry.amount * 100).rounded()) { wrong += 1 }
        }
        return ["\(orders.items.count) items, \(orders.matches.count) charges matched"]
            + tally.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.count) charges, \(Int($0.value.total))" }
            + ["exact matches whose items don't add up: \(wrong)"]
    }

    /// Reads order-history files (one export, or several people's) and matches them to the charges.
    func addOrders(from files: [URL], quietly: Bool = false) async {
        let (read, refunds) = await Task.detached { OrderExport.read(files) }.value
        guard !read.isEmpty else {
            if !quietly { showToast("That order history had no orders in it.", symbol: "shippingbox") }
            return
        }
        orders.merge(read, refunds: refunds)
        refreshOrderRows()
        await rematchOrders()
        Task { await readOrderListings() }
        let charges = orderCharges
        let explained = charges.filter { orders.matches[$0.id.uuidString] != nil }.count
        let count = Set(read.map(\.orderID)).count
        if !quietly {
            showToast("Read \(count.formatted()) orders. \(explained) of \(charges.count) charges from those shops now have their items.", symbol: "shippingbox")
        }
    }

    // MARK: - Persistence

    private func changed() {
        rebuild()
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    /// Writes everything to disk right now (before quitting to install an update).
    func saveForQuit() { saveNow() }

    private func saveNow() {
        saveTask?.cancel()
        library.save(paths: paths)
    }

    // MARK: - Deriving what the screens show

    /// Card issuers we can match between "paid from checking" and "statements added".
    private static let issuers: [(name: String, words: [String])] = [
        ("Chase", ["chase"]), ("American Express", ["american express", "amex"]), ("Citi", ["citi"]),
        ("Capital One", ["capital one"]), ("Coinbase", ["coinbase"]), ("Discover", ["discover"]),
        ("Apple Card", ["apple card"]), ("Barclays", ["barclays"]), ("Bank of America", ["bank of america"]),
        ("Wells Fargo", ["wells fargo"]), ("Synchrony", ["synchrony"]), ("U.S. Bank", ["u.s. bank", "us bank"]),
    ]
    private static func issuer(in text: String) -> String? {
        let t = text.lowercased()
        return issuers.first { $0.words.contains(where: t.contains) }?.name
    }

    private func rebuild() {
        let accountNames = Dictionary(uniqueKeysWithValues: library.accounts.map { ($0.id, $0.name) })
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
        for e in library.entries {
            guard let date = date(e.date) else { continue }
            let info = library.merchants[e.merchantKey]
            let unchecked = info?.isUnconfirmedGuess ?? true
            var category = e.override ?? info?.category ?? .unsorted
            // A payment to a card is a plain transfer only when it ties to that card's statements;
            // otherwise the payment is the only record of the spending, and has to count.
            if tie.covered[e.id] == false { category = .uncoveredCards }
            list.append(Transaction(
                id: e.id, date: date, month: Month(date: date), description: e.description, amount: e.amount,
                merchant: info?.name ?? KeywordExtractor.displayName(for: e.description), merchantKey: e.merchantKey,
                category: category,
                account: accountNames[e.accountID] ?? "", accountID: e.accountID,
                source: e.override != nil ? .user : (info?.source ?? .ai),
                needsCheck: e.override == nil && unchecked, isOverride: e.override != nil))
            if let note = e.note, !note.isEmpty { list[list.count - 1].note = note }
        }
        for issuer in coverage.keys {
            coverage[issuer]?.statementSpend = cardSpend[issuer] ?? 0
            coverage[issuer]?.accounts = library.accounts.filter { cardAccount[$0.id] == issuer }.map(\.name)
        }
        cardCoverage = coverage.values.sorted { $0.paid > $1.paid }
        var domains: [String: String] = [:]
        for info in library.merchants.values { if let d = info.domain, !d.isEmpty { domains[info.name] = d } }
        domainByName = domains
        list.sort { $0.date < $1.date }
        transactions = list
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

    // MARK: - Sorting with Apple Intelligence

    /// Places the instant rules couldn't sort go to the on-device model, a few at a time.
    /// Results are applied automatically; Double-Check lets Tony glance over them later.
    /// Ties every card payment that left a bank account to that card's statements.
    ///
    /// A payment is accounted for when the card's own statement shows it arriving (the same amount
    /// within a few days), or when it equals the balance of a statement that closed shortly before.
    /// A stretch between two statements that a payment was plainly made for is a statement to find;
    /// a stretch nobody paid anything for is just a month the card wasn't used.
    private func reconcileCards(cardAccount: [UUID: String], cardDays: [String: Set<Int>]) -> (covered: [UUID: Bool], cards: [String: CardCoverage]) {
        var parsed: [String: Int] = [:]
        func day(_ s: String) -> Int? {
            if let d = parsed[s] { return d }
            guard let date = DateParsing.parse(s, format: "yyyy-MM-dd") else { return nil }
            let d = Int(date.timeIntervalSinceReferenceDate / 86_400)
            parsed[s] = d
            return d
        }
        func text(_ day: Int) -> String { DateParsing.iso.string(from: Date(timeIntervalSinceReferenceDate: Double(day) * 86_400 + 43_200)) }
        let names = Dictionary(uniqueKeysWithValues: library.accounts.map { ($0.id, $0.name) })

        struct Payment { let id: UUID; let day: Int; let amount: Double; let issuer: String; var billed = false; var lineAccount: UUID? }
        struct Credit { let day: Int; let amount: Double; let account: UUID; var used = false }
        struct Statement { let account: UUID; let start: Int?; let close: Int; var purchases = 0.0; var net = 0.0 }
        var payments: [Payment] = []
        var credits: [String: [Credit]] = [:]
        var bySource: [String: (purchases: Double, net: Double)] = [:]
        var firstCharge: [String: Int] = [:]
        for e in library.entries {
            guard let d = day(e.date) else { continue }
            let info = library.merchants[e.merchantKey]
            if let issuer = cardAccount[e.accountID] {
                firstCharge[issuer] = min(firstCharge[issuer] ?? d, d)
                let upper = e.description.uppercased()
                let isPayment = e.amount < 0 && ["PAYMENT", "AUTOPAY", "PYMT", "AUTO-PMT"].contains(where: upper.contains)
                if e.amount < 0 { credits[issuer, default: []].append(Credit(day: d, amount: -e.amount, account: e.accountID)) }
                if let source = e.sourceID {
                    var sums = bySource[source] ?? (0, 0)
                    if e.amount > 0 { sums.purchases += e.amount }
                    if !isPayment { sums.net += e.amount }
                    bySource[source] = sums
                }
            } else if (e.override ?? info?.category) == .transfer, e.override == nil, e.amount > 0,
                      let name = info?.name, name.hasSuffix("Card Payment") {
                payments.append(Payment(id: e.id, day: d, amount: e.amount, issuer: Self.issuer(in: name) ?? "Other cards"))
            }
        }
        var statements: [String: [Statement]] = [:]
        for source in library.sources ?? [] {
            guard let account = source.accountID, let issuer = cardAccount[account],
                  let close = (source.periodEnd.flatMap { $0.isEmpty ? nil : day($0) }) ?? source.lastDate.flatMap(day) else { continue }
            let sums = bySource[source.id] ?? (0, 0)
            statements[issuer, default: []].append(Statement(account: account, start: source.periodStart.flatMap { $0.isEmpty ? nil : day($0) },
                                                             close: close, purchases: sums.purchases, net: sums.net))
        }

        var covered: [UUID: Bool] = [:]
        var cards: [String: CardCoverage] = [:]
        payments.sort { $0.day < $1.day }
        let allDays = cardDays.values.reduce(into: Set<Int>()) { $0.formUnion($1) }
        for i in payments.indices {
            let p = payments[i]
            var card = cards[p.issuer] ?? CardCoverage(issuer: p.issuer)
            card.paid += p.amount; card.payments += 1
            // The card's statement shows this payment arriving.
            var line = false
            if let index = credits[p.issuer]?.firstIndex(where: { !$0.used && abs($0.amount - p.amount) < 0.005 && (-4...7).contains($0.day - p.day) }) {
                credits[p.issuer]![index].used = true
                payments[i].lineAccount = credits[p.issuer]![index].account
                line = true
            }
            // It pays off, to the cent, a statement that closed in the weeks before.
            let billed = (statements[p.issuer] ?? []).contains { s in
                (1...75).contains(p.day - s.close) && (abs(s.purchases - p.amount) < 0.005 || abs(s.net - p.amount) < 0.005)
            }
            payments[i].billed = billed
            // Or, for a card not paid in full, that card's purchases are simply here for the weeks before.
            let days = p.issuer == "Other cards" ? allDays : (cardDays[p.issuer] ?? [])
            let inRange = (15...50).contains { days.contains(p.day - $0) }
            covered[p.id] = line || billed || inRange
            if line || billed || inRange {
                card.tied += 1
            } else {
                card.uncoveredPaid += p.amount; card.uncoveredPayments += 1
                let loose = LoosePayment(id: p.id, date: text(p.day), amount: p.amount)
                let begins = (statements[p.issuer] ?? []).map(\.close).min() ?? firstCharge[p.issuer]
                if let begins, p.day < begins + 45 { card.early.append(loose) } else if begins != nil { card.unexplained.append(loose) }
            }
            cards[p.issuer] = card
        }

        // Holes between one statement and the next. A payment made for the hole proves a statement is missing.
        for (issuer, list) in statements {
            for (account, mine) in Dictionary(grouping: list.filter { $0.start != nil }, by: \.account) where mine.count >= 3 {
                let ordered = mine.sorted { $0.close < $1.close }
                for (a, b) in zip(ordered, ordered.dropFirst()) {
                    guard let nextStart = b.start, nextStart - a.close > 7 else { continue }
                    let from = a.close + 1, to = nextStart - 1
                    // What was due for a statement closing in the hole would be paid two to five weeks after it closed.
                    let proof = payments.first { p in
                        p.issuer == issuer && !p.billed && (p.lineAccount == nil || p.lineAccount == account) && (from + 15...to + 35).contains(p.day)
                    }
                    guard let proof else { continue }
                    cards[issuer]?.toFind.append(StatementToFind(account: names[account] ?? issuer, from: text(from), to: text(to),
                                                                 paid: proof.amount, paidOn: text(proof.day)))
                }
            }
        }
        for issuer in cards.keys { cards[issuer]?.toFind.sort { $0.from < $1.from } }
        return (covered, cards)
    }

    /// Statements added before the app noted the billing period they print: read it from the kept copies.
    func notePeriodsIfNeeded() async {
        let waiting = (library.sources ?? []).filter { $0.isPDF && $0.periodStart == nil }
        guard !waiting.isEmpty else { return }
        let files = waiting.map { ($0.id, paths.statementFile($0)) }
        let found = await Task.detached(priority: .utility) { () -> [String: (String, String)] in
            var out: [String: (String, String)] = [:]
            for (id, url) in files {
                guard let data = try? Data(contentsOf: url) else { continue }
                out[id] = PDFStatement.period(ofPDF: data).map { ($0.start, $0.end) } ?? ("", "")
            }
            return out
        }.value
        guard !found.isEmpty else { return }
        for i in (library.sources ?? []).indices {
            if let period = found[library.sources![i].id] { library.sources![i].periodStart = period.0; library.sources![i].periodEnd = period.1 }
        }
        changed()
    }

    private func sortRemaining() async {
        guard !isSuggesting else { return }
        isSuggesting = true
        defer {
            isSuggesting = false
            // Once everything has a category, look for the trips and events in it, and find logos.
            Task { await findStoriesIfNeeded() }
            Task { await findLogosIfNeeded() }
            Task { await findDiscoveriesIfNeeded() }
            announceNewFindings()
        }
        // With a cloud key, the powerful model decides everything the built-in list doesn't know.
        if CloudAI.isEnabled { await sortWithCloud(); await lookUpGuesses() }
        guard aiAvailable else { return }
        while true {
            let used = Dictionary(grouping: library.entries, by: \.merchantKey)
            let waiting = library.merchants
                .filter { $0.value.category == nil && !aiAttempted.contains($0.key) && used[$0.key] != nil }
                .map { key, info -> (SuggestionInput, Double) in
                    let entries = used[key] ?? []
                    let total = entries.reduce(0) { $0 + $1.amount }
                    return (SuggestionInput(keyword: key, description: info.sample, averageAmount: total / Double(max(entries.count, 1))), abs(total))
                }
                .sorted { $0.1 > $1.1 }   // biggest first, so the totals settle quickly
                .map(\.0)
            guard !waiting.isEmpty else { break }
            // Tony's own choices teach the model his habits.
            let examples = library.merchants.values
                .filter { $0.confirmed && $0.category != nil }
                .map { MerchantRule(name: $0.name, category: $0.category!) }
            for batch in waiting.chunked(into: 8) {
                aiAttempted.formUnion(batch.map(\.keyword))
                let results = await CategorySuggester.suggest(batch, examples: examples)
                for (key, suggestion) in results where library.merchants[key]?.category == nil {
                    library.merchants[key]?.category = suggestion.category
                    library.merchants[key]?.name = suggestion.name
                    library.merchants[key]?.source = .ai
                }
                if !results.isEmpty { withAnimation(.snappy) { changed() } }
            }
        }
    }

    /// The cloud model reviews every place that isn't Tony's own choice or a business the app knows
    /// for certain: unsorted places, on-device guesses, the bank's broad categories and word matches.
    /// What it's sure of is simply filed; only what it calls a guess goes to Double-Check.
    private func sortWithCloud() async {
        while true {
            let used = Dictionary(grouping: library.entries, by: \.merchantKey)
            var waiting: [(item: CloudItem, weight: Double)] = []
            for (key, info) in library.merchants {
                guard !info.confirmed, [.ai, .bank, .generic].contains(info.source) || relearnKeys.contains(key), !cloudAttempted.contains(key),
                      let entries = used[key], !entries.isEmpty else { continue }
                let total = entries.reduce(0) { $0 + $1.amount }
                var item = CloudItem(key: key, description: info.sample, averageAmount: total / Double(entries.count),
                                     count: entries.count, bankCategory: entries.compactMap(\.bankCategory).first)
                item.amounts = Array(entries.suffix(8).map { abs($0.amount) })
                item.notes = ([info.note].compactMap { $0 } + entries.compactMap(\.note)).filter { !$0.isEmpty }.suffix(4).map { String($0.prefix(200)) }
                if let guess = info.category { item.appGuess = "\(info.name): \(guess.rawValue)" }
                waiting.append((item, abs(total)))
            }
            guard !waiting.isEmpty else { relearnKeys.removeAll(); return }
            waiting.sort { $0.weight > $1.weight }
            let examples = library.merchants.values
                .filter { $0.confirmed && $0.category != nil }
                .map { MerchantRule(name: $0.name, category: $0.category!) }
            // Several batches at once, biggest places first. A batch that fails is retried in halves;
            // only if nothing at all gets through do we assume the cloud is unreachable and stop.
            var batches = waiting.map(\.item).chunked(into: 15)
            cloudAttempted.formUnion(waiting.map(\.item.key))
            var anySucceeded = false
            await withTaskGroup(of: ([CloudItem], [String: CloudVerdict]?).self) { group in
                var running = 0
                func start() {
                    // Measured on 567 real places: forty small batches in flight finish in under ten
                    // seconds; five at a time took a minute. The answers are the same.
                    while running < 40, !batches.isEmpty {
                        let batch = batches.removeFirst()
                        running += 1
                        group.addTask { (batch, await CloudSorter.sortTwice(batch, examples: examples)) }
                    }
                }
                start()
                for await (batch, verdicts) in group {
                    running -= 1
                    if let verdicts {
                        anySucceeded = true
                        for (key, verdict) in verdicts where library.merchants[key]?.confirmed == false {
                            library.merchants[key]?.category = verdict.category
                            library.merchants[key]?.name = verdict.name
                            library.merchants[key]?.source = verdict.confident ? .cloud : .cloudGuess
                            library.merchants[key]?.domain = verdict.domain
                        }
                        if !verdicts.isEmpty { withAnimation(.snappy) { changed() } }
                    } else if batch.count > 4, anySucceeded || batch.count > 15 {
                        // Too big a bite, or a hiccup: try again in two halves.
                        let half = batch.count / 2
                        batches.append(Array(batch[..<half])); batches.append(Array(batch[half...]))
                    }
                    start()
                }
            }
            if !anySucceeded { return }
        }
    }

    /// Called when a key is added in Settings: everything uncertain gets a second, better look.
    func cloudBecameAvailable() {
        cloudAttempted.removeAll()
        Task { await sortRemaining() }
    }

    // MARK: - Logos

    @ObservationIgnored private var isFindingLogos = false

    /// The website of the business with this name, if known (its logo is fetched from there).
    func domain(forPlace name: String) -> String? { domainByName[name] }

    /// Businesses the app recognized by itself (Starbucks, Con Edison…) never went to the cloud
    /// model, so nobody has said what their website is. Ask once, in the background.
    private func findLogosIfNeeded() async {
        guard CloudAI.isEnabled, !isFindingLogos else { return }
        let used = Set(library.entries.map(\.merchantKey))
        let unknown = library.merchants.filter { $0.value.domain == nil && used.contains($0.key) }
        guard !unknown.isEmpty else { return }
        isFindingLogos = true
        defer { isFindingLogos = false }
        for batch in Array(unknown).chunked(into: 80) {
            guard let found = await LogoFinder.domains(for: batch.map(\.value.name)) else { return }
            for (key, info) in batch { library.merchants[key]?.domain = found[info.name] ?? "" }
            changed()
        }
    }

    // MARK: - Trips and events

    private(set) var isFindingStories = false

    /// Trips and events, newest first, without the ones Tony said weren't.
    var stories: [Story] {
        let dismissed = library.dismissedStories ?? []
        var list = (library.stories ?? []).filter { !dismissed.contains($0.fingerprint) }
        // What Tony moved by hand wins over what the model worked out.
        let choices = library.storyChoices ?? [:]
        guard !choices.isEmpty else { return list }
        let moved = Set(choices.keys.compactMap { UUID(uuidString: $0) })
        for i in list.indices { list[i].entryIDs.removeAll { moved.contains($0) } }
        for (key, choice) in choices {
            guard let id = UUID(uuidString: key), let index = Self.resolve(choice, in: list) else { continue }
            list[index].entryIDs.append(id)
        }
        return list
    }

    /// A choice remembers the trip's name and its dates. When the model looks again it may word the
    /// name differently ("Austin" becomes "Austin weekend"), so if the name is gone, the trip that
    /// shares the most days with the remembered dates is the same trip.
    private static func choice(for story: Story) -> String { "\(story.fingerprint)\t\(story.start)\t\(story.end)" }
    private static func resolve(_ choice: String, in list: [Story]) -> Int? {
        let parts = choice.components(separatedBy: "\t")
        guard parts.count == 3, !parts[0].isEmpty else { return nil }
        if let exact = list.firstIndex(where: { $0.fingerprint == parts[0] }) { return exact }
        let overlaps = list.indices.filter { list[$0].start <= parts[2] && list[$0].end >= parts[1] }
        return overlaps.max { a, b in
            func shared(_ s: Story) -> Int {
                guard let from = DateParsing.parse(max(s.start, parts[1]), format: "yyyy-MM-dd"),
                      let to = DateParsing.parse(min(s.end, parts[2]), format: "yyyy-MM-dd") else { return 0 }
                return Calendar.current.dateComponents([.day], from: from, to: to).day ?? 0
            }
            return shared(list[a]) < shared(list[b])
        }
    }

    func story(containing id: Transaction.ID) -> Story? {
        stories.first { $0.entryIDs.contains(id) }
    }

    /// Puts charges in a trip or event (or in none), whatever the model thought. Remembered for good.
    func move(_ ids: Set<Transaction.ID>, to story: Story?) {
        guard !ids.isEmpty else { return }
        var choices = library.storyChoices ?? [:]
        for id in ids { choices[id.uuidString] = story.map(Self.choice(for:)) ?? "" }
        library.storyChoices = choices
        changed()
        let what = ids.count == 1 ? (transactions.first { ids.contains($0.id) }?.merchant ?? "1 charge") : "\(ids.count) charges"
        showToast(story.map { "Moved \(what) to “\($0.name)”." } ?? "\(what): no longer part of a trip or event.", symbol: "checkmark.circle.fill")
    }

    func transactions(in story: Story) -> [Transaction] {
        let ids = Set(story.entryIDs)
        return transactions.filter { ids.contains($0.id) }
    }

    func dismissStory(_ story: Story) {
        var dismissed = library.dismissedStories ?? []
        dismissed.insert(story.fingerprint)
        library.dismissedStories = dismissed
        if transactionFilter.storyID == story.id { transactionFilter.storyID = nil }
        withAnimation(.snappy) { changed() }
        showToast("Removed “\(story.name)”. Its charges are untouched.", symbol: "checkmark.circle.fill")
    }

    /// What the stories were last worked out from: when the data changes, look again.
    /// Work that may be owed from an earlier session (the app was quit mid-way, or a feature is
    /// new since the last import): look up the remaining guesses, then read for things to notice.
    func catchUp() async {
        guard CloudAI.isEnabled, !isImporting, !isSuggesting, !accounts.isEmpty else { return }
        await adoptWineCategory()
        await lookUpGuesses()
        await guessWhatTheyWere()
        await findStoriesIfNeeded()
        await findDiscoveriesIfNeeded()
    }

    // MARK: - Looking places up on the web

    private(set) var isLookingUp = false

    /// The guesses that matter most by dollars are searched for on the web, once each.
    private func lookUpGuesses() async {
        guard CloudAI.isEnabled, WebLookup.isOn, !isLookingUp else { return }
        let used = Dictionary(grouping: library.entries, by: \.merchantKey)
        var waiting: [(item: CloudItem, weight: Double)] = []
        for (key, info) in library.merchants where info.source == .cloudGuess && !info.confirmed && info.lookedUp != true {
            guard let entries = used[key], !entries.isEmpty, WebLookup.isSearchable(info.sample) else { continue }
            let total = entries.reduce(0) { $0 + $1.amount }
            var item = CloudItem(key: key, description: info.sample, averageAmount: total / Double(entries.count),
                                 count: entries.count, bankCategory: nil)
            item.appGuess = "\(info.name): \(info.category?.rawValue ?? "unknown")"
            waiting.append((item, abs(total)))
        }
        guard !waiting.isEmpty else { return }
        let cap = ProcessInfo.processInfo.environment["SPENDTHRIFT_LOOKUP_CAP"].flatMap(Int.init) ?? 40
        let chosen = waiting.sorted { $0.weight > $1.weight }.prefix(cap).map(\.item)
        isLookingUp = true
        defer { isLookingUp = false }
        let batches = chosen.chunked(into: 5)
        await withTaskGroup(of: ([CloudItem], [String: CloudVerdict]).self) { group in
            for batch in batches { group.addTask { (batch, await WebLookup.identify(batch)) } }
            for await (batch, verdicts) in group {
                for item in batch { library.merchants[item.key]?.lookedUp = true }
                for (key, verdict) in verdicts where library.merchants[key]?.confirmed == false {
                    if ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] != nil {
                        print("DEBUG LOOKUP \(library.merchants[key]?.sample ?? "") → \(verdict.name) | \(verdict.category.rawValue) | \(verdict.domain ?? "-")")
                    }
                    library.merchants[key]?.name = verdict.name
                    library.merchants[key]?.category = verdict.category
                    library.merchants[key]?.source = .cloud
                    if let domain = verdict.domain, !domain.isEmpty { library.merchants[key]?.domain = domain }
                }
                withAnimation(.snappy) { changed() }
            }
        }
    }

    /// Libraries from before wires were told apart hold every international wire as one payee.
    /// Once, each wire is given to its own recipient. A recipient that is new starts with the old
    /// payee's category as a guess and goes to Double-Check to be named.
    private func splitWiresByRecipient() {
        guard library.adopted?.contains("wires") != true else { return }
        library.adopted = (library.adopted ?? []).union(["wires"])
        // Which recipients each old payee turns into.
        var becomes: [String: Set<String>] = [:]
        for entry in library.entries where !entry.merchantKey.hasPrefix("known:") {
            guard let recipient = KeywordExtractor.wireRecipient(entry.description), "WIRE " + recipient != entry.merchantKey else { continue }
            becomes[entry.merchantKey, default: []].insert("WIRE " + recipient)
        }
        guard !becomes.isEmpty else { return }
        for i in library.entries.indices {
            let entry = library.entries[i]
            guard let targets = becomes[entry.merchantKey], let recipient = KeywordExtractor.wireRecipient(entry.description) else { continue }
            let key = "WIRE " + recipient
            if library.merchants[key] == nil, let old = library.merchants[entry.merchantKey] {
                if targets.count == 1 {
                    // It was one recipient all along: everything the person decided about it carries over.
                    library.merchants[key] = old
                } else {
                    var info = MerchantResolver.instant(description: entry.description, amount: entry.amount, bankCategory: nil)
                    info.category = old.category
                    library.merchants[key] = info
                }
            }
            library.entries[i].merchantKey = key
        }
        // The lumped payees are empty now; a confirmed one would otherwise linger as a name with nothing in it.
        for old in becomes.keys { library.merchants[old] = nil }
        pruneUnusedPlaces()
        library.save(paths: paths)
    }

    // MARK: - A category added after a library was sorted

    /// "Wine & Spirits" arrived after people's statements were already sorted, when wine shops went
    /// under Groceries. Once, the places that might belong to it are shown to the model again, and only
    /// the ones it files there are moved. Nothing else changes category, and anything the person
    /// chose themselves is left alone.
    func adoptWineCategory(force: Bool = false) async {
        // Remembered in the library itself, so each library gets this exactly once, on any Mac.
        func done() { library.adopted = (library.adopted ?? []).union(["wine"]); changed() }
        guard CloudAI.isEnabled, !isImporting, !isSuggesting, force || library.adopted?.contains("wine") != true else { return }
        guard !library.entries.isEmpty else { return }
        let used = Dictionary(grouping: library.entries, by: \.merchantKey)
        let hints = ["wine", "liquor", "spirit", "whisk", "bourbon", "cellar", "vineyard", "winery", "vino", "distill", "bottle", "vintner", "champagne"]
        var waiting: [(item: CloudItem, weight: Double)] = []
        for (key, info) in library.merchants where !info.confirmed && info.source != .user {
            guard let entries = used[key], !entries.isEmpty, let category = info.category else { continue }
            let text = (info.name + " " + info.sample).lowercased()
            // Where a bottle shop would have been filed before, or anything that sounds like one.
            guard [Category.groceries, .shopping, .other].contains(category) || hints.contains(where: text.contains) else { continue }
            let total = entries.reduce(0) { $0 + $1.amount }
            guard total > 0 else { continue }
            var item = CloudItem(key: key, description: info.sample, averageAmount: total / Double(entries.count), count: entries.count, bankCategory: nil)
            item.appGuess = "\(info.name): \(category.rawValue)"
            waiting.append((item, total))
        }
        let batches = waiting.sorted { $0.weight > $1.weight }.prefix(900).map(\.item).chunked(into: 15)
        var moved = 0, answered = 0
        await withTaskGroup(of: [String: CloudVerdict]?.self) { group in
            for batch in batches { group.addTask { await CloudSorter.sortTwice(batch, examples: []) } }
            for await verdicts in group {
                guard let verdicts else { continue }
                answered += 1
                for (key, verdict) in verdicts where verdict.category == .wine && library.merchants[key]?.confirmed == false {
                    if ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] != nil {
                        print("DEBUG WINE \(library.merchants[key]?.name ?? key) [\(library.merchants[key]?.category?.rawValue ?? "-")] \(verdict.confident ? "" : "(guess)")")
                    }
                    library.merchants[key]?.category = .wine
                    library.merchants[key]?.source = verdict.confident ? .cloud : .cloudGuess
                    moved += 1
                }
            }
        }
        // Only count it done if the model was reachable; otherwise try again next time.
        if answered > 0 || batches.isEmpty { done() }
        if moved > 0 {
            withAnimation(.snappy) { changed() }
            showToast("New category: Wine & Spirits. \(moved) \(moved == 1 ? "payee" : "payees") moved into it from Groceries and Shopping.", symbol: "wineglass.fill")
        }
    }

    // MARK: - A best guess at each unconfirmed place

    @ObservationIgnored private var isGuessing = false

    /// For every place on Double-Check that has no guess yet: ask once what it most likely was.
    func guessWhatTheyWere() async {
        guard CloudAI.isEnabled, !isGuessing, !isImporting else { return }
        let waiting = reviewItems.filter { $0.info.hunch == nil || $0.info.hunchSorted != true }
        guard !waiting.isEmpty else { return }
        isGuessing = true
        defer { isGuessing = false }
        let byKey = Dictionary(grouping: transactions, by: \.merchantKey)
        let subjects = waiting.prefix(60).map { item -> Huncher.Subject in
            let charges = (byKey[item.key] ?? []).sorted { $0.date > $1.date }
            return Huncher.Subject(key: item.key, name: item.info.name, line: item.info.sample,
                                   category: item.info.category?.rawValue ?? "not sorted",
                                   account: charges.first?.account ?? "",
                                   charges: charges.prefix(8).map { "\(DateParsing.iso.string(from: $0.date)) \(Money.format(abs($0.amount))) \($0.amount < 0 ? "in" : "out")" },
                                   count: charges.count)
        }
        let guesses = await Huncher.guess(Array(subjects), notes: allNotes(limit: 25))
        guard !guesses.isEmpty else { return }
        for (key, guess) in guesses {
            // Still an unconfirmed guess? (The person may have settled it while the model was thinking.)
            guard let info = library.merchants[key], info.isUnconfirmedGuess else { continue }
            library.merchants[key]?.hunch = guess.text
            library.merchants[key]?.hunchSorted = true
            // The category on the row follows the guess, so "looks right" can be one click. It stays a guess.
            if let category = guess.category, !guess.text.isEmpty, category != info.category {
                library.merchants[key]?.category = category
                if info.source != .ai { library.merchants[key]?.source = .cloudGuess }
            }
            if ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] != nil {
                print("DEBUG HUNCH \(info.name): \(guess.text) | \(info.category?.rawValue ?? "-") → \(guess.category?.rawValue ?? "-")")
            }
        }
        withAnimation(.snappy) { changed() }
    }

    // MARK: - What the analyst noticed

    private(set) var isFindingDiscoveries = false

    var discoveries: [Discovery] {
        let dismissed = library.dismissedDiscoveries ?? []
        let kept = (library.discoveries ?? []).filter { !dismissed.contains($0.title.lowercased()) }
        // One of each kind before a second of any: four double charges in a row read as one finding.
        var byKind: [String: [Discovery]] = [:], order: [String] = []
        for item in kept { if byKind[item.kind] == nil { order.append(item.kind) }; byKind[item.kind, default: []].append(item) }
        var mixed: [Discovery] = []
        while mixed.count < kept.count {
            for kind in order { if let next = byKind[kind]?.first { mixed.append(next); byKind[kind]?.removeFirst() } }
        }
        return mixed
    }

    func transactions(in discovery: Discovery) -> [Transaction] {
        let ids = Set(discovery.entryIDs)
        return transactions.filter { ids.contains($0.id) }
    }

    func dismissDiscovery(_ discovery: Discovery) {
        var dismissed = library.dismissedDiscoveries ?? []
        dismissed.insert(discovery.title.lowercased())
        library.dismissedDiscoveries = dismissed
        withAnimation(.snappy) { changed() }
    }

    func showDiscovery(_ discovery: Discovery) {
        var filter = TransactionFilter()
        filter.ids = Set(discovery.entryIDs)
        filter.title = discovery.title
        showCharges(filter)
    }

    private func findDiscoveriesIfNeeded() async {
        guard CloudAI.isEnabled, !isFindingDiscoveries, !isImporting, !isSuggesting, let last = months.last else { return }
        let basis = storiesBasis
        guard library.discoveriesBasis != basis else { return }
        isFindingDiscoveries = true
        defer { isFindingDiscoveries = false }
        // The last twelve months of real spending: recent enough to act on.
        let start = last.adding(-11)
        guard let found = await discover(in: transactions.filter { $0.month >= start }) else { return }
        guard storiesBasis == basis else { return }
        library.discoveries = found
        library.discoveriesBasis = basis
        withAnimation(.snappy) { changed() }
        if ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] != nil {
            for d in discoveries {
                let list = transactions(in: d)
                print("DEBUG NOTICED [\(d.kind)] \(d.title) | \(list.count) charges | \(Int(list.reduce(0) { $0 + $1.amount })) | \(d.detail)")
            }
        }
    }

    /// Has the analyst read one stretch of charges and say what stands out in it.
    private func discover(in stretch: [Transaction]) async -> [Discovery]? {
        let recent = stretch.filter { !$0.isTransfer && !$0.isUnknown && $0.lane != .investments }.suffix(3_000)
        let lines = recent.map { t in
            StoryFinder.Line(id: t.id, date: DateParsing.iso.string(from: t.date),
                             text: t.note.map { "\(t.merchant) (\(t.description)) [note: \($0.prefix(120))]" } ?? "\(t.merchant) (\(t.description.prefix(40)))",
                             amount: t.amount, category: t.category.displayName)
        }
        guard let found = await Discoverer.find(lines, notes: allNotes(limit: 20)) else { return nil }
        return found.map { finding in
            Discovery(title: finding.title, detail: finding.detail, kind: finding.kind, entryIDs: finding.lines.map { lines[$0 - 1].id })
        }
    }

    // MARK: What was noticed in the month or year on screen

    /// Calendar years being read right now.
    private(set) var readingYears: Set<Int> = []

    /// Whether a month falls inside the rolling year the main list was worked out from.
    private func isRecent(_ month: Month) -> Bool { months.last.map { month >= $0.adding(-11) } ?? false }

    private func yearBasis(_ year: Int) -> String {
        let list = library.entries.filter { $0.date.hasPrefix(String(year)) }
        return "\(list.count)|\(Int(list.reduce(0) { $0 + abs($1.amount) }))"
    }

    /// What was noticed that touches this month or year, with only the charges that fall inside it.
    func noticed(in scope: NoticedScope) -> [(item: Discovery, charges: [Transaction])] {
        let dismissed = library.dismissedDiscoveries ?? []
        let source: [Discovery]
        let inside: (Transaction) -> Bool
        switch scope {
        case .last12:
            source = discoveries; inside = { _ in true }
        case .year(let year):
            source = library.discoveriesByYear?[String(year)]?.items ?? []
            inside = { $0.month.year == year }
        case .month(let month):
            source = isRecent(month) ? discoveries : (library.discoveriesByYear?[String(month.year)]?.items ?? [])
            inside = { $0.month == month }
        }
        let byID = Dictionary(transactions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return source.filter { !dismissed.contains($0.title.lowercased()) }.compactMap { item in
            let charges = item.entryIDs.compactMap { byID[$0] }.filter(inside)
            return charges.isEmpty ? nil : (item, charges)
        }
    }

    /// True while the year this scope depends on is still being read.
    func isReading(_ scope: NoticedScope) -> Bool {
        switch scope {
        case .last12: isFindingDiscoveries
        case .year(let year): readingYears.contains(year)
        case .month(let month): isRecent(month) ? isFindingDiscoveries : readingYears.contains(month.year)
        }
    }

    /// An earlier year is read the first time it is looked at, and kept.
    func readIfNeeded(_ scope: NoticedScope) async {
        let year: Int
        switch scope {
        case .last12: return
        case .year(let y): year = y
        case .month(let month):
            guard !isRecent(month) else { return }
            year = month.year
        }
        let basis = yearBasis(year)
        guard CloudAI.isEnabled, !isImporting, !readingYears.contains(year), library.discoveriesByYear?[String(year)]?.basis != basis else { return }
        readingYears.insert(year)
        defer { readingYears.remove(year) }
        guard let found = await discover(in: transactions.filter { $0.month.year == year }) else { return }
        var all = library.discoveriesByYear ?? [:]
        all[String(year)] = YearFindings(basis: basis, items: found)
        library.discoveriesByYear = all
        withAnimation(.snappy) { changed() }
        if ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] != nil {
            for d in found { print("DEBUG NOTICED \(year) [\(d.kind)] \(d.title) | \(d.entryIDs.count) charges | \(d.detail)") }
        }
    }

    private var storiesBasis: String {
        "\(library.entries.count)|\(Int(library.entries.reduce(0) { $0 + abs($1.amount) }))"
    }

    private func findStoriesIfNeeded() async {
        guard CloudAI.isEnabled, !isFindingStories, !isImporting, !isSuggesting else { return }
        let basis = storiesBasis
        guard library.storiesBasis != basis else { return }
        isFindingStories = true
        defer { isFindingStories = false }
        let lines = transactions.filter { $0.countsAsSpending && !$0.isUnknown }.map { t in
            StoryFinder.Line(id: t.id, date: DateParsing.iso.string(from: t.date),
                             text: t.note.map { "\(t.description) [the person's note: \($0.prefix(160))]" } ?? t.description,
                             amount: t.amount, category: t.category.displayName)
        }
        guard let found = await StoryFinder.find(lines) else { return }      // offline: try again next time
        guard storiesBasis == basis else { return }                          // more arrived meanwhile; a newer pass will run
        let before = Set(stories.map(\.fingerprint))
        library.stories = found
        library.storiesBasis = basis
        withAnimation(.snappy) { changed() }
        if let fresh = stories.first(where: { !before.contains($0.fingerprint) }), !before.isEmpty || stories.count == 1 {
            Notifier.post(title: fresh.kind == .trip ? "I noticed a trip" : "I noticed something",
                          body: "\(fresh.name): \(Money.format(transactions(in: fresh).reduce(0) { $0 + $1.amount }, cents: false)) across \(fresh.entryIDs.count) charges.")
        }
    }

    // MARK: - Changing categories by hand

    /// - wholePlace: true changes every charge from that place, now and in future (the usual case).
    func setCategory(_ category: Category, for ids: Set<UUID>, wholePlace: Bool) {
        let chosen = transactions.filter { ids.contains($0.id) }
        guard !chosen.isEmpty else { return }
        if wholePlace {
            let keys = Set(chosen.map(\.merchantKey))
            for key in keys {
                library.merchants[key]?.category = category
                library.merchants[key]?.source = .user
                library.merchants[key]?.confirmed = true
            }
            for i in library.entries.indices where keys.contains(library.entries[i].merchantKey) { library.entries[i].override = nil }
            let name = keys.count == 1 ? chosen[0].merchant : "\(keys.count) payees"
            showToast("\(name) is now \(category.displayName), every time.", symbol: category.symbol)
            learnFromCorrection()
        } else {
            for i in library.entries.indices where ids.contains(library.entries[i].id) { library.entries[i].override = category }
            showToast(ids.count == 1 ? "Just this one is now \(category.displayName)." : "\(ids.count) charges are now \(category.displayName).",
                      symbol: category.symbol)
        }
        withAnimation(.snappy) { changed() }
    }

    func setCategory(_ category: Category, forPlace key: String) {
        guard library.merchants[key] != nil else { return }
        library.merchants[key]?.category = category
        library.merchants[key]?.source = .user
        library.merchants[key]?.confirmed = true
        for i in library.entries.indices where library.entries[i].merchantKey == key { library.entries[i].override = nil }
        withAnimation(.snappy) { changed() }
        learnFromCorrection()
    }

    /// Tony just taught the app something. A few seconds later (in case he's changing several),
    /// the model takes another look at its remaining guesses with his choices as fresh examples.
    private func learnFromCorrection() {
        guard CloudAI.isEnabled else { return }
        relearnTask?.cancel()
        relearnTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            let guesses = library.merchants.filter { !$0.value.confirmed && $0.value.source == .cloudGuess }.map(\.key)
            guard !guesses.isEmpty else { return }
            relearnKeys.formUnion(guesses)
            cloudAttempted.subtract(guesses)
            await sortRemaining()
        }
    }

    /// "Looks right": keeps the AI's guess and stops asking about it.
    func confirm(_ keys: [String]) {
        for key in keys where library.merchants[key]?.category != nil { library.merchants[key]?.confirmed = true }
        withAnimation(.snappy) { changed() }
    }

    /// What the person wrote about a place, if anything.
    func note(forPlace name: String) -> String {
        library.merchants.values.first { $0.name == name && !($0.note ?? "").isEmpty }?.note ?? ""
    }

    /// Saves a note about a place. If the place is still a guess, the note is the person saying
    /// what it is, so it is acted on; either way the estimate of what's coming is worked out again.
    func setNote(_ text: String, forPlace name: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard note(forPlace: name) != trimmed else { return }
        let keys = library.merchants.filter { $0.value.name == name }.map(\.key)
        for key in keys { library.merchants[key]?.note = trimmed.isEmpty ? nil : trimmed }
        changed()
        Forecaster.forget()
        if !trimmed.isEmpty, CloudAI.isEnabled, let guess = keys.first(where: { library.merchants[$0]?.confirmed == false }) {
            Task { await explain(guess, said: trimmed) }
        }
    }

    /// Every note the person has written, about places and about single charges: what the model
    /// should know before it answers a question or estimates what's coming.
    func allNotes(limit: Int = 40) -> [String] {
        var lines: [String] = []
        var seen: Set<String> = []
        for info in library.merchants.values {
            if let note = info.note, !note.isEmpty, seen.insert(info.name).inserted { lines.append("\(info.name): \(note)") }
        }
        for t in transactions.reversed() {
            if let note = t.note, !note.isEmpty {
                lines.append("\(t.merchant), \(DateParsing.iso.string(from: t.date)), \(Money.format(t.amount)): \(note)")
            }
            if lines.count >= limit { break }
        }
        return Array(lines.prefix(limit))
    }

    /// Places being worked out from what the person said about them.
    private(set) var explaining: Set<String> = []

    /// "It was my accountant, for tax prep": in one step, files the place where that belongs (making
    /// a category if none fits), gives it a name that says what it is, and keeps the words as a note.
    /// Returns false if it couldn't be worked out, so the caller can fall back to the category menu.
    @discardableResult
    func explain(_ key: String, said text: String) async -> Bool {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty, let info = library.merchants[key], !explaining.contains(key) else { return false }
        // The words are kept either way.
        for i in library.entries.indices where library.entries[i].merchantKey == key && (library.entries[i].note ?? "").isEmpty {
            library.entries[i].note = said
        }
        changed()
        guard CloudAI.isEnabled else { return false }
        explaining.insert(key)
        defer { explaining.remove(key) }
        let amounts = library.entries.filter { $0.merchantKey == key }.map(\.amount)
        let typical = amounts.isEmpty ? 0 : amounts.reduce(0, +) / Double(amounts.count)
        guard let verdict = await Explainer.decide(statementText: info.sample, currentName: info.name, amount: typical, said: said) else { return false }
        var category = Category.pickable.first { $0.rawValue == verdict.category }
        var made = false
        if category == nil {
            let symbol = verdict.symbol.flatMap { CustomCategory.symbols.contains($0) ? $0 : nil } ?? "tag.fill"
            let color = CustomCategory.palette[(customCategories.count * 5 + 3) % CustomCategory.palette.count].name
            category = saveCategory(CustomCategory(name: verdict.category, symbol: symbol, color: color))
            made = category != nil
        }
        guard let category else { return false }
        library.merchants[key]?.name = verdict.name
        setCategory(category, forPlace: key)
        showToast(made ? "Filed \(verdict.name) under a new category, \(category.displayName)." : "Filed \(verdict.name) under \(category.displayName).",
                  symbol: "checkmark.circle.fill")
        return true
    }

    /// Returns places to the Double-Check list (used by the test pictures, which confirm everything briefly).
    func unconfirm(_ keys: [String]) {
        for key in keys where library.merchants[key]?.source != .user { library.merchants[key]?.confirmed = false }
        changed()
    }

    func renamePlace(_ key: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, library.merchants[key] != nil, library.merchants[key]?.name != trimmed else { return }
        library.merchants[key]?.name = trimmed
        changed()
    }

    func place(_ key: String) -> MerchantInfo? { library.merchants[key] }

    /// Saves what the person remembers about one charge. If the place is still a guess, the note is
    /// reason enough to have the model look at it again.
    func setNote(_ text: String, for id: Transaction.ID) {
        guard let i = library.entries.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (library.entries[i].note ?? "") != trimmed else { return }
        library.entries[i].note = trimmed.isEmpty ? nil : trimmed
        let key = library.entries[i].merchantKey
        changed()
        // A note on a place that is still a guess is the person telling us what it was: act on it.
        if !trimmed.isEmpty, library.merchants[key]?.confirmed == false, CloudAI.isEnabled {
            Task { await explain(key, said: trimmed) }
        }
    }

    /// Opens one simple page listing the charges that match.
    func showCharges(_ filter: TransactionFilter) {
        withAnimation(.snappy(duration: 0.25)) { placeFocus = nil; chargesFocus = filter }
    }

    func transactions(matching f: TransactionFilter) -> [Transaction] {
        var list = transactions
        if let c = f.category { list = list.filter { $0.category == c } }
        if let m = f.month { list = list.filter { $0.month == m } }
        if let a = f.accountID { list = list.filter { $0.accountID == a } }
        if let k = f.merchantKey { list = list.filter { $0.merchantKey == k } }
        if let name = f.merchant { list = list.filter { $0.merchant == name } }
        if let s = f.storyID, let story = stories.first(where: { $0.id == s }) {
            let ids = Set(story.entryIDs)
            list = list.filter { ids.contains($0.id) }
        }
        if let ids = f.ids { list = list.filter { ids.contains($0.id) } }
        if f.needsCheck { list = list.filter(\.needsCheck) }
        return list
    }

    /// Opens the page for one place: everything ever spent there.
    /// A charge from this same day in an earlier year, worth being reminded of: the largest that
    /// wasn't a bill or a subscription.
    func onThisDay(_ today: Date = .now) -> (years: Int, charge: Transaction)? {
        let cal = Calendar.current
        let now = cal.dateComponents([.year, .month, .day], from: today)
        let routine = Set(subscriptions().map(\.merchant))
        var best: (years: Int, charge: Transaction)?
        for t in transactions where t.countsAsSpending && t.amount >= 15 {
            let c = cal.dateComponents([.year, .month, .day], from: t.date)
            guard c.month == now.month, c.day == now.day, let year = c.year, let thisYear = now.year, year < thisYear,
                  !routine.contains(t.merchant), ![Category.home, .bills, .fees].contains(t.category) else { continue }
            if best == nil || t.amount > best!.charge.amount { best = (thisYear - year, t) }
        }
        return best
    }

    /// Everything that counted as spending in one month: what a bar on a chart stands for.
    func showSpending(in month: Month) {
        showCharges(TransactionFilter(ids: Set(spending(in: month).map(\.id)), title: "Spending in \(month.title)"))
    }

    func showPlace(_ name: String) {
        withAnimation(.snappy(duration: 0.25)) { placeFocus = name }
    }

    /// Two names for one business: everything filed under `other` becomes part of `name` from now on.
    func combinePlaces(_ other: String, into name: String) {
        let target = library.merchants.values.first { $0.name == name }
        var moved = 0
        for (key, info) in library.merchants where info.name == other {
            library.merchants[key]?.name = name
            if let category = target?.category { library.merchants[key]?.category = category }
            library.merchants[key]?.domain = target?.domain ?? info.domain
            library.merchants[key]?.source = .user
            library.merchants[key]?.confirmed = true
            moved += 1
        }
        guard moved > 0 else { return }
        withAnimation(.snappy) { changed() }
        showToast("“\(other)” is now part of \(name).", symbol: "checkmark.circle.fill")
    }

    // MARK: - Tony's own categories

    var customCategories: [CustomCategory] { library.customCategories ?? [] }

    /// Opens the "New Category" sheet; `then` gets the new category (e.g. to apply it right away).
    func newCategory(then: @escaping (Category) -> Void = { _ in }) {
        categoryEditor = CategoryEditorRequest(editing: nil, then: then)
    }

    func isCategoryNameTaken(_ name: String, except id: UUID? = nil) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        if Category.allCases.contains(where: { $0.isBuiltIn && ($0.rawValue.lowercased() == n || $0.displayName.lowercased() == n) }) { return true }
        return customCategories.contains { $0.id != id && $0.name.lowercased() == n }
    }

    /// Creates a category, or updates one (renaming moves everything filed under the old name).
    @discardableResult
    func saveCategory(_ category: CustomCategory) -> Category? {
        var c = category
        c.name = c.name.trimmingCharacters(in: .whitespaces)
        guard !c.name.isEmpty, !isCategoryNameTaken(c.name, except: c.id) else { return nil }
        var list = customCategories
        if let i = list.firstIndex(where: { $0.id == c.id }) {
            let old = Category(list[i].name)
            list[i] = c
            if old.rawValue != c.name { refile(from: old, to: Category(c.name)) }
        } else {
            list.append(c)
        }
        library.customCategories = list
        CustomCategories.set(list)
        aiAttempted.removeAll()   // the AI may now have a better home for unsorted places
        withAnimation(.snappy) { changed() }
        return Category(c.name)
    }

    /// Deletes a custom category; anything filed there goes to "Other".
    func deleteCategory(_ category: CustomCategory) {
        refile(from: Category(category.name), to: .other)
        let list = customCategories.filter { $0.id != category.id }
        library.customCategories = list
        CustomCategories.set(list)
        if transactionFilter.category == Category(category.name) { transactionFilter.category = nil }
        withAnimation(.snappy) { changed() }
        showToast("Deleted \(category.name). Its charges moved to Other.", symbol: "trash.fill")
    }

    private func refile(from old: Category, to new: Category) {
        for key in library.merchants.keys where library.merchants[key]?.category == old { library.merchants[key]?.category = new }
        for i in library.entries.indices where library.entries[i].override == old { library.entries[i].override = new }
    }

    /// All-time totals per category, for the Categories screen.
    func categorySummary() -> [(category: Category, total: Double, count: Int)] {
        let groups = Dictionary(grouping: transactions, by: \.category)
        return Category.allCases.map { c in
            let list = groups[c] ?? []
            return (c, list.reduce(0) { $0 + abs($1.amount) * ($1.amount < 0 && c.isSpending ? -1 : 1) }, list.count)
        }
    }

    // MARK: - Importing statements

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.commaSeparatedText, .plainText, .delimitedText, .pdf, .image, .folder]
            + ["ofx", "qfx", "qbo", "xlsx"].compactMap { UTType(filenameExtension: $0) }
        panel.canChooseDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.prompt = "Add"
        panel.message = "Choose statements downloaded from your bank or card (CSV, PDF, or Quicken files)."
        if panel.runModal() == .OK { importFiles(panel.urls) }
    }

    func importFiles(_ urls: [URL]) {
        Task { await importFilesAsync(urls) }
    }

    /// Called when the app comes to the front: Apple Intelligence may have become available since.
    func retrySorting() {
        let unsorted = library.merchants.values.contains { $0.category == nil }
        let forCloud = CloudAI.isEnabled && library.merchants.values.contains { !$0.confirmed && [.ai, .bank, .generic].contains($0.source) }
        guard !isSuggesting, (aiAvailable && unsorted) || forCloud else { return }
        aiAttempted.removeAll()
        cloudAttempted.removeAll()
        Task { await sortRemaining() }
    }

    /// A dropped folder means "everything in here": look inside (two levels) for statements.
    nonisolated private static func expand(_ urls: [URL]) -> (files: [URL], fromFolder: Set<URL>, orders: [URL]) {
        var files: [URL] = [], fromFolder: Set<URL> = [], orders: [URL] = []
        let fm = FileManager.default

        /// Banks often hand over a year of statements as one zip. Opens it; nil if it isn't one.
        func unzipped(_ url: URL) -> URL? {
            let unpacked = fm.temporaryDirectory.appendingPathComponent("SpendthriftZip-\(UUID().uuidString)", isDirectory: true)
            let unzip = Process()
            unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            unzip.arguments = ["-x", "-k", url.path, unpacked.path]
            unzip.standardOutput = FileHandle.nullDevice; unzip.standardError = FileHandle.nullDevice
            guard (try? unzip.run()) != nil else { return nil }
            unzip.waitUntilExit()
            return unzip.terminationStatus == 0 ? unpacked : nil
        }
        /// Everything readable inside a folder (or an opened zip), a few levels down, zips included.
        func walk(_ folder: URL, depth: Int) {
            // A shop's order-history export isn't a statement: take its order files and leave the rest alone.
            if let found = OrderExport.files(in: folder) { orders += found; return }
            guard depth < 4, let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
            for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where files.count < 500 {
                let name = item.lastPathComponent
                if name.hasPrefix("._") || name == "__MACOSX" { continue }
                let ext = item.pathExtension.lowercased()
                if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                    if ext != "app" { walk(item, depth: depth + 1) }
                } else if ext == "zip" {
                    if let inside = unzipped(item) { walk(inside, depth: depth + 1) }
                } else if StatementReader.extensions.contains(ext) {
                    files.append(item); fromFolder.insert(item)
                }
            }
        }
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { files.append(url); continue }
            if isDirectory.boolValue, url.pathExtension.lowercased() != "app" {
                walk(url, depth: 0)
            } else if url.pathExtension.lowercased() == "zip", let inside = unzipped(url) {
                walk(inside, depth: 0)
            } else if OrderExport.isOrderFile(url) {
                orders.append(url)
            } else {
                files.append(url)
            }
        }
        return (files.sorted { $0.lastPathComponent < $1.lastPathComponent }, fromFolder, orders)
    }

    /// Asks for a locked PDF's password. Nothing is stored: it's used once to open the file.
    private func askPassword(for url: URL) -> String? {
        guard ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] == nil else { return nil }
        let alert = NSAlert()
        alert.messageText = "“\(url.lastPathComponent)” is locked"
        alert.informativeText = "Your bank protected this statement with a password. Type it to open the file. It isn't saved anywhere."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Skip This File")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn && !field.stringValue.isEmpty ? field.stringValue : nil
    }

    /// Turns any failure into a sentence Tony can act on.
    private static func explain(_ error: Error, file: URL) -> String {
        if let e = error as? LocalizedError, let text = e.errorDescription { return text }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, [NSFileReadNoPermissionError, NSFileReadNoSuchFileError].contains(ns.code) {
            return "The file couldn't be opened. It may have been moved, or the app isn't allowed to read that folder."
        }
        return "This file couldn't be read (\(ns.localizedDescription))."
    }

    /// - automatic: the app found these in Downloads by itself. Nothing may interrupt Tony then:
    ///   no password prompt, no column picker, no error sheet. Anything that needs him waits in the banner.
    private func importFilesAsync(_ dropped: [URL], automatic: Bool = false) async {
        let (urls, fromFolder, orderFiles) = Self.expand(dropped)
        if !orderFiles.isEmpty {
            await addOrders(from: orderFiles, quietly: automatic)
            if urls.isEmpty { return }
        }
        var issues: [ImportIssue] = []
        var added = 0, touched: [String] = [], verified = 0, mismatches: [String] = [], scanned = 0
        var batch: (entries: Set<UUID>, accounts: Set<UUID>, hashes: Set<String>) = ([], [], [])
        var attached = 0
        // Statements already read, whose originals were never kept: re-read without the model, only to link them.
        let relink = library.entries.isEmpty ? [] : library.importedHashes.subtracting((library.sources ?? []).map(\.id))
        isImporting = true
        // A pile of statements (or the very first one) gets the full show; one new statement doesn't,
        // and neither do statements that are only coming back so their originals can be kept.
        let fresh = library.entries.isEmpty
        let candidates = urls.filter { StatementReader.extensions.contains($0.pathExtension.lowercased()) }
        let new = relink.isEmpty ? candidates.count : await Task.detached {
            candidates.filter { url in (try? Data(contentsOf: url)).map { !relink.contains(Self.hash($0)) } ?? true }.count
        }.value
        if !automatic, ProcessInfo.processInfo.environment["SPENDTHRIFT_NO_SHOW"] == nil, new >= (fresh ? 1 : 4) {
            stage = .working
        }
        // Read every file first, several at a time: a statement that needs the cloud model takes
        // 10 to 40 seconds, and a year of them shouldn't queue up one behind another.
        typealias Reading = Result<(hash: String, data: Data, outcome: StatementReader.Outcome), Error>
        let readable = urls.enumerated().filter { StatementReader.extensions.contains($0.element.pathExtension.lowercased()) }
        for url in urls where !StatementReader.extensions.contains(url.pathExtension.lowercased()) {
            issues.append(ImportIssue(file: url.lastPathComponent, reason: StatementReader.adviceForUnsupported(url)))
        }
        importProgress = readable.count > 1 ? (0, readable.count) : nil

        /// Files go in the moment they're read, so the screens fill up while the rest are still coming.
        func apply(_ url: URL, _ first: Reading) async {
            var reading = first
            do {
                // Some banks lock statements with a password (often part of an ID number). Ask for it.
                if case .failure(PDFStatement.PDFError.locked) = reading {
                    guard !automatic, let password = askPassword(for: url) else { throw PDFStatement.PDFError.lockedAndSkipped }
                    let data = try Data(contentsOf: url)
                    reading = .success((Self.hash(data), data, try await StatementReader.read(url, data: data, password: password)))
                }
                var (hash, data, outcome) = try reading.get()
                // A statement added before the app kept originals: keep it now and point its charges
                // at it, adding nothing. (If none of its charges are here any more, it's simply new.)
                if relink.contains(hash), case .ready(let statement) = outcome {
                    let (accountID, isNew) = account(for: statement.signature, name: statement.suggestedName)
                    if !isNew {
                        _ = add(statement.rows, to: accountID, source: hash, linkOnly: true)
                        if linkedByLastAdd > 0 {
                            keep(data, hash: hash, url: url, accountID: accountID, rows: statement.rows, check: statement.check)
                            attached += 1
                            return
                        }
                    } else {
                        library.accounts.removeAll { $0.id == accountID }
                    }
                    outcome = try await StatementReader.read(url, data: data)
                }
                switch outcome {
                case .ready(let statement):
                    let (accountID, isNew) = account(for: statement.signature, name: statement.suggestedName)
                    let ids = add(statement.rows, to: accountID, source: hash)
                    keep(data, hash: hash, url: url, accountID: accountID, rows: statement.rows, check: statement.check)
                    if !statement.months.isEmpty, let a = library.accounts.firstIndex(where: { $0.id == accountID }) {
                        library.accounts[a].statementMonths = (library.accounts[a].statementMonths ?? []).union(statement.months)
                    }
                    switch statement.check {
                    case .verified: verified += 1
                    case .mismatch(let sections): mismatches.append("\(url.lastPathComponent) (\(sections))")
                    case .scanned: scanned += 1
                    case .none: break
                    }
                    library.importedHashes.insert(hash)
                    batch.entries.formUnion(ids)
                    batch.hashes.insert(hash)
                    if isNew { batch.accounts.insert(accountID) }
                    added += ids.count
                    if let name = accounts.first(where: { $0.id == accountID })?.name, !touched.contains(name) { touched.append(name) }
                    if !ids.isEmpty {
                        withAnimation(.snappy) { changed() }
                        if selection == nil { selection = .overview }
                        Task { await sortRemaining() }
                    }
                case .needsMapping(let table, let signature, let name):
                    guard !automatic else { throw StatementReader.ReadError.notAStatement }
                    pendingImports.append(PendingImport(fileURL: url, fileHash: hash, table: table, mapping: nil,
                                                        candidates: accounts.filter { $0.signature == signature },
                                                        suggestedName: name, signature: signature))
                }
            } catch {
                // Inside a dropped folder, files that aren't statements (a tax form, a receipt) are just skipped.
                if !(fromFolder.contains(url) && url.pathExtension.lowercased() == "pdf") {
                    issues.append(ImportIssue(file: url.lastPathComponent, reason: Self.explain(error, file: url)))
                }
            }
        }

        await withTaskGroup(of: (Int, Reading).self) { group in
            var next = 0
            func startNext() {
                guard next < readable.count else { return }
                let (index, url) = readable[next]
                next += 1
                group.addTask {
                    do {
                        let data = try Data(contentsOf: url)
                        let hash = Self.hash(data)
                        if relink.contains(hash), let outcome = try? await CloudAI.$offline.withValue(true, operation: { try await StatementReader.read(url, data: data) }) {
                            return (index, .success((hash, data, outcome)))
                        }
                        let outcome = try await StatementReader.read(url, data: data)
                        return (index, .success((hash, data, outcome)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            // Reading is mostly waiting (on the disk, or on the model for a statement that needs it),
            // so many at once costs little and a year of statements arrives several times sooner.
            for _ in 0..<24 { startNext() }
            for await (index, reading) in group {
                if let progress = importProgress { importProgress = (progress.done + 1, progress.total) }
                await apply(urls[index], reading)
                startNext()
            }
        }
        joinReissuedCards()
        importProgress = nil
        isImporting = false
        if added > 0 { Task { await rematchOrders() } }
        if dropped.count > 0, urls.isEmpty {
            issues.append(ImportIssue(file: dropped[0].lastPathComponent, reason: "There were no statements in that folder."))
        }
        if !issues.isEmpty, !automatic { importIssues = issues }
        if ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] != nil {
            print("DEBUG IMPORT files \(urls.count) added \(added) verified \(verified) scanned \(scanned) mismatched \(mismatches) issues \(issues.count)")
        }
        if !touched.isEmpty, added > 0 || !automatic {
            lastImport = batch
            withAnimation(.snappy) { changed() }
            showImportToast(added: added, accounts: touched, verified: verified, mismatches: mismatches, scanned: scanned,
                            automatic: automatic)
            if selection == nil { selection = .overview }
            Task { await sortRemaining() }
            if automatic {
                Notifier.post(title: "New statement added",
                              body: "\(added) \(added == 1 ? "transaction" : "transactions") from \(touched.joined(separator: ", ")), sorted and ready.")
            }
        } else if !touched.isEmpty {
            changed()   // nothing new in them, but remember we've seen these files
        }
        if attached > 0 {
            changed()
            if ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] != nil { print("DEBUG ATTACHED \(attached) originals; charges without one: \(chargesWithoutOriginal)") }
            if added == 0, !automatic {
                showToast("Kept \(attached == 1 ? "the original" : "\(attached) originals"). Any charge can now be shown in its statement.", symbol: "doc.text.magnifyingglass")
            }
        }
        refreshDownloads()
    }

    /// Called from the pick-the-columns sheet (only for files the app couldn't read by itself).
    func completeImport(_ pending: PendingImport, existingAccount: UUID?, newName: String, mapping: ColumnMapping) {
        pendingImports.removeAll { $0.id == pending.id }
        let rows = Normalizer.rows(from: pending.table, mapping: mapping).rows
        var isNew = false
        let accountID: UUID
        if let existingAccount {
            accountID = existingAccount
        } else {
            let name = newName.trimmingCharacters(in: .whitespaces)
            let account = Account(name: uniqueAccountName(name.isEmpty ? "Account" : name), signature: pending.signature)
            library.accounts.append(account)
            accountID = account.id
            isNew = true
        }
        let ids = add(rows, to: accountID, source: pending.fileHash)
        if let data = try? Data(contentsOf: pending.fileURL) { keep(data, hash: pending.fileHash, url: pending.fileURL, accountID: accountID, rows: rows) }
        library.importedHashes.insert(pending.fileHash)
        lastImport = (ids, isNew ? [accountID] : [], [pending.fileHash])
        withAnimation(.snappy) { changed() }
        showImportToast(added: ids.count, accounts: [accounts.first { $0.id == accountID }?.name ?? ""])
        Task { await sortRemaining() }
        refreshDownloads()
    }

    func cancelImport(_ pending: PendingImport) {
        pendingImports.removeAll { $0.id == pending.id }
    }

    func undoLastImport() {
        guard let last = lastImport else { return }
        lastImport = nil
        library.entries.removeAll { last.entries.contains($0.id) }
        library.accounts.removeAll { id in last.accounts.contains(id.id) && !library.entries.contains { $0.accountID == id.id } }
        library.importedHashes.subtract(last.hashes)
        forgetSources { last.hashes.contains($0.id) }
        // He took it back out: don't quietly add it again from Downloads.
        library.dismissedDownloads.formUnion(last.hashes)
        pruneUnusedPlaces()
        withAnimation(.snappy) { changed() }
        showToast("Removed. Nothing from that file was kept.", symbol: "arrow.uturn.backward.circle.fill")
        refreshDownloads()
    }

    /// Finds the account a file belongs to, or makes one. Never asks.
    /// When a card is replaced, the bank gives it new last digits and its statements look like a new
    /// account. Two cards from the same bank where one stops just as the other starts are one card:
    /// their histories are joined under the newest number, and the old numbers keep leading here.
    private func joinReissuedCards() {
        var joined = false
        while true {
            // (Dates are kept as yyyy-MM-dd text, which sorts correctly as text.)
            // "first" is where the account really gets going (its 5th percentile), because a new card's
            // first statement often carries a few refunds dated months before the card existed.
            var dates: [UUID: [String]] = [:]
            for entry in library.entries { dates[entry.accountID, default: []].append(entry.date) }
            var ranges: [UUID: (first: Date, last: Date)] = [:]
            for (id, unsorted) in dates {
                let list = unsorted.sorted()
                if let first = DateParsing.parse(list[list.count / 20], format: "yyyy-MM-dd"),
                   let last = DateParsing.parse(list[list.count - 1], format: "yyyy-MM-dd") { ranges[id] = (first, last) }
            }
            let cards = library.accounts.filter { $0.signature.hasPrefix("pdf:") && Self.issuer(in: $0.name) != nil && !$0.name.contains("Checking") && !$0.name.contains("Savings") }
            var pair: (old: Account, new: Account)?
            search: for older in cards {
                for newer in cards where newer.id != older.id && Self.issuer(in: newer.name) == Self.issuer(in: older.name) {
                    guard let a = ranges[older.id], let b = ranges[newer.id], a.first < b.first else { continue }
                    // The old one's last charge and the new one's first are within a few weeks of each other,
                    // and the two barely overlap (charges posted around the changeover).
                    let gap = b.first.timeIntervalSince(a.last) / 86_400
                    if gap > -12, gap < 45 { pair = (older, newer); break search }
                }
            }
            guard let pair, let keep = library.accounts.firstIndex(where: { $0.id == pair.new.id }) else { break }
            for i in library.entries.indices where library.entries[i].accountID == pair.old.id { library.entries[i].accountID = pair.new.id }
            for i in (library.sources ?? []).indices where library.sources![i].accountID == pair.old.id { library.sources![i].accountID = pair.new.id }
            library.accounts[keep].formerSignatures = (library.accounts[keep].formerSignatures ?? []) + [pair.old.signature] + (pair.old.formerSignatures ?? [])
            library.accounts[keep].statementMonths = (library.accounts[keep].statementMonths ?? []).union(pair.old.statementMonths ?? [])
            library.accounts.removeAll { $0.id == pair.old.id }
            joined = true
        }
        if joined { changed() }
    }

    private func account(for signature: String, name: String) -> (UUID, isNew: Bool) {
        if let exact = accounts.first(where: { $0.signature == signature }) { return (exact.id, false) }
        if let former = accounts.first(where: { $0.formerSignatures?.contains(signature) == true }) { return (former.id, false) }
        // Same file shape, and one side doesn't know its card digits: treat as the same account.
        let base = { (s: String) in s.components(separatedBy: "|#")[0] }
        let digits = { (s: String) in s.components(separatedBy: "|#").dropFirst().first }
        let related = accounts.filter { base($0.signature) == base(signature) && (digits($0.signature) == nil || digits(signature) == nil) }
        if !signature.hasPrefix("pdf:"), !signature.hasPrefix("ofx:"),
           let match = related.max(by: { ($0.lastImport ?? .distantPast) < ($1.lastImport ?? .distantPast) }) {
            return (match.id, false)
        }
        // The same card or account arriving in a different format (a CSV one month, a PDF the next):
        // same bank and same last four digits means same account.
        if let issuer = Self.issuer(in: name), let four = Self.digits(ofSignature: signature) ?? Self.digits(inName: name),
           let same = accounts.first(where: {
               Self.issuer(in: $0.name) == issuer && (Self.digits(ofSignature: $0.signature) ?? Self.digits(inName: $0.name)) == four
           }) {
            return (same.id, false)
        }
        let account = Account(name: uniqueAccountName(name), signature: signature)
        library.accounts.append(account)
        return (account.id, true)
    }

    private static func digits(ofSignature s: String) -> String? {
        let last: String?
        if s.hasPrefix("pdf:") || s.hasPrefix("ofx:") { last = s.components(separatedBy: ":").last }
        else { last = s.components(separatedBy: "|#").dropFirst().first }
        guard let d = last, d.count >= 4, d.allSatisfy(\.isNumber) else { return nil }
        return String(d.suffix(4))
    }
    private static func digits(inName name: String) -> String? {
        guard let r = name.range(of: #"••(\d{4})"#, options: .regularExpression) else { return nil }
        return String(name[r].suffix(4))
    }

    /// Adds lines the account doesn't already have, and sorts each one on the spot.
    /// Identical lines that legitimately repeat (two $5 coffees in a day) are kept:
    /// only as many copies are skipped as the account already holds.
    /// - source: the kept original these rows were read from; lines already held are pointed at it too.
    /// - linkOnly: add nothing; only point the lines already held at their original.
    private func add(_ rows: [CanonicalRow], to accountID: UUID, source: String? = nil, linkOnly: Bool = false) -> Set<UUID> {
        linkedByLastAdd = 0
        guard let a = library.accounts.firstIndex(where: { $0.id == accountID }) else { return [] }
        let kept = Set((library.sources ?? []).map(\.id)).union(source.map { [$0] } ?? [])
        // What the account already holds, by day and amount. A line counts as already there if the
        // text matches exactly, or closely: the same charge reads "AMAZON MKTPL*AB12" in a CSV and
        // "AMAZON MKTPL*AB12 SEATTLE WA" in the PDF of the same statement.
        struct Held { let index: Int; let exact: String; let loose: String; var used = false }
        let loose = { (d: String) in String(d.uppercased().filter { $0.isLetter || $0.isNumber }) }
        var held: [String: [Held]] = [:]
        for (i, e) in library.entries.enumerated() where e.accountID == accountID {
            held["\(e.date)|\(String(format: "%.2f", e.amount))", default: []].append(Held(index: i, exact: e.description.uppercased(), loose: loose(e.description)))
        }
        func alreadyHeld(_ entry: LedgerEntry) -> Int? {
            let bucket = "\(entry.date)|\(String(format: "%.2f", entry.amount))"
            guard var list = held[bucket] else { return nil }
            let exact = entry.description.uppercased(), mine = loose(entry.description)
            let index = list.firstIndex { !$0.used && $0.exact == exact }
                ?? list.firstIndex { other in
                    guard !other.used, mine.count >= 6, other.loose.count >= 6 else { return false }
                    return other.loose.hasPrefix(mine.prefix(10)) || mine.hasPrefix(other.loose.prefix(10))
                        || other.loose.contains(mine) || mine.contains(other.loose)
                }
            guard let index else { return nil }
            list[index].used = true
            held[bucket] = list
            return list[index].index
        }
        var keyCache: [String: String] = [:]
        var ids: Set<UUID> = []
        for row in rows {
            let amount = library.accounts[a].invertAmounts == true ? -row.amount : row.amount
            let key: String
            // The same wording can be two different things depending on direction (a fund paying out vs calling capital).
            let cacheKey = (amount > 0 ? "+" : "-") + row.description
            if let cached = keyCache[cacheKey] { key = cached }
            else {
                key = MerchantResolver.key(for: row.description, amount: amount, existingKeys: library.merchants.keys)
                keyCache[cacheKey] = key
            }
            var entry = LedgerEntry(accountID: accountID, date: row.date, description: row.description, amount: amount,
                                    bankCategory: row.bankCategory, merchantKey: key)
            entry.sourceID = source
            if let existing = alreadyHeld(entry) {
                // Already here: remember which original it can be seen in, unless it has one.
                if let source, library.entries[existing].sourceID.map({ !kept.contains($0) }) ?? true {
                    library.entries[existing].sourceID = source
                    linkedByLastAdd += 1
                }
                continue
            }
            if linkOnly { continue }
            if library.merchants[key] == nil {
                library.merchants[key] = MerchantResolver.instant(description: row.description, amount: amount,
                                                                  bankCategory: row.bankCategory)
            }
            library.entries.append(entry)
            ids.insert(entry.id)
        }
        if !linkOnly { library.accounts[a].lastImport = .now }
        return ids
    }

    /// Keeps the file itself, so its charges can be shown in the original later.
    private func keep(_ data: Data, hash: String, url: URL, accountID: UUID, rows: [CanonicalRow], check: StatementCheck = .none) {
        let ext = url.pathExtension.lowercased()
        var source = SourceFile(id: hash, name: url.lastPathComponent, ext: ext.isEmpty ? "txt" : ext, accountID: accountID, added: .now,
                                rows: rows.count, firstDate: rows.map(\.date).min(), lastDate: rows.map(\.date).max(), check: nil)
        if source.isPDF {
            let period = PDFStatement.period(ofPDF: data)
            source.periodStart = period?.start ?? ""; source.periodEnd = period?.end ?? ""
        }
        switch check {
        case .verified: source.check = "verified"
        case .mismatch: source.check = "mismatch"
        case .scanned: source.check = "scanned"
        case .none: break
        }
        try? FileManager.default.createDirectory(at: paths.statementsFolder, withIntermediateDirectories: true)
        let target = paths.statementFile(source)
        if !FileManager.default.fileExists(atPath: target.path) {
            guard (try? data.write(to: target, options: .atomic)) != nil else { return }
        }
        var list = library.sources ?? []
        list.removeAll { $0.id == hash }
        list.append(source)
        library.sources = list
    }

    private func forgetSources(_ gone: (SourceFile) -> Bool) {
        for source in (library.sources ?? []).filter(gone) { try? FileManager.default.removeItem(at: paths.statementFile(source)) }
        library.sources?.removeAll(where: gone)
    }

    // MARK: - Originals

    /// Every kept statement, newest period first.
    var sourceFiles: [SourceFile] { (library.sources ?? []).sorted { ($0.lastDate ?? "", $0.name) > ($1.lastDate ?? "", $1.name) } }
    func sourceURL(_ source: SourceFile) -> URL { paths.statementFile(source) }
    /// Charges that came into the app before originals were kept, and have nothing to show yet.
    var chargesWithoutOriginal: Int {
        let all = library.sources ?? []
        let kept = Set(all.map(\.id))
        // A charge not tied to one file still counts as covered when a kept statement of its account spans its day.
        var spans: [UUID: [(String, String)]] = [:]
        for s in all { if let a = s.accountID, let f = s.firstDate, let l = s.lastDate { spans[a, default: []].append((f, l)) } }
        return library.entries.filter { e in
            if let id = e.sourceID, kept.contains(id) { return false }
            return !(spans[e.accountID] ?? []).contains { $0.0 <= e.date && e.date <= $0.1 }
        }.count
    }
    func entry(_ id: UUID) -> LedgerEntry? { library.entries.first { $0.id == id } }
    func entries(in source: SourceFile) -> [LedgerEntry] { library.entries.filter { $0.sourceID == source.id } }

    /// The originals a charge might be in: the one it was read from, else every statement of its
    /// account that spans its date (the finder then looks for the charge in each).
    func sourceCandidates(for entry: LedgerEntry) -> [SourceFile] {
        let all = library.sources ?? []
        if let id = entry.sourceID, let exact = all.first(where: { $0.id == id }) { return [exact] }
        guard let day = DateParsing.parse(entry.date, format: "yyyy-MM-dd") else { return [] }
        let iso = { (d: Date) in DateParsing.iso.string(from: d) }
        let early = iso(day.addingTimeInterval(-6 * 86_400)), late = iso(day.addingTimeInterval(6 * 86_400))
        return all.filter { $0.accountID == entry.accountID && ($0.firstDate ?? "9") <= late && ($0.lastDate ?? "0") >= early }
            .sorted { $0.isPDF && !$1.isPDF }
    }

    /// Opens the original over the window, at the line this charge was read from.
    func showOriginal(of id: Transaction.ID) {
        guard let entry = entry(id) else { return }
        if sourceCandidates(for: entry).isEmpty {
            showToast((library.sources ?? []).isEmpty
                      ? "This was added before the app kept originals. Drop your statements in again and every charge will link to its statement."
                      : "The statement this came from isn't here. Drop it in again and the link appears.", symbol: "doc.questionmark")
            return
        }
        originalPeek = OriginalPeek(entryID: id)
    }

    /// Opens the Statements page on one file (and, optionally, one charge in it).
    func browse(_ source: SourceFile, charge: UUID? = nil) {
        originalPeek = nil
        statementFocus = StatementFocus(sourceID: source.id, entryID: charge)
        selection = .statements
    }

    private func showImportToast(added: Int, accounts names: [String], verified: Int = 0, mismatches: [String] = [], scanned: Int = 0,
                                 automatic: Bool = false) {
        let where_ = names.joined(separator: ", ")
        if automatic, mismatches.isEmpty, scanned == 0 {
            showToast("Found a new statement in Downloads and added \(added) \(added == 1 ? "transaction" : "transactions") to \(where_).",
                      symbol: "sparkles", offersUndo: true)
            return
        }
        if scanned > 0, added > 0, mismatches.isEmpty {
            showToast("Added \(added) transactions to \(where_). \(scanned == 1 ? "One file was" : "\(scanned) files were") read from a picture, so give the amounts a quick look.",
                      symbol: "text.viewfinder", offersUndo: true)
            return
        }
        if !mismatches.isEmpty {
            // The statement prints its own totals; ours didn't add up to them. Say so rather than hide it.
            showToast("Added \(added) transactions, but the totals don't match the statement for: \(mismatches.joined(separator: "; ")). Worth a look.",
                      symbol: "exclamationmark.triangle.fill", offersUndo: true)
        } else if added > 0, verified > 0 {
            showToast("Added \(added) transactions to \(where_). Totals match the \(verified == 1 ? "statement" : "statements") to the cent.",
                      symbol: "checkmark.seal.fill", offersUndo: true)
        } else if added == 0 {
            showToast("\(where_) is already up to date. Nothing new in that file.", symbol: "checkmark.circle.fill")
        } else {
            showToast("Added \(added) \(added == 1 ? "transaction" : "transactions") to \(where_).",
                      symbol: "tray.and.arrow.down.fill", offersUndo: true)
        }
    }

    private func uniqueAccountName(_ base: String) -> String {
        var name = base, n = 2
        while accounts.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            name = "\(base) \(n)"; n += 1
        }
        return name
    }

    private func pruneUnusedPlaces() {
        let used = Set(library.entries.map(\.merchantKey))
        library.merchants = library.merchants.filter { used.contains($0.key) || $0.value.confirmed }
    }

    nonisolated private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A copy of everything, for peace of mind or for moving to another Mac.
    func backUpToDesktop() {
        saveNow()
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let target = desktop.appendingPathComponent("Spendthrift Backup \(DateParsing.iso.string(from: .now)).json")
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.copyItem(at: paths.libraryFile, to: target)
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } catch {
            showToast("Couldn't save the backup: \(error.localizedDescription)", symbol: "exclamationmark.triangle.fill")
        }
    }

    // MARK: - Accounts

    func renameAccount(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let i = library.accounts.firstIndex(where: { $0.id == id }), library.accounts[i].name != trimmed else { return }
        library.accounts[i].name = trimmed
        changed()
    }

    func removeAccount(_ id: UUID) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        library.entries.removeAll { $0.accountID == id }
        library.accounts.removeAll { $0.id == id }
        // Its statements go too, and may be added again later as if never seen.
        library.importedHashes.subtract((library.sources ?? []).filter { $0.accountID == id }.map(\.id))
        forgetSources { $0.accountID == id }
        pruneUnusedPlaces()
        withAnimation(.snappy) { changed() }
        showToast("Removed \(account.name).", symbol: "trash.fill")
        refreshDownloads()
    }

    /// For the rare export where purchases and payments came in backwards.
    func flipAmounts(_ id: UUID) {
        guard let a = library.accounts.firstIndex(where: { $0.id == id }) else { return }
        library.accounts[a].invertAmounts = !(library.accounts[a].invertAmounts ?? false)   // future statements too
        for i in library.entries.indices where library.entries[i].accountID == id { library.entries[i].amount.negate() }
        withAnimation(.snappy) { changed() }
        showToast("Flipped. Purchases and payments are swapped for this account.", symbol: "arrow.up.arrow.down")
    }

    func transactionCount(for account: Account) -> Int {
        transactions.filter { $0.accountID == account.id }.count
    }

    func spent(in account: Account) -> Double {
        transactions.filter { $0.accountID == account.id && $0.countsAsSpending }.reduce(0) { $0 + $1.amount }
    }

    func dateRange(for account: Account) -> ClosedRange<Date>? {
        let dates = transactions.filter { $0.accountID == account.id }.map(\.date)
        guard let lo = dates.min(), let hi = dates.max() else { return nil }
        return lo...hi
    }

    // MARK: - Downloads folder

    /// Looks for new statements in Downloads, off the main thread (the first look may wait
    /// on macOS's "allow access to Downloads?" prompt, and reading files takes a moment).
    func refreshDownloads() {
        guard ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] == nil else { return }
        let known = library.importedHashes.union(library.dismissedDownloads)
        Task.detached(priority: .utility) {
            let found = Self.scanDownloads(excluding: known)
            await MainActor.run { self.foundInDownloads(found) }
        }
    }

    /// New statements are simply added (Tony can undo). Only ones that need him, such as a locked
    /// PDF, wait in the "New in your Downloads" banner.
    private func foundInDownloads(_ found: [URL]) {
        guard Self.addsDownloadsAutomatically else { downloadCandidates = Array(found.prefix(5)); return }
        let fresh = found.filter { !autoAttempted.contains($0) }
        downloadCandidates = Array(found.filter { autoAttempted.contains($0) }.prefix(5))
        guard !fresh.isEmpty, !isImporting else { return }
        autoAttempted.formUnion(fresh)
        Task { await importFilesAsync(fresh, automatic: true) }
    }

    static var addsDownloadsAutomatically: Bool {
        get { UserDefaults.standard.object(forKey: "addsDownloadsAutomatically") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "addsDownloadsAutomatically") }
    }

    /// Watches the Downloads folder while the app is open, so a statement saved from the bank's
    /// website shows up in the app a few seconds later without Tony doing anything.
    func watchDownloads() {
        guard downloadsWatcher == nil, ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] == nil,
              let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.downloadsDebounce?.cancel()
                self.downloadsDebounce = Task {
                    try? await Task.sleep(for: .seconds(4))      // let the browser finish writing the file
                    guard !Task.isCancelled else { return }
                    self.refreshDownloads()
                }
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        downloadsWatcher = source
    }

    nonisolated private static func scanDownloads(excluding known: Set<String>) -> [URL] {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
              let items = try? FileManager.default.contentsOfDirectory(
                at: downloads, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles])
        else { return [] }
        let cutoff = Date.now.addingTimeInterval(-60 * 24 * 3600)
        return items
            .compactMap { url -> (URL, Date)? in
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return date > cutoff ? (url, date) : nil
            }
            .filter { url, _ in
                switch url.pathExtension.lowercased() {
                case "csv", "ofx", "qfx", "qbo", "xlsx": return true
                // Judge PDFs by their first page, not their name: Amex calls them "2026-11-03.pdf",
                // and a "closing-statement.pdf" from a home purchase isn't a bank statement.
                case "pdf": return PDFStatement.looksLikeStatement(url)
                default: return false
                }
            }
            .filter { url, _ in
                guard let data = try? Data(contentsOf: url) else { return false }
                return !known.contains(hash(data))
            }
            .sorted { $0.1 > $1.1 }
            .prefix(60)
            .map(\.0)
    }

    func dismissDownload(_ url: URL) {
        if let data = try? Data(contentsOf: url) { library.dismissedDownloads.insert(Self.hash(data)) }
        changed()
        withAnimation { downloadCandidates.removeAll { $0 == url } }
    }

    func importAllDownloads() {
        importFiles(downloadCandidates)
    }

    // MARK: - Daily Tony, insights

    /// Recent purchases for Daily Tony: one per place, from the last two weeks of data.
    func recentHighlights() -> [DailyPicture.Highlight] {
        let spending = transactions.filter { $0.countsAsSpending && $0.amount >= 3 && $0.category != .unsorted }
        guard let latest = spending.last?.date else { return [] }
        let cutoff = latest.addingTimeInterval(-14 * 24 * 3600)
        var seen: Set<String> = []
        return spending.filter { $0.date >= cutoff }.reversed().compactMap { t in
            guard seen.insert(t.merchant).inserted else { return nil }
            return DailyPicture.Highlight(merchant: t.merchant, category: t.category, amount: t.amount, date: t.date)
        }
    }

    /// What was bought on this day in an earlier year, and on tomorrow's: the subjects of the
    /// daily picture, today's first. Empty until there is more than a year of statements.
    func memoryHighlights(_ now: Date = .now) -> [DailyPicture.Highlight] {
        [now, now.addingTimeInterval(86_400)].compactMap { day in
            guard let t = onThisDay(day)?.charge else { return nil }
            let trip = story(containing: t.id).flatMap { $0.kind == .trip ? $0 : nil }
            return DailyPicture.Highlight(merchant: t.merchant, category: t.category, amount: t.amount, date: t.date,
                                          trip: trip?.name, tripPlace: trip?.place, entry: t.id)
        }
    }

    /// Charges from trips of the last two years that would make a good picture: for each trip, its
    /// larger charges at places with a name (not the airline or the card's foreign fee).
    func tripHighlights() -> [DailyPicture.Highlight] {
        guard let latest = transactions.last?.date else { return [] }
        let cutoff = latest.addingTimeInterval(-730 * 86_400)
        var out: [DailyPicture.Highlight] = []
        for story in stories where story.kind == .trip {
            let dull = ["withdrawal", "atm", "fee", "payment", "transfer", "unknown"]
            let charges = transactions(in: story).filter { t in
                t.countsAsSpending && t.amount >= 5 && t.date >= cutoff && t.category != .fees && !dull.contains { t.merchant.lowercased().contains($0) }
            }
            var seen: Set<String> = []
            for t in charges.sorted(by: { $0.amount > $1.amount }) where seen.insert(t.merchant).inserted {
                out.append(DailyPicture.Highlight(merchant: t.merchant, category: t.category, amount: t.amount, date: t.date, trip: story.name, tripPlace: story.place))
                if seen.count >= 4 { break }
            }
        }
        return out
    }

    /// Tells the person, once, about anything new worth knowing in the latest month: a price that
    /// went up, a new repeating charge, what looks like a double charge. Only while they're elsewhere
    /// (the notifier stays quiet when the app is in front), and never the same thing twice.
    func announceNewFindings() {
        guard let latest = months.last else { return }
        var told = Set(UserDefaults.standard.stringArray(forKey: "announcedFindings") ?? [])
        let worth: [Insight.Kind] = [.priceIncrease, .duplicate, .newSubscription, .unusual]
        let fresh = insights(for: latest).filter { worth.contains($0.kind) && !told.contains($0.id) }
        // The first time through (a library just imported), remember everything quietly: nobody
        // wants forty notifications about the past.
        let firstTime = UserDefaults.standard.object(forKey: "announcedFindings") == nil
        for insight in fresh.prefix(firstTime ? 0 : 2) {
            Notifier.post(title: insight.title, body: insight.detail)
        }
        told.formUnion(fresh.map(\.id))
        UserDefaults.standard.set(Array(told.suffix(500)), forKey: "announcedFindings")
    }

    func insights(for month: Month) -> [Insight] {
        InsightEngine.insights(for: month, in: transactions).filter { !library.dismissedInsights.contains($0.id) }
    }

    func dismissInsight(_ insight: Insight) {
        withAnimation { _ = library.dismissedInsights.insert(insight.id) }
        changed()
    }

    func subscriptions() -> [Subscription] {
        guard let last = months.last else { return [] }
        return InsightEngine.subscriptions(asOf: last, in: transactions)
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

    func income(in month: Month) -> Double {
        transactions.filter { $0.isIncome && $0.month == month }.reduce(0) { $0 + abs($1.amount) }
    }
}
