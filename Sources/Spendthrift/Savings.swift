import Foundation

/// Ways to save, in dollars a year, found by looking: what crept up, what looks forgotten, what
/// leaks out in fees, and which habits add up to more than they feel like. Pure, like the other
/// engines: charges in, findings out. Every figure is a sum of real charges; nothing is estimated
/// beyond "one fewer a month".
enum SavingsEngine {
    struct Idea: Identifiable, Hashable {
        enum Kind: String { case creep, forgotten, fees, habit }
        let id: String
        let kind: Kind
        let title: String
        let detail: String
        /// What acting on it would save in a year.
        let yearly: Double
        /// The payee it is about, when it is about one.
        let payee: String?
        let chargeIDs: [UUID]

        var symbol: String {
            switch kind {
            case .creep: "arrow.up.right.circle.fill"
            case .forgotten: "zzz"
            case .fees: "drop.triangle.fill"
            case .habit: "repeat.circle.fill"
            }
        }
    }

    /// The best few, largest saving first.
    /// - transactions: everything on file; the last twelve months before `asOf` are what is looked at.
    /// - optional: whether a charge was a choice (only choices are offered as habits to trim).
    static func ideas(in transactions: [Transaction], recurring: [RecurringEngine.Recurring], asOf: Date,
                      optional: (Transaction) -> Bool, limit: Int = 6) -> [Idea] {
        let money = { (v: Double) in Money.format(v, cents: false) }
        let from = Calendar.current.date(byAdding: .month, value: -12, to: asOf) ?? asOf
        let year = transactions.filter { $0.date > from && $0.date <= asOf && $0.countsAsSpending }
        var out: [Idea] = []
        var taken: Set<String> = []

        for r in recurring where r.isActive {
            if r.extraPerYear >= 12 {
                out.append(Idea(id: "creep|\(r.merchant)|\(Int(r.amount * 100))", kind: .creep, title: "\(r.merchant) has crept up",
                                detail: "\(Money.format(r.amount)) \(r.cadence.every), up \(Money.format(r.creep)) since \(r.first.formatted(.dateTime.month(.wide).year())). Worth asking for the old price, or a cheaper plan.",
                                yearly: r.extraPerYear, payee: r.merchant, chargeIDs: r.chargeIDs))
                taken.insert(r.merchant)
            } else if r.isForgotten {
                out.append(Idea(id: "forgotten|\(r.merchant)|\(Int(r.amount * 100))", kind: .forgotten, title: "Still using \(r.merchant)?",
                                detail: "It has charged you \(r.count) times since \(r.first.formatted(.dateTime.month(.wide).year())), \(money(r.yearly)) a year. If it has gone quiet in your life, it is still loud on your card.",
                                yearly: r.yearly, payee: r.merchant, chargeIDs: r.chargeIDs))
                taken.insert(r.merchant)
            }
        }

        // Fees and interest: money that bought nothing. Refunded fees net out.
        let fees = year.filter { $0.category == .fees }
        let feeTotal = fees.reduce(0) { $0 + $1.amount }
        if feeTotal >= 50 {
            let byPayee = Dictionary(grouping: fees, by: \.merchant).mapValues { $0.reduce(0) { $0 + $1.amount } }.filter { $0.value > 0 }
                .sorted { $0.value > $1.value }
            let worst = byPayee.prefix(2).map { "\($0.key) \(money($0.value))" }.joined(separator: ", ")
            out.append(Idea(id: "fees|\(Int(feeTotal))", kind: .fees, title: "\(money(feeTotal)) went on fees and interest",
                            detail: "In the last twelve months, across \(fees.count) charges\(worst.isEmpty ? "" : " (\(worst))"). Annual fees, late fees and interest are the easiest money to get back: one call, or one autopay.",
                            yearly: feeTotal, payee: nil, chargeIDs: fees.map(\.id)))
        }

        // Habits: a chosen payee visited at least once a month. One fewer visit a month is a small ask with a real total.
        let recurringNames = Set(recurring.map(\.merchant))
        // (A flight or a hotel is a trip, not a habit, however often; and a habit is small each time.)
        var byPlace: [String: [Transaction]] = [:]
        for t in year where t.amount > 0 && t.category != .travel && optional(t) { byPlace[t.merchant, default: []].append(t) }
        var habits: [(name: String, total: Double, charges: [Transaction])] = []
        for (name, charges) in byPlace where charges.count >= 12 && !recurringNames.contains(name) && !taken.contains(name) {
            let total = charges.reduce(0) { $0 + $1.amount }
            if total / Double(charges.count) <= 150 { habits.append((name, total, charges)) }
        }
        habits.sort { ($0.total, $1.name) > ($1.total, $0.name) }
        for habit in habits.prefix(3) {
            let each = habit.total / Double(habit.charges.count)
            out.append(Idea(id: "habit|\(habit.name)|\(habit.charges.count)", kind: .habit, title: "\(habit.name), \(habit.charges.count) times",
                            detail: "\(money(habit.total)) in the last twelve months, about \(Money.format(each)) a time. One fewer a month would keep \(money(each * 12)) a year.",
                            yearly: each * 12, payee: habit.name, chargeIDs: habit.charges.map(\.id)))
        }
        return Array(out.sorted { ($0.yearly, $1.id) > ($1.yearly, $0.id) }.prefix(limit))
    }
}
