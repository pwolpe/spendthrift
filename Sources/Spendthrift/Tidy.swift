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

        func marked(byHand: Bool) -> Spelling {
            Spelling(payee: payee, text: text, count: count, typical: typical, category: category, byHand: byHand, sample: sample)
        }
    }

    struct Pair: Hashable {
        enum Kind: String, Codable { case combine, separate }
        let kind: Kind
        /// For `combine`: two payees. For `separate`: the payee's main spelling, then the odd one out.
        let a: Spelling
        let b: Spelling
        /// The same for a given pair of spellings however often it is found and whichever kind it is
        /// taken for, so each pair is only ever asked about once.
        var id: String { "pair|" + [a.text, b.text].sorted().joined(separator: "|") }
        /// What this pair was called before the kind was left out of it: saved answers under these still count.
        var legacyIDs: [String] {
            let rest = [a.text, b.text].sorted().joined(separator: "|")
            return ["combine|" + rest, "separate|" + rest]
        }
        /// Whether this pair, under either name, is among `judged`.
        func isJudged(in judged: Set<String>) -> Bool { judged.contains(id) || legacyIDs.contains(where: judged.contains) }
    }

    /// Which payee record to read a category and website from when several share one name: one the
    /// person set, then the one with most charges, then the smallest key, so every run picks the same.
    static func bestKey(among candidates: [(key: String, byPerson: Bool, charges: Int)]) -> String? {
        candidates.sorted { ($0.byPerson ? 1 : 0, $0.charges, $1.key) > ($1.byPerson ? 1 : 0, $1.charges, $0.key) }.first?.key
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
            // Only the first two words: what follows is a city, a store number, a processor.
            let mainWords = Set(words(main.text).prefix(2))
            for other in list.dropFirst().prefix(6) {
                let otherWords = Set(words(other.text).prefix(2))
                let shared = mainWords.intersection(otherWords).count
                // The same two words is just a branch or a store number apart: not worth asking.
                if shared < max(mainWords.count, otherWords.count) { out.append(Pair(kind: .separate, a: main, b: other)) }
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
        return Array(out.filter { !$0.isJudged(in: alreadyJudged) }.sorted { ($0.a.count + $0.b.count, $1.id) > ($1.a.count + $1.b.count, $0.id) }.prefix(limit))
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

    enum Verdict {
        /// Two payees are one: fold one into the other.
        case combine
        /// The first payee's name does not describe its own charges, which belong with the second: move them there.
        case rehome
        /// One payee is two: the odd spelling becomes a payee of its own.
        case separate
        /// Probably one business, but the names say otherwise (two hotels of one chain, a store and
        /// its subscription): worth offering, not worth doing unasked.
        case suggest
        case leave
    }

    /// What to do about a pair, given how likely the model says "the same business" is.
    /// `recurring` holds the payees that bill on a schedule: a subscription is never folded into
    /// its maker's one-off purchases, or the other way round, without asking.
    static func verdict(for pair: Pair, probabilitySame p: Double, recurring: Set<String> = []) -> Verdict {
        switch pair.kind {
        case .separate:
            // A payee the person named, renamed, filed or confirmed is not taken apart unasked.
            return p <= sureDifferent && !pair.a.byHand ? .separate : .leave
        case .combine:
            guard p >= sureSame else { return .leave }
            // Two payees the person made themselves are two things, as far as they are concerned.
            if pair.a.byHand && pair.b.byHand { return .leave }
            let aFits = nameFits(pair.a.payee, spelling: pair.a.text), bFits = nameFits(pair.b.payee, spelling: pair.b.text)
            // A payee named for something other than what its statements say was gathered wrongly:
            // its charges go to the payee that is named for them.
            if !aFits, bFits { return pair.a.byHand ? .suggest : .rehome }
            if !bFits || !aFits { return .suggest }
            if recurring.contains(pair.a.payee) != recurring.contains(pair.b.payee) { return .suggest }
            if namesAgree(pair.a.payee, pair.b.payee) { return .combine }
            // Two hotels or two branches of one chain are two places someone went: not worth even asking.
            return pair.a.category == .travel || pair.b.category == .travel ? .leave : .suggest
        }
    }

    private static let filler: Set<String> = ["THE", "AND", "OF", "INC", "LLC", "CO", "COMPANY", "CORP", "LTD", "NEW", "YORK", "NY"]

    /// A payee's name as bare words: no punctuation, no possessive, no filler.
    static func nameWords(_ name: String) -> [String] {
        name.uppercased().folding(options: .diacriticInsensitive, locale: nil)
            .replacingOccurrences(of: "'S ", with: "S ").replacingOccurrences(of: "'", with: "")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { !filler.contains($0) }
    }

    /// Whether two names are one name written two ways: the same words give or take a few
    /// ("Chopt" and "Chopt Creative Salad"), or the same letters give or take one or two
    /// ("Buon Italia" and "Buon'Italia"). "Aloft Orlando" and "Aloft Miami" are not.
    static func namesAgree(_ a: String, _ b: String) -> Bool {
        let wa = nameWords(a), wb = nameWords(b)
        guard !wa.isEmpty, !wb.isEmpty else { return false }
        let ja = wa.joined(), jb = wb.joined()
        if ja == jb || distance(ja, jb, limit: 2) <= 2 && min(ja.count, jb.count) >= 6 { return true }
        func stem(_ w: String) -> String { w.count > 4 && w.hasSuffix("S") ? String(w.dropLast()) : w }
        let sa = Set(wa.map(stem)), sb = Set(wb.map(stem))
        return sa.isSubset(of: sb) || sb.isSubset(of: sa)
    }

    /// Whether a payee's name describes a statement line: at least half its words appear there
    /// (statements cut words short, so the first four letters are enough).
    static func nameFits(_ name: String, spelling: String) -> Bool {
        let wanted = nameWords(name), line = words(spelling) + nameWords(spelling)
        guard !wanted.isEmpty else { return false }
        let joined = line.joined()
        let hits = wanted.filter { word in
            let head = String(word.prefix(4))
            return line.contains { $0.hasPrefix(head) || word.hasPrefix($0) && $0.count >= 4 } || joined.contains(word)
        }.count
        return hits * 2 >= wanted.count
    }

    /// How many single-letter edits turn one word into the other, giving up past `limit`.
    static func distance(_ a: String, _ b: String, limit: Int) -> Int {
        let x = Array(a), y = Array(b)
        if abs(x.count - y.count) > limit { return limit + 1 }
        var row = Array(0...y.count)
        for i in 1...max(x.count, 1) where !x.isEmpty {
            var previous = row[0]
            row[0] = i
            for j in 1...max(y.count, 1) where !y.isEmpty {
                let old = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (x[i - 1] == y[j - 1] ? 0 : 1))
                previous = old
            }
        }
        return row[y.count]
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
    /// Further pairs settled by the same change (several spellings moved to the one new payee).
    var morePairIDs: [String]?
    /// The key of the payee created or moved to, so it is shown under whatever it is called now.
    var otherKey: String?
    /// Combine: each payee key that was renamed, with what it was called and filed under before.
    var renamed: [String: Before]?
    /// Separate: the charges that moved, with the key each had before; and the spelling rule added.
    var moved: [String: String]?
    var spelling: String?
    /// False once the person has seen it in the list.
    var isNew: Bool? = true
    /// True once the person has said it is right. It then leaves the list; the pair stays settled.
    var kept: Bool?

    /// How long a change waits in the list to be looked at. After this it is taken as right:
    /// a list of things to undo should not be there forever.
    static let daysOnShow = 30
    /// Whether it still belongs in the list on this day (yyyy-MM-dd).
    func isOnShow(today: String) -> Bool {
        guard kept != true else { return false }
        guard let done = DateParsing.parse(day, format: "yyyy-MM-dd"), let now = DateParsing.parse(today, format: "yyyy-MM-dd") else { return true }
        return now.timeIntervalSince(done) < Double(Self.daysOnShow) * 86_400
    }

    struct Before: Codable, Hashable {
        var name: String
        var category: String?
        var source: String
        var confirmed: Bool
        var domain: String?
        /// A statement line it was known by, so the payee can be made again if it was cleared away meanwhile.
        var sample: String?
    }
}

/// Everything remembered about tidying: what was asked (so nothing is asked twice) and what was done.
struct TidyBook: Codable, Hashable {
    /// Pair id to how likely the model said "the same business" was. Declined pairs are stored as -1;
    /// a pair the model gave no answer to is -2 (asked once more next time), then -3 (not asked again).
    var judged: [String: Double] = [:]
    var changes: [TidyChange] = []
    /// The pairs that are not asked about again: everything answered or declined, and any pair the model
    /// has twice given no answer to (a first miss, -2, is asked once more).
    var settled: Set<String> { Set(judged.filter { $0.value != -2 }.keys) }
    /// Pairs that are probably one business but were not combined unasked.
    var suggestions: [TidySuggestion]?
}

/// "These might be the same": offered, with a button, where the app was not sure enough to act.
struct TidySuggestion: Codable, Identifiable, Hashable {
    var id: String { pairID }
    var pairID: String
    var a: String
    var b: String
}
