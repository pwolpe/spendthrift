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
        return ("\(Int(data.totalIncome))|\(Int(data.spending))|\(Int(data.taxes))|\(Int(data.optionalSpending))|\(ideas.count)", facts)
    }

    /// The sentences on file for these figures, if any. Never waits.
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
        var reads = library.reads ?? [:]
        reads[key] = basis + "\t" + text
        if reads.count > 120 { reads = Dictionary(uniqueKeysWithValues: Array(reads).suffix(90)) }
        library.reads = reads
        changed()
        return text
    }
}

/// The sentences, shown when there are some. Takes no room and shows nothing while there are none.
struct ShortVersion: View {
    @Environment(BudgetStore.self) private var store
    let key: String
    /// Changes whenever the figures do.
    let basis: String
    let facts: [String]
    @State private var text: String?

    var body: some View {
        Group {
            if let text = text ?? store.keptRead(key, basis: basis) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "sparkles").foregroundStyle(Theme.accent).padding(.top, 3)
                    Text(text).font(.system(size: 16, design: .serif)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.sheet, in: .rect(cornerRadius: 14, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline) }
                .transition(.opacity)
            }
        }
        .task(id: key + basis) {
            text = nil
            guard store.keptRead(key, basis: basis) == nil else { return }
            // Not while the page is still arriving: this is a nicety, and it costs a request.
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            let written = await store.read(key, basis: basis, facts: facts)
            withAnimation(.easeOut(duration: 0.3)) { text = written }
        }
    }
}
