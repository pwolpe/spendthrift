import SwiftUI
import FoundationModels

// MARK: - Insights (all math done in code; the AI only writes prose)

struct Insight: Identifiable, Hashable {
    enum Kind: Hashable { case newSubscription, priceIncrease, duplicate, unusual, categoryUp, categoryDown }
    let id: String
    let kind: Kind
    let title: String
    let detail: String

    var symbol: String {
        switch kind {
        case .newSubscription: "repeat.circle.fill"
        case .priceIncrease: "arrow.up.circle.fill"
        case .duplicate: "equal.circle.fill"
        case .unusual: "exclamationmark.circle.fill"
        case .categoryUp: "chart.line.uptrend.xyaxis.circle.fill"
        case .categoryDown: "hand.thumbsup.circle.fill"
        }
    }

    var color: Color {
        switch kind {
        case .newSubscription: .purple
        case .priceIncrease: .orange
        case .duplicate: .red
        case .unusual: .pink
        case .categoryUp: .yellow
        case .categoryDown: .green
        }
    }
}

struct Subscription: Identifiable, Hashable {
    var id: String { merchant }
    let merchant: String
    let category: Category
    let monthlyAmount: Double
    let lastCharge: Date
}

enum InsightEngine {
    private static func monthCharges(_ txns: [Transaction]) -> [Month: [Transaction]] {
        Dictionary(grouping: txns) { Month(date: $0.date) }
    }

    /// Merchants charged about the same amount, once a month, in at least 2 of the last 4 months.
    static func subscriptions(asOf month: Month, in all: [Transaction]) -> [Subscription] {
        let window = Set((0..<4).map { month.adding(-$0) })
        let spending = all.filter { $0.countsAsSpending && $0.amount > 0 && window.contains(Month(date: $0.date)) }
        return Dictionary(grouping: spending, by: \.merchantDisplay).compactMap { name, txns in
            let byMonth = monthCharges(txns)
            guard byMonth.count >= 2, byMonth.values.allSatisfy({ $0.count == 1 }) else { return nil }
            let amounts = txns.map(\.amount).sorted()
            let median = amounts[amounts.count / 2]
            guard amounts.allSatisfy({ abs($0 - median) <= median * 0.2 }) else { return nil }
            let latest = txns.max { $0.date < $1.date }!
            // Must still be active: charged this month or last.
            guard Month(date: latest.date) >= month.adding(-1) else { return nil }
            return Subscription(merchant: name, category: latest.category, monthlyAmount: latest.amount, lastCharge: latest.date)
        }
        .sorted { $0.monthlyAmount > $1.monthlyAmount }
    }

