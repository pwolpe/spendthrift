import Foundation

/// A payee in a few words, from nothing but when it was paid: "Tuesdays, mostly", "only in summer",
/// "three times in one week of March 2023". Pure; nil when there is nothing particular to say.
enum PayeeSketch {
    private static let calendar = Calendar.current

    /// `days` are the days it was paid (purchases only). `trips` names the trip each of those fell
    /// in, if any, in the same order.
    static func line(days: [Date], trips: [String?], asOf: Date) -> String? {
        guard days.count >= 2 else { return nil }
        let order = days.indices.sorted { days[$0] < days[$1] }
        let sorted = order.map { days[$0] }, first = sorted[0], last = sorted[sorted.count - 1], count = sorted.count
        let span = calendar.dateComponents([.day], from: first, to: last).day ?? 0
        let monthYear = Date.FormatStyle.dateTime.month(.wide).year()

        // Only away from home.
        let away = trips.compactMap { $0 }
        if away.count * 5 >= count * 4 {
            let which = Set(away)
            return which.count == 1 ? "Only on the \(which.first!) trip" : "Only when you travel"
        }
        // All at once.
        if count >= 3, span <= 10 {
            return "\(count) times in \(span <= 7 ? "one week" : "ten days") of \(first.formatted(monthYear))"
        }
        // Come and gone, or just arrived.
        let quiet = calendar.dateComponents([.month], from: last, to: asOf).month ?? 0
        if count >= 4, quiet >= 18 { return "A regular until \(last.formatted(.dateTime.year()))" }
        if (calendar.dateComponents([.day], from: first, to: asOf).day ?? 0) <= 60 { return "New since \(first.formatted(.dateTime.month(.wide)))" }

        // Like clockwork.
        let gaps = zip(sorted, sorted.dropFirst()).map { calendar.dateComponents([.day], from: $0, to: $1).day ?? 0 }.sorted()
        let usual = gaps[gaps.count / 2]
        func steady(_ low: Int, _ high: Int) -> Bool { gaps.filter { $0 >= low && $0 <= high }.count * 10 >= gaps.count * 7 }
        if count >= 6, (27...33).contains(usual), steady(25, 35) { return "Every month, like clockwork" }
        if count >= 8, (6...8).contains(usual), steady(5, 9) { return "Every week, like clockwork" }
        if count >= 3, (350...380).contains(usual), steady(340, 390) { return "Once a year, in \(last.formatted(.dateTime.month(.wide)))" }

        // A day of the week.
        if count >= 8 {
            var byDay = [Int](repeating: 0, count: 8)
            for day in sorted { byDay[calendar.component(.weekday, from: day)] += 1 }
            if let top = (1...7).max(by: { byDay[$0] < byDay[$1] }), byDay[top] * 20 >= count * 11 {
                return "\(calendar.weekdaySymbols[top - 1])s, mostly"
            }
            if (byDay[1] + byDay[7]) * 4 >= count * 3 { return "A weekend place" }
            if count >= 12, byDay[1] + byDay[7] == 0 { return "Weekdays only" }
        }
        // A time of year.
        let years = Set(sorted.map { calendar.component(.year, from: $0) }).count
        if count >= 4, years >= 2 {
            var byMonth = [Int](repeating: 0, count: 13)
            for day in sorted { byMonth[calendar.component(.month, from: day)] += 1 }
            if let top = (1...12).max(by: { byMonth[$0] < byMonth[$1] }), byMonth[top] * 10 >= count * 7 {
                return "Every \(calendar.monthSymbols[top - 1])"
            }
            let seasons = [("summer", [6, 7, 8]), ("winter", [12, 1, 2]), ("spring", [3, 4, 5]), ("autumn", [9, 10, 11])]
            for (name, months) in seasons where months.reduce(0, { $0 + byMonth[$1] }) * 5 >= count * 4 { return "Only in \(name)" }
        }
        // How often, lately.
        let yearAgo = calendar.date(byAdding: .year, value: -1, to: asOf) ?? asOf
        let lately = sorted.filter { $0 > yearAgo }.count
        if lately >= 75 { return "A few times a week" }
        if lately >= 40 { return "About once a week" }
        if lately >= 20 { return "A couple of times a month" }
        return nil
    }
}

