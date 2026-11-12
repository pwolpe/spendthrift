import Foundation
import PDFKit
import AppKit
import Observation

// MARK: - A best guess at what each unconfirmed place was

/// For the places on Double-Check: reads the statement line, the amounts, the days and the account,
/// and says in a few words what each one most likely was. One request for all of them.
enum Huncher {
    struct Subject: Sendable {
        let key: String
        let name: String
        let line: String
        let category: String
        let account: String
        /// "2026-02-03 $3,800.00 out", newest first.
        let charges: [String]
        let count: Int
    }

    static func guess(_ subjects: [Subject], notes: [String]) async -> [String: (text: String, category: Category?)] {
        guard !subjects.isEmpty else { return [:] }
        let categories = Category.pickable.map(\.rawValue)
        let system = """
        A budgeting app has sorted someone's bank and card statements and is unsure about a few payees. For each \
        one, say what it most likely was, the way the person themselves would describe it to a friend, and choose \
        the category that guess belongs in.

        Reason from everything given: the wording of the statement line, the size of the amounts, how regular they \
        are, the days and months, which account, and whether money came in or went out. Round thousands by Zelle \
        every month suggest rent or a regular helper; a one-off wire abroad suggests a property, tuition or family; \
        small monthly deposits suggest interest, rewards or a refund; cash withdrawals before a trip suggest travel money.

        Reply with JSON only: {"guesses": {"<number>": {"guess": "<guess>", "category": "<category>"}}}
        guess: at most 12 words, plain and specific, no full stop, starting lower case, hedged only by being a \
        guess (do not write "probably"). Name a likely purpose, not just a restatement of the line. \
        Never invent a person's relationship as fact; "rent or a contractor, paid by Zelle" is fine. \
        If there is truly nothing to go on, use "".
        category: exactly one of these, the best fit for your guess (when the guess names two possibilities, \
        the category of the first): \(categories.joined(separator: "; ")). \
        The category must agree with the guess: a guess of "a restaurant" is never filed under Shopping. \
        Money coming in is income, a refund of spending, or a transfer between the person's own accounts; \
        saving and investing are not spending. A payment to another person (Zelle, Venmo, a check) is spending, \
        never a transfer: file it under what it was most likely for, or under Other when that is unclear. \
        Keep the category it is already sorted as when your guess gives \
        no reason to change it.
        """
        var lines: [String] = []
        for (i, s) in subjects.enumerated() {
            lines.append("\(i + 1). \(s.name) | statement line: \(Redactor.scrub(s.line)) | sorted as: \(s.category) | account: \(Redactor.accountLabel(s.account)) | \(s.count) in all | \(s.charges.joined(separator: "; "))")
        }
        let context = notes.isEmpty ? "" : "\n\nNotes the person has written about other things (context only):\n" + notes.joined(separator: "\n")
        let reply = await Timeout.run(90) {
            try? await CloudAI.complete(job: "Best guesses", system: system, user: lines.joined(separator: "\n") + context, json: true, maxTokens: 8_000, temperature: 0.2, timeout: 85)
        }
        guard let reply, let guesses = CloudAI.object(from: reply)?["guesses"] as? [String: Any] else { return [:] }
        var out: [String: (text: String, category: Category?)] = [:]
        for (i, s) in subjects.enumerated() {
            guard let one = guesses[String(i + 1)] as? [String: Any], let text = one["guess"] as? String else { continue }
            let named = ((one["category"] as? String) ?? "").trimmingCharacters(in: .whitespaces)
            let category = Category.pickable.first { $0.rawValue.caseInsensitiveCompare(named) == .orderedSame || $0.displayName.caseInsensitiveCompare(named) == .orderedSame }
            out[s.key] = (String(text.trimmingCharacters(in: CharacterSet(charactersIn: " .\"\n")).prefix(110)), category)
        }
        return out
    }
}

// MARK: - "It was my accountant"

/// The person says in their own words what a payee was. The model turns that into a tidy name and
/// a category, making a new category when their words name something the list doesn't have.
enum Explainer {
    struct Verdict: Sendable {
        let name: String
        let category: String
        let isNew: Bool
        let symbol: String?
    }

