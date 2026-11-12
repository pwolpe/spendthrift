import SwiftUI

/// The app checking itself. `scripts/test.sh` runs this against the made-up statements in
/// `Tests/Fixtures`, and against a copy of a real library when there is one, and fails on any FAIL line.
///
/// Three parts: `logic` needs no data at all; `books` holds for any library, however large or odd
/// (these are the sums the screens show, so a screen can never say two different things);
/// the rest changes things the way a person would and checks what happened.
@MainActor
enum SelfTest {
    private static var passed = 0, failed = 0

    private static func check(_ name: String, _ ok: Bool) {
        if ok { passed += 1 } else { failed += 1 }
        print("SELFTEST \(ok ? "PASS" : "FAIL") \(name)")
    }

    // MARK: Rules that need no data

    private static func logic() {
        // Who a line belongs to.
        check("a known name needs its whole name", KnownMerchants.match("PARAMOUNT+ 888-274-5343 CA", generic: false)?.name == "Paramount+"
              && KnownMerchants.match("PARAMOUNT HOTEL NEW YORK NY", generic: false) == nil)
        check("a mobile deposit is not a petrol station", KnownMerchants.match("MOBILE DEPOSIT REF 1234", generic: false)?.name != "Mobil")
        check("a spelling ignores what changes charge to charge",
              MerchantResolver.spelling("STARBUCKS STORE 04127  NEW YORK") == MerchantResolver.spelling("STARBUCKS STORE 99310 NEW YORK"))
        check("a spelling the person separated wins",
              MerchantResolver.key(for: "PARAMOUNT+ CA", amount: 5, existingKeys: [String](), spellings: ["PARAMOUNT+ CA": "own:1"]) == "own:1"
              && MerchantResolver.key(for: "PARAMOUNT+ CA", amount: 5, existingKeys: [String]()) == "known:Paramount+")
        check("finding a payee ignores punctuation and case", PlacesView.squeeze("Barry's  Bootcamp") == "barrysbootcamp")

        // Orders against card charges.
        func item(_ order: String, _ cents: Int, _ date: String, gift: Bool = false) -> OrderItem {
            var item = OrderItem(orderID: order, shop: .store, date: date, shipment: date + "T10:00", name: "Thing from \(order)", cents: cents, quantity: 1)
            item.giftPart = gift ? true : nil
            return item
        }
        let items = [item("A", 1999, "2026-03-01"), item("B", 5000, "2026-03-10"), item("C", 8000, "2026-04-01", gift: true)]
        let exact = OrderMatcher.Charge(id: UUID(), date: "2026-03-02", cents: 1999, shop: .store)
        let pinned = OrderMatcher.Charge(id: UUID(), date: "2026-03-11", cents: 3100, shop: .store)
        let partGift = OrderMatcher.Charge(id: UUID(), date: "2026-04-02", cents: 6500, shop: .store)
        let stranger = OrderMatcher.Charge(id: UUID(), date: "2026-06-15", cents: 777, shop: .store)
        let matches = OrderMatcher.match([exact, pinned, partGift, stranger], to: items, pins: [pinned.id.uuidString: "B"])
        check("an order that adds up to a charge is matched exactly", matches[exact.id.uuidString]?.kind == .exact && matches[exact.id.uuidString]?.items == [0])
        check("the shop's own record outranks the amounts", matches[pinned.id.uuidString]?.kind == .recorded && matches[pinned.id.uuidString]?.items == [1])
        check("a gift balance explains a smaller charge", matches[partGift.id.uuidString]?.kind == .lessCredit && matches[partGift.id.uuidString]?.items == [2])
        check("a charge with no order stays unmatched", matches[stranger.id.uuidString] == nil)

        // Answers may only quote amounts the app computed.
        check("dollar amounts are read out of an answer", ChatAnalyst.dollarAmounts(in: "You spent $1,234.56, then $80.") == ["$1,234.56", "$80"])
        check("months step across a year", Month(year: 2026, month: 1).adding(-1) == Month(year: 2025, month: 12) && Month(year: 2025, month: 12) < Month(year: 2026, month: 1))
    }

    // MARK: Sums that must agree, whatever the library holds