/// What a statement just brought in, as a few lines worth reading: how much, the biggest thing,
/// places never paid before, a card credit that landed. Pure: the new charges and the older ones in,
/// lines out.
enum ImportStory {
    struct Line: Identifiable, Hashable {
        var id: String { text }
        var symbol: String
        var text: String
        var charges: Set<UUID> = []
        /// Good news is drawn as such.
        var isGood = false
    }

    static func lines(new: [Transaction], before: [Transaction], verified: Bool) -> [Line] {
        guard !new.isEmpty else { return [] }
        let money = { (v: Double) in Money.format(v, cents: false) }
        let bought = new.filter { $0.amount > 0 && !$0.isTransfer }
        // Things bought, as against what the card or bank charges for itself.
        let things = bought.filter { $0.countsAsSpending && $0.category != .fees && !CardEngine.annualFee($0.description).isFee }
        let day = Date.FormatStyle.dateTime.month(.abbreviated).day()
        var out: [Line] = []
        if let from = new.map(\.date).min(), let to = new.map(\.date).max() {
            let spent = bought.filter(\.countsAsSpending).reduce(0) { $0 + $1.amount }
            out.append(Line(symbol: "calendar", text: "\(new.count) \(new.count == 1 ? "line" : "lines"), \(from.formatted(day)) to \(to.formatted(day))"
                            + (spent > 0.5 ? ": \(money(spent)) spent" : ""), charges: Set(new.map(\.id))))
        }
        if let biggest = things.max(by: { ($0.amount, $1.merchant) < ($1.amount, $0.merchant) }), things.count > 1 {
            out.append(Line(symbol: "arrow.up.right.circle", text: "The biggest: \(biggest.merchant), \(Money.format(biggest.amount))", charges: [biggest.id]))
        }
        // Somewhere new.
        // (By name: one payee may be spelled several ways on statements.)
        let known = Set(before.map(\.merchant))
        var fresh: [String] = [], freshIDs: Set<UUID> = []
        for t in things where !known.contains(t.merchant) {
            if !fresh.contains(t.merchant) { fresh.append(t.merchant) }
            freshIDs.insert(t.id)
        }
        if !fresh.isEmpty, !before.isEmpty {
            let named = fresh.prefix(3).joined(separator: ", ") + (fresh.count > 3 ? " and \(fresh.count - 3) more" : "")
            out.append(Line(symbol: "mappin.and.ellipse", text: fresh.count == 1 ? "Somewhere new: \(named)" : "\(fresh.count) places you have never paid before: \(named)", charges: freshIDs))
        }
        // The regular.
        let visits = Dictionary(grouping: things, by: \.merchant).max { ($0.value.count, $1.key) < ($1.value.count, $0.key) }
        if let visits, visits.value.count >= 4 {
            out.append(Line(symbol: "repeat", text: "Most often: \(visits.key), \(visits.value.count) times", charges: Set(visits.value.map(\.id))))
        }
        // What a card gave back, and what it charged to be held.
        var credits: [(name: String, total: Double, ids: Set<UUID>)] = []
        for credit in new where credit.amount < 0 && !credit.isTransfer {
            guard let name = CardEngine.benefitName(credit.description) else { continue }
            if let at = credits.firstIndex(where: { $0.name == name }) { credits[at].total -= credit.amount; credits[at].ids.insert(credit.id) }
            else { credits.append((name, -credit.amount, [credit.id])) }
        }
        for credit in credits {
            out.append(Line(symbol: "gift", text: "A credit landed: \(credit.name), \(Money.format(credit.total))", charges: credit.ids, isGood: true))
        }
        for fee in bought where CardEngine.annualFee(fee.description).isFee {
            out.append(Line(symbol: "calendar.badge.clock", text: "The yearly fee came round: \(Money.format(fee.amount))", charges: [fee.id]))
        }
        if verified { out.append(Line(symbol: "checkmark.seal", text: "Every line adds up to the totals the statement prints", isGood: true)) }
        return out
    }
}
