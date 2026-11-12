import SwiftUI

/// "What changed" and "Budget": worked out once and kept until the library changes.
extension BudgetStore {
    /// Why this month differs from usual; nil when there is too little history or the month is unfinished.
    func changes(in month: Month) -> ChangeEngine.Explanation? {
        let key = month.key
        if let kept = changeCache[key] { return kept }
        let made = ChangeEngine.explain(month: month, in: transactions, stories: stories, recurring: recurring())
        changeCache[key] = made
        return made
    }

    /// The same for the last twelve months (or one calendar year) against the twelve before.
    func changes(in period: ReportPeriod) -> ChangeEngine.Explanation? {
        let key = "period-\(period.id)"
        if let kept = changeCache[key] { return kept }
        var made: ChangeEngine.Explanation?
        switch period {
        case .last12:
            // The same twelve months the verdict above it is about, so the page never gives two totals for one stretch.
            if let end = months.last { made = ChangeEngine.explainYear(endingAt: end, in: transactions, stories: stories) }
        case .year(let year):
            made = ChangeEngine.explainYear(endingAt: Month(year: year, month: 12), label: String(year), in: transactions, stories: stories)
        }
        changeCache[key] = made
        return made
    }

    /// Opens what a driver is about.
    func show(_ driver: ChangeEngine.Driver) {
        switch driver.target {
        case .story(let id, let name): showCharges(TransactionFilter(storyID: id, title: name))
        case .charges(let ids, let title): showCharges(TransactionFilter(ids: ids, title: title))
        case .place(let name): showPlace(name)
        case .category(let category, let month): showCharges(TransactionFilter(category: category, month: month))
        case .spending(let month): showSpending(in: month)
        }
    }

    func budget(for month: Month) -> BudgetEngine.Summary {
        if let kept = budgetCache[month] { return kept }
        let made = BudgetEngine.summary(for: month, in: transactions, stories: stories, overrides: library.budgetOverrides ?? [:],
                                        asOf: transactions.last?.date ?? .now)
        budgetCache[month] = made
        return made
    }

    /// A figure of the person's own for a category, or nil to have the app work it out again.
    func setBudget(_ category: Category, to amount: Double?) {
        var all = library.budgetOverrides ?? [:]
        if let amount, amount > 0 { all[category.rawValue] = (amount * 100).rounded() / 100 } else { all[category.rawValue] = nil }
        library.budgetOverrides = all.isEmpty ? nil : all
        changed()
    }

    /// Opens one category's charges in a budget month (trips and events are not part of a budget).
    func showBudgetCharges(_ line: BudgetEngine.Line, in month: Month) {
        showCharges(TransactionFilter(ids: line.chargeIDs, title: "\(line.category.displayName) in \(month.title)"))
    }
}
