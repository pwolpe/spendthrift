import SwiftUI
import Charts

struct TransactionsView: View {
    @Environment(BudgetStore.self) private var store
    @State private var search = ""
    @State private var selection = Set<Transaction.ID>()
    @State private var sortOrder = [KeyPathComparator(\Transaction.date, order: .reverse)]
    @State private var showInspector = true

    private var rows: [Transaction] {
        let f = store.transactionFilter
        var list = store.transactions
        if let c = f.category { list = list.filter { $0.category == c } }
        if let m = f.month { list = list.filter { $0.month == m } }
        if let a = f.accountID { list = list.filter { $0.accountID == a } }
        if let k = f.merchantKey { list = list.filter { $0.merchantKey == k } }
        if let name = f.merchant { list = list.filter { $0.merchant == name } }
        if let s = f.storyID, let story = store.stories.first(where: { $0.id == s }) {
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
        return list.sorted(using: sortOrder)
    }

    private var selected: Transaction? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return store.transactions.first { $0.id == id }
    }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            FilterBar(rows: rows)
            Divider()
            if rows.isEmpty {
                TonySays(title: "Nothing matches", message: "Try a different search, or clear the filters above.") {
                    Button("Show Everything") { store.transactionFilter = TransactionFilter(); search = "" }
                }
                .frame(maxHeight: .infinity)
            } else {
                table(rows)
            }
        }
        .searchable(text: $search, prompt: "Search places or categories")
        .navigationTitle("Transactions")
        .navigationSubtitle(rows.count == 1 ? "1 transaction" : "\(rows.count) transactions")
        .inspector(isPresented: $showInspector) {
            Group {
                if let selected {
                    TransactionInspector(transaction: selected)
                } else {
                    ContentUnavailableView(selection.isEmpty ? "No Selection" : "\(selection.count) Selected",
                                           systemImage: "cursorarrow.click",
                                           description: Text(selection.isEmpty ? "Click a transaction to see the details and change its category."
                                                                               : "Right-click to change the category for all of them."))
                }
            }
            .inspectorColumnWidth(min: 260, ideal: 300, max: 360)
        }
        .toolbar {
            ToolbarItem {
                Button { showInspector.toggle() } label: { Label("Details", systemImage: "sidebar.trailing") }
                    .help("Show or hide details")
            }
        }
    }

    private func table(_ rows: [Transaction]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Date", value: \.date) { t in
                Text(t.date, format: .dateTime.month(.abbreviated).day().year())
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 105, max: 125)

            TableColumn("Place", value: \.merchant) { t in
                HStack(spacing: 10) {
                    MerchantIcon(name: t.merchant, category: t.category, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(t.merchant).font(.body.weight(.medium)).lineLimit(1)
                        Text(t.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.vertical, 3)
            }
            .width(min: 180, ideal: 280)

            TableColumn("Category", value: \.categorySortKey) { t in
                CategoryPill(category: t.isUnknown ? nil : t.category, sparkle: t.needsCheck && !t.isUnknown) { c in
                    store.setCategory(c, for: [t.id], wholePlace: true)
                }
                .help(t.needsCheck ? "Sorted by Apple Intelligence. Click to change." : "Click to change the category for \(t.merchant)")
            }
            .width(min: 150, ideal: 190)

            TableColumn("Account", value: \.account) { t in
                Text(t.account).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 130)

            TableColumn("Amount", value: \.amount) { t in
                AmountText(transaction: t)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 80, ideal: 100)
        }
        .contextMenu(forSelectionType: Transaction.ID.self) { ids in
            let chosen = store.transactions.filter { ids.contains($0.id) }
            if let first = chosen.first {
                let places = Set(chosen.map(\.merchantKey))
                Menu(places.count == 1 ? "Change Category for \(first.merchant)" : "Change Category for \(places.count) Places") {
                    CategoryChoices { store.setCategory($0, for: ids, wholePlace: true) }
                }
                Menu(chosen.count == 1 ? "Change Only This Charge" : "Change Only These \(chosen.count) Charges") {
                    CategoryChoices { store.setCategory($0, for: ids, wholePlace: false) }
                }
                if !store.stories.isEmpty {
                    Divider()
                    Menu("Trip or Event") { StoryChoices(ids: ids) }
                }
                if places.count == 1 {
                    Divider()
                    Button("Everything at \(first.merchant)") { store.showPlace(first.merchant) }
                }
            }
        } primaryAction: { ids in
            // Double-click a charge: everything ever spent at that place.
            if let t = store.transactions.first(where: { ids.contains($0.id) }) { store.showPlace(t.merchant) }
        }
    }
}

