import SwiftUI

/// Needs and wants. Some of what is spent keeps a household running (a mortgage, the electricity,
/// insurance); the rest is chosen (dinners out, trips, things bought for pleasure). Knowing which is
/// which is what makes "where could I trim?" answerable, and it is a judgement about each payee that
/// a category alone gets wrong: a grocery delivery is a need, a wine club filed beside it is not.
///
/// A decision model is asked once per payee and its answer kept. Until it has answered, and whenever
/// there is no key, the category's usual answer stands in, so every figure works offline.
extension BudgetStore {
    static let factsModel = "google/gemini-decision-1"

    /// What a category usually is, when nothing better is known about the payee.
    static func usuallyOptional(_ category: Category) -> Bool {
        [.dining, .travel, .entertainment, .shopping, .wine, .gifts, .personal, .subscriptions].contains(category)
    }

    /// Whether money spent in this charge was a choice.
    func isOptional(_ t: Transaction) -> Bool {
        guard t.countsAsSpending else { return false }
        // A category chosen for this one charge says more than anything known about the payee.
        if !t.isOverride, let judged = library.merchants[t.merchantKey]?.optional { return judged >= 0.5 }
        return Self.usuallyOptional(t.category)
    }

    /// Whether spending at a payee counts as chosen: what the person said, else what the model judged,
    /// else what its category usually is.
    func isOptional(payee keys: Set<String>, category: Category) -> Bool {
        let judged = keys.compactMap { library.merchants[$0]?.optional }
        return judged.isEmpty ? Self.usuallyOptional(category) : judged.reduce(0, +) / Double(judged.count) >= 0.5
    }

    /// The person's own word on whether a payee is a need or a choice. It is final: 0 or 1, never asked again.
    func setOptional(_ optional: Bool, payee keys: Set<String>) {
        for key in keys where library.merchants[key] != nil { library.merchants[key]?.optional = optional ? 1 : 0 }
        withAnimation(.snappy) { changed() }
    }

    static let optionalQuestion = Decisions.Question.yesNo(
        "Is money spent at this payee a lifestyle choice rather than a necessity?",
        yes: "Chosen for enjoyment or convenience and could be cut without hardship: restaurants, bars, takeaway, travel, hotels, entertainment, hobbies, gifts, clothes and things bought for pleasure, streaming and other subscriptions, wine and spirits, rides taken for comfort.",
        no: "Needed to keep a household running: housing, utilities, insurance, groceries, medical care, childcare, education, commuting, fuel, taxes, loan payments, basic phone and internet.")

    /// Asks about every payee not yet judged. One short question each, a dozen at a time; a library
    /// of a few thousand payees takes under a minute the first time and nothing after.
    func learnFactsIfNeeded() async {
        guard CloudAI.isEnabled, !isLearningFacts, !isImporting, !isSuggesting else { return }
        var seen: [String: (count: Int, total: Double)] = [:]
        for t in transactions where t.countsAsSpending && !t.isUnknown {
            let old = seen[t.merchantKey] ?? (0, 0)
            seen[t.merchantKey] = (old.count + 1, old.total + abs(t.amount))
        }
        var states: [String: String] = [:]
        for (key, sums) in seen {
            guard let info = library.merchants[key], info.optional == nil, let category = info.category else { continue }
            states[key] = "Payee: \(info.name). Statement line: \(Redactor.scrub(info.sample)). Filed under: \(category.rawValue). "
                + "Typical amount $\(String(format: "%.2f", sums.total / Double(sums.count))). Appears \(sums.count) time\(sums.count == 1 ? "" : "s")."
        }
        guard !states.isEmpty else { return }
        isLearningFacts = true
        defer { isLearningFacts = false }
        let answers = await Decisions.askAll(job: "Needs and wants", model: Self.factsModel, states: states, questions: ["optional": Self.optionalQuestion])
        var learned = 0
        for (key, answer) in answers {
            guard let p = answer["optional"]?.yes, library.merchants[key] != nil else { continue }
            library.merchants[key]?.optional = p
            learned += 1
        }
        if ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] != nil { print("FACTS asked about \(states.count) payees, learned \(learned)") }
        if learned > 0 { changed() }
    }
}

/// What was spent in a stretch, ranked, for finding where to trim.
enum TrimEngine {
    struct Line: Identifiable, Hashable {
        var id: String { name }
        let name: String
        let category: Category
        let total: Double
        let count: Int
        /// The share of this line that was a choice rather than a necessity (0 to 1).
        let optionalShare: Double
        let chargeIDs: [UUID]
    }

    /// Spending by payee or by category, largest first. Refunds come off where they belong; a line
    /// that nets to nothing or less is left out.
    static func lines(_ transactions: [Transaction], byPayee: Bool, optional: (Transaction) -> Bool) -> [Line] {
        var groups: [String: (category: Category, total: Double, wanted: Double, ids: [UUID])] = [:]
        for t in transactions where t.countsAsSpending {
            let key = byPayee ? t.merchant : t.category.displayName
            var g = groups[key] ?? (t.category, 0, 0, [])
            g.total += t.amount
            if optional(t) { g.wanted += t.amount }
            g.ids.append(t.id)
            groups[key] = g
        }
        return groups.compactMap { name, g in
            g.total > 0.005 ? Line(name: name, category: g.category, total: g.total, count: g.ids.count,
                                   optionalShare: min(1, max(0, g.wanted / g.total)), chargeIDs: g.ids) : nil
        }.sorted { ($0.total, $1.name) > ($1.total, $0.name) }
    }
}
