import Foundation

/// Tidying payees without being asked.
///
/// Statements write the same business a dozen ways, and different businesses the same way. Two
/// kinds of mess follow: one payee that is really two ("Westside Market" holding a tavern's charges),
/// and two payees that are really one ("Buon Italia" and "Buon'Italia"). This file finds the pairs
/// worth asking about, in code; a decision model then says how likely each pair is the same business,
/// and the store acts only on the answers it is sure of. Everything it does is recorded and can be undone.
enum TidyEngine {
    /// One way a payee is written on statements, with how much was seen written that way.
    struct Spelling: Hashable {
        let payee: String
        let text: String
        let count: Int
        let typical: Double
        let category: Category
        /// True when the person named or filed this payee by hand: their word is final.
        let byHand: Bool
        let sample: String
    }

    struct Pair: Hashable {
        enum Kind: String, Codable { case combine, separate }
        let kind: Kind
        /// For `combine`: two payees. For `separate`: the payee's main spelling, then the odd one out.
        let a: Spelling
        let b: Spelling
        /// The same for a given pair however often it is found, so each is only ever asked about once.
        var id: String { "\(kind.rawValue)|\([a.text, b.text].sorted().joined(separator: "|"))" }
    }

    /// The word a statement line leads with once processors, punctuation and store numbers are gone:
    /// "TST* WESTSIDE TAVERN 0042" leads with WESTSIDE.
    static func leadingWord(_ line: String) -> String? {
        words(line).first { $0.count >= 4 }
    }

    static func words(_ line: String) -> [String] {
        KeywordExtractor.keyword(for: line, maxTokens: 6).uppercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map { $0.replacingOccurrences(of: "'", with: "") }
            .filter { !$0.isEmpty && !$0.allSatisfy(\.isNumber) }
    }

    /// Every spelling of every payee that counts as spending, by payee.
    static func spellings(of transactions: [Transaction], byHand: Set<String>) -> [String: [Spelling]] {
        var seen: [String: [String: (count: Int, total: Double, category: Category, sample: String)]] = [:]
        for t in transactions where t.category.isSpending && !t.isUnknown && !isPerson(t.description) {
            let text = MerchantResolver.spelling(t.description).uppercased()
            var entry = seen[t.merchant]?[text] ?? (0, 0, t.category, t.description)
            entry.count += 1
            entry.total += abs(t.amount)
            seen[t.merchant, default: [:]][text] = entry
        }
        return seen.reduce(into: [:]) { out, payee in
            out[payee.key] = payee.value.map { text, e in
                Spelling(payee: payee.key, text: text, count: e.count, typical: e.total / Double(e.count), category: e.category,
                         byHand: byHand.contains(payee.key), sample: e.sample)
            }.sorted { ($0.count, $1.text) > ($1.count, $0.text) }
        }
    }

    /// Payments to people, wires and checks are who the person says they are; nothing here can know better.
    static func isPerson(_ line: String) -> Bool {
        let upper = line.uppercased()
        return ["ZELLE", "VENMO", "WIRE", "CHECK", "CK#", "PAYPAL *", "CASH APP", "ACH "].contains { upper.contains($0) }
    }

