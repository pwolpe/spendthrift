import Foundation

/// Questions worth asking, proposed from what the app has found. The Ask pane opens with a few;
/// they change when the findings change, and once a week regardless, so the list is never stale.
/// A model writes the questions; it is handed findings, not statements, and nothing it writes is
/// shown as fact: each is only a question the person may choose to ask.
extension BudgetStore {
    private static let askIdeasKey = "ask-ideas"

    /// What the app has found lately, one line each: the raw material for questions.
    func askIdeaFacts() -> [String] {
        guard let latest = months.last, let first = months.first, let end = transactions.last?.date else { return [] }
        let money = { (v: Double) in Money.format(v, cents: false) }
        var facts = ["Statements on file run from \(first.title) to \(latest.title)."]
        if let why = changes(in: latest), !why.isAboutUsual {
            facts.append("\(latest.name) was \(money(abs(why.delta))) \(why.delta > 0 ? "above" : "below") a usual month: " + why.drivers.prefix(4).map(\.fallback).joined(separator: "; ") + ".")
        }
        if let why = changes(in: ReportPeriod.last12), !why.isAboutUsual {
            facts.append("The last twelve months against the twelve before: " + why.drivers.prefix(5).map(\.fallback).joined(separator: "; ") + ".")
        }
        for insight in insights(for: latest).prefix(6) { facts.append("Noticed in \(latest.name): \(insight.title). \(insight.detail)") }
        let bills = recurring().filter(\.isActive)
        let crept = bills.filter { $0.creep > 0 }.prefix(4)
        if !crept.isEmpty { facts.append("Bills whose price crept up: " + crept.map { "\($0.merchant) (now \(money($0.amount)) \($0.cadence.every))" }.joined(separator: "; ") + ".") }
        let forgotten = bills.filter(\.isForgotten).prefix(4)
        if !forgotten.isEmpty { facts.append("Subscriptions running a long time that may be forgotten: " + forgotten.map(\.merchant).joined(separator: ", ") + ".") }
        let ideas = savingsIdeas().prefix(3)
        if !ideas.isEmpty { facts.append("Ways to save the app found: " + ideas.map(\.title).joined(separator: "; ") + ".") }
        if !stories.isEmpty { facts.append("Trips and events on file: " + stories.prefix(4).map(\.name).joined(separator: ", ") + ".") }
        // Where the money went this past year, and who is new.
        let yearAgo = end.addingTimeInterval(-365 * 86_400), recently = end.addingTimeInterval(-75 * 86_400)
        var spent: [String: Double] = [:], firstSeen: [String: Date] = [:], kinds: [Category: Double] = [:]
        for t in transactions where t.countsAsSpending && t.amount > 0 {
            if firstSeen[t.merchant] == nil { firstSeen[t.merchant] = t.date }
            guard t.date >= yearAgo else { continue }
            spent[t.merchant, default: 0] += t.amount
            kinds[t.category, default: 0] += t.amount
        }
        let top = spent.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        if !top.isEmpty { facts.append("Biggest payees of the last twelve months: " + top.prefix(8).map { "\($0.key) \(money($0.value))" }.joined(separator: "; ") + ".") }
        let kindsTop = kinds.sorted { ($0.value, $1.key.rawValue) > ($1.value, $0.key.rawValue) }.prefix(7)
        if !kindsTop.isEmpty { facts.append("Biggest categories of the last twelve months: " + kindsTop.map { "\($0.key.rawValue) \(money($0.value))" }.joined(separator: "; ") + ".") }
        let new = top.filter { (firstSeen[$0.key] ?? .distantPast) >= recently && $0.value >= 150 }.prefix(5)
        if !new.isEmpty { facts.append("Payees never seen before the last ten weeks: " + new.map { "\($0.key) \(money($0.value))" }.joined(separator: "; ") + ".") }
        // What the cards' own statements show (said without the card's number).
        for card in cardFacts() {
            let name = card.name.components(separatedBy: "••").first?.trimmingCharacters(in: .whitespaces) ?? "A card"
            for finding in card.findings.filter({ [.waiting, .wrongCard, .missed, .feeRose, .quiet].contains($0.kind) }).prefix(2) {
                facts.append("On the \(name) card: \(finding.text)")
            }
        }
        // What the order history adds.
        let habits = orderHabits().prefix(4)
        if !habits.isEmpty {
            facts.append("Ordered again and again from Amazon: " + habits.map { habit in
                habit.name + ", " + OrderHabits.rhythm(habit.everyDays) + (habit.price.map { $0.now > $0.was ? ", price up since \($0.when.formatted(.dateTime.year()))" : ", price down" } ?? "")
            }.joined(separator: "; ") + ".")
        }
        return facts
    }

