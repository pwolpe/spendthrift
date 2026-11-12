import SwiftUI
import FoundationModels

// MARK: - Insights (all math done in code; the AI only writes prose)

struct Insight: Identifiable, Hashable {
    enum Kind: Hashable { case newSubscription, priceIncrease, duplicate, unusual, categoryUp, categoryDown }
    let id: String
    let kind: Kind
    let title: String
    let detail: String
    /// What a click on it opens: the charges, payee or category it is about.
    var target: Target?

    enum Target: Hashable {
        case place(String)
        case charges(Set<UUID>, title: String)
        case category(Category, Month)
    }

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
        case .unusual: Theme.spent
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
        return Dictionary(grouping: spending, by: \.merchant).compactMap { name, txns in
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
            let history = spending.filter { $0.merchant == sub.merchant }.sorted { $0.date < $1.date }
            guard let first = history.first else { continue }
            let firstMonth = Month(date: first.date)
            if firstMonth >= month.adding(-1), firstMonth > firstDataMonth {
                out.append(Insight(id: "sub-\(sub.merchant)-\(firstMonth.key)", kind: .newSubscription,
                                   title: "New subscription: \(sub.merchant)",
                                   detail: "\(Money.format(sub.monthlyAmount)) a month, starting \(firstMonth.name).", target: .place(sub.merchant)))
            }
            let inMonth = history.filter { Month(date: $0.date) == month }
            let before = history.filter { Month(date: $0.date) < month }
            if let now = inMonth.last, let prev = before.last,
               now.amount > prev.amount + 0.5, now.amount / prev.amount >= 1.03, now.amount / prev.amount <= 1.5 {
                out.append(Insight(id: "price-\(sub.merchant)-\(month.key)", kind: .priceIncrease,
                                   title: "\(sub.merchant) went up",
                                   detail: "From \(Money.format(prev.amount)) to \(Money.format(now.amount)) a month.", target: .place(sub.merchant)))
            }
        }

        // Possible double charges
        let sameDay = Dictionary(grouping: thisMonth.filter { $0.amount >= 5 }) {
            "\($0.merchant)|\($0.account)|\(String(format: "%.2f", $0.amount))"
        }
        for (_, group) in sameDay where group.count >= 2 {
            let sorted = group.sorted { $0.date < $1.date }
            for (a, b) in zip(sorted, sorted.dropFirst())
            where Calendar.current.dateComponents([.day], from: a.date, to: b.date).day ?? 99 <= 1 {
                out.append(Insight(id: "dup-\(a.merchant)-\(DateParsing.iso.string(from: a.date))-\(a.amount)", kind: .duplicate,
                                   title: "Possible double charge at \(a.merchant)",
                                   detail: "Two charges of \(Money.format(a.amount)) on \(a.date.formatted(.dateTime.month(.abbreviated).day())). Worth a quick look.",
                                   target: .charges([a.id, b.id], title: "Possible double charge at \(a.merchant)")))
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
            out.append(Insight(id: "big-\(t.merchant)-\(DateParsing.iso.string(from: t.date))-\(t.amount)", kind: .unusual,
                               title: "Bigger than usual: \(t.merchant)",
                               detail: "\(Money.format(t.amount)) on \(t.date.formatted(.dateTime.month(.abbreviated).day())), more than a typical \(t.category.displayName) purchase.",
                               target: .charges([t.id], title: "Bigger than usual: \(t.merchant)")))
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
                                       detail: "\(Money.format(now, cents: false)) in \(month.name), about \(Money.format(diff, cents: false)) more than usual.", target: .category(category, month)))
                } else if monthIsComplete, -diff >= 75, usual > 0, -diff / usual >= 0.3 {
                    out.append(Insight(id: "down-\(category.rawValue)-\(month.key)", kind: .categoryDown,
                                       title: "Nice: \(category.displayName) is down",
                                       detail: "\(Money.format(now, cents: false)) in \(month.name), \(Money.format(-diff, cents: false)) less than usual.", target: .category(category, month)))
                }
            }
        }

        let order: [Insight.Kind] = [.duplicate, .priceIncrease, .newSubscription, .unusual, .categoryUp, .categoryDown]
        return out.sorted { order.firstIndex(of: $0.kind)! < order.firstIndex(of: $1.kind)! }
    }
}

