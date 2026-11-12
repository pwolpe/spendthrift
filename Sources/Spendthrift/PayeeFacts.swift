import Foundation

/// A few true things about one payee, worked out from its charges and everyone else's: how it
/// ranks, whether it is growing, when it tends to happen. Pure; each is a sentence built from sums.
enum PayeeFacts {
    static func lines(for charges: [Transaction], among all: [Transaction], asOf: Date) -> [String] {
        let spent = charges.filter { $0.countsAsSpending && $0.amount > 0 }
        guard spent.count >= 3, let category = spent.first?.category else { return [] }
        let money = { (v: Double) in Money.format(v, cents: false) }
        var out: [String] = []
        let name = spent[0].merchant

        // Where it stands among payees of its kind, over the last twelve months.
        let from = Calendar.current.date(byAdding: .month, value: -12, to: asOf) ?? asOf
        var totals: [String: Double] = [:]
        for t in all where t.category == category && t.countsAsSpending && t.date > from { totals[t.merchant, default: 0] += t.amount }
        let ranked = totals.filter { $0.value > 0 }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        if ranked.count >= 5, let place = ranked.firstIndex(where: { $0.key == name }), place < 10 {
            let ordinal = ["largest", "second largest", "third largest", "fourth largest", "fifth largest", "sixth largest", "seventh largest", "eighth largest", "ninth largest", "tenth largest"][place]
            out.append("Your \(ordinal) \(category.displayName) payee of the last twelve months, at \(money(ranked[place].value)).")
        }

        // This twelve months against the twelve before.
        let before = Calendar.current.date(byAdding: .month, value: -24, to: asOf) ?? asOf
        let now = spent.filter { $0.date > from }.reduce(0) { $0 + $1.amount }
        let then = spent.filter { $0.date > before && $0.date <= from }.reduce(0) { $0 + $1.amount }
        if then >= 100, now >= 100, abs(now - then) >= max(100, then * 0.25) {
            out.append(now > then ? "\(money(now)) in the last twelve months, up from \(money(then)) the twelve before."
                                  : "\(money(now)) in the last twelve months, down from \(money(then)) the twelve before.")
        } else if then >= 100, now < 1 {
            out.append("Nothing in the last twelve months; \(money(then)) the twelve before.")
        }

        // What a visit costs now against what it used to.
        if spent.count >= 12 {
            let ordered = spent.sorted { $0.date < $1.date }
            let third = ordered.count / 3
            let early = median(ordered.prefix(third).map(\.amount)), late = median(ordered.suffix(third).map(\.amount))
            if early >= 5, late >= early * 1.2, late - early >= 3 {
                out.append("A typical charge is \(Money.format(late)) now. It used to be \(Money.format(early)).")
            }
        }

        // The day of the week it mostly happens.
        if spent.count >= 10 {
            var days = [Int](repeating: 0, count: 8)
            for t in spent { days[Calendar.current.component(.weekday, from: t.date)] += 1 }
            if let top = days.indices.max(by: { days[$0] < days[$1] }), days[top] * 5 >= spent.count * 2 {
                out.append("Mostly on \(Calendar.current.weekdaySymbols[top - 1])s: \(days[top]) of \(spent.count) charges.")
            }
        }
        return out
    }

    private static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