    static func insights(for month: Month, in all: [Transaction]) -> [Insight] {
        let spending = all.filter(\.countsAsSpending)
        guard let firstDataMonth = spending.map({ Month(date: $0.date) }).min(),
              let lastDate = spending.map(\.date).max() else { return [] }
        let thisMonth = spending.filter { Month(date: $0.date) == month }
        let monthIsComplete = Month(date: lastDate) > month || Calendar.current.component(.day, from: lastDate) >= 25
        var out: [Insight] = []

        // New subscriptions & price increases
        for sub in subscriptions(asOf: month, in: all) {
            let history = spending.filter { $0.merchantDisplay == sub.merchant }.sorted { $0.date < $1.date }
            guard let first = history.first else { continue }
            let firstMonth = Month(date: first.date)
            if firstMonth >= month.adding(-1), firstMonth > firstDataMonth {
                out.append(Insight(id: "sub-\(sub.merchant)-\(firstMonth.key)", kind: .newSubscription,
                                   title: "New subscription: \(sub.merchant)",
                                   detail: "\(Money.format(sub.monthlyAmount)) a month, starting \(firstMonth.name)."))
            }
            let inMonth = history.filter { Month(date: $0.date) == month }
            let before = history.filter { Month(date: $0.date) < month }
            if let now = inMonth.last, let prev = before.last,
               now.amount > prev.amount + 0.5, now.amount / prev.amount >= 1.03, now.amount / prev.amount <= 1.5 {
                out.append(Insight(id: "price-\(sub.merchant)-\(month.key)", kind: .priceIncrease,
                                   title: "\(sub.merchant) went up",
                                   detail: "From \(Money.format(prev.amount)) to \(Money.format(now.amount)) a month."))
            }
        }

        // Possible double charges
        let sameDay = Dictionary(grouping: thisMonth.filter { $0.amount >= 5 }) {
            "\($0.merchantDisplay)|\($0.account)|\(String(format: "%.2f", $0.amount))"
        }
        for (_, group) in sameDay where group.count >= 2 {
            let sorted = group.sorted { $0.date < $1.date }
            for (a, b) in zip(sorted, sorted.dropFirst())
            where Calendar.current.dateComponents([.day], from: a.date, to: b.date).day ?? 99 <= 1 {
                out.append(Insight(id: "dup-\(a.merchantDisplay)-\(DateParsing.iso.string(from: a.date))-\(a.amount)", kind: .duplicate,
                                   title: "Possible double charge at \(a.merchantDisplay)",
                                   detail: "Two charges of \(Money.format(a.amount)) on \(a.date.formatted(.dateTime.month(.abbreviated).day())). Worth a quick look."))
                break
            }
        }

        // Unusually large purchases
        let earlier = spending.filter { Month(date: $0.date) < month && $0.amount > 0 }
        let byCategory = Dictionary(grouping: earlier, by: \.category)
        let unusual = thisMonth.filter { t in
            guard t.amount >= 150, t.category != .unsorted else { return false }
            let past = (byCategory[t.category] ?? []).map(\.amount).sorted()
            guard past.count >= 5 else { return t.amount >= 750 }
            return t.amount >= past[past.count / 2] * 4 && t.amount >= (past.last ?? 0) * 0.9
        }
        for t in unusual.sorted(by: { $0.amount > $1.amount }).prefix(3) {
            out.append(Insight(id: "big-\(t.merchantDisplay)-\(DateParsing.iso.string(from: t.date))-\(t.amount)", kind: .unusual,
                               title: "Bigger than usual: \(t.merchantDisplay)",
                               detail: "\(Money.format(t.amount)) on \(t.date.formatted(.dateTime.month(.abbreviated).day())), more than a typical \(t.category.displayName) purchase."))
        }

        // Category trends vs. the previous 3 months
        let previous = (1...3).map { month.adding(-$0) }.filter { $0 >= firstDataMonth }
        if previous.count >= 2 {
            let current = Dictionary(grouping: thisMonth, by: \.category).mapValues { $0.reduce(0) { $0 + $1.amount } }
            let pastTotals = Dictionary(grouping: spending.filter { previous.contains(Month(date: $0.date)) }, by: \.category)
                .mapValues { $0.reduce(0) { $0 + $1.amount } / Double(previous.count) }
            for category in Category.spendingCases {
                let now = current[category] ?? 0, usual = pastTotals[category] ?? 0
                let diff = now - usual
                if diff >= 75, usual > 0, diff / usual >= 0.3 {
                    out.append(Insight(id: "up-\(category.rawValue)-\(month.key)", kind: .categoryUp,
                                       title: "\(category.displayName) is up",
                                       detail: "\(Money.format(now, cents: false)) in \(month.name), about \(Money.format(diff, cents: false)) more than usual."))
                } else if monthIsComplete, -diff >= 75, usual > 0, -diff / usual >= 0.3 {
                    out.append(Insight(id: "down-\(category.rawValue)-\(month.key)", kind: .categoryDown,
                                       title: "Nice: \(category.displayName) is down",
                                       detail: "\(Money.format(now, cents: false)) in \(month.name), \(Money.format(-diff, cents: false)) less than usual."))
                }
            }
        }

        let order: [Insight.Kind] = [.duplicate, .priceIncrease, .newSubscription, .unusual, .categoryUp, .categoryDown]
        return out.sorted { order.firstIndex(of: $0.kind)! < order.firstIndex(of: $1.kind)! }
    }
}

// MARK: - The awards (computed from real data)

struct Award: Identifiable, Hashable {
    var id: String { title }
    let title: String
    let winner: String
    let value: String
    let category: Category?
    let symbol: String
}

