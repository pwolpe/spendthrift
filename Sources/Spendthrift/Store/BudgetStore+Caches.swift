import SwiftUI

/// Things worked out from every transaction, kept until the library next changes.
///
/// Pages ask for these from their bodies, and a body runs on every keystroke and every hover. Each
/// value is stored under a string and the store's `revision`; when the revision moves, everything
/// is thrown away at the next ask. Not observable: reading it never makes a page redraw.
@MainActor
final class DerivedCache {
    static let shared = DerivedCache()

    private var revision = -1
    private var owner: ObjectIdentifier?
    private var ordersStamp = 0
    private var seenOrders = 0
    private var values: [String: Any] = [:]

    /// The order histories were laid out again (they change without the transactions changing).
    func ordersChanged() { ordersStamp += 1 }

    /// The value kept under `key`, made by `make` the first time it is asked for at this revision.
    func value<T>(_ key: String, for store: BudgetStore, make: () -> T) -> T {
        let current = store.revision, who = ObjectIdentifier(store)
        if current != revision || who != owner || seenOrders != ordersStamp {
            values.removeAll(keepingCapacity: true)
            revision = current
            owner = who
            seenOrders = ordersStamp
        }
        if let kept = values[key] as? T { return kept }
        let made = make()
        values[key] = made
        return made
    }

    /// How many values are being kept (for the self-test).
    var count: Int { values.count }
}

/// What a page was showing when the person left it, for the pages whose state lives in a view.
/// Kept here because the store's stored properties are all in BudgetStore.swift.
@MainActor
final class PageMemory {
    static let shared = PageMemory()
    /// The Amazon page's expanded order or item.
    var ordersOpen: String?
    /// The Statements page: the account chosen, the statement chosen, and the search.
    var statementsAccount: StatementsView.AccountChoice?
    var statementsSelected: String?
    var statementsSearch = ""
}

extension TransactionFilter {
    /// A string that is the same for filters that select the same charges.
    var cacheKey: String {
        let ids = ids.map { "\($0.count):\($0.hashValue)" } ?? "-"
        return [category?.rawValue ?? "-", month?.key ?? "-", accountID?.uuidString ?? "-", merchantKey ?? "-", merchant ?? "-",
                needsCheck ? "1" : "0", storyID?.uuidString ?? "-", ids].joined(separator: "|")
    }
}

/// One account's figures, worked out in a single pass over the transactions.
struct AccountSummary {
    var count = 0
    var spent = 0.0
    var range: ClosedRange<Date>?
    var months: Set<Month> = []
}

extension BudgetStore {
    private var cache: DerivedCache { .shared }

    /// The value kept under `key` until the library next changes.
    func cached<T>(_ key: String, make: () -> T) -> T { cache.value(key, for: self, make: make) }

    // MARK: Transactions page

    /// The charges that match a filter and a search, in the order of `transactions`.
    func filteredTransactions(_ f: TransactionFilter, search: String) -> [Transaction] {
        cached("txn|\(f.cacheKey)|\(search)") {
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
            if f.needsCheck { list = list.filter(\.needsCheck) }
            if !search.isEmpty {
                list = list.filter {
                    $0.merchant.localizedCaseInsensitiveContains(search)
                        || $0.description.localizedCaseInsensitiveContains(search)
                        || $0.category.displayName.localizedCaseInsensitiveContains(search)
                        || ($0.note?.localizedCaseInsensitiveContains(search) ?? false)
                }
            }
            return list
        }
    }

    /// The same, sorted as the table asks. Kept for each sort, so a selection change sorts nothing.
    func sortedTransactions(_ f: TransactionFilter, search: String, by order: [KeyPathComparator<Transaction>]) -> [Transaction] {
        let how = order.map { "\($0.keyPath)\($0.order)" }.joined(separator: ",")
        return cached("txn-sorted|\(f.cacheKey)|\(search)|\(how)") {
            filteredTransactions(f, search: search).sorted(using: order)
        }
    }

    // MARK: Payees

