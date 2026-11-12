import SwiftUI
import Charts

/// The items of one charge, printed on its receipt: what "Amazon $41.35" actually was.
struct OrderItemsList: View {
    let items: [OrderItem]
    let kind: OrderMatch.Kind
    /// What the card was charged, to explain any difference from the items.
    let charged: Double

    private var listed: Double { Double(items.reduce(0) { $0 + $1.cents }) / 100 }

    private var footnote: String? {
        switch kind {
        case .exact: nil
        case .lessCredit: "Items come to \(Money.format(listed)). Points or a gift balance covered \(Money.format(listed - charged))."
        case .approximate: "Items as ordered. Weighed items, bag fees and tips make up the difference."
        case .recorded:
            listed - charged > 0.005 ? "Amazon's own payment record ties this charge to this order. Items come to \(Money.format(listed)); points or a gift balance paid \(Money.format(listed - charged))."
                : charged - listed > 0.005 ? "Amazon's own payment record ties this charge to this order. The order was paid in more than one charge."
                : "Amazon's own payment record ties this charge to this order."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(items.count == 1 ? "1 ITEM" : "\(items.count) ITEMS")
                .font(Theme.mono(10.5, .bold)).tracking(1.2).foregroundStyle(.secondary)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                ReceiptLine(value: Money.format(Double(item.cents) / 100)) {
                    Text(item.quantity > 1 ? "\(item.quantity) × \(item.name)" : item.name)
                        .font(.callout).lineLimit(2).help(item.name)
                }
            }
            if let footnote {
                Text(footnote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Amazon, opened up: every order from the order histories that were added (Amazon, Whole Foods,
/// Kindle), what was in it, where the money went, and how it lines up with the card charges.
/// A closer look at charges the statements only name; the rest of the app works the same without it.
struct OrdersView: View {
    private var store: BudgetStore { .shared }
    @FocusState private var searching: Bool
    @State private var open: String?
    @State private var read: String?
    /// False when rendered for a test snapshot.
    var scrolls = true

    typealias Row = BudgetStore.OrderRow

    /// One order: the things in it, what they came to, and the charges that paid for it.
    struct Order: Identifiable {
        let id: String
        var date: Date
        var who: String?
        var rows: [Row] = []
        var net: Int { rows.reduce(0) { $0 + $1.net } }
        var refunded: Int { rows.reduce(0) { $0 + $1.item.cents - $1.net } }
        var charges: [UUID] { var seen: Set<UUID> = []; return rows.compactMap(\.charge).filter { seen.insert($0).inserted } }
    }

    private func inStretch(_ month: Month) -> Bool {
        switch store.orderScope {
        case .all: true
        case .year(let year): month.year == year
        case .month(let m): month == m
        }
    }

    /// Everything on screen follows from these: the stretch, the person, the search, and the category clicked.
    private func rows(ignoringCategory: Bool = false) -> [Row] {
        if let only = store.orderOnly { return store.orderRows.filter { $0.item.orderID == only && $0.item.cents > 0 } }
        let query = PlacesView.squeeze(store.orderSearch)
        return store.orderRows.filter { row in
            guard row.item.cents > 0, inStretch(row.month) else { return false }
            if let who = store.orderWho, row.item.who != who { return false }
            if !ignoringCategory, let kind = store.orderKind, row.kind != kind { return false }
            return query.isEmpty || row.haystack.contains(query)
        }
    }

    private var scopeTitle: String {
        switch store.orderScope {
        case .all: "All Time"
        case .year(let year): String(year)
        case .month(let month): month.title
        }
    }
    /// Nothing narrowing the page but the stretch: the state the tie-out and the summary are about.
    private var plain: Bool {
        store.orderWho == nil && store.orderKind == nil && store.orderOnly == nil && store.orderSearch.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func money(_ cents: Int, cents showCents: Bool = true) -> String { Money.format(Double(cents) / 100, cents: showCents) }
    private static let day = Date.FormatStyle.dateTime.month(.abbreviated).day().year()

    var body: some View {
        @Bindable var store = store
        let everything = rows(ignoringCategory: true)
        let list = store.orderKind == nil ? everything : everything.filter { $0.kind == store.orderKind }
        let finding = !store.orderSearch.trimmingCharacters(in: .whitespaces).isEmpty
        MaybeScroll(scrolls: scrolls) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Amazon").font(.system(size: 30, weight: .bold, design: .serif))
                    Text("What was inside the boxes: every Amazon, Whole Foods and Kindle order, and where that money went.")
                        .font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let only = store.orderOnly {
                    HStack(spacing: 10) {
                        Label("Showing one order: \(only)", systemImage: "shippingbox.fill").font(.callout.weight(.medium))
                        Button("Show Everything") { withAnimation(.snappy(duration: 0.2)) { store.orderOnly = nil } }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Theme.accent.opacity(0.08), in: .rect(cornerRadius: 10, style: .continuous))
                } else {
                    controls
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Find anything you ordered: coffee, charger, a book title…", text: $store.orderSearch)
                            .textFieldStyle(.plain)
                            .font(.title3)
                            .focused($searching)
                        if finding {
                            Button { store.orderSearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(Theme.sheet, in: .rect(cornerRadius: 12, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(searching ? Theme.accent.opacity(0.55) : Theme.hairline) }
                }

                if everything.isEmpty {
                    TonySays(title: finding ? "Nothing ordered by that name" : "No orders in \(scopeTitle)",
                             message: finding ? "Nothing matches “\(store.orderSearch)” in \(scopeTitle.lowercased()). Try one word of what it was, or look in All Time."
                                              : "The order history on file has nothing here. Step to another stretch, or choose All Time.",
                             art: "nothing")
                } else if store.orderOnly != nil {
                    listing(list)
                } else {
                    if plain { shortVersion(list) }
                    // Side by side when there is room for both to be read in full; one under the other when not.
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 18) { summary(list, finding: finding); ring(everything) }
                        VStack(alignment: .leading, spacing: 18) { summary(list, finding: finding); ring(everything) }
                    }
                    trend(list)
                    if !finding { favourites(list) }
                    if plain { tieOut() }
                    listing(list)
                }
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Amazon")
        .navigationSubtitle(store.orderOnly == nil ? scopeTitle : "One order")
    }

    // MARK: The stretch and the person

    private var controls: some View {
        @Bindable var store = store
        let months = Array(Set(store.orderRows.map(\.month))).sorted()
        let years = Array(Set(months.map(\.year))).sorted()
        let kind = Binding<Int>(
            get: { switch store.orderScope { case .all: 0; case .year: 1; case .month: 2 } },
            set: { new in
                // Stepping in keeps you where you were: a year opens on its latest month, a month's year on that year.
                let year: Int = switch store.orderScope { case .year(let y): y; case .month(let m): m.year; case .all: years.last ?? 2000 }
                switch new {
                case 1: store.orderScope = .year(year)
                case 2: store.orderScope = .month(months.last { $0.year == year } ?? months.last ?? Month(date: .now))
                default: store.orderScope = .all
                }
            })
        return HStack(spacing: 12) {
            Picker("Stretch", selection: kind) {
                Text("All Time").tag(0); Text("Year").tag(1); Text("Month").tag(2)
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            switch store.orderScope {
            case .all: EmptyView()
            case .year(let year):
                StretchStepper(title: String(year), older: years.last { $0 < year }.map { y in { store.orderScope = .year(y) } },
                        newer: years.first { $0 > year }.map { y in { store.orderScope = .year(y) } })
            case .month(let month):
                StretchStepper(title: month.title, older: months.last { $0 < month }.map { m in { store.orderScope = .month(m) } },
                        newer: months.first { $0 > month }.map { m in { store.orderScope = .month(m) } })
            }
            Spacer()
            // Whose orders: only worth asking once more than one person's history is here.
            if store.orderPeople.count > 1 {
                Picker("Whose", selection: $store.orderWho) {
                    Text("Everyone").tag(String?.none)
                    ForEach(store.orderPeople, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
        }
    }

    // MARK: The short version

    /// What was bought more than once, most often first.
    private static func repeats(_ list: [Row]) -> [(name: String, times: Int, cents: Int)] {
        Dictionary(grouping: list, by: \.name).map { (name: $0.key, times: $0.value.count, cents: $0.value.reduce(0) { $0 + $1.net }) }
            .filter { $0.times >= 3 }
            .sorted { ($0.times, $0.cents, $1.name) > ($1.times, $1.cents, $0.name) }
    }

    /// The facts the model writes its few sentences from: totals the app has already worked out.
    private func facts(_ list: [Row]) -> String {
        let total = list.reduce(0) { $0 + $1.net }
        var lines = ["Stretch: \(scopeTitle)", "Orders: \(Set(list.map(\.item.orderID)).count), items: \(list.count), total after refunds: \(Self.money(total, cents: false))"]
        let byCategory = Dictionary(grouping: list, by: \.kind).map { ($0.key, $0.value.reduce(0) { $0 + $1.net }) }.sorted { $0.1 > $1.1 }
        lines.append("By kind of thing: " + byCategory.prefix(7).map { "\($0.0) \(Self.money($0.1, cents: false))" }.joined(separator: "; "))
        let people = Dictionary(grouping: list.filter { $0.item.who != nil }, by: { $0.item.who! }).map { ($0.key, $0.value.reduce(0) { $0 + $1.net }) }.sorted { $0.1 > $1.1 }
        if people.count > 1 { lines.append("By who ordered: " + people.map { "\($0.0) \(Self.money($0.1, cents: false))" }.joined(separator: "; ")) }
        lines.append("Biggest single items: " + list.sorted { $0.net > $1.net }.prefix(6).map { "\($0.name) \(Self.money($0.net, cents: false))" }.joined(separator: "; "))
        let again = Self.repeats(list).prefix(6)
        if !again.isEmpty { lines.append("Bought again and again: " + again.map { "\($0.name), \($0.times) times, \(Self.money($0.cents, cents: false))" }.joined(separator: "; ")) }
        // The stretch before, for comparison.
        let before: [Row]? = switch store.orderScope {
        case .all: nil
        case .year(let y): store.orderRows.filter { $0.month.year == y - 1 && $0.item.cents > 0 }
        case .month(let m): store.orderRows.filter { $0.month == m.adding(-1) && $0.item.cents > 0 }
        }
        if let before, !before.isEmpty { lines.append("The stretch before: \(Self.money(before.reduce(0) { $0 + $1.net }, cents: false)) across \(Set(before.map(\.item.orderID)).count) orders") }
        if let through = store.orderCoverage.through, case .all = store.orderScope {
            lines.append("Order history runs from \(list.map(\.date).min().map { $0.formatted(.dateTime.year()) } ?? "") to \(through.formatted(Self.day))")
        }
        return lines.joined(separator: "\n")
    }

    /// For tests: the few sentences for the stretch on show, written now.
    func shortVersionForTest() async -> String? {
        let list = rows()
        return await store.orderRead(key: scopeTitle, basis: "\(list.count)|\(list.reduce(0) { $0 + $1.net })", facts: facts(list))
    }

    @ViewBuilder private func shortVersion(_ list: [Row]) -> some View {
        let key = scopeTitle
        let basis = "\(list.count)|\(list.reduce(0) { $0 + $1.net })"
        Group {
            if let read {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "sparkles").foregroundStyle(Theme.accent).padding(.top, 2)
                    Text(read).font(.system(size: 16, design: .serif)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.sheet, in: .rect(cornerRadius: 14, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline) }
                .transition(.opacity)
            }
        }
        .task(id: key + basis) {
            guard scrolls else { return }
            read = nil
            let text = await store.orderRead(key: key, basis: basis, facts: facts(list))
            withAnimation(.easeOut(duration: 0.3)) { read = text }
        }
    }

    // MARK: What it came to

    private func summary(_ list: [Row], finding: Bool) -> some View {
        let ordered = list.reduce(0) { $0 + $1.item.cents }, net = list.reduce(0) { $0 + $1.net }
        let orders = Set(list.map(\.item.orderID)).count
        var title = ["What was ordered", scopeTitle]
        if let who = store.orderWho { title.append(who) }
        if let kind = store.orderKind { title.append(kind) }
        if finding { title.append("“\(store.orderSearch.trimmingCharacters(in: .whitespaces))”") }
        return ReceiptPaper(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title.joined(separator: " · ").uppercased()).font(Theme.mono(10.5, .bold)).tracking(1.2).foregroundStyle(.secondary)
                ReceiptRule()
                ReceiptLine(value: Self.money(ordered)) { Text("\(orders.formatted()) \(orders == 1 ? "order" : "orders"), \(list.count.formatted()) \(list.count == 1 ? "item" : "items")") }
                if ordered != net {
                    ReceiptLine(value: "−" + Self.money(ordered - net), valueColor: Theme.good) { Text("Refunded") }
                }
                ReceiptRule()
                ReceiptLine(value: Self.money(net), bold: true) { Text("TOTAL").font(Theme.mono(13, .bold)) }
                if store.isReadingOrders {
                    Label("Still reading what each item is. Names and categories fill in as it goes.", systemImage: "sparkles")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 320)
    }

    // MARK: Where it went

    /// One colour per kind of thing, the same wherever it appears. Twelve colours that read apart
    /// in light and dark, taken in turn down the list of kinds.
    static func color(of kind: String) -> Color {
        guard let index = ItemSorter.kinds.firstIndex(of: kind), kind != "Other" else { return .gray }
        let palette: [Color] = [.pink, .blue, .orange, .purple, .mint, .brown, .indigo, .green, .red, .teal, .yellow, .cyan]
        return palette[index % palette.count]
    }

    /// Where the money went, by the kind of thing bought. Click a slice or a line to see only that kind;
    /// click it again to see everything.
    private func ring(_ list: [Row]) -> some View {
        let totals = Dictionary(grouping: list, by: \.kind)
            .map { (kind: $0.key, cents: $0.value.reduce(0) { $0 + $1.net }) }
            .filter { $0.cents > 0 }
            .sorted { ($0.cents, $1.kind) > ($1.cents, $0.kind) }
        let sum = max(1, totals.reduce(0) { $0 + $1.cents })
        let drawn = totals.filter { $0.cents * 250 >= sum }
        let chosen = store.orderKind
        let pick = { (kind: String) in
            withAnimation(.snappy(duration: 0.2)) { store.orderKind = chosen == kind ? nil : kind }
        }
        return Card(padding: 16) {
            HStack(alignment: .center, spacing: 14) {
                Chart(drawn, id: \.kind) { item in
                    SectorMark(angle: .value("Amount", item.cents), innerRadius: .ratio(0.62),
                               outerRadius: chosen == item.kind ? .ratio(1) : .ratio(0.93), angularInset: 1.5)
                        .cornerRadius(4)
                        .foregroundStyle(Self.color(of: item.kind).gradient)
                        .opacity(chosen == nil || chosen == item.kind ? 1 : 0.35)
                }
                .frame(width: 124, height: 124)
                // A click on the ring lands on a slice: slices start at twelve o'clock and run clockwise.
                .overlay {
                    GeometryReader { geo in
                        Color.clear.contentShape(Circle())
                            .onTapGesture { point in
                                let dx = point.x - geo.size.width / 2, dy = point.y - geo.size.height / 2
                                var turn = atan2(dx, -dy) / (2 * .pi)
                                if turn < 0 { turn += 1 }
                                let whole = Double(drawn.reduce(0) { $0 + $1.cents })
                                var run = 0.0
                                for item in drawn {
                                    run += Double(item.cents) / max(whole, 1)
                                    if turn <= run { pick(item.kind); return }
                                }
                            }
                    }
                }
                .help("Click a slice to see only that kind of thing")
                // Every name in full, and the whole line is the button.
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(totals.prefix(9), id: \.kind) { item in
                        Button { pick(item.kind) } label: {
                            HStack(spacing: 8) {
                                Circle().fill(Self.color(of: item.kind)).frame(width: 9, height: 9)
                                Text(item.kind).fontWeight(chosen == item.kind ? .semibold : .regular).fixedSize()
                                Spacer(minLength: 8)
                                Text("\(Int((Double(item.cents) / Double(sum) * 100).rounded()))%").foregroundStyle(.secondary).monospacedDigit()
                                    .frame(width: 32, alignment: .trailing)
                                Text(Self.money(item.cents, cents: false)).font(Theme.mono(12.5, .medium)).frame(width: 60, alignment: .trailing)
                            }
                            .font(.callout)
                            .padding(.vertical, 3).padding(.horizontal, 6)
                            .frame(maxWidth: .infinity)
                            .background(chosen == item.kind ? Theme.accent.opacity(0.12) : .clear, in: .rect(cornerRadius: 6, style: .continuous))
                            .opacity(chosen == nil || chosen == item.kind ? 1 : 0.5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(chosen == item.kind ? "Show everything again" : "Show only \(item.kind)")
                    }
                    if totals.count > 9 {
                        Menu("and \(totals.count - 9) smaller") {
                            ForEach(totals.dropFirst(9), id: \.kind) { item in
                                Button("\(item.kind)  \(Self.money(item.cents, cents: false))") { pick(item.kind) }
                            }
                        }
                        .menuStyle(.borderlessButton).fixedSize().font(.caption).padding(.leading, 6)
                    }
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: How it moved

    /// Years across all time, months across a year. The chart stops where the order history stops,
    /// and says so: a missing month is "not added yet", not "nothing bought".
    @ViewBuilder private func trend(_ list: [Row]) -> some View {
        let through = store.orderCoverage.through
        let ends = through.map { "Order history ends \($0.formatted(Self.day)). Anything ordered since isn't here until a newer one is added." }
        switch store.orderScope {
        case .month:
            if let ends, let through, case .month(let m) = store.orderScope, m == Month(date: through) {
                Text(ends).font(.caption).foregroundStyle(.secondary)
            }
        case .all:
            let bars = Dictionary(grouping: list, by: \.month.year).map { (year: $0.key, cents: $0.value.reduce(0) { $0 + $1.net }) }.sorted { $0.year < $1.year }
            chart(title: "By year", note: ends) {
                Chart(bars, id: \.year) { bar in
                    BarMark(x: .value("Year", String(bar.year)), y: .value("Ordered", Double(bar.cents) / 100), width: .ratio(0.62))
                        .cornerRadius(3).foregroundStyle(Theme.inkFill.gradient)
                }
                .chartXAxis { AxisMarks { value in
                    AxisValueLabel { if let y = value.as(String.self), bars.count <= 14 || (Int(y) ?? 0) % 2 == 0 { Text("’" + y.suffix(2)) } }
                } }
                // Click a year's bar to step into that year.
                .chartOverlay { proxy in Color.clear.barPointer(proxy) { label in
                    if let year = Int(label), bars.contains(where: { $0.year == year }) { withAnimation(.snappy(duration: 0.25)) { store.orderScope = .year(year) } }
                } }
                .help("Click a bar to open that year")
            }
        case .year(let year):
            let last = through.map { Month(date: $0) }
            let months = (1...12).map { Month(year: year, month: $0) }.filter { last == nil || $0 <= last! }
            let byMonth = Dictionary(grouping: list, by: \.month).mapValues { $0.reduce(0) { $0 + $1.net } }
            chart(title: "By month", note: last.map { $0.year == year } == true ? ends : nil) {
                Chart(months) { month in
                    BarMark(x: .value("Month", month.shortName), y: .value("Ordered", Double(byMonth[month] ?? 0) / 100), width: .ratio(0.62))
                        .cornerRadius(3).foregroundStyle(Theme.inkFill.gradient)
                }
                .chartXScale(domain: (1...12).map { Month(year: year, month: $0).shortName })
                // Click a month's bar to step into that month.
                .chartOverlay { proxy in Color.clear.barPointer(proxy) { label in
                    if let month = months.first(where: { $0.shortName == label }), (byMonth[month] ?? 0) > 0 { withAnimation(.snappy(duration: 0.25)) { store.orderScope = .month(month) } }
                } }
                .help("Click a bar to open that month")
            }
        }
    }

    private func chart(title: String, note: String?, @ViewBuilder _ content: () -> some View) -> some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text(title.uppercased()).font(Theme.mono(10.5, .bold)).tracking(1.2).foregroundStyle(.secondary)
                content()
                    .chartYAxis { AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(Theme.hairline)
                        AxisValueLabel { if let v = value.as(Double.self) { Text(Money.format(v, cents: false)) } }
                    } }
                    .frame(height: 150)
                if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    // MARK: The things themselves

    /// What keeps coming back, and what cost the most: the two questions people ask of an order history.
    @ViewBuilder private func favourites(_ list: [Row]) -> some View {
        let again = Self.repeats(list).prefix(6)
        let biggest = list.sorted { $0.net > $1.net }.prefix(6)
        HStack(alignment: .top, spacing: 18) {
            if !again.isEmpty {
                Card(padding: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("BOUGHT AGAIN AND AGAIN").font(Theme.mono(10.5, .bold)).tracking(1.2).foregroundStyle(.secondary)
                        ForEach(Array(again), id: \.name) { item in
                            Button { store.orderSearch = item.name } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text("\(item.times)×").font(Theme.mono(12, .bold)).foregroundStyle(Theme.accent).frame(width: 34, alignment: .trailing)
                                    Text(item.name).font(.callout).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(Self.money(item.cents, cents: false)).font(Theme.mono(12, .medium))
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).help("Show every time this was ordered")
                        }
                    }
                }
            }
            Card(padding: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("THE BIGGEST THINGS").font(Theme.mono(10.5, .bold)).tracking(1.2).foregroundStyle(.secondary)
                    ForEach(Array(biggest)) { row in
                        Button { store.orderOnly = row.item.orderID } label: {
                            HStack(alignment: .center, spacing: 8) {
                                ProductThumb(asin: row.item.asin, kind: row.kind, size: 26)
                                Text(row.name).font(.callout).lineLimit(1)
                                Spacer(minLength: 8)
                                Text(row.date.formatted(.dateTime.month(.abbreviated).year())).font(.caption).foregroundStyle(.secondary)
                                Text(Self.money(row.net, cents: false)).font(Theme.mono(12, .medium)).frame(minWidth: 56, alignment: .trailing)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).help("Open this order")
                    }
                }
            }
        }
    }

    // MARK: How it ties to the cards

    /// Order totals and card charges are two sets of books. This says, without fuss, how far they
    /// agree for the stretch on screen and what the gap is made of; it narrows as more history is added.
    @ViewBuilder private func tieOut() -> some View {
        let charges = store.orderChargeList.filter { charge in
            guard let date = DateParsing.parse(charge.date, format: "yyyy-MM-dd") else { return false }
            return inStretch(Month(date: date))
        }
        if !charges.isEmpty {
            let total = charges.reduce(0) { $0 + $1.amount }
            let open = charges.filter { !$0.itemized }
            let openTotal = open.reduce(0) { $0 + $1.amount }
            let through = store.orderCoverage.through.map { DateParsing.iso.string(from: $0) } ?? ""
            let newer = open.filter { $0.date > through }
            let share = total > 0 ? Int(((total - openTotal) / total * 100).rounded()) : 0
            let firstCharge = store.orderChargeList.map(\.date).min() ?? ""
            let stretch = rows(ignoringCategory: true)
            let unpaid = Dictionary(grouping: stretch, by: \.item.orderID).filter { !$0.value.contains { $0.charge != nil } }
            let early = unpaid.filter { ($0.value.map { DateParsing.iso.string(from: $0.date) }.max() ?? "") < firstCharge }.count
            let lastCharge = store.orderChargeList.map(\.date).max() ?? ""
            let late = unpaid.filter { ($0.value.map { DateParsing.iso.string(from: $0.date) }.min() ?? "") > lastCharge }.count
            Card(padding: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("HOW THIS TIES TO YOUR CARDS").font(Theme.mono(10.5, .bold)).tracking(1.2).foregroundStyle(.secondary)
                        Spacer()
                        Text("\(share)% of the dollars tie").font(.callout.weight(.medium)).foregroundStyle(share >= 95 ? Theme.good : .primary)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.08))
                            Capsule().fill(Theme.inkFill.gradient).frame(width: max(4, geo.size.width * CGFloat(share) / 100))
                        }
                    }
                    .frame(height: 7)
                    ReceiptLine(value: Money.format(total)) { Text("\(charges.count.formatted()) card charges from these shops, \(scopeTitle.lowercased())").font(.callout) }
                    ReceiptLine(value: Money.format(total - openTotal)) { Text("\((charges.count - open.count).formatted()) of them matched to an order, item by item").font(.callout) }
                    if !open.isEmpty {
                        ReceiptLine(value: Money.format(openTotal)) {
                            Button {
                                store.showCharges(TransactionFilter(ids: Set(open.map(\.id)), title: "Amazon charges with no order behind them"))
                            } label: {
                                (Text("\(open.count.formatted()) not matched") + Text("  See them").foregroundStyle(Theme.accent)).font(.callout)
                            }
                            .buttonStyle(.plain).help("List the card charges no order explains")
                        }
                    }
                    Text(Self.gapNote(newer: newer.count, open: open.count, inStore: open.filter { $0.shop == .groceries }.count, unpaid: unpaid.count, early: early, late: late))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private static func gapNote(newer: Int, open: Int, inStore: Int, unpaid: Int, early: Int, late: Int) -> String {
        var parts: [String] = []
        if inStore > 0 {
            parts.append("\(inStore) of the unmatched \(inStore == 1 ? "is a grocery charge" : "are grocery charges"), most likely bought in the store, where there is no order to find.")
        }
        if open > inStore {
            parts.append(newer > 0 ? "\(newer) of the unmatched charges are newer than the order history, and will match when a fresh one is added."
                                   : "Unmatched charges are usually part-paid with a gift balance or points, or ordered on an account whose history isn't here.")
        }
        if unpaid > 0 {
            var why: [String] = []
            if early > 0 { why.append("\(early.formatted()) from before your statements begin") }
            if late > 0 { why.append("\(late.formatted()) newer than your last statement") }
            let other = unpaid - early - late
            if other > 0 { why.append("\(other.formatted()) paid with a gift balance or another card") }
            parts.append("\(unpaid.formatted()) \(unpaid == 1 ? "order has" : "orders have") no card charge: " + why.joined(separator: ", ") + ".")
        }
        parts.append("The two sets of books never tie to the cent; the gap narrows as more history is added.")
        return parts.joined(separator: " ")
    }

    // MARK: The orders themselves

    @ViewBuilder private func listing(_ list: [Row]) -> some View {
        @Bindable var store = store
        let limit = scrolls ? 250 : 12
        if store.orderOnly == nil {
            HStack {
                Picker("Show", selection: $store.orderList) {
                    ForEach(BudgetStore.OrderList.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                if let kind = store.orderKind {
                    Button { withAnimation(.snappy(duration: 0.2)) { store.orderKind = nil } } label: {
                        Label("Only \(kind)", systemImage: "xmark.circle.fill").font(.callout)
                    }
                    .buttonStyle(.bordered).help("Show everything again")
                }
                Spacer()
            }
        }
        if store.orderList == .orders || store.orderOnly != nil {
            let orders = Self.orders(list)
            Card(padding: 8) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(orders.prefix(limit).enumerated()), id: \.element.id) { index, order in
                        if index > 0 { Divider().padding(.leading, 14) }
                        OrderRowView(order: order, isOpen: open == order.id || store.orderOnly == order.id) {
                            withAnimation(.snappy(duration: 0.2)) { open = open == order.id ? nil : order.id }
                        }
                    }
                }
            }
            if orders.count > limit { more(orders.count, limit, "orders") }
        } else {
            Card(padding: 8) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(list.reversed().prefix(limit).enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().padding(.leading, 14) }
                        ItemRowView(row: row, isOpen: open == "item\(row.id)") {
                            withAnimation(.snappy(duration: 0.2)) { open = open == "item\(row.id)" ? nil : "item\(row.id)" }
                        }
                    }
                }
            }
            if list.count > limit { more(list.count, limit, "items") }
        }
    }

    private func more(_ count: Int, _ limit: Int, _ what: String) -> some View {
        Text("Showing the latest \(limit) of \(count.formatted()) \(what). Narrow the stretch or type a word to reach the rest.")
            .font(.callout).foregroundStyle(.secondary)
    }

    /// The rows gathered into their orders, newest first.
    static func orders(_ list: [Row]) -> [Order] {
        var found: [String: Order] = [:]
        for row in list {
            found[row.item.orderID, default: Order(id: row.item.orderID, date: row.date, who: row.item.who)].rows.append(row)
        }
        return found.values.map { order in
            var order = order
            order.date = order.rows.map(\.date).min() ?? order.date
            order.rows.sort { $0.net > $1.net }
            return order
        }
        .sorted { ($0.date, $0.id) > ($1.date, $1.id) }
    }
}

/// The card charge behind an order or an item, with the ways onward: the charge itself, its
/// payee, and the line in the original statement.
private struct ChargeLine: View {
    @Environment(BudgetStore.self) private var store
    let id: UUID

    var body: some View {
        if let charge = store.transactions.first(where: { $0.id == id }) {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Charged \(Money.format(charge.amount)) to \(charge.account) on \(charge.date.formatted(.dateTime.month(.abbreviated).day().year()))")
                        .font(.callout)
                    Text(charge.description).font(Theme.mono(11)).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 8) {
                    Button("Open the Charge", systemImage: "creditcard") {
                        store.showCharges(TransactionFilter(ids: [charge.id], title: "\(charge.merchant), \(charge.date.formatted(.dateTime.month(.abbreviated).day().year()))"))
                    }
                    .help("The card charge, with its category, note and trip")
                    Button("Everything at \(charge.merchant)", systemImage: "storefront") { store.showPlace(charge.merchant) }
                        .help("Every charge from this payee")
                    Button("Show in Statement", systemImage: "doc.text.magnifyingglass") { store.showOriginal(of: charge.id) }
                }
                .controlSize(.small)
            }
        }
    }
}

/// Opens a page at the shop in the person's browser.
private struct ShopLink: View {
    let title: String
    let url: URL?
    var body: some View {
        if let url {
            Button(title, systemImage: "arrow.up.forward.square") { NSWorkspace.shared.open(url) }
                .help("Opens in your browser. Amazon may ask you to sign in.")
        }
    }
}

private let noCharge = "No card charge on file for this. It may be older than your statements, paid with a gift balance or another card, or newer than the last statement."

/// One order. Clicking it opens the box: each item, any refund, and the charges that paid for it.
private struct OrderRowView: View {
    let order: OrdersView.Order
    let isOpen: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        let count = order.rows.count
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(alignment: .center, spacing: 12) {
                    // The first few things in the box, overlapping like a small pile.
                    HStack(spacing: -14) {
                        ForEach(Array(order.rows.prefix(3).enumerated()), id: \.element.id) { index, row in
                            ProductThumb(asin: row.item.asin, kind: row.kind, size: 38).zIndex(Double(3 - index))
                        }
                    }
                    .frame(width: 38 + CGFloat(min(count, 3) - 1) * 24, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(order.rows.prefix(3).map(\.name).joined(separator: ", ") + (count > 3 ? ", and \(count - 3) more" : ""))
                            .font(.body.weight(.medium)).lineLimit(1)
                        Text(([order.date.formatted(.dateTime.month(.abbreviated).day().year()), order.who, count == 1 ? "1 item" : "\(count) items",
                               order.refunded > 0 ? "\(Money.format(Double(order.refunded) / 100)) refunded" : nil,
                               order.charges.isEmpty ? "no card charge on file" : nil] as [String?]).compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Text(Money.format(Double(order.net) / 100)).font(Theme.mono(14, .semibold))
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .foregroundStyle(hovering || isOpen ? Theme.accent : Color.secondary.opacity(0.4))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(order.rows) { row in
                        HStack(alignment: .center, spacing: 10) {
                            ProductThumb(asin: row.item.asin, kind: row.kind, size: 44)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.item.quantity > 1 ? "\(row.item.quantity) × \(row.name)" : row.name).font(.callout)
                                if row.name != row.item.name {
                                    Text(row.item.name).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                                }
                            }
                            Spacer(minLength: 8)
                            Text(row.kind).font(.caption).foregroundStyle(.secondary)
                            Text(Money.format(Double(row.item.cents) / 100)).font(Theme.mono(12, .medium)).frame(minWidth: 70, alignment: .trailing)
                            if let url = row.item.productURL {
                                Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "arrow.up.forward.square") }
                                    .buttonStyle(.borderless).help("See this product on Amazon")
                            }
                        }
                    }
                    Divider()
                    if order.charges.isEmpty {
                        Text(noCharge).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(order.charges, id: \.self) { ChargeLine(id: $0) }
                    }
                    ShopLink(title: "This Order on Amazon", url: order.rows.first?.item.orderURL).controlSize(.small)
                }
                .padding(.horizontal, 10).padding(.bottom, 10)
            }
        }
        .background(hovering || isOpen ? Theme.accent.opacity(0.06) : .clear, in: .rect(cornerRadius: 9, style: .continuous))
        .onHover { hovering = $0 }
    }
}