enum AwardEngine {
    static func awards(for month: Month, in all: [Transaction]) -> [Award] {
        let spending = all.filter { $0.countsAsSpending && $0.category != .unsorted }
        let thisMonth = spending.filter { Month(date: $0.date) == month }
        guard !thisMonth.isEmpty else { return [] }
        var awards: [Award] = []
        var usedWinners: Set<String> = []

        // Categories
        let byCategory = Dictionary(grouping: thisMonth, by: \.category)
            .map { (cat: $0.key, total: $0.value.reduce(0.0) { $0 + $1.amount }) }
            .filter { $0.total > 0 }
            .sorted { $0.total > $1.total }
        if let lead = byCategory.first {
            awards.append(Award(title: "Best Leading Category", winner: lead.cat.displayName,
                                value: Money.format(lead.total, cents: false), category: lead.cat, symbol: "star.fill"))
        }
        if byCategory.count > 1 {
            let support = byCategory[1]
            awards.append(Award(title: "Best Supporting Category", winner: support.cat.displayName,
                                value: Money.format(support.total, cents: false), category: support.cat, symbol: "star.leadinghalf.filled"))
        }

        // Places
        var places: [(name: String, total: Double, count: Int, cat: Category)] = []
        for (name, txns) in Dictionary(grouping: thisMonth, by: \.merchantDisplay) {
            places.append((name, txns.reduce(0.0) { $0 + $1.amount }, txns.count, txns[0].category))
        }
        if let venue = places.max(by: { $0.total < $1.total }), venue.total > 0 {
            awards.append(Award(title: "Best Venue", winner: venue.name, value: Money.format(venue.total, cents: false),
                                category: venue.cat, symbol: "building.2.fill"))
            usedWinners.insert(venue.name)
        }
        if let regular = places.filter({ $0.count >= 3 && !usedWinners.contains($0.name) }).max(by: { $0.count < $1.count }) {
            awards.append(Award(title: "Most Curtain Calls", winner: regular.name, value: "\(regular.count) visits",
                                category: regular.cat, symbol: "arrow.clockwise.circle.fill"))
            usedWinners.insert(regular.name)
        }

        // Newcomer: first-ever appearance this month (only if we have earlier history).
        let firstDataMonth = spending.map { Month(date: $0.date) }.min() ?? month
        if firstDataMonth < month {
            let seenBefore = Set(spending.filter { Month(date: $0.date) < month }.map(\.merchantDisplay))
            if let newcomer = places.filter({ !seenBefore.contains($0.name) && !usedWinners.contains($0.name) && $0.total >= 10 })
                .max(by: { $0.total < $1.total }) {
                awards.append(Award(title: "Surprise Newcomer", winner: newcomer.name, value: Money.format(newcomer.total),
                                    category: newcomer.cat, symbol: "sparkles"))
                usedWinners.insert(newcomer.name)
            }
        }

        // Most improved: biggest drop vs the previous months' average.
        let previous = (1...3).map { month.adding(-$0) }.filter { $0 >= firstDataMonth }
        if previous.count >= 2 {
            let current = Dictionary(grouping: thisMonth, by: \.category).mapValues { $0.reduce(0.0) { $0 + $1.amount } }
            let past = Dictionary(grouping: spending.filter { previous.contains(Month(date: $0.date)) }, by: \.category)
                .mapValues { $0.reduce(0.0) { $0 + $1.amount } / Double(previous.count) }
            let drops = past.compactMap { cat, usual -> (Category, Double)? in
                let drop = usual - (current[cat] ?? 0)
                return drop >= 25 ? (cat, drop) : nil
            }
            if let best = drops.max(by: { $0.1 < $1.1 }) {
                awards.append(Award(title: "Most Improved", winner: best.0.displayName,
                                    value: "↓ \(Money.format(best.1, cents: false))", category: best.0, symbol: "chart.line.downtrend.xyaxis"))
            }
        }

        // Lifetime achievement: the longest-running regular charge.
        let subs = InsightEngine.subscriptions(asOf: month, in: all)
        let lifetime = subs.map { sub -> (Subscription, Int) in
            let months = Set(spending.filter { $0.merchantDisplay == sub.merchant }.map { Month(date: $0.date) }).count
            return (sub, months)
        }.filter { !usedWinners.contains($0.0.merchant) }.max { $0.1 < $1.1 }
        if let (sub, months) = lifetime, months >= 3 {
            awards.append(Award(title: "Lifetime Achievement", winner: sub.merchant, value: "\(months) months running",
                                category: sub.category, symbol: "medal.fill"))
        }
        return awards
    }
}

// MARK: - The host's opening remarks

enum RecapWriter {
    private static var cache: [String: String] = [:]

