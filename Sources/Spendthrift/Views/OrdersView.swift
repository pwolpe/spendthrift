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

/// The order histories that were added, as a place to browse: every order and what was in it,
/// by all time, year or month, with where the money went and how it moved. A closer look at
/// charges the statements only name; the rest of the app works the same without it.
struct OrdersView: View {
    @Environment(BudgetStore.self) private var store
    @FocusState private var searching: Bool
    @State private var open: String?
    @State private var hoveredAngle: Double?
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

    /// Everything on screen follows from these: the stretch, the person, the search, and the category clicked.
    private func rows(ignoringCategory: Bool = false) -> [Row] {
        let query = PlacesView.squeeze(store.orderSearch)
        return store.orderRows.filter { row in
            guard row.item.cents > 0 else { return false }
            switch store.orderScope {
            case .all: break
            case .year(let year): if row.month.year != year { return false }
            case .month(let month): if row.month != month { return false }
            }
            if let who = store.orderWho, row.item.who != who { return false }
            if !ignoringCategory, let category = store.orderCategory, row.category != category { return false }
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

    private static func money(_ cents: Int) -> String { Money.format(Double(cents) / 100) }
    private static let day = Date.FormatStyle.dateTime.month(.abbreviated).day().year()

    var body: some View {
        @Bindable var store = store
        let everything = rows(ignoringCategory: true)
        let list = store.orderCategory == nil ? everything : everything.filter { $0.category == store.orderCategory }
        let finding = !store.orderSearch.trimmingCharacters(in: .whitespaces).isEmpty
        MaybeScroll(scrolls: scrolls) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Orders").font(.system(size: 30, weight: .bold, design: .serif))
                    Text("What was inside the boxes: every order, what it was, and where that money went.")
                        .font(.title3).foregroundStyle(.secondary)
                }
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

                if everything.isEmpty {
                    TonySays(title: finding ? "Nothing ordered by that name" : "No orders in \(scopeTitle)",
                             message: finding ? "Nothing matches “\(store.orderSearch)” in \(scopeTitle.lowercased()). Try one word of what it was, or look in All Time."
                                              : "The order history on file has nothing here. Step to another stretch, or choose All Time.",
                             art: "nothing")
                } else {
                    HStack(alignment: .top, spacing: 18) {
                        summary(list, finding: finding)
                        ring(everything)
                    }
                    trend(list)
                    listing(list)
                }
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Orders")
        .navigationSubtitle(scopeTitle)
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
                stepper(String(year), older: years.last { $0 < year }.map { y in { store.orderScope = .year(y) } },
                        newer: years.first { $0 > year }.map { y in { store.orderScope = .year(y) } })
            case .month(let month):
                stepper(month.title, older: months.last { $0 < month }.map { m in { store.orderScope = .month(m) } },
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

    private func stepper(_ title: String, older: (() -> Void)?, newer: (() -> Void)?) -> some View {
        HStack(spacing: 4) {
            Button { withAnimation(.snappy(duration: 0.2)) { older?() } } label: { Image(systemName: "chevron.left").frame(width: 18, height: 18) }
                .disabled(older == nil).help("Earlier")
            Text(title).font(.headline).frame(minWidth: 120)
            Button { withAnimation(.snappy(duration: 0.2)) { newer?() } } label: { Image(systemName: "chevron.right").frame(width: 18, height: 18) }
                .disabled(newer == nil).help("Later")
        }
    }

    // MARK: What it came to

    /// The total as a receipt, with what the cards were actually charged beside it: order totals and
    /// statements are two sets of books, and this is where they are shown side by side.
    private func summary(_ list: [Row], finding: Bool) -> some View {
        let ordered = list.reduce(0) { $0 + $1.item.cents }, net = list.reduce(0) { $0 + $1.net }
        let orders = Set(list.map(\.item.orderID)).count
        let chargeIDs = Set(list.compactMap(\.charge))
        let charged = store.transactions.filter { chargeIDs.contains($0.id) }.reduce(0.0) { $0 + $1.amount }
        let unpaid = Set(list.filter { $0.charge == nil }.map(\.item.orderID)).count
        var title = ["What was ordered", scopeTitle]
        if let who = store.orderWho { title.append(who) }
        if let category = store.orderCategory { title.append(category.displayName) }
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
                ReceiptRule()
                ReceiptLine(value: Money.format(charged)) {
                    Text("On your statements (\(chargeIDs.count) \(chargeIDs.count == 1 ? "charge" : "charges"))").foregroundStyle(.secondary)
                }
                Text(unpaid == 0 ? "Every order here has its card charge. Totals can still differ by points or a gift balance."
                                 : "\(unpaid.formatted()) \(unpaid == 1 ? "order has" : "orders have") no card charge on file: older than your statements, paid with a gift balance or another card, or newer than the last statement.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if store.isReadingOrders {
                    Label("Still reading what each item is. Names and categories fill in as it goes.", systemImage: "sparkles")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: 400)
    }

    // MARK: Where it went

    private func ring(_ list: [Row]) -> some View {
        let totals = Dictionary(grouping: list, by: \.category)
            .map { (category: $0.key, cents: $0.value.reduce(0) { $0 + $1.net }) }
            .filter { $0.cents > 0 }
            .sorted { ($0.cents, $1.category.rawValue) > ($1.cents, $0.category.rawValue) }
        let sum = max(1, totals.reduce(0) { $0 + $1.cents })
        let chosen = store.orderCategory
        return Card(padding: 16) {
            HStack(alignment: .center, spacing: 18) {
                Chart(totals.filter { $0.cents * 250 >= sum }, id: \.category) { item in
                    SectorMark(angle: .value("Amount", item.cents), innerRadius: .ratio(0.62),
                               outerRadius: chosen == item.category ? .ratio(1) : .ratio(0.93), angularInset: 1.5)
                        .cornerRadius(4)
                        .foregroundStyle(item.category.color.gradient)
                        .opacity(chosen == nil || chosen == item.category ? 1 : 0.35)
                }
                .frame(width: 150, height: 150)
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(totals.prefix(8), id: \.category) { item in
                        Button {
                            withAnimation(.snappy(duration: 0.2)) { store.orderCategory = chosen == item.category ? nil : item.category }
                        } label: {
                            HStack(spacing: 8) {
                                Circle().fill(item.category.color).frame(width: 9, height: 9)
                                Text(item.category.displayName).lineLimit(1)
                                    .fontWeight(chosen == item.category ? .semibold : .regular)
                                Spacer(minLength: 8)
                                Text("\(Int((Double(item.cents) / Double(sum) * 100).rounded()))%").foregroundStyle(.secondary).monospacedDigit()
                                Text(Self.money(item.cents)).font(Theme.mono(12, .medium)).frame(minWidth: 78, alignment: .trailing)
                            }
                            .font(.callout)
                            .opacity(chosen == nil || chosen == item.category ? 1 : 0.5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(chosen == item.category ? "Show every category again" : "Show only \(item.category.displayName)")
                    }
                    if totals.count > 8 {
                        Text("and \(totals.count - 8) smaller").font(.caption).foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
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

    // MARK: The orders themselves

    @ViewBuilder private func listing(_ list: [Row]) -> some View {
        @Bindable var store = store
        let limit = scrolls ? 250 : 14
        HStack {
            Picker("Show", selection: $store.orderList) {
                ForEach(BudgetStore.OrderList.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            if let category = store.orderCategory {
                Button { withAnimation(.snappy(duration: 0.2)) { store.orderCategory = nil } } label: {
                    Label("Only \(category.displayName)", systemImage: "xmark.circle.fill").font(.callout)
                }
                .buttonStyle(.bordered).help("Show every category again")
            }
            Spacer()
        }
        switch store.orderList {
        case .orders:
            let orders = Self.orders(list)
            Card(padding: 8) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(orders.prefix(limit).enumerated()), id: \.element.id) { index, order in
                        if index > 0 { Divider().padding(.leading, 14) }
                        OrderRowView(order: order, isOpen: open == order.id) {
                            withAnimation(.snappy(duration: 0.2)) { open = open == order.id ? nil : order.id }
                        }
                    }
                }
            }
            if orders.count > limit { more(orders.count, limit, "orders") }
        case .items:
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

/// The card charge behind an order or an item, with the way back to its statement.
private struct ChargeLine: View {
    @Environment(BudgetStore.self) private var store
    let id: UUID

    var body: some View {
        if let charge = store.transactions.first(where: { $0.id == id }) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Charged \(Money.format(charge.amount)) to \(charge.account) on \(charge.date.formatted(.dateTime.month(.abbreviated).day().year()))")
                        .font(.callout)
                    Text(charge.description).font(Theme.mono(11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Show in Statement", systemImage: "doc.text.magnifyingglass") { store.showOriginal(of: charge.id) }
            }
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
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(order.rows.prefix(3).map(\.name).joined(separator: ", ") + (count > 3 ? ", and \(count - 3) more" : ""))
                            .font(.body.weight(.medium)).lineLimit(1)
                        Text(([order.date.formatted(.dateTime.month(.abbreviated).day().year()), order.who, count == 1 ? "1 item" : "\(count) items",
                               order.refunded > 0 ? "\(Money.format(Double(order.refunded) / 100)) refunded" : nil] as [String?]).compactMap { $0 }.joined(separator: " · "))
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
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(order.rows) { row in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(row.category.color).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(row.item.quantity > 1 ? "\(row.item.quantity) × \(row.name)" : row.name).font(.callout)
                                if row.name != row.item.name {
                                    Text(row.item.name).font(.caption).foregroundStyle(.tertiary).lineLimit(2)
                                }
                            }
                            Spacer(minLength: 8)
                            Text(row.category.displayName).font(.caption).foregroundStyle(.secondary)
                            Text(Money.format(Double(row.item.cents) / 100)).font(Theme.mono(12, .medium)).frame(minWidth: 70, alignment: .trailing)
                        }
                    }
                    Divider()
                    if order.charges.isEmpty {
                        Text(noCharge).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(order.charges, id: \.self) { ChargeLine(id: $0) }
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 10)
            }
        }
        .background(hovering || isOpen ? Theme.accent.opacity(0.06) : .clear, in: .rect(cornerRadius: 9, style: .continuous))
        .onHover { hovering = $0 }
    }
}

/// One item ordered. Clicking it shows the listing as the shop wrote it and the charge that paid for it.
private struct ItemRowView: View {
    let row: BudgetStore.OrderRow
    let isOpen: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Circle().fill(row.category.color).frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.item.quantity > 1 ? "\(row.item.quantity) × \(row.name)" : row.name)
                            .font(.body.weight(.medium)).lineLimit(1)
                        Text(([row.category.displayName, row.date.formatted(.dateTime.month(.abbreviated).day().year()), row.item.who] as [String?]).compactMap { $0 }.joined(separator: " · "))
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
                VStack(alignment: .leading, spacing: 7) {
                    if row.name != row.item.name {
                        Text(row.item.name).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
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
