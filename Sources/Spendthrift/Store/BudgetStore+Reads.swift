import SwiftUI

/// "The short version": two or three sentences about a stretch, written by a model from figures
/// the app worked out, the way a friend who is good with numbers would put it. The figures are the
/// app's; only the wording is the model's, and any dollar amount it did not get from the app throws
/// the whole thing away. Written once for a given set of figures and kept.
extension BudgetStore {
    /// The Overview's own figures for a stretch, as plain lines for a model to say in a few sentences.
    /// Only what the page shows is given. `basis` changes whenever the figures do.
    func overviewFacts(_ data: CashFlowData, period: ReportPeriod) -> (basis: String, facts: [String]) {
        let money = { (v: Double) in Money.format(v, cents: false) }
        var facts = ["Stretch: \(data.title).",
                     "Came in, all told: \(money(data.totalIncome)), of which pay was \(money(data.income)) and investments paid out \(money(data.fromInvestments)).",
                     "Income taxes paid: \(money(data.taxes)). Lived on: \(money(data.spending)). Loan interest: \(money(data.loanInterest)).",
                     data.surplus >= 0 ? "Left to keep or invest after all of that: \(money(data.surplus))." : "Lived on \(money(-data.surplus)) more than came in.",
                     "Money put into investments (not spending, still theirs): \(money(data.built))."]
        if data.income > 0.5 {
            let gap = data.income - data.spending
            facts.append(gap >= 0 ? "Against pay alone: lived on \(FlowHero.percent(data.spending / data.income)) of pay, \(money(gap)) of pay left."
                                  : "Against pay alone: lived on \(money(-gap)) more than pay (\(FlowHero.percent(-gap / data.income)) over); investments or savings covered that.")
            if data.optionalSpending > 0.5 {
                facts.append("Of what was lived on, \(money(data.optionalSpending)) was chosen rather than needed (dining out, travel, things for pleasure): \(FlowHero.percent(data.optionalSpending / data.income)) of pay.")
            }
        }
        if let why = changes(in: period) {
            facts.append(why.isAboutUsual ? "Spending was about the same as the twelve months before."
                                          : "Spending was \(money(abs(why.delta))) \(why.delta > 0 ? "more" : "less") than the twelve months before. Reasons, largest first: "
                                            + why.drivers.map(\.fallback).joined(separator: "; ") + ".")
        }
        let bills = recurring().filter(\.isActive)
        if !bills.isEmpty { facts.append("Bills and subscriptions: \(bills.count) that repeat, \(money(bills.reduce(0) { $0 + $1.yearly })) a year.") }
        let ideas = savingsIdeas()
        if !ideas.isEmpty {
            facts.append("Ways to save found: \(ideas.count), worth \(money(ideas.reduce(0) { $0 + $1.yearly })) a year together; the largest: \(ideas.prefix(2).map { "\($0.title) (\(money($0.yearly)) a year)" }.joined(separator: "; ")).")
        }
        return (Self.basis(of: facts), facts)
    }

    /// Changes whenever any fact a sentence is written from changes: a hash of all of them.
    nonisolated static func basis(of facts: [String]) -> String {
        String(Self.hash(Data(facts.joined(separator: "\n").utf8)).prefix(16))
    }

    /// The sentences on file for these figures, if any. Never waits.
    /// A cheap fingerprint of the library: enough to say "nothing has changed since this was last
    /// checked" without working out the figures, which costs a tenth of a second the opening page
    /// does not have. Anything that could alter the figures alters one of these counts.
    private var glance: String {
        "\(library.entries.count)|\(library.merchants.count)|\(library.tidy?.changes.count ?? 0)|\(library.dismissedInsights.count)|\(library.sources?.count ?? 0)"
    }

    /// The sentences shown last time, if the library looks untouched since they were checked against
    /// their figures. For the first draw only: `confirmRead` then checks properly.
    func glancedRead(_ key: String) -> String? {
        guard (UserDefaults.standard.dictionary(forKey: "readGlances") as? [String: String])?[key] == glance,
              let kept = library.reads?[key], let tab = kept.firstIndex(of: "\t") else { return nil }
        return String(kept[kept.index(after: tab)...])
    }

    /// Checks the kept sentences against today's figures, writes new ones if they no longer match,
    /// and remembers the library's fingerprint so the next opening can show them at once.
    func confirmRead(_ key: String, basis: String, facts: [String]) async {
        var glances = (UserDefaults.standard.dictionary(forKey: "readGlances") as? [String: String]) ?? [:]
        if keptRead(key, basis: basis) == nil {
            // What was shown at a glance is out of date: take it down before asking for better.
            glances[key] = nil
            UserDefaults.standard.set(glances, forKey: "readGlances")
            readsChecked += 1
            guard await read(key, basis: basis, facts: facts) != nil else { return }
        }
        glances[key] = glance
        UserDefaults.standard.set(glances, forKey: "readGlances")
        readsChecked += 1
    }

    func keptRead(_ key: String, basis: String) -> String? {
        guard let kept = library.reads?[key], kept.hasPrefix(basis + "\t") else { return nil }
        return String(kept.dropFirst(basis.count + 1))
    }

    /// The sentences for these figures, writing them if need be. Nil with no key or no connection.
    func read(_ key: String, basis: String, facts: [String]) async -> String? {
        if let kept = keptRead(key, basis: basis) { return kept }
        guard CloudAI.isEnabled, !facts.isEmpty else { return nil }
        let system = """
        You are the voice of Spendthrift, a personal money app. You are given figures the app worked out about \
        one person's money over a stretch of time. Write two or three sentences: the read a sharp, kind friend \
        would give after looking at them. Lead with what matters most to someone asking "am I living within my \
        means, and what changed?". Say what explains it when the figures say so.
        Use ONLY the figures given. Copy every dollar amount and percentage exactly as written; never add, \
        subtract, round or estimate. Speak to the person as "you". Plain words, dry and warm. No advice the \
        figures do not support, no lists, no headings, no exclamation marks, no opening such as "Over the last".
        """
        let given = facts.joined(separator: "\n")
        guard let text = await CloudWriter.line(system: system, facts: given, maxTokens: 3_000, temperature: 0.4), !text.isEmpty else { return nil }
        // Every dollar amount in what was written must be one the app supplied.
        let allowed = Set(ChatAnalyst.dollarAmounts(in: given))
        guard ChatAnalyst.dollarAmounts(in: text).allSatisfy(allowed.contains) else { return nil }
        var reads = library.reads ?? [:], times = library.readTimes ?? [:]
        reads[key] = basis + "\t" + text
        times[key] = .now
        if reads.count > 120 {
            // The oldest go (one never timed is the oldest of all), the newest ninety stay.
            let newest = reads.keys.sorted { (times[$0] ?? .distantPast, $0) > (times[$1] ?? .distantPast, $1) }.prefix(90)
            reads = reads.filter { newest.contains($0.key) }
            times = times.filter { newest.contains($0.key) }
        }
        library.reads = reads
        library.readTimes = times
        // Nothing the pages work out from the charges has changed: write it down, and do not rebuild everything.
        savedOnly()
        return text
    }
}
