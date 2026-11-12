import Foundation

/// Budgets that set themselves: for each category, what you usually spend in a month, and where this
/// month stands against it. Pure: transactions in, figures out, so it can be checked without a window.
enum BudgetEngine {
    enum Pace { case under, onPace, over }

    struct Line: Identifiable, Hashable {
        var id: String { category.rawValue }
        let category: Category
        /// What counts: the person's own figure when there is one, else the computed one.
        let target: Double
        /// What the app works out (nil when it has too little history to).
        let computed: Double?
        let isOverride: Bool
        let spent: Double
        let pace: Pace
        /// Where the month is heading, shown only once it is past day 10.
        let projected: Double?
        /// The charges that make up `spent` (trips and events are left out of both sides).
        let chargeIDs: Set<UUID>
        var left: Double { target - spent }
    }

    struct Summary: Hashable {
        let month: Month
        let lines: [Line]
        var spent: Double { lines.reduce(0) { $0 + $1.spent } }
        var target: Double { lines.reduce(0) { $0 + $1.target } }
        var onPace: Int { lines.filter { $0.pace != .over }.count }
        var over: Int { lines.filter { $0.pace == .over }.count }
        /// True while the month is still going: the pace is judged against how much of it has passed.
        let isInProgress: Bool
        /// How much of the month has passed (1 for a finished one).
        let elapsed: Double
        /// Spending on trips and events this month, which no budget counts.
        let leftOut: Double
        let leftOutIDs: Set<UUID>
    }

    static let monthsLookedAt = 6

    /// The median of the six complete months before `month`, trips and events left out, to the nearest $10.
    /// A category needs three months with spending in them and a figure of at least $25.
    static func targets(before month: Month, in all: [Transaction], stories: [Story]) -> [Category: Double] {
        let inStory = Set(stories.flatMap(\.entryIDs))
        let spending = all.filter(\.countsAsSpending)
        let present = Set(spending.map(\.month))
        let window = present.filter { $0 < month }.sorted().suffix(monthsLookedAt)
        guard window.count >= 3 else { return [:] }
        let inWindow = Set(window)
        var sums: [Category: [Month: Double]] = [:]
        for t in spending where inWindow.contains(t.month) && !inStory.contains(t.id) { sums[t.category, default: [:]][t.month, default: 0] += t.amount }
        var out: [Category: Double] = [:]
        let budgetable = Set(Category.spendingCases)
        for (category, byMonth) in sums where budgetable.contains(category) {
            let values = window.map { byMonth[$0] ?? 0 }
            guard values.filter({ $0 > 0.005 }).count >= 3 else { continue }
            let sorted = values.sorted()
            let middle = sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            let target = (middle / 10).rounded() * 10
            if target >= 25 { out[category] = target }
        }
        return out
    }

    /// Where `month` stands. `asOf` is the date of the newest charge: a month it falls inside is still going.
    static func summary(for month: Month, in all: [Transaction], stories: [Story], overrides: [String: Double], asOf: Date) -> Summary {
        let inStory = Set(stories.flatMap(\.entryIDs))
        let computed = targets(before: month, in: all, stories: stories)
        let cal = Calendar.current
        let days = cal.range(of: .day, in: .month, for: month.firstDay)?.count ?? 30
        let day = cal.component(.day, from: asOf)
        let inProgress = Month(date: asOf) == month && day < days
        let elapsed = inProgress ? Double(day) / Double(days) : 1

        var spent: [Category: Double] = [:], ids: [Category: Set<UUID>] = [:]
        var tripIDs: Set<UUID> = [], trip = 0.0
        for t in all where t.countsAsSpending && t.month == month {
            if inStory.contains(t.id) { trip += t.amount; tripIDs.insert(t.id); continue }
            spent[t.category, default: 0] += t.amount
            ids[t.category, default: []].insert(t.id)
        }
        var categories = Set(computed.keys)
        for (key, value) in overrides where value > 0 { categories.insert(Category(key)) }
        let lines: [Line] = categories.compactMap { category in
            let own = overrides[category.rawValue].flatMap { $0 > 0 ? $0 : nil }
            guard let target = own ?? computed[category] else { return nil }
            let now = spent[category] ?? 0
            let expected = target * elapsed
            let pace: Pace = now < expected * 0.9 ? .under : (now > expected * 1.1 ? .over : .onPace)
            let projected = inProgress && day > 10 ? now / elapsed : nil
            return Line(category: category, target: target, computed: computed[category], isOverride: own != nil, spent: now, pace: pace,
                        projected: projected, chargeIDs: ids[category] ?? [])
        }
        .sorted { $0.target != $1.target ? $0.target > $1.target : $0.category.rawValue < $1.category.rawValue }
        return Summary(month: month, lines: lines, isInProgress: inProgress, elapsed: elapsed, leftOut: trip, leftOutIDs: tripIDs)
    }
}
