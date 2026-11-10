import SwiftUI
import Charts

/// Everything ever spent at one place. A place is a name: however many ways a business is
/// spelled on statements ("WESTSIDE MKT #12", "TST* WESTSIDE MARKET"), once those lines carry
/// the same tidy name they are one place here. Reached by double-clicking any charge.
struct PlaceView: View {
    private var store: BudgetStore { .shared }
    let name: String
    @State private var draft = ""

    private var charges: [Transaction] {
        store.transactions.filter { $0.merchant == name }.sorted { $0.date > $1.date }
    }

    var body: some View {
        let all = charges
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Button { store.placeFocus = nil } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                if let first = all.first {
                    header(all, first)
                    tiles(all)
                    if Set(all.map(\.month)).count > 1 { monthly(all) }
                    spellings(all)
                    list(all)
                } else {
                    TonySays(title: "Nothing here any more", message: "This place was renamed or combined with another one.")
                }
            }
            .padding(28)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(name)
        .onAppear { draft = name }
        .onChange(of: name) { draft = name }
    }

    private func header(_ all: [Transaction], _ first: Transaction) -> some View {
        let keys = Set(all.map(\.merchantKey))
        return HStack(alignment: .center, spacing: 16) {
            MerchantIcon(name: name, category: first.category, size: 64)
            VStack(alignment: .leading, spacing: 6) {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 30, weight: .bold, design: .serif))
                    .onSubmit { rename(keys) }
                    .help("Click to rename. Give two places the same name and they become one.")
                HStack(spacing: 10) {
                    CategoryPill(category: first.isUnknown ? nil : first.category) { category in
                        for key in keys { store.setCategory(category, forPlace: key) }
                    }
                    let others = similar()
                    if !others.isEmpty {
                        Menu("Same Place As…") {
                            ForEach(others, id: \.self) { other in
                                Button(other) { store.combinePlaces(other, into: name) }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Fold another spelling of this place into this one")
                    }
                }
            }
            Spacer()
        }
    }

    private func rename(_ keys: Set<String>) {
        let new = draft.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, new != name else { return }
        for key in keys { store.renamePlace(key, to: new) }
        store.placeFocus = new
    }

    /// Other places whose names look like this one: likely the same business under another spelling.
    private func similar() -> [String] {
        func words(_ s: String) -> [String] {
            s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 }
        }
        let mine = words(name)
        guard let lead = mine.first else { return [] }
        let names = Set(store.transactions.map(\.merchant)).subtracting([name])
        return names.filter { other in
            let theirs = words(other)
            return theirs.first == lead || !Set(theirs).intersection(mine).isEmpty && (other.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains(other))
        }.sorted().prefix(10).map { $0 }
    }

    private func tiles(_ all: [Transaction]) -> some View {
        let total = all.reduce(0) { $0 + $1.amount }
        let received = total < 0
        let first = all.last!.date, last = all.first!.date
        let thisYear = all.filter { Calendar.current.isDate($0.date, equalTo: last, toGranularity: .year) }.reduce(0) { $0 + $1.amount }
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
            tile(received ? "Received, all time" : "Spent, all time", Money.format(abs(total), cents: false),
                 "\(first.formatted(.dateTime.month(.abbreviated).year())) – \(last.formatted(.dateTime.month(.abbreviated).year()))")
            tile(all.count == 1 ? "Visit" : "Visits", "\(all.count)", all.count > 1 ? "last on \(last.formatted(.dateTime.month(.abbreviated).day().year()))" : last.formatted(.dateTime.month(.wide).day().year()))
            tile("Typical", Money.format(abs(total) / Double(all.count)), "a visit")
            tile("In \(Calendar.current.component(.year, from: last).formatted(.number.grouping(.never)))", Money.format(abs(thisYear), cents: false), "so far")
        }
    }

    private func tile(_ title: String, _ value: String, _ note: String) -> some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit()
                Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func monthly(_ all: [Transaction]) -> some View {
        let calendar = Calendar.current
        let byMonth = Dictionary(grouping: all) { calendar.date(from: calendar.dateComponents([.year, .month], from: $0.date)) ?? $0.date }
            .map { (month: $0.key, total: abs($0.value.reduce(0) { $0 + $1.amount })) }
            .sorted { $0.month < $1.month }
        return Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Month by month")
                Chart(byMonth, id: \.month) { item in
                    BarMark(x: .value("Month", item.month, unit: .month), y: .value("Total", item.total))
                        .foregroundStyle(Theme.accent.gradient)
                        .cornerRadius(4)
                }
                .chartYAxis { AxisMarks(format: .currency(code: "USD").precision(.fractionLength(0))) }
                .frame(height: 180)
            }
        }
    }

    /// The different ways this place is written on statements, so it's clear what was gathered here.
    @ViewBuilder
    private func spellings(_ all: [Transaction]) -> some View {
        let groups = Dictionary(grouping: all) { $0.description.replacingOccurrences(of: "[0-9#*]{3,}", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces) }
            .map { (text: $0.key, count: $0.value.count) }
            .sorted { $0.count > $1.count }
        if groups.count > 1 {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "How it appears on your statements", subtitle: "All of these are counted here as \(name).")
                    ForEach(groups.prefix(12), id: \.text) { group in
                        HStack {
                            Text(group.text).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(group.count == 1 ? "once" : "\(group.count) times").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if groups.count > 12 { Text("and \(groups.count - 12) more").font(.caption).foregroundStyle(.tertiary) }
                }
            }
        }
    }

    private func list(_ all: [Transaction]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    SectionHeader(title: all.count == 1 ? "The charge" : "All \(all.count) charges")
                    Spacer()
                    Button("Open in Transactions") {
                        store.transactionFilter = TransactionFilter(merchant: name)
                        store.selection = .transactions
                    }
                }
                .padding(.bottom, 8)
                ForEach(Array(all.enumerated()), id: \.element.id) { i, t in
                    HStack(spacing: 12) {
                        Text(t.date.formatted(.dateTime.month(.abbreviated).day().year()))
                            .monospacedDigit()
                            .frame(width: 110, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.account).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                            if let trip = store.story(containing: t.id) {
                                Label(trip.name, systemImage: "airplane.departure").font(.caption).foregroundStyle(Theme.gold)
                            }
                        }
                        Spacer()
                        AmountText(transaction: t).monospacedDigit()
                    }
                    .padding(.vertical, 7)
                    if i < all.count - 1 { Divider() }
                }
            }
        }
    }
}

/// Accounts and categories: the two things worth adjusting, on one page.
struct SetupView: View {
    private var store: BudgetStore { .shared }

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            Picker("Show", selection: Binding(get: { store.selection == .categories ? SidebarItem.categories : .accounts },
                                              set: { store.selection = $0 })) {
                Text("Accounts").tag(SidebarItem.accounts)
                Text("Categories").tag(SidebarItem.categories)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.large)
            .padding(.top, 14)
            if store.selection == .categories { CategoriesView() } else { AccountsView() }
        }
        .navigationTitle("Setup")
    }
}
