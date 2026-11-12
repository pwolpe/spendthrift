import Foundation

/// Why a month (or a year) differs from what is usual: the biggest reasons, in dollars, that add up
/// exactly to the difference. Pure: transactions in, findings out, so it can be checked without a window.
///
/// Every figure is worked out here. A model may later put a sentence round a driver (`Driver.written`);
/// until then, and whenever there is no key, the plain sentence built in code is shown.
enum ChangeEngine {
    enum Kind: Hashable {
        case story, oneOff, newRepeating, priceRise, categoryUp, categoryDown, everythingElse

        var symbol: String {
            switch self {
            case .story: "airplane"
            case .oneOff: "exclamationmark.circle.fill"
            case .newRepeating: "repeat.circle.fill"
            case .priceRise: "arrow.up.circle.fill"
            case .categoryUp: "chart.line.uptrend.xyaxis"
            case .categoryDown: "chart.line.downtrend.xyaxis"
            case .everythingElse: "ellipsis.circle.fill"
            }
        }
    }

    /// What a driver opens.
    enum Target: Hashable {
        case story(UUID, String)
        case charges(Set<UUID>, title: String)
        case place(String)
        case category(Category, Month)
        case spending(Month)
    }

    struct Driver: Identifiable, Hashable {
        let id: String
        let kind: Kind
        let title: String
        /// Signed: more than usual is positive.
        let amount: Double
        let target: Target
        /// The sentence built in code from the same figures.
        let fallback: String
        /// A sentence a model wrote around these figures, when there is one. Replaces the fallback.
        var written: String?
        var sentence: String { written ?? fallback }
    }

    struct Explanation: Hashable {
        /// "November", or "The last twelve months".
        let label: String
        let isYear: Bool
        let month: Month?
        let total: Double
        let usual: Double
        let delta: Double
        /// True when the difference is too small to explain; there are then no drivers.
        let isAboutUsual: Bool
        /// The largest reasons, then "everything else". They always add up to `delta`.
        let drivers: [Driver]

        var headline: String {
            let spent = Money.format(total, cents: false)
            if isAboutUsual { return "\(label) came to \(spent), \(isYear ? "about the same as the twelve months before" : "about what you usually spend")" }
            let by = Money.format(abs(delta), cents: false)
            return "\(label) came to \(spent), \(by) \(delta > 0 ? "more" : "less") than \(isYear ? "the twelve months before" : "usual")"
        }
    }

    // MARK: Month