    private static func books(_ store: BudgetStore) {
        guard let period = ReportData.periods(for: store).first else { return }
        let year = CashFlowData(store: store, period: period)
        let near = { (a: Double, b: Double) in abs(a - b) < 0.01 }
        let months = year.months.map { CashFlowData(store: store, month: $0) }
        check("the verdict is income less what was consumed", near(year.surplus, year.totalIncome - year.spending - year.taxes - year.loanInterest))
        check("a year is the sum of its months", near(months.reduce(0) { $0 + $1.spending }, year.spending)
              && near(months.reduce(0) { $0 + $1.totalIncome }, year.totalIncome) && near(months.reduce(0) { $0 + $1.taxes }, year.taxes))
        check("the Spending card and the spending page agree", near(year.months.reduce(0) { $0 + store.totalSpent(in: $1) }, year.spending))
        check("the category ring adds up to spending", year.months.allSatisfy { m in near(store.categoryTotals(in: m).reduce(0) { $0 + $1.total }, max(store.totalSpent(in: m), store.categoryTotals(in: m).reduce(0) { $0 + $1.total })) })
        let run = CashFlowData.run(of: year.months, in: store)
        check("the small bars add up to the big figures", near(run.reduce(0) { $0 + $1.income }, year.totalIncome) && near(run.reduce(0) { $0 + $1.invested }, year.investmentOut))
        let verdict = FlowHero.verdict(for: year)
        check("the stamp matches the sum", year.totalIncome <= 0.5 ? verdict == .unknown
              : verdict == .even ? abs(year.surplus) < year.totalIncome * 0.01 : (verdict == .within) == (year.surplus > 0))
        check("money kept apart is counted nowhere else", Set(store.transactions.map(\.id)).isDisjoint(with: store.setApart.map(\.id)))
        check("every charge falls in a month the app knows", store.transactions.allSatisfy { store.months.contains($0.month) })
        let ids = Set(store.library.entries.map(\.id.uuidString))
        check("every order match points at real items and a real charge", store.orders.matches.allSatisfy { key, match in
            ids.contains(key) && !match.items.isEmpty && match.items.allSatisfy { store.orders.items.indices.contains($0) }
        })
        if let latest = store.months.last {
            check("everything worth knowing leads somewhere", store.insights(for: latest).allSatisfy { $0.target != nil })
        }
    }

    // MARK: Doing what a person would do

