import SwiftUI
import Charts

/// Everything ever spent at one place. A place is a name: however many ways a business is
/// spelled on statements ("WESTSIDE MKT #12", "TST* WESTSIDE MARKET"), once those lines carry
/// the same tidy name they are one place here. Reached by double-clicking any charge.
struct PlaceView: View {
    private var store: BudgetStore { .shared }
    let name: String
    /// False when rendered for a test snapshot.
    var scrolls = true
    @State private var draft = ""
    @State private var note = ""

    private var charges: [Transaction] {
        store.transactions.filter { $0.merchant == name }.sorted { $0.date > $1.date }
    }

    var body: some View {
        let all = charges
        MaybeScroll(scrolls: scrolls) {
            VStack(alignment: .leading, spacing: 20) {
                Button { store.placeFocus = nil } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                if let first = all.first {
                    header(all, first)
                    orderLink(all)
                    noteField
                    tiles(all)
                    if Set(all.map(\.month)).count > 1 { monthly(all) }
                    spellings(all)
                    list(all)
                } else {
                    TonySays(title: "Nothing here any more", message: "This payee was renamed or combined with another one.")
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

    /// For a shop whose order history is on file: how many of these charges have their items, and the way to them.
    @ViewBuilder private func orderLink(_ all: [Transaction]) -> some View {
        let itemized = all.filter { store.orderDetail(for: $0.id) != nil }
        if !itemized.isEmpty {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox.fill").foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(itemized.count) of \(all.count) charges here have their items").font(.callout.weight(.medium))
                    Text("From your Amazon order history. Open any charge to see what was in it, or browse everything ordered.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open Amazon") { store.placeFocus = nil; store.orderOnly = nil; store.selection = .orders }
            }
            .padding(12)
            .background(Theme.accent.opacity(0.07), in: .rect(cornerRadius: 12, style: .continuous))
        }
    }

    private func header(_ all: [Transaction], _ first: Transaction) -> some View {
        let keys = Set(all.map(\.merchantKey))
        return HStack(alignment: .center, spacing: 16) {
            MerchantIcon(name: name, category: first.category, size: 64)
            VStack(alignment: .leading, spacing: 6) {
                EditableName(text: $draft, font: .system(size: 30, weight: .bold, design: .serif),
                             help: "Rename this payee. Give two payees the same name and they become one.",
                             commit: { rename(keys) }, cancel: { draft = name })
                HStack(spacing: 10) {
                    CategoryPill(category: first.isUnknown ? nil : first.category) { category in
                        for key in keys { store.setCategory(category, forPlace: key) }
                    }
                    let others = similar()
                    if !others.isEmpty {
                        Menu("Same Payee As…") {
                            ForEach(others, id: \.self) { other in
                                Button(other) { store.combinePlaces(other, into: name) }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Fold another spelling of this payee into this one")
                    }
                }
            }
            Spacer()
        }
    }

    /// Anything worth remembering about the place. Never required.
    private var noteField: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "text.bubble").foregroundStyle(.secondary).padding(.top, 3)
            VStack(alignment: .leading, spacing: 4) {
                TextField("Add a note about this payee (optional)", text: $note, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .onSubmit { store.setNote(note, forPlace: name) }
                Text("Who it's for, why, whether it's ending. I use notes when sorting, answering questions and estimating what's coming.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 12, style: .continuous))
        .onAppear { note = store.note(forPlace: name) }
        .onChange(of: name) { old, new in store.setNote(note, forPlace: old); note = store.note(forPlace: new) }
        .onDisappear { store.setNote(note, forPlace: name) }
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
                                Label(trip.name, systemImage: "airplane.departure").font(.caption).foregroundStyle(Theme.accent)
                            }
                        }
                        Spacer()
                        AmountText(transaction: t).monospacedDigit()
                        OriginalButton(id: t.id)
                    }
                    .padding(.vertical, 7)
                    if i < all.count - 1 { Divider() }
                }
            }
        }
    }
}

/// A plain page of charges: what a click on a bar or a row in an answer opens. One title, one
/// total, the places that make it up, and the charges. No filters, no table columns, no inspector.
struct ChargesView: View {
    private var store: BudgetStore { .shared }
    let filter: TransactionFilter
    /// False when rendered for a test snapshot.
    var scrolls = true

