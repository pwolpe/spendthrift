import SwiftUI
import AppKit
import CryptoKit
import PDFKit
import UniformTypeIdentifiers

/// The daily picture, on-this-day memories and the month's insights.
extension BudgetStore {
    // MARK: - Daily Tony, insights

    /// Recent purchases for Daily Tony: one per place, from the last two weeks of data.
    func recentHighlights() -> [DailyPicture.Highlight] {
        let spending = transactions.filter { $0.countsAsSpending && $0.amount >= 3 && $0.category != .unsorted }
        guard let latest = spending.last?.date else { return [] }
        let cutoff = latest.addingTimeInterval(-14 * 24 * 3600)
        var seen: Set<String> = []
        return spending.filter { $0.date >= cutoff }.reversed().compactMap { t in
            guard seen.insert(t.merchant).inserted else { return nil }
            return DailyPicture.Highlight(merchant: t.merchant, category: t.category, amount: t.amount, date: t.date)
        }
    }

    /// What was bought on this day in an earlier year, and on tomorrow's: the subjects of the
    /// daily picture, today's first. Empty until there is more than a year of statements.
    func memoryHighlights(_ now: Date = .now) -> [DailyPicture.Highlight] {
        [now, now.addingTimeInterval(86_400)].compactMap { day in
            guard let t = onThisDay(day)?.charge else { return nil }
            let trip = story(containing: t.id).flatMap { $0.kind == .trip ? $0 : nil }
            return DailyPicture.Highlight(merchant: t.merchant, category: t.category, amount: t.amount, date: t.date,
                                          trip: trip?.name, tripPlace: trip?.place, entry: t.id)
        }
    }

    /// Charges from trips of the last two years that would make a good picture: for each trip, its
    /// larger charges at places with a name (not the airline or the card's foreign fee).
    func tripHighlights() -> [DailyPicture.Highlight] {
        guard let latest = transactions.last?.date else { return [] }
        let cutoff = latest.addingTimeInterval(-730 * 86_400)
        var out: [DailyPicture.Highlight] = []
        for story in stories where story.kind == .trip {
            let dull = ["withdrawal", "atm", "fee", "payment", "transfer", "unknown"]
            let charges = transactions(in: story).filter { t in
                t.countsAsSpending && t.amount >= 5 && t.date >= cutoff && t.category != .fees && !dull.contains { t.merchant.lowercased().contains($0) }
            }
            var seen: Set<String> = []
            for t in charges.sorted(by: { $0.amount > $1.amount }) where seen.insert(t.merchant).inserted {
                out.append(DailyPicture.Highlight(merchant: t.merchant, category: t.category, amount: t.amount, date: t.date, trip: story.name, tripPlace: story.place))
                if seen.count >= 4 { break }
            }
        }
        return out
    }

    /// Tells the person, once, about anything new worth knowing in the latest month: a price that
    /// went up, a new repeating charge, what looks like a double charge. Only while they're elsewhere
    /// (the notifier stays quiet when the app is in front), and never the same thing twice.
    func announceNewFindings() {
        guard let latest = months.last else { return }
        var told = Set(UserDefaults.standard.stringArray(forKey: "announcedFindings") ?? [])
        let worth: [Insight.Kind] = [.priceIncrease, .duplicate, .newSubscription, .unusual]
        let fresh = insights(for: latest).filter { worth.contains($0.kind) && !told.contains($0.id) }
        // The first time through (a library just imported), remember everything quietly: nobody
        // wants forty notifications about the past.
        let firstTime = UserDefaults.standard.object(forKey: "announcedFindings") == nil
        for insight in fresh.prefix(firstTime ? 0 : 2) {
            Notifier.post(title: insight.title, body: insight.detail)
        }
        told.formUnion(fresh.map(\.id))
        UserDefaults.standard.set(Array(told.suffix(500)), forKey: "announcedFindings")
    }

    func insights(for month: Month) -> [Insight] {
        let found = insightCache[month] ?? InsightEngine.insights(for: month, in: transactions)
        insightCache[month] = found
        return found.filter { !library.dismissedInsights.contains($0.id) }
    }

    /// The month's superlatives.
    func awards(for month: Month) -> [Award] {
        if let kept = awardCache[month] { return kept }
        let found = AwardEngine.awards(for: month, in: transactions)
        awardCache[month] = found
        return found
    }

    /// The year in review for one period.
    func report(for period: ReportPeriod) -> ReportData {
        if let kept = reportCache[period] { return kept }
        let made = ReportData(store: self, period: period)
        reportCache[period] = made
        return made
    }

    func dismissInsight(_ insight: Insight) {
        withAnimation { _ = library.dismissedInsights.insert(insight.id) }
        changed()
    }

    func subscriptions() -> [Subscription] {
        guard let last = months.last else { return [] }
        return InsightEngine.subscriptions(asOf: last, in: transactions)
    }
}
