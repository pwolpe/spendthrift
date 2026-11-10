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
    @ObservationIgnored private var spendingByMonth: [Month: [Transaction]] = [:]
    @ObservationIgnored private var dateCache: [String: Date] = [:]

    // UI state
    var selection: SidebarItem? = .overview
    var transactionFilter = TransactionFilter()
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
    /// Kept for views that wait on the first load; the library loads instantly at launch.
    let hasLoadedTransactions = true

    let paths = BudgetPaths()
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var aiAttempted: Set<String> = []
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
            let unchecked = info.map { !$0.confirmed && ($0.source == .ai || $0.category == nil) } ?? true
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
        }
        for issuer in coverage.keys {
            coverage[issuer]?.statementSpend = cardSpend[issuer] ?? 0
            coverage[issuer]?.accounts = library.accounts.filter { cardAccount[$0.id] == issuer }.map(\.name)
        }
        cardCoverage = coverage.values.sorted { $0.paid > $1.paid }
        list.sort { $0.date < $1.date }
        transactions = list
        months = Array(Set(list.map(\.month))).sorted()
        spendingByMonth = Dictionary(grouping: list.filter(\.countsAsSpending), by: \.month)

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
        guard aiAvailable, !isSuggesting else { return }
        isSuggesting = true
        defer { isSuggesting = false }
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
        guard !isSuggesting, aiAvailable, library.merchants.values.contains(where: { $0.category == nil }) else { return }
        aiAttempted.removeAll()
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
        guard ProcessInfo.processInfo.environment["TONY_AWARDS_SNAPSHOT"] == nil else { return nil }
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

    private func importFilesAsync(_ dropped: [URL]) async {
        let (urls, fromFolder) = Self.expand(dropped)
        var issues: [ImportIssue] = []
        var added = 0, touched: [String] = [], verified = 0, mismatches: [String] = [], scanned = 0
        var batch: (entries: Set<UUID>, accounts: Set<UUID>, hashes: Set<String>) = ([], [], [])
        isImporting = true
        for url in urls {
            guard StatementReader.extensions.contains(url.pathExtension.lowercased()) else {
                issues.append(ImportIssue(file: url.lastPathComponent, reason: StatementReader.adviceForUnsupported(url)))
                continue
            }
            do {
                let data = try Data(contentsOf: url)
                let hash = Self.hash(data)
                var outcome: StatementReader.Outcome
                do {
                    outcome = try await StatementReader.read(url, data: data)
                } catch PDFStatement.PDFError.locked {
                    // Some banks lock statements with a password (often part of an ID number). Ask for it.
                    guard let password = askPassword(for: url) else { throw PDFStatement.PDFError.lockedAndSkipped }
                    outcome = try await StatementReader.read(url, data: data, password: password)
                }
                switch outcome {
                case .ready(let statement):
                    let (accountID, isNew) = account(for: statement.signature, name: statement.suggestedName)
                    let ids = add(statement.rows, to: accountID)
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
                case .needsMapping(let table, let signature, let name):
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
        isImporting = false
        if dropped.count > 0, urls.isEmpty {
            issues.append(ImportIssue(file: dropped[0].lastPathComponent, reason: "There were no statements in that folder."))
        }
        if !issues.isEmpty { importIssues = issues }
        if !touched.isEmpty {
            lastImport = batch
            withAnimation(.snappy) { changed() }
            showImportToast(added: added, accounts: touched, verified: verified, mismatches: mismatches, scanned: scanned)
            if selection == nil { selection = .overview }
            Task { await sortRemaining() }
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
        pruneUnusedPlaces()
        withAnimation(.snappy) { changed() }
        showToast("Removed. Nothing from that file was kept.", symbol: "arrow.uturn.backward.circle.fill")
        refreshDownloads()
    }

    /// Finds the account a file belongs to, or makes one. Never asks.
    private func account(for signature: String, name: String) -> (UUID, isNew: Bool) {
        if let exact = accounts.first(where: { $0.signature == signature }) { return (exact.id, false) }
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

    private func showImportToast(added: Int, accounts names: [String], verified: Int = 0, mismatches: [String] = [], scanned: Int = 0) {
        let where_ = names.joined(separator: ", ")
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
        let target = desktop.appendingPathComponent("Tony Awards Backup \(DateParsing.iso.string(from: .now)).json")
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
        guard ProcessInfo.processInfo.environment["TONY_AWARDS_SNAPSHOT"] == nil else { return }
        let known = library.importedHashes.union(library.dismissedDownloads)
        Task.detached(priority: .utility) {
            let found = Self.scanDownloads(excluding: known)
            await MainActor.run { self.downloadCandidates = found }
        }
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
            .prefix(5)
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
    func recentHighlights() -> [DailyTony.Highlight] {
        let spending = transactions.filter { $0.countsAsSpending && $0.amount >= 3 && $0.category != .unsorted }
        guard let latest = spending.last?.date else { return [] }
        let cutoff = latest.addingTimeInterval(-14 * 24 * 3600)
        var seen: Set<String> = []
        return spending.filter { $0.date >= cutoff }.reversed().compactMap { t in
            guard seen.insert(t.merchant).inserted else { return nil }
            return DailyTony.Highlight(merchant: t.merchant, category: t.category, amount: t.amount)
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