// MARK: - The month's superlatives (computed from real data)

struct Award: Identifiable, Hashable {
    var id: String { title }
    /// The leaders (biggest category, biggest payee) are what the ring and the list of top payees
    /// already show; the rest are found nowhere else.
    var isLeader = false
    /// Whether the winner is a payee (otherwise it is the category).
    var isPayee = false
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
            awards.append(Award(title: "Biggest category", winner: lead.cat.displayName,
                                value: Money.format(lead.total, cents: false), category: lead.cat, symbol: "star.fill"))
            awards[awards.count - 1].isLeader = true
        }
        if byCategory.count > 1 {
            let support = byCategory[1]
            awards.append(Award(title: "Runner-up", winner: support.cat.displayName,
                                value: Money.format(support.total, cents: false), category: support.cat, symbol: "star.leadinghalf.filled"))
            awards[awards.count - 1].isLeader = true
        }

        // Places
        var places: [(name: String, total: Double, count: Int, cat: Category)] = []
        for (name, txns) in Dictionary(grouping: thisMonth, by: \.merchant) {
            places.append((name, txns.reduce(0.0) { $0 + $1.amount }, txns.count, txns[0].category))
        }
        if let venue = places.max(by: { $0.total < $1.total }), venue.total > 0 {
            awards.append(Award(title: "Biggest single payee", winner: venue.name, value: Money.format(venue.total, cents: false),
                                category: venue.cat, symbol: "building.2.fill"))
            awards[awards.count - 1].isLeader = true
            usedWinners.insert(venue.name)
        }
        if let regular = places.filter({ $0.count >= 3 && !usedWinners.contains($0.name) }).max(by: { $0.count < $1.count }) {
            awards.append(Award(title: "Most visits", winner: regular.name, value: "\(regular.count) visits",
                                category: regular.cat, symbol: "arrow.clockwise.circle.fill"))
            usedWinners.insert(regular.name)
        }

        // Newcomer: first-ever appearance this month (only if we have earlier history).
        let firstDataMonth = spending.map { Month(date: $0.date) }.min() ?? month
        if firstDataMonth < month {
            let seenBefore = Set(spending.filter { Month(date: $0.date) < month }.map(\.merchant))
            if let newcomer = places.filter({ !seenBefore.contains($0.name) && !usedWinners.contains($0.name) && $0.total >= 10 })
                .max(by: { $0.total < $1.total }) {
                awards.append(Award(title: "New this month", winner: newcomer.name, value: Money.format(newcomer.total),
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
                awards.append(Award(title: "Biggest cut", winner: best.0.displayName,
                                    value: "↓ \(Money.format(best.1, cents: false))", category: best.0, symbol: "chart.line.downtrend.xyaxis"))
            }
        }

        // Lifetime achievement: the longest-running regular charge.
        let subs = InsightEngine.subscriptions(asOf: month, in: all)
        let lifetime = subs.map { sub -> (Subscription, Int) in
            let months = Set(spending.filter { $0.merchant == sub.merchant }.map { Month(date: $0.date) }).count
            return (sub, months)
        }.filter { !usedWinners.contains($0.0.merchant) }.max { $0.1 < $1.1 }
        if let (sub, months) = lifetime, months >= 3 {
            awards.append(Award(title: "Longest running", winner: sub.merchant, value: "\(months) months running",
                                category: sub.category, symbol: "medal.fill"))
        }
        let payees = Set(thisMonth.map(\.merchant))
        return awards.map { award in var a = award; a.isPayee = payees.contains(award.winner) && award.category?.displayName != award.winner; return a }
    }
}