    @MainActor
    static func recap(month: Month, total: Double, previous: Double?, awards: [Award], insights: [Insight]) async -> String {
        let fallback = fallbackText(month: month, total: total, previous: previous, awards: awards)
        let key = "\(month.key)|\(Int(total))|\(awards.map(\.winner).joined())|\(insights.count)"
        if let cached = cache[key] { return cached }
        guard SystemLanguageModel.default.isAvailable || CloudAI.isEnabled else { return fallback }

        var facts = ["Month: \(month.title)", "Total spent: \(Money.format(total, cents: false))"]
        if let previous, previous > 0 { facts.append("Previous month: \(Money.format(previous, cents: false))") }
        for a in awards.prefix(5) { facts.append("\(a.title): \(a.winner) (\(a.value))") }
        if !insights.isEmpty { facts.append("Notable: " + insights.prefix(3).map(\.title).joined(separator: "; ")) }

        // Same check for either model: every number in the text must be one we supplied.
        func numbersAreReal(_ text: String) -> Bool {
            let digits = CharacterSet(charactersIn: "0123456789,").inverted
            let allowed = Set(facts.joined(separator: " ").components(separatedBy: digits).filter { $0.count >= 2 })
            return !text.isEmpty && text.components(separatedBy: digits).filter { $0.count >= 2 }.allSatisfy(allowed.contains)
        }
        if let written = await CloudWriter.line(system: """
            You are the host of The Tony Awards, a playful awards show that honors Tony's monthly spending. Tony is a CPA.
            Write a 2-sentence opening for this month's ceremony using ONLY the facts given. Copy dollar amounts exactly as written.
            Use theater and awards-show language. Be warm, witty and specific, never judgmental. No lists, no quotes, no stage directions.
            """, facts: facts.joined(separator: "\n"), maxTokens: 3_000, temperature: 0.8), numbersAreReal(written) {
            cache[key] = written
            return written
        }
        guard SystemLanguageModel.default.isAvailable else { return fallback }

        let session = LanguageModelSession(instructions: """
        You are the host of The Tony Awards, a playful awards show that honors Tony's monthly spending. Tony is a CPA.
        Write a 2-sentence opening for this month's ceremony using ONLY the facts given. Copy dollar amounts exactly as written.
        Use theater and awards-show language. Be warm and funny, never judgmental. No lists, no quotes, no stage directions.
        """)
        do {
            let prompt = facts.joined(separator: "\n")
            guard let answer = await Timeout.run(45, { try? await session.respond(to: prompt, options: GenerationOptions(temperature: 0.7)).content }) else { throw CancellationError() }
            let reply = (content: answer, ())
            let text = reply.content.trimmingCharacters(in: .whitespacesAndNewlines)
            // Guard against the model inventing numbers.
            let digits = CharacterSet(charactersIn: "0123456789,").inverted
            let allowed = Set(facts.joined(separator: " ").components(separatedBy: digits).filter { $0.count >= 2 })
            let used = text.components(separatedBy: digits).filter { $0.count >= 2 }
            guard !text.isEmpty, used.allSatisfy({ allowed.contains($0) }) else { return fallback }
            cache[key] = text
            return text
        } catch {
            return fallback
        }
    }

    static func fallbackText(month: Month, total: Double, previous: Double?, awards: [Award]) -> String {
        var s = "Welcome to the \(month.name) ceremony, where \(Money.format(total, cents: false)) took the stage"
        if let previous, previous > 0 {
            let diff = total - previous
            s += diff <= 0 ? ", \(Money.format(-diff, cents: false)) less than last month" : ", \(Money.format(diff, cents: false)) more than last month"
        }
        s += "."
        if let lead = awards.first { s += " Let's hear it for \(lead.winner)!" }
        return s
    }
}

// MARK: - The ceremony card

struct CeremonyCard: View {
    @Environment(BudgetStore.self) private var store
    let month: Month
    @State private var text = ""

    private let gold = Theme.gold

    var body: some View {
        let insights = store.insights(for: month)
        let awards = AwardEngine.awards(for: month, in: store.transactions)
        Card {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    Image(systemName: "trophy.fill").font(.title2).foregroundStyle(gold)
                    Text("The \(month.name) Ceremony")
                        .font(.system(.title2, design: .serif).weight(.bold))
                }
                Text(text.isEmpty ? " " : text)
                    .font(.title3)
                    .italic()
                    .fixedSize(horizontal: false, vertical: true)
                    .redacted(reason: text.isEmpty ? .placeholder : [])
                    .contentTransition(.opacity)

                if !awards.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                        ForEach(awards) { AwardTile(award: $0) }
                    }
                    .padding(.top, 2)
                }

                if !insights.isEmpty {
                    Divider().padding(.vertical, 2)
                    Text("Notes from the Academy")
                        .font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 20, alignment: .topLeading)], alignment: .leading, spacing: 12) {
                        ForEach(insights) { insight in
                            InsightRow(insight: insight) { store.dismissInsight(insight) }
                                .transition(.opacity)
                        }
                    }
                }
            }
        }
        .task(id: "\(month.key)-\(store.transactions.count)-\(insights.count)") {
            let total = store.totalSpent(in: month)
            let prevMonth = month.adding(-1)
            let previous = store.months.contains(prevMonth) ? store.totalSpent(in: prevMonth) : nil
            let written = await RecapWriter.recap(month: month, total: total, previous: previous,
                                                  awards: awards, insights: insights)
            withAnimation { text = written }
        }
    }
}

private struct AwardTile: View {
    let award: Award

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: award.symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Theme.gold))
            VStack(alignment: .leading, spacing: 2) {
                Text(award.title.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(1.1)
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                Text(award.winner).font(.body.weight(.semibold)).lineLimit(1)
                Text(award.value).font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Theme.goldLight.opacity(0.13), in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.goldDeep.opacity(0.25)))
    }
}

private struct InsightRow: View {
    let insight: Insight
    let dismiss: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: insight.symbol)
                .font(.system(size: 26))
                .foregroundStyle(insight.color.gradient)
            VStack(alignment: .leading, spacing: 2) {
                Text(insight.title).font(.body.weight(.semibold))
                Text(insight.detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill").font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .opacity(hovering ? 1 : 0)
            .help("Got it")
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
