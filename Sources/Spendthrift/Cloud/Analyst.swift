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
