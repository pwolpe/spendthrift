import SwiftUI

extension BudgetStore {
    /// The order rows as the habit engine wants them, for one person or everyone.
    func bought(by who: String? = nil) -> [OrderHabits.Bought] {
        cached("bought|\(who ?? "-")") {
            orderRows.filter { $0.item.cents > 0 && (who == nil || $0.item.who == who) }.map(Self.bought)
        }
    }

    nonisolated static func bought(_ row: OrderRow) -> OrderHabits.Bought {
        OrderHabits.Bought(id: row.id, name: row.name, kind: row.kind, asin: row.item.asin, orderID: row.item.orderID, date: row.date,
                           cents: row.net, quantity: row.item.quantity, digital: row.item.shop == .digital)
    }

    /// What is on the restock clock now.
    func orderHabits(by who: String? = nil) -> [OrderHabits.Habit] {
        cached("habits|\(who ?? "-")") { OrderHabits.habits(bought(by: who), through: orderCoverage.through ?? Date()) }
    }

    /// The first and last days a card charge from these shops is on file.
    /// (Kept as a plain pair: the cache cannot tell a kept "none" from nothing kept.)
    var orderChargeSpan: (first: String, last: String)? {
        let span: [String] = cached("order-charge-span") {
            guard let first = orderChargeList.map(\.date).min(), let last = orderChargeList.map(\.date).max() else { return [] }
            return [first, last]
        }
        return span.count == 2 ? (span[0], span[1]) : nil
    }

    /// Why an order has no card charge, as far as its date says.
    func unpaidNote(for date: Date) -> String {
        guard let span = orderChargeSpan else { return "no card charge on file" }
        let day = DateParsing.iso.string(from: date)
        // A charge is made when the box ships and reaches a statement days later: an order from the
        // last week the statements cover is waiting, not missing.
        let waitingFrom = DateParsing.parse(span.last, format: "yyyy-MM-dd").flatMap { Calendar.current.date(byAdding: .day, value: -7, to: $0) }
        if let waitingFrom, date > waitingFrom { return "not on a statement yet" }
        if day < span.first { return "before your statements begin" }
        return "no card charge on file"
    }
}

// MARK: The shelf

/// The things that arrived, as things: their pictures on two shelves, the dearest largest.
/// Point at one to see what it was; click it to open its box.
struct OrderShelf: View {
    let things: [OrderHabits.Bought]
    let about: String
    @State private var pointed: Int?
    @State private var width: CGFloat = 880
    private var pictures: ProductImages { .shared }
    private var store: BudgetStore { .shared }

    private static let gap: CGFloat = 14, tall: CGFloat = 116, small: CGFloat = 58

    private func size(_ thing: OrderHabits.Bought, top: Int) -> CGFloat {
        Self.small + (Self.tall - Self.small) * CGFloat((Double(thing.cents) / Double(max(top, 1))).squareRoot())
    }

    /// The shelves, filled left to right until each is full.
    private func shelves(_ list: [OrderHabits.Bought], width: CGFloat, top: Int) -> [[OrderHabits.Bought]] {
        var rows: [[OrderHabits.Bought]] = [[]], used: CGFloat = 0
        for thing in list {
            let wide = size(thing, top: top)
            if used + wide > width, !rows[rows.count - 1].isEmpty {
                guard rows.count < 2 else { break }
                rows.append([]); used = 0
            }
            rows[rows.count - 1].append(thing)
            used += wide + Self.gap
        }
        return rows
    }

    var body: some View {
        // Only what there is a picture of: asking for one starts fetching it, so the shelf fills as they arrive.
        let pictured = things.filter { pictures.image(for: $0.asin) != nil }
        if pictured.count >= 5 {
            let top = pictured.first?.cents ?? 1
            Card(padding: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("WHAT ARRIVED").font(Theme.mono(10.5, .bold)).tracking(1.2).foregroundStyle(.secondary)
                    // Each shelf is as tall as the tallest thing on it. (The width is measured behind the
                    // shelves, so their height can follow from what is on them.)
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(shelves(pictured, width: width, top: top).enumerated()), id: \.offset) { _, row in
                            VStack(spacing: 0) {
                                HStack(alignment: .bottom, spacing: Self.gap) {
                                    ForEach(row) { thing in tile(thing, size: size(thing, top: top)) }
                                    Spacer(minLength: 0)
                                }
                                .padding(.top, 8)
                                plank
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background { GeometryReader { geo in Color.clear.onAppear { width = geo.size.width }.onChange(of: geo.size.width) { width = geo.size.width } } }
                    Group {
                        if let thing = pictured.first(where: { $0.id == pointed }) {
                            Text("\(thing.name) · \(Money.format(Double(thing.cents) / 100)) · \(thing.date.formatted(.dateTime.month(.abbreviated).day().year()))")
                                .foregroundStyle(.primary)
                        } else {
                            Text(about).foregroundStyle(.secondary)
                        }
                    }
                    .font(.callout).lineLimit(1)
                }
            }
        }
    }

