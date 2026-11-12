import Foundation
import PDFKit
import AppKit
import Observation

// MARK: - Job 2: reading a statement the app couldn't

enum CloudStatementReader {
    struct Reading {
        var rows: [CanonicalRow]
        /// True when the rows add up to the section totals printed on the statement.
        var verified: Bool
    }

    private static let system = """
    You read bank and credit card statements. The text below was taken from a statement (possibly by OCR, so expect \
    small errors; personal details have been replaced with placeholders like [name] and [number]).

    List every individual transaction. Do NOT include balances, summaries, totals, interest-rate tables, rewards, \
    or the captions under pictures of paid checks. A section about points or rewards ("Shop with Points Activity", \
    "Points redeemed") lists purchases that were paid with points, not charged to the account: leave every line of \
    such a section out. Checks listed under a heading like "Checks Paid" are transactions: include each one.

    For each transaction give:
    - date: YYYY-MM-DD. Statements often print only month/day; use the statement period to work out the year.
    - description: the merchant or payee text as printed, on one line, without the date or amount.
    - amount: a positive number.
    - direction: "out" for purchases, fees, withdrawals, checks and payments made from a bank account; "in" for \
    deposits, refunds, credits, and payments received on a credit card.
    - section: the heading the transaction appears under, if any.

    Also list each section total the statement prints (for example "Total Deposits & Credits 1,234.56") as \
    {"section": "...", "amount": 1234.56}.

    Reply with JSON only: {"transactions": [{"date": "", "description": "", "amount": 0, "direction": "out", "section": ""}], \
    "totals": [{"section": "", "amount": 0}]}
    """

    /// The model asked for a second, independent reading when the first can't be checked against printed
    /// totals. Chosen because it errs differently from the main model, so the two agreeing means something.
    static let secondReader = Models.secondReader

    /// Lines one reading has and the other doesn't, matching on amount and allowing a few days
    /// between dates (one reading may give the purchase date, the other the posting date).
    static func differences(_ a: [CanonicalRow], _ b: [CanonicalRow]) -> [String] {
        func day(_ row: CanonicalRow) -> Int { OrderMatcher.dayNumber(row.date) }
        var rest = b, only: [(CanonicalRow, String)] = []
        for row in a {
            let near = rest.indices.filter { abs(rest[$0].amount - row.amount) < 0.005 && abs(day(rest[$0]) - day(row)) <= 5 }
            if let hit = near.min(by: { abs(day(rest[$0]) - day(row)) < abs(day(rest[$1]) - day(row)) }) { rest.remove(at: hit) }
            else { only.append((row, "only in the first reading")) }
        }
        only += rest.map { ($0, "only in the second reading") }
        return only.sorted { $0.0.date < $1.0.date }.map { row, which in
            "\(row.date) \(row.description.prefix(40)) \(Money.format(abs(row.amount)))\(row.amount < 0 ? " in" : "") (\(which))"
        }
    }

    static func read(text: String, closing: Date, job: String = "Reading statements") async -> Reading? {
        // Send it in pieces of a few pages; statements run to tens of pages, much of it legal text.
        var chunks: [String] = [], current = ""
        for line in Redactor.blank(text).components(separatedBy: .newlines) {
            if current.count + line.count > 24_000, !current.isEmpty { chunks.append(current); current = "" }
            current += line.prefix(2_000) + "\n"
        }
        if current.filter(\.isNumber).count >= 12 { chunks.append(current) }
        guard !chunks.isEmpty, chunks.count <= 12 else { return nil }

        let period = "Statement closing date: \(DateParsing.iso.string(from: closing)).\n\n"
        var rows: [CanonicalRow] = []
        var sums: [String: Double] = [:], totals: [String: Double] = [:]
        for chunk in chunks {
            let reply = await Timeout.run(180) {
                try? await CloudAI.complete(job: job, system: system, user: period + chunk, json: true, maxTokens: 40_000, timeout: 170)
            }
            guard let reply, let object = CloudAI.object(from: reply) else { return nil }
            for t in (object["transactions"] as? [[String: Any]]) ?? [] {
                guard let dateText = t["date"] as? String, DateParsing.parse(dateText, format: "yyyy-MM-dd") != nil,
                      let amount = (t["amount"] as? Double) ?? (t["amount"] as? String).flatMap(MoneyParsing.parse), amount != 0,
                      let description = (t["description"] as? String)?.split(whereSeparator: \.isWhitespace).joined(separator: " "),
                      description.filter(\.isLetter).count >= 2 else { continue }
                let out = ((t["direction"] as? String) ?? "out").lowercased() != "in"
                rows.append(CanonicalRow(date: String(dateText.prefix(10)), description: description,
                                         amount: ((out ? abs(amount) : -abs(amount)) * 100).rounded() / 100))
                if let section = (t["section"] as? String)?.lowercased(), !section.isEmpty { sums[section, default: 0] += abs(amount) }
            }
            for total in (object["totals"] as? [[String: Any]]) ?? [] {
                guard let section = (total["section"] as? String)?.lowercased(),
                      let amount = (total["amount"] as? Double) ?? (total["amount"] as? String).flatMap(MoneyParsing.parse) else { continue }
                totals[section.replacingOccurrences(of: "total ", with: "")] = abs(amount)
            }
        }
        guard !rows.isEmpty else { return nil }
        // Verified = at least one printed total matched and none disagreed.
        var matched = 0, mismatched = 0
        for (section, printed) in totals {
            guard let sum = sums.first(where: { $0.key.contains(section) || section.contains($0.key) })?.value else { continue }
            if abs(sum - printed) < 0.005 { matched += 1 } else { mismatched += 1 }
        }
        return Reading(rows: PDFStatement.removeInternalAdjustments(rows), verified: matched > 0 && mismatched == 0)
    }
}
