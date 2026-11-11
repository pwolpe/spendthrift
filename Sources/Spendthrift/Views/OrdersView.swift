import SwiftUI

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

/// Everything ordered, item by item, from the order histories that were added. A closer look
/// at charges the statements only name; the rest of the app works the same without it.
struct OrdersView: View {
    @Environment(BudgetStore.self) private var store
    @FocusState private var searching: Bool
    @State private var open: Int?
    /// False when rendered for a test snapshot.
    var scrolls = true

    private func rows() -> [BudgetStore.OrderRow] {
        let latest = store.months.last ?? Month(date: .now)
        let from: Month? = switch store.orderSpan {
        case .all: nil
        case .year: Month(year: latest.year, month: 1)
        case .last12: latest.adding(-11)
        }
        let query = PlacesView.squeeze(store.orderSearch)
        return store.orderRows.reversed().filter { row in
            if row.item.cents <= 0 { return false }
            if let from, Month(date: row.date) < from { return false }
            return query.isEmpty || row.haystack.contains(query)
        }
    }

    var body: some View {
        @Bindable var store = store
        let list = rows()
        let finding = !store.orderSearch.trimmingCharacters(in: .whitespaces).isEmpty
        let coverage = store.orderCoverage
        MaybeScroll(scrolls: scrolls) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Orders").font(.system(size: 30, weight: .bold, design: .serif))
                    Text("What was inside the boxes. Type anything to find when you bought it and what it cost.")
                        .font(.title3).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("Find an item: coffee, charger, a book title…", text: $store.orderSearch)
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
                    Picker("When", selection: $store.orderSpan) {
                        ForEach(PlacesView.Span.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }
                // How current this is, said plainly: order histories are added now and then, statements monthly.
                if let through = coverage.through {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Order history through \(through.formatted(.dateTime.month(.abbreviated).day().year())) · \(coverage.itemized) of \(coverage.charges) charges itemized")
                            .font(Theme.mono(11)).foregroundStyle(.secondary)
                        if coverage.newer > 0 {
                            Text("\(coverage.newer) newer \(coverage.newer == 1 ? "charge has" : "charges have") no items yet. They're counted as always; drop in a fresh order history whenever you have one.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if list.isEmpty {
                    TonySays(title: finding ? "Nothing ordered by that name" : "No orders in this stretch",
                             message: finding ? "Nothing matches “\(store.orderSearch)”\(store.orderSpan == .all ? "" : " in \(store.orderSpan.rawValue.lowercased())"). Try one word of the item's name."
                                              : "The order history on file has nothing in \(store.orderSpan.rawValue.lowercased()). Choose All Time to see everything.",
                             art: "nothing")
                } else {
                    summary(list, finding: finding)
                    Card(padding: 8) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(list.prefix(scrolls ? 300 : 25).enumerated()), id: \.element.id) { index, row in
                                if index > 0 { Divider().padding(.leading, 14) }
                                OrderRowView(row: row, isOpen: open == row.id) {
                                    withAnimation(.snappy(duration: 0.2)) { open = open == row.id ? nil : row.id }
                                }
                            }
                        }
                    }
                    if list.count > 300 {
                        Text("Showing the latest 300 of \(list.count.formatted()) items. Type a word to find any of the rest.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Orders")
        .navigationSubtitle(list.count == 1 ? "1 item" : "\(list.count.formatted()) items")
        .onAppear { searching = true }
    }

    /// The answer before the list: what the search came to, or where the money went by shelf.
    @ViewBuilder private func summary(_ list: [BudgetStore.OrderRow], finding: Bool) -> some View {
        let total = Double(list.reduce(0) { $0 + $1.item.cents }) / 100
        let title = finding ? "“\(store.orderSearch.trimmingCharacters(in: .whitespaces))” · \(store.orderSpan.rawValue)" : "By shelf · \(store.orderSpan.rawValue)"
        let shelves = Dictionary(grouping: list, by: \.item.shelf)
            .map { (name: $0.key, cents: $0.value.reduce(0) { $0 + $1.item.cents }) }
            .sorted { ($0.cents, $1.name) > ($1.cents, $0.name) }
        ReceiptPaper(padding: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title.uppercased()).font(Theme.mono(10.5, .bold)).tracking(1.2).foregroundStyle(.secondary)
                ReceiptRule()
                if finding {
                    ForEach(list.prefix(6)) { row in
                        ReceiptLine(value: Money.format(Double(row.item.cents) / 100)) { Text(row.item.name).lineLimit(1) }
                    }
                    if list.count > 6 { Text("and \(list.count - 6) more below").font(.caption).foregroundStyle(.tertiary) }
                } else {
                    ForEach(shelves.prefix(8), id: \.name) { shelf in
                        ReceiptLine(value: Money.format(Double(shelf.cents) / 100)) {
                            Button(shelf.name) { store.orderSearch = shelf.name }
                                .buttonStyle(.plain).help("Show only \(shelf.name)")
                        }
                    }
                    if shelves.count > 8 {
                        ReceiptLine(value: Money.format(Double(shelves.dropFirst(8).reduce(0) { $0 + $1.cents }) / 100)) {
                            Text("\(shelves.count - 8) other shelves").foregroundStyle(.secondary)
                        }
                    }
                }
                ReceiptRule()
                ReceiptLine(value: Money.format(total), bold: true) {
                    Text("TOTAL · \(list.count.formatted()) \(list.count == 1 ? "ITEM" : "ITEMS")").font(Theme.mono(13, .bold))
                }
            }
        }
        .frame(maxWidth: 520)
    }
}

/// One item ordered. Clicking it shows the card charge that paid for it, if the statements have one.
private struct OrderRowView: View {
    @Environment(BudgetStore.self) private var store
    let row: BudgetStore.OrderRow
    let isOpen: Bool
    let toggle: () -> Void
    @State private var hovering = false

    private var charge: Transaction? { row.charge.flatMap { id in store.transactions.first { $0.id == id } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.item.quantity > 1 ? "\(row.item.quantity) × \(row.item.name)" : row.item.name)
                            .font(.body.weight(.medium)).lineLimit(isOpen ? 4 : 1).multilineTextAlignment(.leading)
                        Text("\(row.item.shelf) · \(row.date.formatted(.dateTime.month(.abbreviated).day().year()))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Text(Money.format(Double(row.item.cents) / 100)).font(Theme.mono(14, .semibold))
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .foregroundStyle(hovering || isOpen ? Theme.accent : Color.secondary.opacity(0.4))
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isOpen {
                Group {
                    if let charge {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Charged \(Money.format(charge.amount)) to \(charge.account) on \(charge.date.formatted(.dateTime.month(.abbreviated).day()))")
                                    .font(.callout)
                                Text(charge.description).font(Theme.mono(11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button("Show in Statement", systemImage: "doc.text.magnifyingglass") { store.showOriginal(of: charge.id) }
                        }
                    } else {
                        Text("No card charge on file for this one. It may be older than your statements, or paid with a gift balance or another card.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 10)
            }
        }
        .background(hovering || isOpen ? Theme.accent.opacity(0.06) : .clear, in: .rect(cornerRadius: 9, style: .continuous))
        .onHover { hovering = $0 }
    }
}
