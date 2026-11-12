import Foundation

/// What repeats: bills and subscriptions, found by looking at when and how much each payee charged.
/// Pure: transactions in, findings out, so it can be checked without a window.
enum RecurringEngine {
    enum Cadence: Int, CaseIterable, Hashable {
        case weekly, monthly, quarterly, yearly

        var perYear: Double { [52, 12, 4, 1][rawValue] }
        /// "every month"
        var every: String { ["every week", "every month", "every quarter", "every year"][rawValue] }
        var title: String { ["Weekly", "Monthly", "Quarterly", "Yearly"][rawValue] }

        /// The cadence a median gap of this many days belongs to, if any.
        static func of(medianGap days: Double) -> Cadence? {
            switch days {
            case 5...9: .weekly
            case 26...35: .monthly
            case 85...100: .quarterly
            case 350...380: .yearly
            default: nil
            }
        }
    }

    struct Charge: Hashable {
        let date: Date
        let amount: Double
    }

    struct Recurring: Identifiable, Hashable {
        var id: String { merchant }
        let merchant: String
        let merchantKey: String
        let category: Category
        let cadence: Cadence
        /// The latest charge.
        let amount: Double
        let yearly: Double
        let first: Date
        let last: Date
        /// When the next charge is due; nil once it has stopped.
        let next: Date?
        let history: [Charge]
        let chargeIDs: [UUID]
        let isActive: Bool
        /// How much more the latest charge is than the first, when it crept up steadily; else 0.
        let creep: Double
        var extraPerYear: Double { creep * cadence.perYear }
        /// Active, costly, long-running and the kind of thing people forget they pay for.
        let isForgotten: Bool
        var count: Int { history.count }
    }

    /// The gap, in whole days, between two dates.
    private static func days(from a: Date, to b: Date) -> Double { (b.timeIntervalSince(a) / 86_400).rounded() }

    private static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// Payees charged on a steady rhythm, for about the same amount.
    /// `minCharges` is how many charges a weekly, monthly or quarterly one needs (a yearly one needs two).
    static func find(in transactions: [Transaction], asOf: Date, minCharges: Int = 3) -> [Recurring] {
        let cal = Calendar.current
        var byPayee: [String: [Transaction]] = [:]
        for t in transactions where t.countsAsSpending && t.amount > 0 { byPayee[t.merchant, default: []].append(t) }
        var found: [Recurring] = []
        for (merchant, charges) in byPayee where charges.count >= 2 {
            let sorted = charges.sorted { $0.date < $1.date }
            // Same-day charges are one payment.
            var history: [Charge] = [], ids: [UUID] = []
            for t in sorted {
                ids.append(t.id)
                if let end = history.last, abs(t.date.timeIntervalSince(end.date)) < 43_200 {
                    history[history.count - 1] = Charge(date: end.date, amount: end.amount + t.amount)
                } else {
                    history.append(Charge(date: t.date, amount: t.amount))
                }
            }
            guard history.count >= 2 else { continue }
            let gaps = zip(history, history.dropFirst()).map { days(from: $0.date, to: $1.date) }
            let gap = median(gaps)
            guard let cadence = Cadence.of(medianGap: gap) else { continue }
            guard history.count >= (cadence == .yearly ? 2 : minCharges) else { continue }
            let steady = gaps.filter { abs($0 - gap) <= gap * 0.2 }.count
            guard Double(steady) >= Double(gaps.count) * 0.7 else { continue }

            let amounts = history.map(\.amount)
            let typical = median(amounts)
            let similar = amounts.allSatisfy { abs($0 - typical) <= typical * 0.25 }
            // A price that climbs step by step is still the same bill.
            let rising = zip(amounts, amounts.dropFirst()).allSatisfy { $1 >= $0 * 0.99 } && amounts.last! <= amounts.first! * 1.6
            guard similar || rising else { continue }
            if cadence == .yearly, history.count == 2, max(amounts[0], amounts[1]) > min(amounts[0], amounts[1]) * 1.25 { continue }

            let latest = sorted.last!
            let last = history.last!
            let active = last.date.addingTimeInterval(gap * 1.6 * 86_400) >= asOf
            var next: Date?
            if active {
                let step: (Date) -> Date = { from in
                    switch cadence {
                    case .weekly: cal.date(byAdding: .day, value: 7, to: from) ?? from.addingTimeInterval(7 * 86_400)
                    case .monthly: cal.date(byAdding: .month, value: 1, to: from) ?? from.addingTimeInterval(30 * 86_400)
                    case .quarterly: cal.date(byAdding: .month, value: 3, to: from) ?? from.addingTimeInterval(91 * 86_400)
                    case .yearly: cal.date(byAdding: .year, value: 1, to: from) ?? from.addingTimeInterval(365 * 86_400)
                    }
                }
                let today = cal.startOfDay(for: asOf)
                var due = step(last.date)
                for _ in 0..<60 where due < today { due = step(due) }
                next = due
            }

            let first = history[0]
            let ratio = first.amount > 0 ? last.amount / first.amount : 0
            let lastThree = amounts.suffix(3)
            let creep = (1.03...1.5).contains(ratio) && lastThree.allSatisfy({ $0 >= first.amount }) ? last.amount - first.amount : 0
            let yearly = last.amount * cadence.perYear
            let months = days(from: first.date, to: last.date) / 30.4
            let forgotten = active && yearly >= 60 && months >= 11.5 && (latest.category == .subscriptions || latest.category == .entertainment)

            found.append(Recurring(merchant: merchant, merchantKey: latest.merchantKey, category: latest.category, cadence: cadence,
                                   amount: last.amount, yearly: yearly, first: first.date, last: last.date, next: next,
                                   history: history, chargeIDs: ids, isActive: active, creep: creep, isForgotten: forgotten))
        }
        return found.sorted { $0.yearly != $1.yearly ? $0.yearly > $1.yearly : $0.merchant < $1.merchant }
    }
}