    /// Why `month` differs from the median of the three complete months before it (the mean if only two).
    /// Nil when there is too little history, or when the month is not finished.
    static func explain(month: Month, in all: [Transaction], stories: [Story], recurring: [RecurringEngine.Recurring]) -> Explanation? {
        let spending = all.filter(\.countsAsSpending)
        let present = Set(spending.map(\.month))
        guard present.contains(month), let lastDate = spending.last?.date ?? spending.map(\.date).max() else { return nil }
        // The newest month in the data is only partly there until late in it.
        if Month(date: lastDate) == month, Calendar.current.component(.day, from: lastDate) < 25 { return nil }
        let reference = (1...3).map { month.adding(-$0) }.filter { present.contains($0) }
        guard reference.count >= 2 else { return nil }

        let storyOf = storyIndex(stories)
        let isStory: (Transaction) -> Bool = { storyOf[$0.id] != nil }
        let usualOf: ([Double]) -> Double = { $0.count >= 3 ? median($0) : $0.reduce(0, +) / Double($0.count) }
        let refSet = Set(reference)
        let inMonth = spending.filter { $0.month == month }
        let before = spending.filter { $0.month < month }
        let total = inMonth.reduce(0) { $0 + $1.amount }
        let usual = usualOf(reference.map { m in spending.filter { $0.month == m }.reduce(0) { $0 + $1.amount } })
        let delta = cents(total - usual)
        let label = month.name
        if abs(delta) < max(75, usual * 0.08) {
            return Explanation(label: label, isYear: false, month: month, total: total, usual: usual, delta: delta, isAboutUsual: true, drivers: [])
        }

        var candidates: [Driver] = []
        var attributed: Set<UUID> = []

        // 1. A trip or event: everything that belongs to it this month.
        let byStory = Dictionary(grouping: inMonth.filter(isStory), by: { storyOf[$0.id]! })
        for (index, charges) in byStory.sorted(by: { $0.key < $1.key }) {
            let story = stories[index]
            let amount = charges.reduce(0) { $0 + $1.amount }
            attributed.formUnion(charges.map(\.id))
            guard abs(amount) >= 1 else { continue }
            candidates.append(Driver(id: "story-\(story.id)", kind: .story, title: story.name, amount: cents(amount), target: .story(story.id, story.name),
                                     fallback: "\(story.name) \(amount >= 0 ? "added" : "took off") \(whole(abs(amount)))"))
        }

        // 2. One large charge, far bigger than that category's usual purchase.
        var pastByCategory: [Category: [Double]] = [:]
        for t in before where t.amount > 0 && !isStory(t) { pastByCategory[t.category, default: []].append(t.amount) }
        for t in inMonth where !attributed.contains(t.id) && t.amount >= 150 && t.category != .unsorted {
            let past = pastByCategory[t.category] ?? []
            let unusual = past.count >= 5 ? t.amount >= median(past) * 4 : t.amount >= 750
            guard unusual else { continue }
            attributed.insert(t.id)
            candidates.append(Driver(id: "big-\(t.id)", kind: .oneOff, title: t.merchant, amount: cents(t.amount), target: .charges([t.id], title: "\(t.merchant), \(t.date.formatted(.dateTime.month(.abbreviated).day()))"),
                                     fallback: "One \(t.merchant) charge added \(whole(t.amount)), much more than a usual \(t.category.displayName) purchase"))
        }

        // 3. Something that repeats and started this month; or one whose price went up this month.
        var priceAdjust: [Category: Double] = [:]
        let firstDataMonth = present.min() ?? month
        let chargesByPayee = Dictionary(grouping: inMonth, by: \.merchant)
        for r in recurring {
            let started = Month(date: r.first)
            if started == month, month > firstDataMonth {
                let ids = Set(r.chargeIDs)
                let mine = (chargesByPayee[r.merchant] ?? []).filter { ids.contains($0.id) && !attributed.contains($0.id) }
                let amount = mine.reduce(0) { $0 + $1.amount }
                guard amount >= 1 else { continue }
                attributed.formUnion(mine.map(\.id))
                candidates.append(Driver(id: "new-\(r.merchant)", kind: .newRepeating, title: r.merchant, amount: cents(amount), target: .place(r.merchant),
                                         fallback: "\(r.merchant) is a new charge that repeats \(r.cadence.every.replacingOccurrences(of: "every ", with: "")), \(whole(amount)) this month"))
            } else if started < month, let index = r.history.lastIndex(where: { Month(date: $0.date) == month }), index > 0 {
                let rise = r.history[index].amount - r.history[index - 1].amount
                let ratio = r.history[index - 1].amount > 0 ? r.history[index].amount / r.history[index - 1].amount : 0
                guard rise >= 0.5, (1.03...1.5).contains(ratio) else { continue }
                let ids = Set(r.chargeIDs)
                let mine = (chargesByPayee[r.merchant] ?? []).filter { ids.contains($0.id) }
                guard !mine.isEmpty, mine.allSatisfy({ !attributed.contains($0.id) }) else { continue }
                priceAdjust[r.category, default: 0] += rise
                candidates.append(Driver(id: "price-\(r.merchant)", kind: .priceRise, title: r.merchant, amount: cents(rise), target: .place(r.merchant),
                                         fallback: "\(r.merchant) went up \(Money.format(rise))"))
            }
        }

        // 4. What is left, category by category, against what that category usually costs.
        var remaining: [Category: Double] = [:]
        for t in inMonth where !attributed.contains(t.id) { remaining[t.category, default: 0] += t.amount }
        for (c, v) in priceAdjust { remaining[c, default: 0] -= v }
        var perMonth: [Month: [Category: Double]] = [:]
        for t in spending where refSet.contains(t.month) && !isStory(t) { perMonth[t.month, default: [:]][t.category, default: 0] += t.amount }
        var categories = Set(remaining.keys)
        for m in reference { categories.formUnion(perMonth[m]?.keys.map { $0 } ?? []) }
        for c in categories.sorted(by: { $0.rawValue < $1.rawValue }) {
            let usualInCategory = usualOf(reference.map { perMonth[$0]?[c] ?? 0 })
            let diff = (remaining[c] ?? 0) - usualInCategory
            guard abs(diff) >= 1 else { continue }
            candidates.append(Driver(id: "cat-\(c.rawValue)", kind: diff > 0 ? .categoryUp : .categoryDown, title: c.displayName, amount: cents(diff),
                                     target: .category(c, month),
                                     fallback: "\(c.displayName) ran \(whole(abs(diff))) \(diff > 0 ? "above" : "below") usual"))
        }

        let drivers = choose(candidates, delta: delta, rest: .spending(month), restTitle: month.name)
        return Explanation(label: label, isYear: false, month: month, total: total, usual: usual, delta: delta, isAboutUsual: false, drivers: drivers)
    }

    // MARK: Year