    /// The pairs worth a question. Cheap rules only say "these might be related"; they never decide.
    static func pairs(in spellings: [String: [Spelling]], alreadyJudged: Set<String>, limit: Int = 400) -> [Pair] {
        var out: [Pair] = []
        // One payee, written in ways that lead with the same word but go on differently: perhaps two businesses.
        // Or written with a different leading word altogether: perhaps gathered by mistake.
        for (_, list) in spellings where list.count > 1 {
            guard let main = list.first, !main.byHand else { continue }
            let mainWords = Set(words(main.text))
            for other in list.dropFirst().prefix(6) {
                let otherWords = Set(words(other.text))
                let shared = mainWords.intersection(otherWords).count
                let overlap = Double(shared) / Double(max(1, min(mainWords.count, otherWords.count)))
                // Mostly the same words is just a store number or a city apart: not worth asking.
                if overlap < 0.67 { out.append(Pair(kind: .separate, a: main, b: other)) }
            }
        }
        // Two payees whose statements lead with the same word: perhaps one business under two names.
        var byLead: [String: [Spelling]] = [:]
        for (_, list) in spellings {
            guard let main = list.first, let lead = leadingWord(main.text) else { continue }
            byLead[lead, default: []].append(main)
        }
        for (_, group) in byLead where (2...8).contains(group.count) {
            let sorted = group.sorted { ($0.count, $1.payee) > ($1.count, $0.payee) }
            for i in sorted.indices { for j in sorted.indices where j > i {
                // Two names both given by hand are two things, as far as the person is concerned.
                if sorted[i].byHand && sorted[j].byHand { continue }
                out.append(Pair(kind: .combine, a: sorted[i], b: sorted[j]))
            } }
        }
        return Array(out.filter { !alreadyJudged.contains($0.id) }.sorted { ($0.a.count + $0.b.count, $1.id) > ($1.a.count + $1.b.count, $0.id) }.prefix(limit))
    }

    /// What the model is shown about a pair: only the statement wording and how often each was seen.
    static func state(for pair: Pair) -> String {
        func seen(_ s: Spelling) -> String { "\(s.count) charge\(s.count == 1 ? "" : "s"), typically $\(String(format: "%.2f", s.typical))" }
        let object: [String: String] = ["line_a": Redactor.scrub(pair.a.text), "line_a_seen": seen(pair.a),
                                        "line_b": Redactor.scrub(pair.b.text), "line_b_seen": seen(pair.b)]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    static let sameBusiness = Decisions.Question.yesNo(
        "These are two lines from bank or card statements. Do they come from the same business (the same merchant, possibly written differently or at a different branch)?",
        yes: "The same merchant: the same brand or company, even if the wording, store number, city or payment processor differs.",
        no: "Different businesses that merely share a word, such as a market and a tavern with the same first name, or a streaming service and a hotel.")

    /// How sure the model has to be before the app acts by itself. Measured on a real library:
    /// above 0.9 "same" was right every time it could be checked; below 0.1 it had found a genuine mix-up.
    static let sureSame = 0.92
    static let sureDifferent = 0.08

    enum Verdict { case combine, separate, leave }

    static func verdict(for pair: Pair, probabilitySame p: Double) -> Verdict {
        switch pair.kind {
        case .combine: return p >= sureSame ? .combine : .leave
        case .separate: return p <= sureDifferent ? .separate : .leave
        }
    }
}

/// Something the app tidied by itself, kept so it can be shown and undone.
struct TidyChange: Codable, Identifiable, Hashable {
    var id = UUID()
    var kind: TidyEngine.Pair.Kind
    /// When it was done (yyyy-MM-dd).
    var day: String
    /// The payee that kept its name (combine) or lost some charges (separate).
    var from: String
    /// The payee that was folded in (combine) or created (separate).
    var other: String
    var charges: Int
    /// The pair this came from, so undoing it also means "never again".
    var pairID: String
    /// Combine: each payee key that was renamed, with what it was called and filed under before.
    var renamed: [String: Before]?
    /// Separate: the charges that moved, with the key each had before; and the spelling rule added.
    var moved: [String: String]?
    var spelling: String?
    /// False once the person has seen it in the list.
    var isNew: Bool? = true

    struct Before: Codable, Hashable {
        var name: String
        var category: String?
        var source: String
        var confirmed: Bool
        var domain: String?
    }

    var sentence: String {
        switch kind {
        case .combine: "Combined \(other) into \(from)"
        case .separate: "Separated \(other) from \(from)"
        }
    }
}

/// Everything remembered about tidying: what was asked (so nothing is asked twice) and what was done.
struct TidyBook: Codable, Hashable {
    /// Pair id to how likely the model said "the same business" was. Declined pairs are stored as -1.
    var judged: [String: Double] = [:]
    var changes: [TidyChange] = []
}