    /// Every payee's charges, newest first, by tidy name.
    private var chargesByPayee: [String: [Transaction]] {
        cached("by-payee") {
            Dictionary(grouping: transactions, by: \.merchant).mapValues { $0.sorted { $0.date > $1.date } }
        }
    }

    /// Every charge at one payee, newest first.
    func charges(at name: String) -> [Transaction] { chargesByPayee[name] ?? [] }

    /// Every charge sharing one payee key (however it is spelled), newest first.
    func charges(withKey key: String) -> [Transaction] {
        let index: [String: [Transaction]] = cached("by-key") {
            Dictionary(grouping: transactions, by: \.merchantKey).mapValues { $0.sorted { $0.date > $1.date } }
        }
        return index[key] ?? []
    }

    /// The names of all payees.
    var allPayeeNames: Set<String> {
        cached("payee-names") { Set(chargesByPayee.keys) }
    }

    /// The payee names a sentence can link to, longest first so "Westside Market NYC" beats "Westside Market".
    var linkablePayeeNames: [String] {
        cached("linker-names") {
            allPayeeNames.filter { $0.count >= 4 }.sorted { ($0.count, $1) > ($1.count, $0) }
        }
    }

    // MARK: Accounts

    /// Count, spending and dates for every account.
    var accountSummaries: [UUID: AccountSummary] {
        cached("account-summaries") {
            var out: [UUID: AccountSummary] = [:]
            for t in transactions {
                var s = out[t.accountID] ?? AccountSummary()
                s.count += 1
                if t.countsAsSpending { s.spent += t.amount }
                s.range = s.range.map { min($0.lowerBound, t.date)...max($0.upperBound, t.date) } ?? t.date...t.date
                s.months.insert(t.month)
                out[t.accountID] = s
            }
            return out
        }
    }

    func summary(of account: Account) -> AccountSummary { accountSummaries[account.id] ?? AccountSummary() }

    // MARK: Statements

    /// Every original kept, newest first.
    var sourceFilesSorted: [SourceFile] {
        cached("source-files|\(library.sources?.count ?? 0)") {
            (library.sources ?? []).sorted { ($0.lastDate ?? "", $0.name) > ($1.lastDate ?? "", $1.name) }
        }
    }

    /// The charges read from one statement.
    func cachedEntries(in source: SourceFile) -> [LedgerEntry] {
        cached("entries|\(source.id)|\(library.entries.count)") {
            library.entries.filter { $0.sourceID == source.id }
        }
    }

    // MARK: The Amazon page

    /// Whether a month falls inside the stretch the Amazon page is showing.
    func orderInStretch(_ month: Month) -> Bool {
        switch orderScope {
        case .all: true
        case .year(let year): month.year == year
        case .month(let m): month == m
        }
    }

    /// The order items on show: the stretch, the person, the search and (unless `ignoringCategory`) the kind clicked.
    func shownOrderRows(ignoringCategory: Bool = false) -> [OrderRow] {
        let key = "order-rows|\(orderOnly ?? "-")|\(orderSearch)|\(orderScope)|\(orderWho ?? "-")|\(ignoringCategory ? "-" : orderKind ?? "-")"
        return cached(key) {
            if let only = orderOnly { return orderRows.filter { $0.item.orderID == only && $0.item.cents > 0 } }
            let query = PlacesView.squeeze(orderSearch)
            return orderRows.filter { row in
                guard row.item.cents > 0, orderInStretch(row.month) else { return false }
                if let who = orderWho, row.item.who != who { return false }
                if !ignoringCategory, let kind = orderKind, row.kind != kind { return false }
                return query.isEmpty || row.haystack.contains(query)
            }
        }
    }

    /// The card charges an order history could explain that fall in the stretch on show.
    func orderChargesInStretch() -> [OrderCharge] {
        cached("order-charges|\(orderScope)") {
            orderChargeList.filter { charge in
                guard let date = DateParsing.parse(charge.date, format: "yyyy-MM-dd") else { return false }
                return orderInStretch(Month(date: date))
            }
        }
    }
}