    /// The questions on file, whatever they were written from. Never waits.
    var keptAskIdeas: [String]? {
        guard let kept = library.reads?[Self.askIdeasKey], let tab = kept.firstIndex(of: "\t") else { return nil }
        let ideas = kept[kept.index(after: tab)...].split(separator: "\n").map(String.init)
        return ideas.isEmpty ? nil : ideas
    }

    /// Writes new questions when the findings have changed since the last were written, when a week
    /// has turned, or when the person asks for different ones. Leaves what is there on any failure.
    func refreshAskIdeas(different: Bool = false) async {
        guard CloudAI.isEnabled, !isWritingAskIdeas else { return }
        let facts = askIdeaFacts()
        guard facts.count >= 3 else { return }
        let week = Calendar.current.dateComponents([.yearForWeekOfYear, .weekOfYear], from: .now)
        let basis = Self.basis(of: facts + ["week \(week.yearForWeekOfYear ?? 0)-\(week.weekOfYear ?? 0)"])
        let kept = library.reads?[Self.askIdeasKey]
        if !different, kept?.hasPrefix(basis + "\t") == true { return }
        isWritingAskIdeas = true
        defer { isWritingAskIdeas = false }
        var system = """
        You propose questions for the Ask box of Spendthrift, a personal money app. You are given findings the \
        app worked out from one person's own bank and card statements. Propose 5 questions this person would \
        probably not think to ask, and would be glad they did: specific, a little surprising, useful.
        Each must be answerable from their own transactions alone: payees, categories, months, amounts, trips, \
        bills that repeat, Amazon orders. Name real payees, categories, trips or months from the findings.
        Vary the angle: something that changed and why; a habit or a price creeping up; something new or \
        possibly forgotten; a comparison across time; and one that is simply fun to know.
        Write each as the person would ask it ("I", "my"), under 60 characters, ending in a question mark. \
        No dollar amounts, no advice, nothing that needs information outside the statements, no predictions.
        Statements show payments, not what was used, enjoyed or worth it: never ask whether something is used. \
        Favour the unexpected finding over the obvious headline.
        Return only a JSON array of 5 strings.
        """
        if different, let old = keptAskIdeas { system += "\nDo not repeat or rephrase any of these, and take different angles: " + old.joined(separator: " | ") }
        guard let text = await CloudWriter.line(system: system, facts: facts.joined(separator: "\n"), maxTokens: 2_000, temperature: 0.9) else { return }
        let ideas = Self.askIdeas(in: text)
        guard ideas.count >= 3 else { return }
        var reads = library.reads ?? [:], times = library.readTimes ?? [:]
        reads[Self.askIdeasKey] = basis + "\t" + ideas.joined(separator: "\n")
        times[Self.askIdeasKey] = .now
        library.reads = reads
        library.readTimes = times
        readsChecked += 1
        savedOnly()
    }

    /// The questions in what a model wrote: a list of short questions, with no figures in them
    /// (a figure in a suggestion would read as a fact, and no model's figure is ever shown).
    nonisolated static func askIdeas(in text: String) -> [String] {
        guard let open = text.firstIndex(of: "["), let close = text.lastIndex(of: "]"), open < close,
              let list = try? JSONDecoder().decode([String].self, from: Data(text[open...close].utf8)) else { return [] }
        var seen: Set<String> = []
        return list.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { (8...80).contains($0.count) && $0.hasSuffix("?") && !$0.contains("$") && !$0.contains("\n") && !$0.contains("\t") && seen.insert($0.lowercased()).inserted }
            .prefix(5).map { $0 }
    }
}
