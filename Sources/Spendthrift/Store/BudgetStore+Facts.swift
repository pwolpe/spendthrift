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
    /// The Trim card's lines, worked out once per stretch, ranking and switch until the library changes.
    func trimmed(_ transactions: [Transaction], stretch: String, month: Month?, byPayee: Bool, chosenOnly: Bool) -> TrimEngine.Ranked {
        let key = "trim|\(stretch)|\(month?.key ?? "-")|\(transactions.count)|\(transactions.last?.id.uuidString ?? "-")|\(byPayee)|\(chosenOnly)"
        return cached(key) { TrimEngine.ranked(transactions, byPayee: byPayee, chosenOnly: chosenOnly, optional: isOptional) }
    }

    func isOptional(payee keys: Set<String>, category: Category) -> Bool {
        let judged = keys.compactMap { library.merchants[$0]?.optional }
        return judged.isEmpty ? Self.usuallyOptional(category) : judged.reduce(0, +) / Double(judged.count) >= 0.5
    }

    /// The person's own word on whether a payee is a need or a choice. It is final: 0 or 1, never asked again.
    func setOptional(_ optional: Bool, payee keys: Set<String>) {
        for key in keys where library.merchants[key] != nil { library.merchants[key]?.optional = optional ? 1 : 0 }
        withAnimation(.snappy) { changed() }
    }

    /// What the model is told about a payee: names, like statement lines, can be typed by a person, so both are scrubbed.
    static func optionalState(name: String, sample: String, category: Category, typical: Double, count: Int) -> String {
        "Payee: \(Redactor.scrub(name)). Statement line: \(Redactor.scrub(sample)). Filed under: \(category.rawValue). "
            + "Typical amount $\(String(format: "%.2f", typical)). Appears \(count) time\(count == 1 ? "" : "s")."
    }

    /// Puts a model's answers on the payees that are still unanswered. The person may have said "a need"
    /// while the request was out: their word is never overwritten. Returns how many were filled in.
    @discardableResult
    func applyOptional(_ answers: [String: Double]) -> Int {
        var learned = 0
        for (key, p) in answers where library.merchants[key] != nil && library.merchants[key]?.optional == nil {
            library.merchants[key]?.optional = p
            learned += 1
        }
        return learned
    }

    /// Payee records that share a name are one payee: those not yet judged take the answer given for the
    /// others (the person's word above all). Returns whether anything changed.
    func inheritOptionalByName() -> Bool {
        let counts = Dictionary(grouping: library.entries, by: \.merchantKey).mapValues(\.count)
        var any = false
        for keys in Dictionary(grouping: library.merchants.keys, by: { library.merchants[$0]?.name ?? "" }).values where keys.count > 1 {
            let known = keys.compactMap { key in library.merchants[key]?.optional.map { (key: key, value: $0, charges: counts[key] ?? 0) } }
            guard known.count < keys.count, let value = TrimEngine.inherited(known) else { continue }
            for key in keys where library.merchants[key]?.optional == nil { library.merchants[key]?.optional = value; any = true }
        }
        return any
    }

    static let optionalQuestion = Decisions.Question.yesNo(
        "Is money spent at this payee a lifestyle choice rather than a necessity?",
        yes: "Chosen for enjoyment or convenience and could be cut without hardship: restaurants, bars, takeaway, travel, hotels, entertainment, hobbies, gifts, clothes and things bought for pleasure, streaming and other subscriptions, wine and spirits, rides taken for comfort.",
        no: "Needed to keep a household running: housing, utilities, insurance, groceries, medical care, childcare, education, commuting, fuel, taxes, loan payments, basic phone and internet.")

    /// Asks about every payee not yet judged. One short question each, a dozen at a time; a library
    /// of a few thousand payees takes under a minute the first time and nothing after.
    func learnFactsIfNeeded() async {
        guard !isLearningFacts, !isImporting, !isSuggesting else { return }
        // A payee record made since the person (or the model) answered for its name takes that answer, before anything is asked.
        if inheritOptionalByName() { changed() }
        guard CloudAI.isEnabled else { return }
        var seen: [String: (count: Int, total: Double)] = [:]
        for t in transactions where t.countsAsSpending && !t.isUnknown {
            let old = seen[t.merchantKey] ?? (0, 0)
            seen[t.merchantKey] = (old.count + 1, old.total + abs(t.amount))
        }
        var states: [String: String] = [:]
        for (key, sums) in seen {
            guard let info = library.merchants[key], info.optional == nil, let category = info.category else { continue }
            states[key] = Self.optionalState(name: info.name, sample: info.sample, category: category, typical: sums.total / Double(sums.count), count: sums.count)
        }
        guard !states.isEmpty else { return }
        isLearningFacts = true
        defer { isLearningFacts = false }
        let answers = await Decisions.askAll(job: "Needs and wants", model: Self.factsModel, states: states, questions: ["optional": Self.optionalQuestion])
        let learned = applyOptional(answers.compactMapValues { $0["optional"]?.yes })
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
        /// How much of this line was a choice rather than a necessity (the sum of its chosen charges).
        let chosen: Double
        let chargeIDs: [UUID]
        /// The share of this line that was chosen (0 to 1).
        var optionalShare: Double { min(1, max(0, chosen / total)) }
        /// Most of the line was chosen.
        var isMostlyChosen: Bool { chosen > 0 && chosen * 2 >= total }
    }

    /// What was chosen in a stretch: the one figure that "$X of $Y was chosen" and the Spending card both show.
    static func chosenTotal(_ transactions: [Transaction], optional: (Transaction) -> Bool) -> Double {
        max(0, transactions.filter { $0.countsAsSpending && optional($0) }.reduce(0) { $0 + $1.amount })
    }

    /// The answer a payee record without one takes from records of the same name: the person's (exactly
    /// 0 or 1) over a model's, then the record with most charges, then the smallest key.
    static func inherited(_ known: [(key: String, value: Double, charges: Int)]) -> Double? {
        known.sorted { l, r in
            let lp = l.value == 0 || l.value == 1, rp = r.value == 0 || r.value == 1
            if lp != rp { return lp }
            return l.charges != r.charges ? l.charges > r.charges : l.key < r.key
        }.first?.value
    }

    /// What the Trim card shows for a stretch, ranking and switch.
    struct Ranked {
        let lines: [Line]
        /// The stretch's own total, refunds and all, so it is the same figure the page gives above.
        let total: Double
        /// The sum of what was chosen: the figure the Spending card gives for the same stretch.
        let chosen: Double
    }

    static func ranked(_ transactions: [Transaction], byPayee: Bool, chosenOnly: Bool, optional: (Transaction) -> Bool) -> Ranked {
        let all = lines(transactions, byPayee: byPayee, optional: optional)
        let shown = chosenOnly ? all.filter(\.isMostlyChosen).sorted { ($0.chosen, $1.name) > ($1.chosen, $0.name) } : all
        return Ranked(lines: shown, total: transactions.filter(\.countsAsSpending).reduce(0) { $0 + $1.amount },
                      chosen: chosenTotal(transactions, optional: optional))
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
                                   chosen: g.wanted, chargeIDs: g.ids) : nil
        }.sorted { ($0.total, $1.name) > ($1.total, $0.name) }
    }
}