    static func decide(statementText: String, currentName: String, amount: Double, said: String) async -> Verdict? {
        let existing = Category.pickable.map(\.rawValue)
        let system = """
        A person is telling a budgeting app what one payee on their statement really was. From their words, decide:

        category: the category it belongs in. Use one from this list exactly when it truly fits:
        \(existing.joined(separator: "; "))
        If their words name a kind of spending the list has no real home for (tax preparation, childcare, a pet, \
        tuition, a hobby, a housekeeper), make a new category instead: 1 to 3 plain words in title case, the kind of \
        heading a person would choose ("Tax Preparation", "Childcare"). Do not put something in "Other" or "Fees & \
        Interest" just because nothing fits. Money moved into savings or investments is "Investing & Capital Calls"; \
        money moved between their own accounts is "Payments & Transfers". "Income Taxes" is only for payments to \
        the government, not for an accountant's fee.
        new_category: true only if you made a new one.
        symbol: for a new category, the best fit from this list: \(CustomCategory.symbols.joined(separator: ", ")). Otherwise null.
        name: a tidy name for the payee that includes what the person told you, under 40 characters \
        ("Dana Whitfield, Tax Preparer"; "Maria, Housekeeper").

        Reply with JSON only: {"name": "…", "category": "…", "new_category": false, "symbol": null}
        """
        let user = "Statement text: \(Redactor.scrub(statementText))\nCurrently called: \(currentName)\nTypical amount: \(Money.format(abs(amount)))\nThe person says: \(said)"
        let reply = await Timeout.run(30) {
            try? await CloudAI.complete(job: "Explaining a charge", system: system, user: user, json: true, maxTokens: 2_000, timeout: 25)
        }
        guard let reply, let o = CloudAI.object(from: reply), let category = (o["category"] as? String)?.trimmingCharacters(in: .whitespaces),
              !category.isEmpty else { return nil }
        let name = ((o["name"] as? String) ?? currentName).trimmingCharacters(in: .whitespaces)
        let isNew = !existing.contains(category)
        return Verdict(name: name.isEmpty ? currentName : String(name.prefix(48)), category: category, isNew: isNew, symbol: o["symbol"] as? String)
    }
}

// MARK: - Looking places up

/// A line like "69 LEONARD STREET 0000 MANHATTAN NY" means nothing to the model from memory, but a
/// web search finds it in seconds (a sushi restaurant). The places still guessed at after sorting
/// are searched for, the biggest first. This sends the statement's text for those places to a
/// search service: the trade of a little privacy for an app that knows nearly every place.
enum WebLookup {
    static var isOn: Bool {
        get { UserDefaults.standard.object(forKey: "looksUpPlaces") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "looksUpPlaces") }
    }
    /// Payments to people, cash and transfers: nothing to find, and not ours to go searching for.
    static func isSearchable(_ text: String) -> Bool {
        text.range(of: #"(?i)\b(zelle|venmo|paypal|cash app|check|atm|withdraw|deposit|transfer|wire|payment to|autopay)\b"#, options: .regularExpression) == nil
    }

    static func identify(_ items: [CloudItem]) async -> [String: CloudVerdict] {
        guard !items.isEmpty else { return [:] }
        let system = """
        Each item is a line from a bank or card statement that could not be identified. Search the web for the \
        business behind each one; the text usually holds its name, or a street address, and a city. Then file it.

        Reply with JSON only: {"results": [{"id": 1, "found": true, "name": "…", "category": "…", "website": null}]}
        found: true only if the search clearly identified the business. Otherwise false, and leave the rest as your best guess.
        name: how a person would say it, under 40 characters ("69 Leonard Street", "Shell").
        category: exactly one of: \(Category.pickable.map(\.rawValue).joined(separator: "; "))
        website: the business's own domain, lower case, or null.
        """
        let payload: [[String: Any]] = items.enumerated().map { i, item in
            ["id": i + 1, "text": Redactor.scrub(item.description), "typical_amount": (abs(item.averageAmount) * 100).rounded() / 100,
             "app_guess": item.appGuess ?? ""]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let user = String(data: data, encoding: .utf8) else { return [:] }
        let reply = await Timeout.run(120) {
            try? await CloudAI.complete(job: "Looking payees up on the web", system: system, user: user, json: true, maxTokens: 4_000, timeout: 110, web: true)
        }
        guard let reply, let results = CloudAI.object(from: reply)?["results"] as? [[String: Any]] else { return [:] }
        var out: [String: CloudVerdict] = [:]
        for result in results {
            guard let id = result["id"] as? Int, id >= 1, id <= items.count, (result["found"] as? Bool) == true,
                  let name = (result["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                  let category = Category.pickable.first(where: { $0.rawValue == (result["category"] as? String) }) else { continue }
            out[items[id - 1].key] = CloudVerdict(name: String(name.prefix(48)), category: category, confident: true,
                                                  domain: (result["website"] as? String)?.lowercased())
        }
        return out
    }
}
