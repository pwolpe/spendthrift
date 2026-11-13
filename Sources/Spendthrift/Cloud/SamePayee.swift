import Foundation

/// "Which of my other payees is this one?" An accountant is paid as "Dana Whitfield" by check and as
/// "DRW" by transfer: nothing in the two names says so, but the category, the amounts, the months
/// and the statement lines often do. The model reads the payee and the list of every other one and
/// picks the few most likely to be the same. It only suggests: the person chooses, and can choose
/// anything else.
enum SamePayeeGuesser {
    struct Payee: Sendable {
        let name: String
        let category: String
        /// How statements write it, most common first.
        let spellings: [String]
        let count: Int
        /// The middle amount of its charges.
        let typical: Double
        /// "2026-04": the month of its latest charge.
        let last: String

        fileprivate func line(spellings limit: Int) -> String {
            let written = spellings.prefix(limit).map { String(Redactor.scrub($0).prefix(60)) }.joined(separator: " / ")
            return "\(name) | \(category) | written: \(written) | \(count == 1 ? "1 charge" : "\(count) charges"), typically \(Money.format(typical)), latest \(last)"
        }
    }

    /// The most that are sent to choose among; `others` should come with the likeliest first.
    static let limit = 700

    /// The names among `others` most likely to be the same payee as `subject`, likeliest first. Empty
    /// when none stands out, or when there is no model to ask.
    static func guess(for subject: Payee, among others: [Payee]) async -> [String] {
        let others = Array(others.prefix(limit))
        guard CloudAI.isEnabled, !others.isEmpty else { return [] }
        let system = """
        A budgeting app gathers the lines of someone's bank and card statements under payees. Sometimes one real \
        payee ends up under two names: a person paid by check under their full name and by transfer under their \
        initials or their firm's name; a shop under its brand and under its parent company; a name and its \
        abbreviation, nickname, misspelling or payment-processor prefix.

        You are given one payee and a numbered list of the person's other payees. Pick the ones most likely to be \
        the very same person or business as the given payee, the likeliest first.

        Reason from everything: initials and abbreviations of the name (DRW could be Dana R. Whitfield), words shared \
        with the statement lines, the same category, similar amounts, and similar timing. Two different businesses \
        of the same kind are not the same payee: two restaurants, two branches in different cities, a service and \
        its separate add-on. Pick at most 5, fewer when fewer are plausible, and none when nothing is.

        Reply with JSON only: {"matches": [<number>, …]}
        """
        let user = "The payee:\n\(subject.line(spellings: 6))\n\nThe other payees:\n"
            + others.enumerated().map { "\($0.offset + 1). \($0.element.line(spellings: 2))" }.joined(separator: "\n")
        let reply = await Timeout.run(40) {
            try? await CloudAI.complete(job: "Likely the same payee", system: system, user: user, json: true, maxTokens: 4_000, timeout: 35, effort: "low")
        }
        guard let reply, let picks = CloudAI.object(from: reply)?["matches"] as? [Any] else { return [] }
        var names: [String] = []
        for pick in picks {
            guard let n = (pick as? Int) ?? (pick as? String).flatMap(Int.init), others.indices.contains(n - 1) else { continue }
            let name = others[n - 1].name
            if !names.contains(name) { names.append(name) }
        }
        return Array(names.prefix(5))
    }
}