struct AmountText: View {
    let transaction: Transaction

    var body: some View {
        let moneyIn = transaction.amount < 0
        Text(moneyIn ? "+" + Money.format(-transaction.amount) : Money.format(transaction.amount))
            .monospacedDigit()
            .foregroundStyle(moneyIn ? Theme.good : (transaction.countsAsSpending ? Color.primary : Color.secondary))
    }
}

// MARK: - Filters

private struct FilterBar: View {
    @Environment(BudgetStore.self) private var store
    let rows: [Transaction]

    var body: some View {
        @Bindable var store = store
        let spent = rows.filter(\.countsAsSpending).reduce(0) { $0 + $1.amount }
        HStack(spacing: 10) {
            Picker("Month", selection: $store.transactionFilter.month) {
                Text("All Months").tag(Month?.none)
                Divider()
                ForEach(store.months.reversed()) { Text($0.title).tag(Optional($0)) }
            }
            Picker("Category", selection: $store.transactionFilter.category) {
                Text("All Categories").tag(Category?.none)
                Divider()
                ForEach(Category.allCases) { c in Label(c.displayName, systemImage: c.symbol).tag(Optional(c)) }
            }
            if store.accounts.count > 1 {
                Picker("Account", selection: $store.transactionFilter.accountID) {
                    Text("All Accounts").tag(UUID?.none)
                    Divider()
                    ForEach(store.accounts) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            if let key = store.transactionFilter.merchantKey {
                chip(store.place(key)?.name ?? "One place", symbol: "mappin.circle.fill") { store.transactionFilter.merchantKey = nil }
            }
            if let name = store.transactionFilter.merchant {
                chip(name, symbol: "mappin.circle.fill") { store.transactionFilter.merchant = nil }
            }
            if store.transactionFilter.needsCheck {
                chip("AI guesses", symbol: "sparkles") { store.transactionFilter.needsCheck = false }
            }
            if let id = store.transactionFilter.storyID {
                chip(store.stories.first { $0.id == id }?.name ?? "One trip", symbol: "airplane") { store.transactionFilter.storyID = nil }
            }
            if store.transactionFilter != TransactionFilter() {
                Button("Clear") { store.transactionFilter = TransactionFilter() }
                    .buttonStyle(.borderless)
            }
            Spacer()
            Text("\(Money.format(spent)) spent")
                .font(.callout.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .contentTransition(.numericText(value: spent))
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func chip(_ title: String, symbol: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
            Text(title).lineLimit(1)
            Button(action: remove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.accent.opacity(0.14)))
    }
}

// MARK: - Inspector

private struct TransactionInspector: View {
    @Environment(BudgetStore.self) private var store
    let transaction: Transaction
    @State private var name = ""
    @State private var note = ""

    private var sameplace: [Transaction] { store.transactions.filter { $0.merchantKey == transaction.merchantKey } }

    private var reason: (text: String, symbol: String) {
        if transaction.isOverride { return ("You chose this for just this charge.", "hand.point.up.left.fill") }
        switch transaction.source {
        case .user: return ("You chose this.", "person.fill.checkmark")
        case .known: return ("A business the Academy knows well.", "building.2.fill")
        case .bank: return ("Your bank's own category.", "building.columns.fill")
        case .generic: return ("Guessed from the name.", "text.magnifyingglass")
        case .ai: return (transaction.isUnknown ? "Not sorted yet." : "Sorted by Apple Intelligence, on this Mac.", "apple.intelligence")
        case .cloud: return ("Sorted by AI.", "sparkles")
        case .cloudGuess: return ("AI's best guess. Change it if it's wrong.", "sparkles")
        }
    }

    var body: some View {
        let t = transaction
        let place = sameplace
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(spacing: 10) {
                    MerchantIcon(name: t.merchant, category: t.category, size: 56)
                    TextField("Name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                        .onSubmit { store.renamePlace(t.merchantKey, to: name) }
                        .help("Click to rename this place")
                    AmountText(transaction: t)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("\(t.date.formatted(date: .complete, time: .omitted))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)

                group("Category") {
                    HStack {
                        CategoryPill(category: t.isUnknown ? nil : t.category) { store.setCategory($0, forPlace: t.merchantKey) }
                        Spacer()
                    }
                    Label(reason.text, systemImage: reason.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    // The distinction the whole app turns on: was this money consumed, or put away?
                    if t.amount > 0, t.lane == .everyday {
                        Button("This Was Saving or Investing, Not Spending", systemImage: "arrow.up.forward.circle") {
                            store.setCategory(.investing, forPlace: t.merchantKey)
                        }
                        .buttonStyle(.borderless)
                        .font(.callout)
                        .help("Money moved to a brokerage, a retirement account or another investment. It stops counting as spending.")
                    } else if t.amount > 0, t.lane == .investments {
                        Label("Counted as investing, not spending", systemImage: "arrow.up.forward.circle.fill")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(Theme.goldDeep)
                    }
                    Menu("Change only this charge") {
                        CategoryChoices { store.setCategory($0, for: [t.id], wholePlace: false) }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .font(.callout)
                }

                if !store.stories.isEmpty {
                    group("Trip or event") {
                        Menu {
                            StoryChoices(ids: [t.id])
                        } label: {
                            Label(store.story(containing: t.id)?.name ?? "Not part of one",
                                  systemImage: store.story(containing: t.id) == nil ? "minus.circle" : "airplane.departure")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        if store.story(containing: t.id) == nil {
                            Text("If this belongs to a trip, choose it here and it will count toward that trip.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                group("Your note") {
                    TextField("What was this? (optional)", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { store.setNote(note, for: t.id) }
                    Text("Anything you remember helps: who it was for, what trip, why. I use it when sorting, finding trips and answering questions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                group("From your statement") {
                    Text(t.description)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    Label(t.account, systemImage: "creditcard").font(.callout).foregroundStyle(.secondary)
                }

                if place.count > 1 {
                    group("All visits to \(t.merchant)") {
                        PlaceHistory(transactions: place)
                        Button("Everything at \(t.merchant)") { store.showPlace(t.merchant) }
                    }
                }
            }
            .padding(18)
        }
        .onAppear { name = transaction.merchant; note = transaction.note ?? "" }
        // Leaving a charge saves what was typed about it, whether or not Return was pressed.
        .onChange(of: transaction.id) { old, _ in
            store.setNote(note, for: old)
            name = transaction.merchant; note = transaction.note ?? ""
        }
        .onDisappear { store.setNote(note, for: transaction.id) }
        .onChange(of: transaction.merchant) { name = transaction.merchant }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct PlaceHistory: View {
    let transactions: [Transaction]

    var body: some View {
        let total = transactions.reduce(0) { $0 + $1.amount }
        let byMonth = Dictionary(grouping: transactions, by: \.month)
            .map { (month: $0.key, total: $0.value.reduce(0) { $0 + $1.amount }) }
            .sorted { $0.month < $1.month }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                stat("Total", Money.format(total, cents: false))
                Spacer()
                stat("Visits", "\(transactions.count)")
                Spacer()
                stat("Usually", Money.format(total / Double(transactions.count)))
            }
            if byMonth.count > 1 {
                Chart(byMonth, id: \.month) { item in
                    BarMark(x: .value("Month", item.month.firstDay, unit: .month), y: .value("Spent", max(item.total, 0)))
                        .cornerRadius(3)
                        .foregroundStyle(Theme.accent.gradient)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) { _ in
                        AxisValueLabel(format: .dateTime.month(.narrow), centered: true)
                    }
                }
                .chartYAxis(.hidden)
                .frame(height: 70)
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value).font(.headline).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Every trip and event, for a menu that moves charges into one (or out of all of them).
struct StoryChoices: View {
    private var store: BudgetStore { .shared }
    let ids: Set<Transaction.ID>

    var body: some View {
        let current = ids.count == 1 ? ids.first.flatMap { store.story(containing: $0) } : nil
        ForEach(store.stories) { story in
            Button {
                store.move(ids, to: story)
            } label: {
                if current?.id == story.id { Label(story.name, systemImage: "checkmark") } else { Text(story.name) }
            }
        }
        Divider()
        Button("Not Part of a Trip or Event") { store.move(ids, to: nil) }
    }
}