    private var title: String {
        if let title = filter.title { return title }
        var parts: [String] = []
        if let id = filter.storyID, let story = store.stories.first(where: { $0.id == id }) { parts.append(story.name) }
        if let c = filter.category { parts.append(c.displayName) }
        if let id = filter.accountID, let account = store.accounts.first(where: { $0.id == id }) { parts.append(account.name) }
        if let name = filter.merchant { parts.append(name) }
        if let m = filter.month { parts.append(m.title) }
        return parts.isEmpty ? "Charges" : parts.joined(separator: " · ")
    }

    var body: some View {
        let all = store.transactions(matching: filter).sorted { $0.date > $1.date }
        let total = all.reduce(0) { $0 + $1.amount }
        let places = Dictionary(grouping: all, by: \.merchant)
            .map { (name: $0.key, category: $0.value[0].category, count: $0.value.count, total: $0.value.reduce(0) { $0 + $1.amount }) }
            .sorted { abs($0.total) > abs($1.total) }
        MaybeScroll(scrolls: scrolls) {
            VStack(alignment: .leading, spacing: 20) {
                Button { store.chargesFocus = nil } label: { Label("Back", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                HStack(alignment: .lastTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.system(size: 30, weight: .bold, design: .serif))
                        Text(all.count == 1 ? "1 charge" : "\(all.count) charges").font(.title3).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(Money.format(abs(total), cents: false))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                // A trip or an occasion gets its own picture: them, there, holding a receipt from it.
                if let id = filter.storyID, let story = store.stories.first(where: { $0.id == id }), scrolls { TripPictureCard(story: story) }
                if all.isEmpty {
                    TonySays(title: "Nothing here", message: "No charges match. Try another month or category.", art: "nothing")
                } else {
                    if places.count > 1 {
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionHeader(title: "Where", subtitle: "Click a payee for everything you've ever paid them.")
                                ForEach(Array(places.prefix(8).enumerated()), id: \.element.name) { i, place in
                                    Button { store.showPlace(place.name) } label: {
                                        HStack(spacing: 12) {
                                            MerchantIcon(name: place.name, category: place.category, size: 28)
                                            Text(place.name).font(.body.weight(.medium)).lineLimit(1)
                                            Text(place.count == 1 ? "once" : "\(place.count) times").font(.callout).foregroundStyle(.secondary)
                                            Spacer()
                                            Text(Money.format(place.total, cents: false)).monospacedDigit()
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    if i < min(places.count, 8) - 1 { Divider().padding(.leading, 40) }
                                }
                                if places.count > 8 { Text("and \(places.count - 8) more payees below").font(.caption).foregroundStyle(.tertiary) }
                            }
                        }
                    }
                    Card {
                        VStack(alignment: .leading, spacing: 0) {
                            SectionHeader(title: "Every charge").padding(.bottom, 8)
                            ForEach(Array(all.prefix(400).enumerated()), id: \.element.id) { i, t in
                                HStack(spacing: 12) {
                                    Button { store.showPlace(t.merchant) } label: {
                                        HStack(spacing: 12) {
                                            Text(t.date.formatted(.dateTime.month(.abbreviated).day().year()))
                                                .monospacedDigit().foregroundStyle(.secondary)
                                                .frame(width: 110, alignment: .leading)
                                            Text(t.merchant).lineLimit(1)
                                            Spacer()
                                            AmountText(transaction: t).monospacedDigit()
                                        }
                                        .padding(.vertical, 6)
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                    OriginalButton(id: t.id)
                                }
                                if i < min(all.count, 400) - 1 { Divider() }
                            }
                            if all.count > 400 {
                                Button("See All \(all.count) in Transactions") {
                                    store.transactionFilter = filter
                                    store.selection = .transactions
                                }
                                .padding(.top, 10)
                            }
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(title)
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

/// A scroll view, except when a picture of the page is being taken (which can't draw one).
struct MaybeScroll<Content: View>: View {
    let scrolls: Bool
    @ViewBuilder var content: Content

    var body: some View {
        if scrolls { ScrollView { content } } else { content }
    }
}

/// The small button at the end of a charge's row: open the original statement at this line.
struct OriginalButton: View {
    let id: Transaction.ID

    var body: some View {
        Button { BudgetStore.shared.showOriginal(of: id) } label: { Image(systemName: "doc.text.magnifyingglass") }
            .buttonStyle(.borderless)
            .foregroundStyle(.tertiary)
            .help("Show this charge in its original statement")
    }
}