    /// Why the twelve months ending at `end` differ from the twelve before, by trip and by category.
    /// Nil unless both stretches have at least ten months of data.
    static func explainYear(endingAt end: Month, label: String = "The last twelve months", in all: [Transaction], stories: [Story]) -> Explanation? {
        let spending = all.filter(\.countsAsSpending)
        let present = Set(spending.map(\.month))
        let now = Set((0..<12).map { end.adding(-$0) }), then = Set((12..<24).map { end.adding(-$0) })
        guard now.intersection(present).count >= 10, then.intersection(present).count >= 10 else { return nil }
        let storyOf = storyIndex(stories)
        let nowCharges = spending.filter { now.contains($0.month) }, thenCharges = spending.filter { then.contains($0.month) }
        let total = nowCharges.reduce(0) { $0 + $1.amount }, usual = thenCharges.reduce(0) { $0 + $1.amount }
        let delta = cents(total - usual)
        if abs(delta) < max(75, usual * 0.08) {
            return Explanation(label: label, isYear: true, month: nil, total: total, usual: usual, delta: delta, isAboutUsual: true, drivers: [])
        }
        var candidates: [Driver] = []
        let byStory = Dictionary(grouping: nowCharges.filter { storyOf[$0.id] != nil }, by: { storyOf[$0.id]! })
        for (index, charges) in byStory.sorted(by: { $0.key < $1.key }) {
            let amount = charges.reduce(0) { $0 + $1.amount }
            guard abs(amount) >= 1 else { continue }
            let story = stories[index]
            candidates.append(Driver(id: "story-\(story.id)", kind: .story, title: story.name, amount: cents(amount), target: .story(story.id, story.name),
                                     fallback: "\(story.name) added \(whole(abs(amount)))"))
        }
        let oldTrips = thenCharges.filter { storyOf[$0.id] != nil }
        let oldTripTotal = oldTrips.reduce(0) { $0 + $1.amount }
        if abs(oldTripTotal) >= 1 {
            candidates.append(Driver(id: "story-before", kind: .story, title: "Trips and events the year before", amount: cents(-oldTripTotal),
                                     target: .charges(Set(oldTrips.map(\.id)), title: "Trips and events the year before"),
                                     fallback: "Trips and events the year before came to \(whole(abs(oldTripTotal)))"))
        }
        func byCategory(_ list: [Transaction]) -> [Category: [Transaction]] { Dictionary(grouping: list.filter { storyOf[$0.id] == nil }, by: \.category) }
        let a = byCategory(nowCharges), b = byCategory(thenCharges)
        for c in Set(a.keys).union(b.keys).sorted(by: { $0.rawValue < $1.rawValue }) {
            let diff = (a[c] ?? []).reduce(0) { $0 + $1.amount } - (b[c] ?? []).reduce(0) { $0 + $1.amount }
            guard abs(diff) >= 1 else { continue }
            candidates.append(Driver(id: "cat-\(c.rawValue)", kind: diff > 0 ? .categoryUp : .categoryDown, title: c.displayName, amount: cents(diff),
                                     target: .charges(Set((a[c] ?? []).map(\.id)), title: "\(c.displayName), \(label.lowercased())"),
                                     fallback: "\(c.displayName) ran \(whole(abs(diff))) \(diff > 0 ? "above" : "below") the year before"))
        }
        let drivers = choose(candidates, delta: delta, rest: .charges(Set(nowCharges.map(\.id)), title: "Spending, \(label.lowercased())"), restTitle: label)
        return Explanation(label: label, isYear: true, month: nil, total: total, usual: usual, delta: delta, isAboutUsual: false, drivers: drivers)
    }

    // MARK: Shared

    /// The largest candidates that point the way the total moved, enough to cover 80% of the change and
    /// at most four; the rest is "everything else", so the drivers add up to `delta` exactly.
    private static func choose(_ candidates: [Driver], delta: Double, rest: Target, restTitle: String) -> [Driver] {
        let sign: Double = delta > 0 ? 1 : -1
        let pool = candidates.filter { $0.amount * sign > 0 }.sorted { abs($0.amount) != abs($1.amount) ? abs($0.amount) > abs($1.amount) : $0.id < $1.id }
        var kept: [Driver] = []
        var covered = 0.0
        for c in pool where kept.count < 4 && covered < abs(delta) * 0.8 {
            kept.append(c)
            covered += abs(c.amount)
        }
        let remainder = cents(delta - kept.reduce(0) { $0 + $1.amount })
        if abs(remainder) >= 1 || kept.isEmpty {
            let more = remainder > 0
            kept.append(Driver(id: "rest", kind: .everythingElse, title: "Everything else", amount: remainder, target: rest,
                               fallback: "Everything else came to \(whole(abs(remainder))) \(more ? "above" : "below") usual"))
        } else if let last = kept.last {
            // Too small to show as a line of its own: it belongs to the smallest reason given.
            let merged = cents(last.amount + remainder)
            kept[kept.count - 1] = Driver(id: last.id, kind: last.kind, title: last.title, amount: merged, target: last.target,
                                          fallback: last.fallback, written: last.written)
        }
        return kept
    }

    /// Entry id to the position of the trip or event that holds it.
    private static func storyIndex(_ stories: [Story]) -> [UUID: Int] {
        var index: [UUID: Int] = [:]
        for (i, s) in stories.enumerated() { for id in s.entryIDs where index[id] == nil { index[id] = i } }
        return index
    }

    private static func median(_ values: [Double]) -> Double {
        let s = values.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
    private static func cents(_ v: Double) -> Double { (v * 100).rounded() / 100 }
    private static func whole(_ v: Double) -> String { Money.format(v, cents: false) }
}
