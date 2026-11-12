import SwiftUI
import AppKit
import CryptoKit
import PDFKit
import UniformTypeIdentifiers

/// What was inside the orders: an order history read, matched to card charges, and summed for the Amazon page.
extension BudgetStore {
    // MARK: - Orders


    /// A statement charge at one of the shops an order history covers, and whether an order explains it.
    struct OrderCharge: Identifiable {
        let id: UUID
        let date: String
        let amount: Double
        let itemized: Bool
        let shop: OrderItem.Shop
    }

    enum OrderScope: Hashable { case all, year(Int), month(Month) }

    struct OrderRow: Identifiable {
        let id: Int
        let item: OrderItem
        let date: Date
        let month: Month
        /// What it is in plain words (the model's reading of the listing), or the listing itself until it's read.
        let name: String
        let category: Category
        /// What sort of thing it is, finer than the budget category.
        let kind: String
        /// What it cost after any refund on its order, in cents.
        let net: Int
        /// Name, listing and category squeezed to letters and digits, for finding.
        let haystack: String
        /// The card charge that paid for it, when one was found.
        let charge: UUID?
    }


    /// How far the order history reaches, set against the charges it could explain.
    struct OrderCoverage {
        var through: Date?
        var charges = 0, itemized = 0
        /// Charges at these shops made after the last order on file: waiting for a newer export.
        var newer = 0
    }


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
        // The same name, kind and person come up again and again: squeeze each for searching only once.
        var squeezed: [String: String] = [:]
        func squeeze(_ text: String) -> String {
            if let done = squeezed[text] { return done }
            let done = PlacesView.squeeze(text)
            squeezed[text] = done
            return done
        }
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
            // Until the model has said what kind of thing it is, the shop's own shelf stands in.
            let kind = read?.kind ?? (item.shop == .digital ? "Kindle & Digital Media" : item.shop == .groceries ? "Fresh Food" : "Not Read Yet")
            return OrderRow(id: i, item: item, date: date, month: Month(date: date), name: name, category: category, kind: kind, net: net,
                            haystack: [name, item.name, kind, category.rawValue, item.who ?? ""].map(squeeze).joined(separator: " "),
                            charge: charge[i])
        }
        orderPeople = Array(Set(orders.items.compactMap(\.who))).sorted()
        var coverage = OrderCoverage()
        let last = orders.items.map(\.date).max()
        coverage.through = last.flatMap { DateParsing.parse($0, format: "yyyy-MM-dd") }
        let charges = orderCharges, apart = apartEntryIDs
        var list: [OrderCharge] = []
        for c in charges {
            let itemized = orders.matches[c.id.uuidString] != nil
            coverage.charges += 1
            if itemized { coverage.itemized += 1 } else if let last, c.date > last { coverage.newer += 1 }
            if !apart.contains(c.id) { list.append(OrderCharge(id: c.id, date: c.date, amount: Double(c.cents) / 100, itemized: itemized, shop: c.shop)) }
        }
        orderCoverage = coverage
        orderChargeList = list
    }

    /// Charges on accounts kept apart: not the person's own, so not part of this tie-out either.
    private var apartEntryIDs: Set<UUID> { Set(setApart.map(\.id)) }

    /// A few sentences about one stretch of orders, written by the model from totals the app worked out.
    /// Written once for a given set of facts and kept; nil while it is being written or when the model is off.
    func orderRead(key: String, basis: String, facts: String) async -> String? {
        if let kept = orders.reads?[key], kept.hasPrefix(basis + "\t") { return String(kept.dropFirst(basis.count + 1)) }
        guard CloudAI.isEnabled else { return nil }
        let system = """
        You are looking at a household's online order history for one stretch of time, as totals worked out by a \
        budgeting app. Write two or three plain sentences that tell them something true and specific about it: \
        what the money mostly went on, anything bought again and again, the one or two purchases that stand out, \
        how the stretch compares with the one before when that is given. Use the names and amounts given, rounded \
        to whole dollars. Dry and warm, like a friend who is good with numbers. No advice, no exclamation marks, \
        no lists, no opening like "In this period". Do not invent anything that is not in the facts.
        """
        guard let text = await Timeout.run(45, { try? await CloudAI.complete(job: "Amazon: the short version", system: system, user: facts, json: false, maxTokens: 400, temperature: 0.4, timeout: 40) }),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var reads = orders.reads ?? [:]
        reads[key] = basis + "\t" + clean
        if reads.count > 200 { reads = Dictionary(uniqueKeysWithValues: Array(reads).suffix(150)) }
        orders.reads = reads
        let book = orders, file = paths.ordersFile
        book.save(to: file)
        return clean
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

    func loadOrders() async {
        let file = paths.ordersFile, entries = library.entries
        // Read the file and pick out the charges it could explain away from the main thread: the
        // window is already up, and nothing on it should wait for this.
        let (saved, charges) = await Task.detached(priority: .utility) { (OrderBook.load(file), Self.orderCharges(in: entries)) }.value
        guard !saved.items.isEmpty else { return }
        if orderChargeCache == nil, entries.count == library.entries.count { orderChargeCache = charges }
        Launch.mark("orders read")
        orders = saved
        refreshOrderRows()
        Launch.mark("order rows laid out")
        await rematchOrders()   // statements may have been added since the orders were last lined up
        Launch.mark("orders rematched")
        await readOrderListings()
    }

    /// The charges an order export could explain: spending at the shops it covers.
    /// Worked out once for each state of the library and kept: it means reading every line on file.
    private var orderCharges: [OrderMatcher.Charge] {
        if let kept = orderChargeCache { return kept }
        let charges = Self.orderCharges(in: library.entries)
        orderChargeCache = charges
        return charges
    }

    nonisolated private static func orderCharges(in entries: [LedgerEntry]) -> [OrderMatcher.Charge] {
        entries.compactMap { entry in
            guard entry.amount > 0, let shop = OrderMatcher.shop(of: entry.description) else { return nil }
            return .init(id: entry.id, date: entry.date, cents: Int((entry.amount * 100).rounded()), shop: shop)
        }
    }

    /// Lines the charges up with the orders again (new statements or a new export can both change the answer).
    func rematchOrders() async {
        guard !orders.items.isEmpty else { return }
        let charges = orderCharges, items = orders.items, file = paths.ordersFile
        let pins = (orders.pins ?? [:]).mapValues(\.order)
        let matches = await Task.detached { OrderMatcher.match(charges, to: items, pins: pins) }.value
        guard items == orders.items else { return }   // another export arrived meanwhile; its own pass will follow
        guard matches != orders.matches || orderRows.isEmpty else { return }
        orders.matches = matches
        refreshOrderRows()
        let book = orders
        book.save(to: file)
    }

    /// Has the model read every product listing it hasn't yet: what each thing is, and its budget category.
    /// Newest first, a few requests at a time; each answer is kept as it arrives, so stopping loses nothing.
    func readOrderListings() async {
        guard CloudAI.isEnabled, !isReadingOrders else { return }
        let done = orders.sorted ?? [:]
        var seen: Set<String> = [], unread: [String] = []
        for item in orders.items.reversed() where (done[item.name] == nil || done[item.name]?.kind == nil) && seen.insert(item.name).inserted { unread.append(item.name) }
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
                    book.save(to: file)
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

    /// Reads kept statements again with today's reader and puts what it finds in place of what an
    /// earlier reader made of them. Only statements the reader can now prove (its lines tie to the
    /// printed totals) and that are printed as a ledger, the layout the earlier reader got wrong.
    /// A charge that is still there keeps its identity, so notes, own categories and trips survive.
    /// Never asks the model. Returns one line per statement, for the record.
    func rereadLedgerStatements() async -> [String] {
        var report: [String] = []
        for source in (library.sources ?? []) where source.isPDF {
            guard let accountID = source.accountID, library.accounts.contains(where: { $0.id == accountID }) else { continue }
            let url = paths.statementFile(source)
            guard let data = try? Data(contentsOf: url), let doc = PDFDocument(data: data), !doc.isLocked else { continue }
            let pages = (0..<min(doc.pageCount, 30)).compactMap { doc.page(at: $0) }
            // (The text as stored and as laid out on the page: the telltale line can read differently in each.)
            let text = pages.compactMap(\.string).joined(separator: "\n") + "\n" + pages.map(PDFStatement.positionalText).joined(separator: "\n")
            let ledger = text.range(of: #"(?im)^.*total (?:withdrawals|checks)[^\n]*\d ?-(?: .*)?$"#, options: .regularExpression) != nil
            let mine = library.entries.filter { $0.sourceID == source.id }
            // The mark of an earlier misreading, on any kind of statement: the same line both as a
            // charge and as a credit (a reading that filed everything as credits, added beside the right one).
            var signed: [String: Set<Bool>] = [:]
            for e in mine { signed["\(e.date)|\(abs(e.amount))|\(e.description)", default: []].insert(e.amount > 0) }
            let mirrored = signed.values.filter { $0.count == 2 }.count >= 3
            // A ledger that already ties has been through this, unless it still holds the same line twice.
            let repeats = Dictionary(grouping: mine, by: { "\($0.date)|\($0.amount)|\($0.description)" }).contains { $0.value.count > 1 }
            guard mirrored || (ledger && !(source.check == "verified" && !mine.isEmpty && !repeats)) else { continue }
            guard let outcome = try? await CloudAI.$offline.withValue(true, operation: { try await StatementReader.read(url, data: data) }),
                  case .ready(let statement) = outcome, statement.check == .verified else {
                report.append("LEFT \(source.name): today's reader can't prove it either")
                continue
            }
            let old = library.entries.filter { $0.sourceID == source.id }
            library.entries.removeAll { $0.sourceID == source.id }
            let ids = add(statement.rows, to: accountID, source: source.id)
            // A line that was there before, whatever its sign was and however short its text: same charge.
            var pool = old, carried = 0
            for i in library.entries.indices where ids.contains(library.entries[i].id) {
                let entry = library.entries[i]
                // Of the old lines this could be, the one the person touched comes first, then the one with the right sign.
                let matches = pool.indices.filter { pool[$0].date == entry.date && abs(abs(pool[$0].amount) - abs(entry.amount)) < 0.005
                    && entry.description.uppercased().hasPrefix(pool[$0].description.uppercased().prefix(12)) }
                func worth(_ e: LedgerEntry) -> Int {
                    ((e.note ?? "").isEmpty && e.override == nil && !e.merchantKey.hasPrefix("own:") && !e.merchantKey.hasPrefix("CHECK TO ") ? 0 : 2)
                        + ((e.amount > 0) == (entry.amount > 0) ? 1 : 0)
                }
                guard let j = matches.max(by: { worth(pool[$0]) < worth(pool[$1]) }) else { continue }
                let was = pool.remove(at: j)
                library.entries[i].id = was.id
                library.entries[i].note = was.note
                library.entries[i].override = was.override
                // A payee the person (or a check's picture) gave it stays too.
                if was.merchantKey.hasPrefix("own:") || was.merchantKey.hasPrefix("CHECK TO ") || library.merchants[was.merchantKey]?.source == .user {
                    library.entries[i].merchantKey = was.merchantKey
                }
                carried += 1
            }
            if let s = library.sources?.firstIndex(where: { $0.id == source.id }) {
                library.sources?[s].rows = statement.rows.count
                library.sources?[s].check = "verified"
                library.sources?[s].checkNote = nil
                library.sources?[s].firstDate = statement.rows.map(\.date).min() ?? source.firstDate
                library.sources?[s].lastDate = statement.rows.map(\.date).max() ?? source.lastDate
            }
            report.append("REREAD \(source.name): \(old.count) lines before, \(statement.rows.count) now (\(ids.count) added, \(carried) kept their identity)")
        }
        pruneUnusedPlaces()
        changed()
        saveNow()
        return report
    }

    /// Puts lines the app now reads better with the payee they belong to: a bank account's debit-card
    /// purchases (once all one payee), mobile deposits (once a petrol station). Payees the person
    /// named or chose a category for are left alone. Also drops captions of check pictures that were
    /// taken for transactions, and trims a page footer that was taken for a payee.
    func cleanUpPayees() -> [String] {
        var report: [String] = []
        let captions = library.entries.filter { $0.description.caseInsensitiveCompare("amount") == .orderedSame }
        if !captions.isEmpty {
            library.entries.removeAll { $0.description.caseInsensitiveCompare("amount") == .orderedSame }
            report.append("removed \(captions.count) check-picture captions (\(Money.format(captions.reduce(0) { $0 + abs($1.amount) })))")
        }
        var moved = 0
        for i in library.entries.indices {
            var entry = library.entries[i]
            if let footer = entry.description.range(of: " 24 hour automated banking", options: .caseInsensitive) {
                entry.description = String(entry.description[..<footer.lowerBound])
                library.entries[i].description = entry.description
            }
            let upper = entry.description.uppercased()
            guard upper.range(of: #"^(?:RECURRING )?CARD PURCHASE"#, options: .regularExpression) != nil || upper.hasPrefix("MOBILE DEPOSIT") else { continue }
            if library.merchants[entry.merchantKey]?.source == .user || entry.merchantKey.hasPrefix("own:") { continue }
            let key = MerchantResolver.key(for: entry.description, amount: entry.amount, existingKeys: library.merchants.keys)
            guard key != entry.merchantKey else { continue }
            if library.merchants[key] == nil {
                library.merchants[key] = MerchantResolver.instant(description: entry.description, amount: entry.amount, bankCategory: entry.bankCategory)
            }
            library.entries[i].merchantKey = key
            moved += 1
        }
        report.append("gave \(moved) lines the payee they belong to")
        pruneUnusedPlaces()
        changed()
        saveNow()
        return report
    }

    /// Gives each paid check the payee written on it. A statement lists "Check #109 $175,000"; the
    /// picture of the check on a later page says who it went to and why. For every kept statement
    /// that hasn't been looked at, the model reads those pictures and each check is filed under its
    /// payee (checks to the same payee together), with the memo saved as the charge's note.
    /// A check the person already named is left alone. Returns what it did, for tests.
    @discardableResult
    func readCheckPictures() async -> [String] {
        guard CloudAI.canReadStatements, !isImporting else { return [] }
        var report: [String] = []
        let isCheck = { (e: LedgerEntry) in e.amount > 0 && e.description.range(of: #"^check\s*#?\s*\d+"#, options: [.regularExpression, .caseInsensitive]) != nil }
        let number = { (e: LedgerEntry) in String(e.description.filter(\.isNumber).drop(while: { $0 == "0" })) }
        for source in (library.sources ?? []) where source.isPDF && source.checksRead != true {
            let waiting = library.entries.contains { $0.sourceID == source.id && isCheck($0) }
            var pictures: [Data] = []
            if waiting, let document = PDFDocument(url: paths.statementFile(source)), !document.isLocked {
                pictures = CheckReader.picturePages(of: document).compactMap(CheckReader.picture)
            }
            var read: [CheckReader.Check] = [], failed = false
            for picture in pictures {
                if let checks = await CheckReader.read(picture) { read += checks } else { failed = true }
            }
            guard !failed else { continue }     // the model couldn't be reached: try this statement again another time
            for check in read {
                guard let i = library.entries.firstIndex(where: { e in
                    e.accountID == source.accountID && isCheck(e) && number(e) == check.number && abs(e.amount - check.amount) < 0.005
                }) else { continue }
                let entry = library.entries[i]
                // Named by the person already (or by an earlier reading): theirs stands.
                if entry.merchantKey.hasPrefix("own:") || entry.merchantKey.hasPrefix("CHECK TO ") || library.merchants[entry.merchantKey]?.source == .user { continue }
                let key = "CHECK TO " + check.payee.uppercased().filter { $0.isLetter || $0.isNumber || $0 == " " }
                if library.merchants[key] == nil {
                    library.merchants[key] = MerchantInfo(name: check.payee, category: check.category ?? .other,
                                                          source: check.confident && check.category != nil ? .cloud : .cloudGuess,
                                                          sample: "\(entry.description) to \(check.payee)" + (check.memo.isEmpty ? "" : " (\(check.memo))"))
                }
                library.entries[i].merchantKey = key
                if (entry.note ?? "").isEmpty {
                    library.entries[i].note = "To \(check.payee)." + (check.memo.isEmpty ? "" : " Memo: \(check.memo).")
                }
                report.append("\(entry.date) \(entry.description) \(Money.format(entry.amount)) → \(check.payee) | \(check.memo) | \(library.merchants[key]?.category?.rawValue ?? "")")
            }
            if let s = library.sources?.firstIndex(where: { $0.id == source.id }) { library.sources?[s].checksRead = true }
        }
        if !report.isEmpty {
            pruneUnusedPlaces()
            withAnimation(.snappy) { changed() }
        } else {
            saveNow()
        }
        return report
    }

    /// A file that was already added, exactly as it is: skipped without being read.
    struct AlreadyHere: Error {}

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
}
