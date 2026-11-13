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
    /// The statement spelling being made into a payee of its own, while its editor is open.
    @State private var separating: String?
    /// Whether the picker for combining this payee with another is open.
    @State private var combining = false

    private var charges: [Transaction] {
        store.charges(at: name)
    }

    var body: some View {
        let all = charges
        MaybeScroll(scrolls: scrolls) {
            VStack(alignment: .leading, spacing: 20) {
                if let first = all.first {
                    header(all, first)
                    orderLink(all)
                    noteField
                    tiles(all)
                    facts(all)
                    trips(all)
                    if Set(all.map(\.month)).count > 1 { monthly(all) }
                    spellings(all)
                    list(all)
                } else {
                    EmptyState(title: "Nothing here any more", message: "This payee was renamed or combined with another one.")
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
                Button("Open Amazon") { store.go(to: .orders) { store.orderOnly = nil } }
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
                    // Need or choice, as judged; one click says otherwise, and that is then final.
                    if first.countsAsSpending {
                        let chosen = store.isOptional(payee: keys, category: first.category)
                        Menu(chosen ? "A Choice" : "A Need") {
                            Button("A choice: could be trimmed") { store.setOptional(true, payee: keys) }
                            Button("A need: keeps the household running") { store.setOptional(false, payee: keys) }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .help("Whether spending here counts as chosen (it then shows under Where to trim) or needed. Change it if the app has it wrong.")
                    }
                    Button("Same Payee As…") { combining = true }
                        .buttonStyle(.borderless)
                        .help("Combine this payee with any other one: search by name or by how a statement writes it")
                        .popover(isPresented: $combining, arrowEdge: .bottom) {
                            SamePayeePicker(name: name) { combining = false }
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
        store.placeRenamed(to: new)
    }

    /// A few things worth knowing about this payee, each a sentence built from sums.
    @ViewBuilder private func facts(_ all: [Transaction]) -> some View {
        let lines = store.cached("facts|\(name)") { PayeeFacts.lines(for: all, among: store.transactions, asOf: store.transactions.last?.date ?? .now) }
        // What it is paid with, over the last year (or ever, if nothing lately): each a way to that card or account.
        let paid = store.cached("paid-with|\(name)") { () -> [PaidWith] in
            let cutoff = (store.transactions.last?.date ?? .now).addingTimeInterval(-365 * 86_400)
            let bought = all.filter { $0.amount > 0 }, recent = bought.filter { $0.date > cutoff }
            let pool = recent.count >= 3 ? recent : bought
            let total = pool.reduce(0) { $0 + $1.amount }
            guard pool.count >= 3, total > 0 else { return [] }
            return Dictionary(grouping: pool, by: \.accountID).map { PaidWith(id: $0.key, share: $0.value.reduce(0) { $0 + $1.amount } / total) }
                .filter { $0.share >= 0.05 }.sorted { ($0.share, $0.id.uuidString) > ($1.share, $1.id.uuidString) }
        }
        if !lines.isEmpty || !paid.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(lines, id: \.self) { line in
                    Label(line, systemImage: "sparkle").font(.callout).foregroundStyle(.secondary)
                }
                if !paid.isEmpty {
                    HStack(spacing: 6) {
                        Label("Paid with", systemImage: "creditcard").font(.callout).foregroundStyle(.secondary)
                        ForEach(Array(paid.prefix(3).enumerated()), id: \.element.id) { index, with in
                            if index > 0 { Text("·").foregroundStyle(.tertiary) }
                            LinkText(text: "\(store.accountLabel(with.id)) \(Int((with.share * 100).rounded()))%", help: "Open \(store.accountLabel(with.id))") { store.showAccount(with.id) }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
        }
    }

    /// The trips and events this payee was part of, each a way into that trip.
    @ViewBuilder private func trips(_ all: [Transaction]) -> some View {
        let touched = store.stories(touching: all)
        if !touched.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: touched.count == 1 ? "Part of a trip or event" : "Part of \(touched.count) trips and events")
                    ForEach(touched.prefix(8), id: \.story.id) { item in
                        Button { store.showCharges(TransactionFilter(storyID: item.story.id)) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item.story.kind == .trip ? "airplane.departure" : "sparkles")
                                    .font(.title3).foregroundStyle(Theme.accent).frame(width: 30)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.story.name).font(.body.weight(.medium)).lineLimit(1)
                                    Text(Self.span(item.story) + (item.during ? " · while you were away" : ""))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(Money.format(item.charges.reduce(0) { $0 + $1.amount })).monospacedDigit()
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Open \(item.story.name): everything spent on it")
                    }
                    if touched.count > 8 { Text("and \(touched.count - 8) more").font(.caption).foregroundStyle(.tertiary) }
                }
            }
        }
    }

    private static func span(_ story: Story) -> String {
        guard let from = DateParsing.isoDay(story.start), let to = DateParsing.isoDay(story.end) else { return story.start }
        let style = Date.FormatStyle.dateTime.month(.abbreviated).day().year()
        return story.start == story.end ? from.formatted(style) : "\(from.formatted(.dateTime.month(.abbreviated).day())) to \(to.formatted(style))"
    }

    private func tiles(_ all: [Transaction]) -> some View {
        let total = all.reduce(0) { $0 + $1.amount }
        let received = total < 0
        let first = all.last!.date, last = all.first!.date
        let thisYear = all.filter { Calendar.current.isDate($0.date, equalTo: last, toGranularity: .year) }.reduce(0) { $0 + $1.amount }
        // Somewhere money is spent that has also given some back: the total is what was kept, and says
        // so; a refund is not a visit, and does not pull down what a visit usually costs.
        let bought = all.filter { $0.amount > 0 }
        let charged = bought.reduce(0) { $0 + $1.amount }, back = charged - total
        let refunded = !received && back > 0.005
        let visits = refunded ? bought.count : all.count
        let year = Calendar.current.component(.year, from: last).formatted(.number.grouping(.never))
        return LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 14)], spacing: 14) {
            tile(received ? "Received, all time" : refunded ? "Spent, after refunds" : "Spent, all time", Money.format(abs(total), cents: false),
                 refunded ? "\(Money.format(back, cents: false)) refunded of \(Money.format(charged, cents: false))"
                          : "\(first.formatted(.dateTime.month(.abbreviated).year())) – \(last.formatted(.dateTime.month(.abbreviated).year()))")
            tile(visits == 1 ? "Visit" : "Visits", "\(visits)", visits > 1 ? "last on \(last.formatted(.dateTime.month(.abbreviated).day().year()))" : last.formatted(.dateTime.month(.wide).day().year()))
            tile("Typical", Money.format(abs(refunded ? charged : total) / Double(max(visits, 1))), "a visit")
            if refunded && thisYear < 0 {
                tile("Refunded in \(year)", Money.format(-thisYear, cents: false), "more than was spent")
            } else {
                tile("In \(year)", Money.format(abs(thisYear), cents: false), "so far")
            }
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
        // Money spent rises from the line and money given back hangs below it, each in the month it
        // happened: a refund is seen, where a single net bar would hide it (or show it as spending).
        let received = all.reduce(0) { $0 + $1.amount } < 0
        let bars = Dictionary(grouping: all, by: \.month)
            .map { month, charges in
                let net = charges.reduce(0) { $0 + $1.amount }
                let spent = charges.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount }
                return received ? MonthBars.Bar(month: month, total: abs(net)) : MonthBars.Bar(month: month, total: spent, back: spent - net)
            }
            .sorted { $0.month < $1.month }
        let refunds = bars.contains { $0.back > 0.005 }
        return Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Month by month", subtitle: refunds ? "Refunds are shown below the line, in the month they came back." : nil)
                MonthBars(bars: bars, help: "Click a month to see its charges at \(name)") { month in
                    store.showCharges(TransactionFilter(month: month, merchant: name))
                }
            }
        }
    }

    /// The different ways this place is written on statements, so it's clear what was gathered here.
    @ViewBuilder
    private func spellings(_ all: [Transaction]) -> some View {
        let groups = Dictionary(grouping: all) { MerchantResolver.spelling($0.description) }
            .map { (text: $0.key, charges: $0.value) }
            .sorted { ($0.charges.count, $1.text) > ($1.charges.count, $0.text) }
        if groups.count > 1 {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    SectionHeader(title: "How it appears on your statements",
                                  subtitle: "All of these are counted here as \(name). If one of them is someone else, separate it.")
                    ForEach(groups.prefix(12), id: \.text) { group in
                        HStack(spacing: 12) {
                            Text(group.text).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(group.charges.count == 1 ? "once" : "\(group.charges.count) times").font(.callout).foregroundStyle(.secondary)
                            Button("Not \(name)?") { separating = group.text }
                                .buttonStyle(.borderless).font(.callout)
                                .help("Make everything written this way its own payee, now and on future statements")
                                .popover(isPresented: Binding(get: { separating == group.text }, set: { if !$0 { separating = nil } }), arrowEdge: .trailing) {
                                    PayeeEditor(charges: group.charges, spelling: group.text) { separating = nil }
                                }
                        }
                    }
                    if groups.count > 12 { Text("and \(groups.count - 12) more").font(.caption).foregroundStyle(.tertiary) }
                }
            }
        }
    }

    /// "All 6 charges", or "4 charges and 2 refunds" where money has also come back from somewhere it is spent.
    private static func heading(_ all: [Transaction]) -> String {
        let back = all.filter { $0.amount < 0 }.count, bought = all.count - back
        guard back > 0, bought > 0, all.reduce(0, { $0 + $1.amount }) >= 0 else { return all.count == 1 ? "The charge" : "All \(all.count) charges" }
        return "\(bought == 1 ? "1 charge" : "\(bought) charges") and \(back == 1 ? "1 refund" : "\(back) refunds")"
    }

    private func list(_ all: [Transaction]) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    SectionHeader(title: Self.heading(all))
                    Spacer()
                    Button("Open in Transactions") {
                        store.go(to: .transactions) { store.transactionFilter = TransactionFilter(merchant: name) }
                    }
                }
                .padding(.bottom, 8)
                ForEach(Array(all.enumerated()), id: \.element.id) { i, t in
                    HStack(spacing: 12) {
                        Text(t.date.formatted(.dateTime.month(.abbreviated).day().year()))
                            .monospacedDigit()
                            .frame(width: 110, alignment: .leading)
                        VStack(alignment: .leading, spacing: 1) {
                            LinkText(text: store.accountLabel(t.accountID), help: "Open \(store.accountLabel(t.accountID))") {
                                store.showAccount(t.accountID)
                            }
                            if let trip = store.story(containing: t.id) {
                                Button { store.showCharges(TransactionFilter(storyID: trip.id)) } label: {
                                    Label(trip.name, systemImage: "airplane.departure").font(.caption).foregroundStyle(Theme.accent)
                                }
                                .buttonStyle(.plain)
                                .help("Open \(trip.name)")
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
/// total, the payees that make it up, and the charges. No filters, no table columns, no inspector.
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
                // A trip or event gets its own picture: them, there, holding a receipt from it.
                if let id = filter.storyID, let story = store.stories.first(where: { $0.id == id }), scrolls { TripPictureCard(story: story) }
                if all.isEmpty {
                    EmptyState(title: "Nothing here", message: "No charges match. Try another month or category.", art: "nothing")
                } else {
                    if places.count > 1 {
                        Card {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionHeader(title: "Where", subtitle: "Click a payee for everything you've ever paid them.")
                                ForEach(Array(places.prefix(8).enumerated()), id: \.element.name) { i, place in
                                    PayeeLine(name: place.name, category: place.category,
                                              detail: place.count == 1 ? "once" : "\(place.count) times",
                                              amount: place.total, iconSize: 28,
                                              amountText: Money.format(place.total, cents: false),
                                              help: "Open \(place.name): everything you've paid them") { store.showPlace(place.name) }
                                    if i < min(places.count, 8) - 1 { Divider().padding(.leading, 48) }
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
                                    store.go(to: .transactions) { store.transactionFilter = filter }
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
                                              set: { tab in if tab != store.selection { store.go(to: tab) } })) {
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

/// An account a payee is paid with, and its part of what the payee was paid.
struct PaidWith: Identifiable, Hashable {
    let id: UUID
    let share: Double
}

/// The small button at the end of a charge's row: open the original statement at this line.
struct OriginalButton: View {
    let id: Transaction.ID

    var body: some View {
        Button { BudgetStore.shared.showOriginal(of: id) } label: { Image(systemName: "doc.text.magnifyingglass") }
            .buttonStyle(.borderless)
            .foregroundStyle(.tertiary)
            .help("Show this charge in its original statement")
            .accessibilityLabel("Show in original statement")
    }
}

/// Says that the payee on screen and some other payee are one and the same. Any payee can be
/// chosen, not only those with a name like this one (an accountant billed under his initials):
/// the likely ones come first, and a search finds the rest by name or by how a statement writes them.
struct SamePayeePicker: View {
    @Environment(BudgetStore.self) private var store
    let name: String
    var done: () -> Void = {}
    /// False when rendered for a test snapshot.
    var scrolls = true
    @State private var search = ""
    /// The payee picked, while the person says which name to keep.
    @State private var picked: String?
    @State private var kept = ""
    /// The model's picks for which payees this most likely is; nil while it is still looking.
    @State private var guesses: [String]?

    var body: some View {
        Group {
            if let picked { confirm(picked) } else { choose }
        }
        .padding(16)
        .frame(width: 400)
        .task { guesses = CloudAI.isEnabled ? await store.likelySamePayees(as: name) : [] }
    }

    private var choose: some View {
        let all = store.mergeChoices(for: name, search: search)
        let searching = !search.trimmingCharacters(in: .whitespaces).isEmpty
        // The model's picks lead, and are not then repeated lower down. A search looks through everything alike.
        let guessed = searching ? [] : (guesses ?? []).filter { store.allPayeeNames.contains($0) && $0 != name }
        let choices = (likely: all.likely.filter { !guessed.contains($0.name) }, rest: all.rest.filter { !guessed.contains($0.name) })
        let looking = !searching && guesses == nil
        return VStack(alignment: .leading, spacing: 10) {
            Text("Which payee is \(name) the same as?").font(.headline).fixedSize(horizontal: false, vertical: true)
            SearchField(prompt: "Search every payee", text: $search, large: false, autofocus: true) {
                if searching, let first = choices.rest.first { pick(first.name) }
            }
            MaybeScroll(scrolls: scrolls) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if looking {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Looking for the likeliest matches…").font(.callout).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 8)
                    }
                    if !guessed.isEmpty {
                        heading("Most likely", symbol: "sparkles")
                        ForEach(guessed, id: \.self) { row(.init(name: $0)) }
                    }
                    if !choices.likely.isEmpty {
                        heading("Names like this one")
                        ForEach(choices.likely) { row($0) }
                    }
                    if !searching, looking || !guessed.isEmpty || !choices.likely.isEmpty, !choices.rest.isEmpty {
                        heading("Every other payee")
                    }
                    ForEach(choices.rest) { row($0) }
                    if guessed.isEmpty && choices.likely.isEmpty && choices.rest.isEmpty {
                        Text(searching ? "No payee has “\(search.trimmingCharacters(in: .whitespaces))” in its name or on a statement line."
                                       : "There are no other payees yet.")
                            .font(.callout).foregroundStyle(.secondary).padding(.vertical, 20).frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(height: 300, alignment: .top).clipped()
            Text("Finds a payee by its name or by how it is written on a statement.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func heading(_ title: String, symbol: String? = nil) -> some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).foregroundStyle(Theme.accent) }
            Text(title.uppercased()).foregroundStyle(.tertiary)
        }
        .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 2)
    }

    private func row(_ choice: BudgetStore.MergeChoice) -> some View {
        let charges = store.charges(at: choice.name)
        let count = charges.count == 1 ? "1 charge" : "\(charges.count) charges"
        return PayeeLine(name: choice.name, category: charges.first?.category ?? .other,
                         detail: choice.writtenAs.map { "written as \($0)" } ?? count,
                         amount: charges.reduce(0) { $0 + $1.amount }, iconSize: 26,
                         help: "\(name) and \(choice.name) are the same payee") { pick(choice.name) }
    }

    private func pick(_ other: String) {
        // The name with more history behind it is the likelier one to keep; the person has the last word.
        kept = store.charges(at: other).count > store.charges(at: name).count ? other : name
        picked = other
    }

    private func confirm(_ other: String) -> some View {
        let total = store.charges(at: name).count + store.charges(at: other).count
        return VStack(alignment: .leading, spacing: 12) {
            Text("Combine these two payees?").font(.headline)
            Picker("Keep the name", selection: $kept) {
                ForEach([name, other], id: \.self) { each in
                    let n = store.charges(at: each).count
                    Text("\(each)  ") + Text(n == 1 ? "1 charge" : "\(n) charges").foregroundStyle(.secondary)
                }
            }
            .pickerStyle(.radioGroup)
            Text("All \(total) charges will be under \(kept), and so will anything on a future statement written either way. A line that doesn't belong can be separated again from the payee's page.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Back") { picked = nil }
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Combine") { combine(other) }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func combine(_ other: String) {
        done()
        store.combinePlaces(kept == name ? other : name, into: kept)
        if kept != name { store.placeRenamed(to: kept) }
    }
}
