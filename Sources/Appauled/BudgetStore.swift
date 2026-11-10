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
    var selection: SidebarItem? = .overview { didSet { if placeFocus != nil { placeFocus = nil } } }
    /// Non-nil while one place's page is open over whatever page was showing.
    var placeFocus: String?
    /// The question pane on the right, available from every page.
    var showsAsk = false
    var transactionFilter = TransactionFilter()
    /// The Overview looks at one month or at a whole year; the same page either way.
    var overviewShowsYear = ProcessInfo.processInfo.environment["APPAULED_YEAR"] != nil
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
        var coverage: [String: CardCoverage] = [:]

        var list: [Transaction] = []
        list.reserveCapacity(library.entries.count)
        for e in library.entries {
            guard let date = date(e.date) else { continue }
            let info = library.merchants[e.merchantKey]
            let unchecked = info?.isUnconfirmedGuess ?? true
            var category = e.override ?? info?.category ?? .unsorted
            if category == .transfer, e.override == nil, e.amount > 0, cardAccount[e.accountID] == nil,
               let name = info?.name, name.hasSuffix("Card Payment") {
                // A payment that doesn't say which card ("ONLINE PAYMENT") is matched against any card added.
                let issuer = Self.issuer(in: name) ?? "Other cards"
                let d = day(date)
                let days = issuer == "Other cards" ? cardDays.values.reduce(into: Set<Int>()) { $0.formUnion($1) } : (cardDays[issuer] ?? [])
                // A payment settles the statement that closed two to four weeks earlier, so look for
                // that card's purchases 15 to 50 days back.
                let covered = (15...50).contains { days.contains(d - $0) }
                var c = coverage[issuer] ?? CardCoverage(issuer: issuer)
                c.paid += e.amount; c.payments += 1
                if !covered { c.uncoveredPaid += e.amount; c.uncoveredPayments += 1; category = .uncoveredCards }
                coverage[issuer] = c
            }
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
    private func sortRemaining() async {
        guard !isSuggesting else { return }
        isSuggesting = true
        defer {
            isSuggesting = false
            // Once everything has a category, look for the trips and events in it, and find logos.
            Task { await findStoriesIfNeeded() }
            Task { await findLogosIfNeeded() }
        }
        // With a cloud key, the powerful model decides everything the built-in list doesn't know.
        if CloudAI.isEnabled { await sortWithCloud() }
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
                item.notes = entries.compactMap(\.note).filter { !$0.isEmpty }.suffix(4).map { String($0.prefix(200)) }
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
                        group.addTask { (batch, await CloudSorter.sort(batch, examples: examples)) }
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
            let name = keys.count == 1 ? chosen[0].merchant : "\(keys.count) places"
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
        if !trimmed.isEmpty, library.merchants[key]?.confirmed == false, CloudAI.isEnabled {
            relearnKeys.insert(key)
            cloudAttempted.remove(key)
            Task { await sortRemaining() }
        }
    }

    /// Opens the page for one place: everything ever spent there.
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
    nonisolated private static func expand(_ urls: [URL]) -> (files: [URL], fromFolder: Set<URL>) {
        var files: [URL] = [], fromFolder: Set<URL> = []
        let fm = FileManager.default
        for url in urls {
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { files.append(url); continue }
            guard isDirectory.boolValue, url.pathExtension.lowercased() != "app" else { files.append(url); continue }
            let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let item = walker?.nextObject() as? URL {
                if (walker?.level ?? 0) > 2 { walker?.skipDescendants(); continue }
                if StatementReader.extensions.contains(item.pathExtension.lowercased()) { files.append(item); fromFolder.insert(item) }
                if files.count >= 500 { break }
            }
        }
        return (files.sorted { $0.lastPathComponent < $1.lastPathComponent }, fromFolder)
    }

    /// Asks for a locked PDF's password. Nothing is stored: it's used once to open the file.
    private func askPassword(for url: URL) -> String? {
        guard ProcessInfo.processInfo.environment["APPAULED_SNAPSHOT"] == nil else { return nil }
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
        let (urls, fromFolder) = Self.expand(dropped)
        var issues: [ImportIssue] = []
        var added = 0, touched: [String] = [], verified = 0, mismatches: [String] = [], scanned = 0
        var batch: (entries: Set<UUID>, accounts: Set<UUID>, hashes: Set<String>) = ([], [], [])
        isImporting = true
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
                let (hash, _, outcome) = try reading.get()
                switch outcome {
                case .ready(let statement):
                    let (accountID, isNew) = account(for: statement.signature, name: statement.suggestedName)
                    let ids = add(statement.rows, to: accountID)
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
                        let outcome = try await StatementReader.read(url, data: data)
                        return (index, .success((Self.hash(data), data, outcome)))
                    } catch {
                        return (index, .failure(error))
                    }
                }
            }
            for _ in 0..<8 { startNext() }
            for await (index, reading) in group {
                if let progress = importProgress { importProgress = (progress.done + 1, progress.total) }
                await apply(urls[index], reading)
                startNext()
            }
        }
        joinReissuedCards()
        importProgress = nil
        isImporting = false
        if dropped.count > 0, urls.isEmpty {
            issues.append(ImportIssue(file: dropped[0].lastPathComponent, reason: "There were no statements in that folder."))
        }
        if !issues.isEmpty, !automatic { importIssues = issues }
        if ProcessInfo.processInfo.environment["APPAULED_SNAPSHOT"] != nil {
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
        let ids = add(rows, to: accountID)
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
    private func add(_ rows: [CanonicalRow], to accountID: UUID) -> Set<UUID> {
        guard let a = library.accounts.firstIndex(where: { $0.id == accountID }) else { return [] }
        // What the account already holds, by day and amount. A line counts as already there if the
        // text matches exactly, or closely: the same charge reads "AMAZON MKTPL*AB12" in a CSV and
        // "AMAZON MKTPL*AB12 SEATTLE WA" in the PDF of the same statement.
        struct Held { let exact: String; let loose: String; var used = false }
        let loose = { (d: String) in String(d.uppercased().filter { $0.isLetter || $0.isNumber }) }
        var held: [String: [Held]] = [:]
        for e in library.entries where e.accountID == accountID {
            held["\(e.date)|\(String(format: "%.2f", e.amount))", default: []].append(Held(exact: e.description.uppercased(), loose: loose(e.description)))
        }
        func alreadyHeld(_ entry: LedgerEntry) -> Bool {
            let bucket = "\(entry.date)|\(String(format: "%.2f", entry.amount))"
            guard var list = held[bucket] else { return false }
            let exact = entry.description.uppercased(), mine = loose(entry.description)
            let index = list.firstIndex { !$0.used && $0.exact == exact }
                ?? list.firstIndex { other in
                    guard !other.used, mine.count >= 6, other.loose.count >= 6 else { return false }
                    return other.loose.hasPrefix(mine.prefix(10)) || mine.hasPrefix(other.loose.prefix(10))
                        || other.loose.contains(mine) || mine.contains(other.loose)
                }
            guard let index else { return false }
            list[index].used = true
            held[bucket] = list
            return true
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
            let entry = LedgerEntry(accountID: accountID, date: row.date, description: row.description, amount: amount,
                                    bankCategory: row.bankCategory, merchantKey: key)
            if alreadyHeld(entry) { continue }
            if library.merchants[key] == nil {
                library.merchants[key] = MerchantResolver.instant(description: row.description, amount: amount,
                                                                  bankCategory: row.bankCategory)
            }
            library.entries.append(entry)
            ids.insert(entry.id)
        }
        library.accounts[a].lastImport = .now
        return ids
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
        let target = desktop.appendingPathComponent("Appauled Backup \(DateParsing.iso.string(from: .now)).json")
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
        guard ProcessInfo.processInfo.environment["APPAULED_SNAPSHOT"] == nil else { return }
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
        guard downloadsWatcher == nil, ProcessInfo.processInfo.environment["APPAULED_SNAPSHOT"] == nil,
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