// MARK: - The bookkeeper's note

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
        let voice = """
            You are the voice of Spendthrift, a personal spending app with the manner of a dry, fond bookkeeper who is quietly amused by where the money goes. Speak to the person as \"you\"; never name them or guess their job.
            Write a 2-sentence note on this month using ONLY the facts given. Copy dollar amounts exactly as written.
            Deadpan and warm, a little wry, specific, never scolding and never gushing. No awards or theater language. No lists, no quotes, no exclamation marks.
            """
        let prompt = facts.joined(separator: "\n")
        // The cloud model when there is one, Apple's on the Mac otherwise; the same brief and the same check for both.
        var written = await CloudWriter.line(system: voice, facts: prompt, maxTokens: 3_000, temperature: 0.8)
        if written == nil, SystemLanguageModel.default.isAvailable {
            let session = LanguageModelSession(instructions: voice)
            written = await Timeout.run(45) { try? await session.respond(to: prompt, options: GenerationOptions(temperature: 0.7)).content }
        }
        guard let text = written?.trimmingCharacters(in: .whitespacesAndNewlines), numbersAreReal(text) else { return fallback }
        cache[key] = text
        return text
    }

    static func fallbackText(month: Month, total: Double, previous: Double?, awards: [Award]) -> String {
        var s = "\(month.name) came to \(Money.format(total, cents: false))"
        if let previous, previous > 0 {
            let diff = total - previous
            s += diff <= 0 ? ", \(Money.format(-diff, cents: false)) less than the month before" : ", \(Money.format(diff, cents: false)) more than the month before"
        }
        s += "."
        if let lead = awards.first { s += " Most of it went to \(lead.winner)." }
        return s
    }
}

// MARK: - The month, itemized

/// The month written up the way a till would: a short note, then the superlatives as printed lines.
struct CeremonyCard: View {
    @Environment(BudgetStore.self) private var store
    let month: Month
    @State private var text = ""

    var body: some View {
        let insights = store.insights(for: month)
        let awards = AwardEngine.awards(for: month, in: store.transactions)
        // Only what the page doesn't already show: the ring and Top payees cover the leaders.
        let printed = awards.filter { !$0.isLeader }
        Card {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(month.name), itemized")
                            .font(.system(.title2, design: .serif).weight(.bold))
                        Text(text.isEmpty ? " " : text)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .redacted(reason: text.isEmpty ? .placeholder : [])
                            .contentTransition(.opacity)
                        if !insights.isEmpty {
                            Divider().padding(.vertical, 4)
                            Text("Also worth knowing")
                                .font(.headline)
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(insights) { insight in
                                    InsightRow(insight: insight, open: { store.show(insight) }) { store.dismissInsight(insight) }
                                        .transition(.opacity)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !printed.isEmpty {
                        ReceiptPaper(padding: 16) {
                            VStack(alignment: .leading, spacing: 9) {
                                Text(month.title.uppercased()).font(Theme.mono(11, .bold)).tracking(1.5)
                                    .frame(maxWidth: .infinity)
                                ReceiptRule()
                                ForEach(printed) { award in
                                    Button {
                                        if award.isPayee { store.showPlace(award.winner) }
                                        else if let category = award.category { store.showCharges(TransactionFilter(category: category, month: month)) }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(award.title.uppercased()).font(Theme.mono(9.5, .semibold)).tracking(0.8).foregroundStyle(.secondary)
                                            ReceiptLine(value: award.value) {
                                                Text(award.winner).font(.callout.weight(.medium)).lineLimit(1)
                                            }
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                                ReceiptRule()
                                ReceiptLine(value: Money.format(store.totalSpent(in: month), cents: false), bold: true) {
                                    Text("TOTAL").font(Theme.mono(13, .bold))
                                }
                            }
                        }
                        .frame(width: 320)
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

private struct InsightRow: View {
    let insight: Insight
    let open: () -> Void
    let dismiss: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            // The row itself opens what it is about; the cross beside it puts it away.
            Button(action: open) {
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
                    if insight.target != nil {
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            .opacity(hovering ? 1 : 0)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(insight.target == nil)
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill").font(.title3)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .opacity(hovering ? 1 : 0)
            .help("Got it")
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background(Color.primary.opacity(hovering && insight.target != nil ? 0.05 : 0), in: .rect(cornerRadius: 10, style: .continuous))
        .onHover { hovering = $0 }
    }
}