    static func run(files: [URL]) async {
        let store = BudgetStore.shared
        logic()
        books(store)
        // One way a payee is written can be made a payee of its own; the rest stay, and the choice is kept.
        let bySpelling = Dictionary(grouping: store.transactions, by: \.merchant)
            .mapValues { Dictionary(grouping: $0) { MerchantResolver.spelling($0.description) } }
        if let (payee, spellings) = bySpelling.first(where: { $0.value.count > 1 }), let (spelling, moving) = spellings.min(by: { $0.value.count < $1.value.count }) {
            let before = store.transactions.filter { $0.merchant == payee }.count
            store.separate(spelling: spelling, from: payee, as: "Somebody Else Entirely", category: .travel)
            let moved = store.transactions.filter { $0.merchant == "Somebody Else Entirely" }
            check("separate one spelling from a payee", moved.count == moving.count && moved.allSatisfy { $0.category == .travel }
                  && store.transactions.filter { $0.merchant == payee }.count == before - moving.count
                  && moved.first.map { MerchantResolver.key(for: $0.description, amount: $0.amount, existingKeys: [String](), spellings: [spelling.uppercased(): $0.merchantKey]) == $0.merchantKey } == true)
        } else { print("SELFTEST SKIP separate one spelling (no payee here is written two ways)") }
        // Back always returns to where a link was followed from, however deep; the sidebar is a fresh start.
        if let payee = store.transactions.first?.merchant, let month = store.months.first {
            store.selection = .overview
            store.overviewMonth = month
            store.stepInto(.spending)
            store.showCharges(TransactionFilter(category: .dining, month: month))
            store.showPlace(payee)
            store.go(to: .transactions)
            let deep = store.selection == .transactions && store.route.isEmpty && store.canGoBack
            store.back()
            let onPayee = store.selection == .overview && store.route.last == .place(payee) && store.overviewDetail == .spending
            store.back(); store.back()
            let onDetail = store.route.isEmpty && store.overviewDetail == .spending && store.overviewMonth == month
            store.back()
            check("back retraces every step", deep && onPayee && onDetail && store.overviewDetail == nil && !store.canGoBack)
            store.showPlace(payee)
            store.selection = .places
            check("the sidebar starts afresh", store.route.isEmpty && !store.canGoBack)
            store.selection = .overview
            store.overviewMonth = nil
        }
        // SPENDTHRIFT_EXPLAIN="Whitfield|my accountant, for tax prep": say what a place was and print what happened.
        if let spec = ProcessInfo.processInfo.environment["SPENDTHRIFT_EXPLAIN"]?.split(separator: "|", maxSplits: 1).map(String.init), spec.count == 2,
           let t = store.transactions.first(where: { $0.merchant.localizedCaseInsensitiveContains(spec[0]) }) {
            let before = "\(t.merchant) | \(t.category.displayName)"
            let ok = await store.explain(t.merchantKey, said: spec[1])
            let after = store.transactions.first { $0.id == t.id }
            print("EXPLAIN \(ok ? "ok" : "failed"): \(before)  →  \(after?.merchant ?? "?") | \(after?.category.displayName ?? "?") | note: \(after?.note ?? "-") | needs check: \(after?.needsCheck ?? true)")
        }
        if store.stories.count >= 2, let moving = store.transactions(in: store.stories[0]).first?.id {
            let from = store.stories[0], to = store.stories[1]
            let before = store.transactions(in: to).count
            store.move([moving], to: to)
            check("move a charge between trips", store.story(containing: moving)?.fingerprint == to.fingerprint
                  && store.stories.first { $0.fingerprint == to.fingerprint }.map { store.transactions(in: $0).count } == before + 1)
            store.move([moving], to: nil)
            check("take a charge out of every trip", store.story(containing: moving) == nil)
            store.move([moving], to: from)
        }
        guard let t = store.transactions.first(where: { $0.countsAsSpending && $0.category != .gifts }) else { check("has data", false); print("SELFTEST SUMMARY \(passed) passed, \(failed) failed"); return }
        let samePlace = store.transactions.filter { $0.merchantKey == t.merchantKey }.count

        store.setCategory(.gifts, for: [t.id], wholePlace: false)
        check("only-this-charge changes one", store.transactions.filter { $0.merchantKey == t.merchantKey && $0.category == .gifts }.count == 1)
        check("override is flagged", store.transactions.first { $0.id == t.id }?.isOverride == true)

        store.setCategory(.travel, for: [t.id], wholePlace: true)
        check("whole-place changes all \(samePlace)", store.transactions.filter { $0.merchantKey == t.merchantKey && $0.category == .travel }.count == samePlace)
        check("whole-place marks as user's choice", store.place(t.merchantKey)?.source == .user && store.place(t.merchantKey)?.confirmed == true)

        store.renamePlace(t.merchantKey, to: "Renamed Place")
        check("rename applies everywhere", store.transactions.filter { $0.merchant == "Renamed Place" }.count == samePlace)

        // Custom categories
        let pets = store.saveCategory(CustomCategory(name: "Pets", symbol: "pawprint.fill", color: "teal"))
        check("create custom category", pets != nil && Category.spendingCases.contains(Category("Pets")) && Category("Pets").symbol == "pawprint.fill")
        check("duplicate name refused", store.saveCategory(CustomCategory(name: "pets", symbol: "tag.fill", color: "red")) == nil
              && store.saveCategory(CustomCategory(name: "Dining", symbol: "tag.fill", color: "red")) == nil)
        if let pets {
            store.setCategory(pets, forPlace: t.merchantKey)
            check("file a place under it", store.transactions.filter { $0.category == pets }.count == samePlace)
            guard var edited = store.customCategories.first(where: { $0.name == "Pets" }) else { return check("the new category is listed", false) }
            let customBefore = Category.custom.count
            edited.name = "Dog"
            store.saveCategory(edited)
            check("rename keeps its charges", store.transactions.filter { $0.category == Category("Dog") }.count == samePlace && !Category.allCases.contains(pets))
            check("AI schema offers it", Category.spendingCases.map(\.rawValue).contains("Dog") && AISchemas.merchantGuesses(count: 1, purchasesOnly: true) != nil)
            if let dog = store.customCategories.first(where: { $0.name == "Dog" }) { store.deleteCategory(dog) }
            check("delete moves charges to Other", store.transactions.filter { $0.merchantKey == t.merchantKey && $0.category == .other }.count == samePlace
                  && Category.custom.count == customBefore - 1)
            store.setCategory(.travel, forPlace: t.merchantKey)
        }

        let before = store.transactions.count, accountsBefore = store.accounts.count
        store.importFiles(files)
        try? await Task.sleep(for: .seconds(3))
        check("re-import adds nothing (\(store.transactions.count) vs \(before))", store.transactions.count == before && store.accounts.count == accountsBefore)
        check("choices survive re-import", store.transactions.filter { $0.merchantKey == t.merchantKey && $0.category == .travel }.count == samePlace)

        if let account = store.accounts.first {
            let spent = store.spent(in: account)
            store.flipAmounts(account.id)
            check("flip swaps signs", abs(store.spent(in: account) + spent) < 0.01 || spent == 0)
            store.flipAmounts(account.id)
            check("flip twice restores", abs(store.spent(in: account) - spent) < 0.01)
            let n = store.transactionCount(for: account)
            store.removeAccount(account.id)
            check("remove account drops its \(n) transactions", store.transactions.count == before - n)
        }
        // Saved library reloads identically.
        // Written now, rather than after the usual short wait, so this checks the file and not the timing.
        store.saveNow()
        let reloaded = Library.load(paths: store.paths).0
        let cents = { (entries: [LedgerEntry]) in entries.reduce(0) { $0 + Int(($1.amount * 100).rounded()) } }
        check("saved to disk (\(reloaded.entries.count) entries)", reloaded.entries.count == store.library.entries.count
              && cents(reloaded.entries) == cents(store.library.entries) && reloaded.merchants.count == store.library.merchants.count)
        print("SELFTEST SUMMARY \(passed) passed, \(failed) failed")
    }
}
