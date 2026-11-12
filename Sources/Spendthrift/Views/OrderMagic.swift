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

    private static let gap: CGFloat = 18, tall: CGFloat = 124, small: CGFloat = 60

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

    /// The wall behind the shelves: warm paper in light and dark alike, so product shots (which come
    /// on white) melt into it and the things look as if they are standing there.
    private static let wall = Color(red: 0.985, green: 0.965, blue: 0.925)
    private static let ink = Color(red: 0.2, green: 0.17, blue: 0.14)

    var body: some View {
        // Only what there is a picture of: asking for one starts fetching it, so the shelf fills as they arrive.
        let pictured = things.filter { pictures.image(for: $0.asin) != nil }
        if pictured.count >= 5 {
            let top = pictured.first?.cents ?? 1
            VStack(alignment: .leading, spacing: 10) {
                Text("WHAT ARRIVED").font(Theme.mono(10.5, .bold)).tracking(1.2).foregroundStyle(Self.ink.opacity(0.55))
                // Each shelf is as tall as the tallest thing on it. (The width is measured behind the
                // shelves, so their height can follow from what is on them.)
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(shelves(pictured, width: width, top: top).enumerated()), id: \.offset) { _, row in
                        VStack(spacing: 0) {
                            HStack(alignment: .bottom, spacing: Self.gap) {
                                ForEach(row) { thing in item(thing, size: size(thing, top: top)) }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 10).padding(.top, 26)
                            plank
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { GeometryReader { geo in Color.clear.onAppear { width = geo.size.width - 20 }.onChange(of: geo.size.width) { width = geo.size.width - 20 } } }
                Group {
                    if let thing = pictured.first(where: { $0.id == pointed }) {
                        Text("\(thing.name) · \(thing.date.formatted(.dateTime.month(.abbreviated).day().year()))").foregroundStyle(Self.ink)
                    } else {
                        Text(about).foregroundStyle(Self.ink.opacity(0.6))
                    }
                }
                .font(.callout).lineLimit(1).padding(.top, 2)
            }
            .padding(18)
            .background(Self.wall, in: .rect(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline) }
        }
    }

    /// A wooden shelf: a lit top edge, a face, and the shadow it throws on the wall.
    private var plank: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color(red: 0.86, green: 0.71, blue: 0.5)).frame(height: 2)
            Rectangle().fill(LinearGradient(colors: [Color(red: 0.74, green: 0.57, blue: 0.37), Color(red: 0.6, green: 0.44, blue: 0.27)], startPoint: .top, endPoint: .bottom)).frame(height: 8)
        }
        .clipShape(.rect(cornerRadius: 2, style: .continuous))
        .shadow(color: Color(red: 0.35, green: 0.25, blue: 0.12).opacity(0.3), radius: 5, y: 5)
    }

    /// One thing, standing on the shelf: no frame around it, a soft shadow at its feet. Pointed at,
    /// it hops, leans, and shows its price on a tag.
    private func item(_ thing: OrderHabits.Bought, size: CGFloat) -> some View {
        let up = pointed == thing.id
        let lean: Double = thing.id % 2 == 0 ? -4 : 4
        return Button { store.navigate { store.orderOnly = thing.orderID } } label: {
            ZStack(alignment: .bottom) {
                Ellipse().fill(Color(red: 0.3, green: 0.22, blue: 0.12).opacity(up ? 0.12 : 0.22))
                    .frame(width: size * (up ? 0.6 : 0.78), height: 7).blur(radius: 3).offset(y: 3)
                if let picture = pictures.image(for: thing.asin) {
                    Image(nsImage: picture).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: size, height: size, alignment: .bottom)
                        // White in the shot becomes the wall; only the thing itself is left.
                        .blendMode(.multiply)
                        .rotationEffect(.degrees(up ? lean : 0), anchor: .bottom)
                        .offset(y: up ? -9 : 0)
                }
            }
            .overlay(alignment: .top) {
                if up {
                    Text(Money.format(Double(thing.cents) / 100, cents: false))
                        .font(Theme.mono(11, .bold)).foregroundStyle(Self.ink)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color(red: 1, green: 0.86, blue: 0.4), in: .rect(cornerRadius: 4, style: .continuous))
                        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                        .rotationEffect(.degrees(-lean * 1.5))
                        .fixedSize()
                        .offset(y: -24)
                        .transition(.scale(scale: 0.4, anchor: .bottom).combined(with: .opacity))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in withAnimation(.spring(response: 0.28, dampingFraction: 0.5)) { pointed = inside ? thing.id : (pointed == thing.id ? nil : pointed) } }
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
