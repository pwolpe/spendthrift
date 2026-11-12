import SwiftUI
import AppKit
import CryptoKit
import PDFKit
import UniformTypeIdentifiers

/// Bringing statements in, and keeping the originals so any charge can be shown where it was printed.
extension BudgetStore {
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
    static func explain(_ error: Error, file: URL) -> String {
        if let e = error as? LocalizedError, let text = e.errorDescription { return text }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, [NSFileReadNoPermissionError, NSFileReadNoSuchFileError].contains(ns.code) {
            return "The file couldn't be opened. It may have been moved, or the app isn't allowed to read that folder."
        }
        return "This file couldn't be read (\(ns.localizedDescription))."
    }

    /// - automatic: the app found these in Downloads by itself. Nothing may interrupt Tony then:
    ///   no password prompt, no column picker, no error sheet. Anything that needs him waits in the banner.
    func importFilesAsync(_ dropped: [URL], automatic: Bool = false) async {
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
        let alreadyHere = library.importedHashes.intersection((library.sources ?? []).map(\.id))
        var already = 0
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
            } catch is AlreadyHere {
                already += 1
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
                        // The very same file, already read and its original kept: nothing to learn from
                        // reading it again, and reading can mean asking the model, which costs money.
                        if alreadyHere.contains(hash) { return (index, .failure(AlreadyHere())) }
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
        joinSplitBankAccounts()
        importProgress = nil
        isImporting = false
        if added > 0 { Task { await rematchOrders() } }
        if dropped.count > 0, urls.isEmpty {
            issues.append(ImportIssue(file: dropped[0].lastPathComponent, reason: "There were no statements in that folder."))
        }
        if !issues.isEmpty, !automatic { importIssues = issues }
        if already > 0, added == 0, attached == 0, issues.isEmpty, pendingImports.isEmpty, !automatic {
            showToast(already == 1 ? "That statement was already here." : "All \(already) of those statements were already here.", symbol: "checkmark.circle")
        }
        if ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] != nil {
            print("DEBUG IMPORT files \(urls.count) already here \(already) added \(added) verified \(verified) scanned \(scanned) mismatched \(mismatches) issues \(issues.count)")
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

    /// One bank account that ended up as several: same account digits, statements for different
    /// months of the same run. It happens when a bank is renamed or bought (the number carries
    /// over), or when an old statement was filed under another bank it happened to mention.
    /// They become one account, under the name of whichever has the newest statement.
    func joinSplitBankAccounts() {
        var joined = false
        let isBank = { (a: Account) in a.signature.hasPrefix("pdf:") && (a.name.contains("Checking") || a.name.contains("Savings")) }
        let digits = { (a: Account) in a.signature.components(separatedBy: ":").last ?? "" }
        let kind = { (a: Account) in a.name.contains("Savings") ? "savings" : "checking" }
        while true {
            var months: [UUID: Set<String>] = [:], newest: [UUID: String] = [:]
            for source in library.sources ?? [] {
                guard let id = source.accountID, let day = [source.periodEnd, source.lastDate].compactMap({ $0 }).first(where: { $0.count >= 7 }) else { continue }
                months[id, default: []].insert(String(day.prefix(7)))
                newest[id] = max(newest[id] ?? "", day)
            }
            let banks = library.accounts.filter { isBank($0) && digits($0).count >= 4 && months[$0.id] != nil }
            var pair: (old: Account, new: Account)?
            search: for a in banks {
                for b in banks where a.id != b.id && digits(a) == digits(b) && kind(a) == kind(b) && (newest[a.id] ?? "") < (newest[b.id] ?? "") {
                    guard let ma = months[a.id], let mb = months[b.id], let firstA = ma.min(), let lastA = ma.max(),
                          let firstB = mb.min(), let lastB = mb.max() else { continue }
                    // Two real accounts would each have a statement for the same months. One account split in
                    // two has (almost) none in common, and the two runs touch or interleave.
                    let touch = Month(key: lastA).map { $0.adding(2).key >= firstB } ?? false
                    let touchBack = Month(key: lastB).map { $0.adding(2).key >= firstA } ?? false
                    if ma.intersection(mb).count <= 1, touch, touchBack { pair = (a, b); break search }
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

    func account(for signature: String, name: String) -> (UUID, isNew: Bool) {
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

    static func digits(ofSignature s: String) -> String? {
        let last: String?
        if s.hasPrefix("pdf:") || s.hasPrefix("ofx:") { last = s.components(separatedBy: ":").last }
        else { last = s.components(separatedBy: "|#").dropFirst().first }
        guard let d = last, d.count >= 4, d.allSatisfy(\.isNumber) else { return nil }
        return String(d.suffix(4))
    }
    static func digits(inName name: String) -> String? {
        guard let r = name.range(of: #"••(\d{4})"#, options: .regularExpression) else { return nil }
        return String(name[r].suffix(4))
    }

    /// Adds lines the account doesn't already have, and sorts each one on the spot.
    /// Identical lines that legitimately repeat (two $5 coffees in a day) are kept:
    /// only as many copies are skipped as the account already holds.
    /// - source: the kept original these rows were read from; lines already held are pointed at it too.
    /// - linkOnly: add nothing; only point the lines already held at their original.
    func add(_ rows: [CanonicalRow], to accountID: UUID, source: String? = nil, linkOnly: Bool = false) -> Set<UUID> {
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
                key = MerchantResolver.key(for: row.description, amount: amount, existingKeys: library.merchants.keys,
                                           spellings: (library.spellings ?? [:]).filter { library.merchants[$0.value] != nil })
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
    func keep(_ data: Data, hash: String, url: URL, accountID: UUID, rows: [CanonicalRow], check: StatementCheck = .none) {
        let ext = url.pathExtension.lowercased()
        var source = SourceFile(id: hash, name: url.lastPathComponent, ext: ext.isEmpty ? "txt" : ext, accountID: accountID, added: .now,
                                rows: rows.count, firstDate: rows.map(\.date).min(), lastDate: rows.map(\.date).max(), check: nil)
        if source.isPDF {
            let period = PDFStatement.period(ofPDF: data)
            source.periodStart = period?.start ?? ""; source.periodEnd = period?.end ?? ""
        }
        switch check {
        case .verified: source.check = "verified"
        case .mismatch(let note): source.check = "mismatch"; source.checkNote = note
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

    func forgetSources(_ gone: (SourceFile) -> Bool) {
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

    func pruneUnusedPlaces() {
        let used = Set(library.entries.map(\.merchantKey))
        library.merchants = library.merchants.filter { used.contains($0.key) || $0.value.confirmed }
    }

    nonisolated static func hash(_ data: Data) -> String {
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
}