/// One item ordered. Clicking it shows the listing as the shop wrote it, the way to it at the shop,
/// and the charge that paid for it.
private struct ItemRowView: View {
    @Environment(BudgetStore.self) private var store
    let row: BudgetStore.OrderRow
    let isOpen: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(alignment: .center, spacing: 12) {
                    ProductThumb(asin: row.item.asin, kind: row.kind, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.item.quantity > 1 ? "\(row.item.quantity) × \(row.name)" : row.name)
                            .font(.body.weight(.medium)).lineLimit(1)
                        Text(([row.kind, row.date.formatted(.dateTime.month(.abbreviated).day().year()), row.item.who] as [String?]).compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Text(Money.format(Double(row.net) / 100)).font(Theme.mono(14, .semibold))
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .foregroundStyle(hovering || isOpen ? Theme.accent : Color.secondary.opacity(0.4))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                VStack(alignment: .leading, spacing: 8) {
                    if row.name != row.item.name {
                        Text(row.item.name).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        ShopLink(title: "See It on Amazon", url: row.item.productURL)
                        Button("The Whole Order", systemImage: "shippingbox") { store.orderOnly = row.item.orderID }
                            .help("Everything that was ordered with it")
                    }
                    .controlSize(.small)
                    if let charge = row.charge { ChargeLine(id: charge) } else {
                        Text(noCharge).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 26).padding(.bottom, 10)
            }
        }
        .background(hovering || isOpen ? Theme.accent.opacity(0.06) : .clear, in: .rect(cornerRadius: 9, style: .continuous))
        .onHover { hovering = $0 }
    }
}