    private var plank: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(LinearGradient(colors: [Color(red: 0.72, green: 0.56, blue: 0.38), Color(red: 0.52, green: 0.38, blue: 0.24)], startPoint: .top, endPoint: .bottom))
            .frame(height: 7)
            .shadow(color: .black.opacity(0.25), radius: 3, y: 3)
    }

    private func tile(_ thing: OrderHabits.Bought, size: CGFloat) -> some View {
        let up = pointed == thing.id
        return Button { store.navigate { store.orderOnly = thing.orderID } } label: {
            ProductThumb(asin: thing.asin, kind: thing.kind, size: size)
                .shadow(color: .black.opacity(up ? 0.3 : 0.16), radius: up ? 9 : 4, y: up ? 6 : 2)
                .scaleEffect(up ? 1.07 : 1, anchor: .bottom)
                .rotationEffect(.degrees(up ? (thing.id % 2 == 0 ? -2 : 2) : 0), anchor: .bottom)
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { pointed = inside ? thing.id : (pointed == thing.id ? nil : pointed) } }
        .help("Open this order")
        .accessibilityLabel("\(thing.name), \(Money.format(Double(thing.cents) / 100))")
        .zIndex(up ? 1 : 0)
    }
}

// MARK: The restock clock

/// The things that keep coming back: how often, what a year of each costs, whether its price has
/// moved, and when the next is due.
struct RestockCard: View {
    let habits: [OrderHabits.Habit]
    /// Where the order history ends: nothing after this day can be seen.
    let through: Date
    private var store: BudgetStore { .shared }

    private func due(_ habit: OrderHabits.Habit) -> (text: String, color: Color) {
        let day = habit.due.formatted(.dateTime.month(.abbreviated).day())
        let today = Calendar.current.startOfDay(for: Date())
        if habit.due >= today { return ("due \(day)", .secondary) }
        // Past due as far as the history goes; past it, there is no telling.
        return habit.due <= through ? ("due now", Theme.caution) : ("was due \(day)", Theme.caution)
    }

    private func detail(_ habit: OrderHabits.Habit) -> String {
        var parts = [OrderHabits.rhythm(habit.everyDays)]
        if let price = habit.price {
            parts.append("\(Money.format(Double(price.now) / 100)), was \(Money.format(Double(price.was) / 100)) in \(price.when.formatted(.dateTime.year()))")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 9) {
                Text("ON THE RESTOCK CLOCK").font(Theme.mono(10.5, .bold)).tracking(1.2).foregroundStyle(.secondary)
                ForEach(habits.prefix(6)) { habit in
                    let due = due(habit)
                    Button { store.navigate { store.orderScope = .all; store.orderSearch = habit.name } } label: {
                        HStack(alignment: .center, spacing: 9) {
                            ProductThumb(asin: habit.asin, kind: habit.kind, size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(habit.name).font(.callout).lineLimit(1)
                                Text(detail(habit)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            VStack(alignment: .trailing, spacing: 1) {
                                Text("\(Money.format(Double(habit.yearlyCents) / 100, cents: false)) a year").font(Theme.mono(12, .medium))
                                Text(due.text).font(.caption).foregroundStyle(due.color)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Show every time this was ordered")
                }
            }
        }
    }
}

// MARK: On this day

/// One line of memory at the top of the page: what arrived this week in another year.
struct OnThisDayCard: View {
    let memory: (thing: OrderHabits.Bought, yearsAgo: Int, exact: Bool)
    private var store: BudgetStore { .shared }

    var body: some View {
        let thing = memory.thing
        Button { store.navigate { store.orderOnly = thing.orderID } } label: {
            HStack(alignment: .center, spacing: 14) {
                ProductThumb(asin: thing.asin, kind: thing.kind, size: 54)
                    .rotationEffect(.degrees(-3))
                    .shadow(color: .black.opacity(0.18), radius: 5, y: 3)
                VStack(alignment: .leading, spacing: 3) {
                    Text("ON THIS DAY · \(thing.date.formatted(.dateTime.year()))").font(Theme.mono(10.5, .bold)).tracking(1.2).foregroundStyle(Theme.accent)
                    Text("\(OrderHabits.yearsAgo(memory.yearsAgo)) \(memory.exact ? "today" : "this week") you bought \(thing.name) for \(Money.format(Double(thing.cents) / 100, cents: false)).")
                        .font(.system(size: 17, weight: .medium, design: .serif)).fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accent.opacity(0.07), in: .rect(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Open this order")
    }
}
