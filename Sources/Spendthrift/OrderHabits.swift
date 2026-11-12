import Foundation

/// What an order history says beyond its totals: the things that keep coming back and when the
/// next is due, what the same thing costs now against what it cost, what arrived this week in
/// another year, and which things are worth putting on a shelf. Pure: lists in, findings out.
enum OrderHabits {
    /// One thing that was ordered, reduced to what these questions need.
    struct Bought: Hashable, Identifiable {
        var id: Int
        var name: String
        var kind: String
        var asin: String?
        var orderID: String
        var date: Date
        /// What it cost after any refund, for the whole line.
        var cents: Int
        var quantity: Int = 1
        /// A download, a membership, a rental: nothing that runs out or sits on a shelf.
        var digital = false

        var unitCents: Int { cents / max(quantity, 1) }
    }

    /// Something bought at a steady rhythm.
    struct Habit: Identifiable {
        var id: String { name }
        var name: String
        var kind: String
        var asin: String?
        /// On how many separate days it was ordered.
        var times: Int
        /// The usual gap between orders lately, in days.
        var everyDays: Int
        var last: Date
        /// When the next would fall if the rhythm holds.
        var due: Date
        /// What a year of it costs at this rhythm and the recent price.
        var yearlyCents: Int
        /// The same product's price the first time and the latest time, when it has moved.
        var price: (was: Int, when: Date, now: Int)?
    }

    private static let calendar = Calendar.current

    /// The things bought again and again that are still being bought, dearest habit first.
    /// `through` is where the order history ends: a habit is judged against that day, not today,
    /// because nothing ordered since can be seen.
    static func habits(_ list: [Bought], through: Date) -> [Habit] {
        Dictionary(grouping: list.filter { !$0.digital && $0.cents > 0 }, by: \.name).compactMap { name, rows -> Habit? in
            let byDay = Dictionary(grouping: rows) { calendar.startOfDay(for: $0.date) }
            let days = byDay.keys.sorted()
            guard days.count >= 3, let last = days.last else { return nil }
            let gaps = zip(days, days.dropFirst()).map { calendar.dateComponents([.day], from: $0, to: $1).day ?? 0 }
            // The rhythm of late, which may not be the rhythm of five years ago.
            let recent = gaps.suffix(5).sorted()
            let every = recent[recent.count / 2]
            guard every >= 7, every <= 400 else { return nil }
            let quiet = calendar.dateComponents([.day], from: last, to: through).day ?? 0
            guard quiet <= max(45, every * 5 / 2) else { return nil }
            let spends = days.suffix(6).map { day in byDay[day]!.reduce(0) { $0 + $1.cents } }
            let usual = spends.reduce(0, +) / spends.count
            let lead = rows.max { ($0.date, $0.id) < ($1.date, $1.id) }!
            return Habit(name: name, kind: lead.kind, asin: lead.asin, times: days.count, everyDays: every, last: last,
                         due: calendar.date(byAdding: .day, value: every, to: last) ?? last,
                         yearlyCents: Int((Double(usual) * 365 / Double(every)).rounded()), price: priceMove(rows))
        }
        .sorted { ($0.yearlyCents, $1.name) > ($1.yearlyCents, $0.name) }
    }

    /// The first and latest price of the one product bought most under this name. Different
    /// products (another size, another pack) are never compared with each other.
    private static func priceMove(_ rows: [Bought]) -> (was: Int, when: Date, now: Int)? {
        let known = rows.filter { $0.asin != nil && $0.unitCents > 0 }
        guard let most = Dictionary(grouping: known, by: { $0.asin! }).max(by: { ($0.value.count, $1.key) < ($1.value.count, $0.key) })?.value
            .sorted(by: { ($0.date, $0.id) < ($1.date, $1.id) }),
              let first = most.first, let latest = most.last,
              !calendar.isDate(first.date, inSameDayAs: latest.date) else { return nil }
        let change = latest.unitCents - first.unitCents
        guard abs(change) >= 50, Double(abs(change)) / Double(first.unitCents) >= 0.08 else { return nil }
        return (first.unitCents, first.date, latest.unitCents)
    }

    /// "about every 5 weeks"
    static func rhythm(_ days: Int) -> String {
        if days < 14 { return "every \(days) days" }
        if days < 60 { return "about every \(Int((Double(days) / 7).rounded())) weeks" }
        let months = Int((Double(days) / 30.4).rounded())
        return months >= 12 ? "about once a year" : "about every \(months) months"
    }

    /// The most notable thing that arrived on this day, or within a few days of it, in an earlier year.
    /// A thing bought on the very day wins over one up to three times dearer from the same week.
    static func onThisDay(_ list: [Bought], today: Date, within window: Int = 3, atLeast cents: Int = 1500) -> (thing: Bought, yearsAgo: Int, exact: Bool)? {
        let year = calendar.component(.year, from: today), start = calendar.startOfDay(for: today)
        var best: (thing: Bought, yearsAgo: Int, exact: Bool)?
        for thing in list where !thing.digital && thing.cents >= cents {
            let then = calendar.component(.year, from: thing.date)
            guard then < year else { continue }
            var parts = calendar.dateComponents([.month, .day], from: thing.date)
            parts.year = year
            guard let moved = calendar.date(from: parts), let apart = calendar.dateComponents([.day], from: start, to: moved).day,
                  abs(apart) <= window else { continue }
            let found = (thing: thing, yearsAgo: year - then, exact: apart == 0)
            // The very day counts for a lot, but not for everything: a camera three days off beats dusters today.
            func weight(_ m: (thing: Bought, yearsAgo: Int, exact: Bool)) -> Int { m.thing.cents * (m.exact ? 3 : 1) }
            if let held = best, (weight(held), held.thing.id) >= (weight(found), thing.id) { continue }
            best = found
        }
        return best
    }

    /// What to put on the shelf: each product once, the dearest first. Only things with a product
    /// number can have a picture.
    static func shelf(_ list: [Bought], upTo count: Int) -> [Bought] {
        var seen: Set<String> = []
        return list.filter { !$0.digital && $0.asin != nil && $0.cents > 0 }
            .sorted { ($0.cents, $0.id) > ($1.cents, $1.id) }
            .filter { seen.insert($0.asin!).inserted && seen.insert("name:" + $0.name).inserted }
            .prefix(count).map { $0 }
    }

    /// "Fourteen years ago", "A year ago".
    static func yearsAgo(_ years: Int) -> String {
        if years == 1 { return "A year ago" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        let word = formatter.string(from: NSNumber(value: years)) ?? "\(years)"
        return word.prefix(1).uppercased() + word.dropFirst() + " years ago"
    }
}
