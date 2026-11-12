import Foundation
import PDFKit
import AppKit
import Observation

// MARK: - The analyst

/// Reads every charge of the last year and says what a sharp bookkeeper would point out. The model
/// chooses which charges make up each finding; the app adds them up, so no total is ever invented.
enum Discoverer {
    struct Finding: Sendable {
        let title: String
        let detail: String
        let kind: String
        let lines: [Int]
    }

    static func find(_ lines: [StoryFinder.Line], notes: [String]) async -> [Finding]? {
        guard lines.count >= 40 else { return [] }
        let system = """
        You are a sharp, kind personal bookkeeper who has just read a year of someone's charges. Tell them up to 8 \
        things they would want to know and probably don't. Look for:
        - subscription: something paid for twice, or two services that do the same job, or one that looks forgotten
        - increase: a repeating charge whose price went up
        - duplicate: the same amount charged twice by one place on or near the same day
        - fees: interest, late fees, bank or foreign-transaction fees
        - habit: a small frequent thing that adds up to a surprising amount (name the place)
        - mistake: a charge that looks wrong or unlike anything else they do
        - tax: charges that may matter at tax time (donations, medical, a home office)
        - other: anything else genuinely striking
        Be specific to this person; no generic advice, nothing obvious (that rent is large, that travel costs money), \
        and do not report trips. Read the person's notes first and respect them.

        For each: {"kind": "…", "title": "…", "detail": "…", "lines": [numbers]}
        title: under 9 words, names the place or thing, no dollar amounts.
        detail: one plain sentence saying why it's worth a look. No dollar amounts and no counts: the app adds those from the lines.
        lines: the number of every charge that makes up the finding. Only include what truly belongs.
        Order them most valuable first. Reply with JSON only: {"findings": [ … ]}
        """
        var user = lines.enumerated().map { i, l in "\(i + 1) | \(l.date) | \(l.text) | \(String(format: "%.2f", l.amount)) | \(l.category)" }
            .joined(separator: "\n")
        if !notes.isEmpty { user = "The person's notes:\n" + notes.joined(separator: "\n") + "\n\nCharges:\n" + user }
        let text = user
        let reply = await Timeout.run(200) {
            try? await CloudAI.complete(job: "What was noticed", system: system, user: text, json: true, maxTokens: 12_000, timeout: 190, effort: "medium")
        }
        guard let reply, let list = CloudAI.object(from: reply)?["findings"] as? [[String: Any]] else { return nil }
        return list.compactMap { item in
            guard let title = (item["title"] as? String)?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return nil }
            let numbers = ((item["lines"] as? [Any]) ?? []).compactMap { ($0 as? Int) ?? ($0 as? Double).map(Int.init) }.filter { $0 >= 1 && $0 <= lines.count }
            guard !numbers.isEmpty else { return nil }
            return Finding(title: title, detail: ((item["detail"] as? String) ?? "").trimmingCharacters(in: .whitespaces),
                           kind: (item["kind"] as? String) ?? "other", lines: numbers)
        }
    }
}

// MARK: - What's coming

/// An estimate of next month's everyday spending. The app supplies the history, the charges that
/// repeat, and anything the person has written ("that was a one-time wedding", "cancelled in
/// October"); the model weighs them. It is an estimate and is always labelled as one.
enum Forecaster {
    struct Estimate: Codable, Sendable {
        var amount: Double
        var low: Double
        var high: Double
        var because: String
        var basis: String
    }

    private static let cacheKey = "forecast"
    static var cached: Estimate? {
        (UserDefaults.standard.data(forKey: cacheKey)).flatMap { try? JSONDecoder().decode(Estimate.self, from: $0) }
    }
    static func forget() { UserDefaults.standard.removeObject(forKey: cacheKey) }

    static func estimate(month: String, history: [String], repeating: [String], notes: [String], basis: String) async -> Estimate? {
        if let cached, cached.basis == basis { return cached }
        let system = """
        You estimate a person's everyday spending for the coming month from their own history. You are given \
        monthly totals by category, the charges that repeat every month, and notes the person has written about \
        places and charges. Weigh them the way a thoughtful bookkeeper would:
        - Notes outrank arithmetic. If a note says something was one-time, cancelled, seasonal, reimbursed or about to \
        start, adjust for it and say so.
        - Leave out one-off spikes (a single trip, a large purchase) unless the notes or the calendar say another is coming.
        - Start from the typical recent month, not the average of everything.
        Reply with JSON only: {"amount": 0, "low": 0, "high": 0, "because": "…"} where amount is your best estimate in \
        dollars, low and high bound a likely range, and because is one plain sentence (under 30 words) saying what \
        drove it, mentioning a note if one mattered. No dollar signs inside the numbers.
        """
        var user = "Estimate everyday spending for \(month).\n\nMonthly history (most recent last):\n" + history.joined(separator: "\n")
        if !repeating.isEmpty { user += "\n\nCharges that repeat every month:\n" + repeating.joined(separator: "\n") }
        if !notes.isEmpty { user += "\n\nNotes the person wrote:\n" + notes.joined(separator: "\n") }
        let reply = await Timeout.run(40) {
            try? await CloudAI.complete(job: "Forecast", system: system, user: user, json: true, maxTokens: 3_000, timeout: 35)
        }
        func number(_ any: Any?) -> Double? { (any as? Double) ?? (any as? Int).map(Double.init) ?? (any as? String).flatMap(MoneyParsing.parse) }
        guard let reply, let o = CloudAI.object(from: reply), let amount = number(o["amount"]), amount > 0 else { return nil }
        let estimate = Estimate(amount: amount, low: number(o["low"]) ?? amount * 0.85, high: number(o["high"]) ?? amount * 1.15,
                                because: ((o["because"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines), basis: basis)
        if let data = try? JSONEncoder().encode(estimate) { UserDefaults.standard.set(data, forKey: cacheKey) }
        return estimate
    }
}
