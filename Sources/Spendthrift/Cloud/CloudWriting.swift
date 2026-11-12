import Foundation
import PDFKit
import AppKit
import Observation

// MARK: - Job 3: a spreadsheet whose columns the app couldn't work out

enum CloudColumnMapper {
    static func mapping(for table: CSVTable) async -> ColumnMapping? {
        let header = (0..<table.columnCount).map { "\($0): \(table.header?[safe: $0] ?? "(no header)")" }.joined(separator: " | ")
        let sample = table.rows.prefix(12).map { row in row.map { Redactor.scrub(String($0.prefix(60))) }.joined(separator: " | ") }.joined(separator: "\n")
        let system = """
        A bank export has these columns (numbered from 0) and sample rows. Work out which columns matter. Reply with JSON only:
        {"date": <column>, "date_format": "<a DateFormatter pattern such as MM/dd/yyyy or yyyy-MM-dd>", "description": <column>,
         "amount": <column or null>, "debit": <column or null>, "credit": <column or null>, "purchases_are_negative": <true or false>}
        Use "amount" when one column holds signed amounts, otherwise "debit" (money out) and "credit" (money in).
        purchases_are_negative: true if money spent appears as negative numbers in the amount column.
        """
        let reply = await Timeout.run(60) {
            try? await CloudAI.complete(job: "Reading spreadsheets", system: system, user: "Columns: \(header)\n\nRows:\n\(sample)", json: true, maxTokens: 300, timeout: 50)
        }
        guard let reply, let o = CloudAI.object(from: reply) else { return nil }
        func column(_ key: String) -> Int? {
            guard let i = o[key] as? Int, (0..<table.columnCount).contains(i) else { return nil }
            return i
        }
        guard let date = column("date"), let description = column("description"),
              let format = (o["date_format"] as? String) ?? DateParsing.guessFormat(for: table.values(date)) else { return nil }
        let amount = column("amount"), debit = column("debit"), credit = column("credit")
        guard amount != nil || (debit != nil && credit != nil) else { return nil }
        return ColumnMapping(dateColumn: date, dateFormat: format, descriptionColumn: description, amountColumn: amount,
                             debitColumn: amount == nil ? debit : nil, creditColumn: amount == nil ? credit : nil,
                             purchasesAreNegative: (o["purchases_are_negative"] as? Bool) ?? true)
    }
}

// MARK: - Job 4 and 5: questions and short lines of writing

enum CloudWriter {
    /// A short piece of text (the monthly recap, today's caption). Nil if the cloud isn't on or fails.
    static func line(system: String, facts: String, maxTokens: Int, temperature: Double) async -> String? {
        guard CloudAI.isEnabled else { return nil }
        return await Timeout.run(40) {
            try? await CloudAI.complete(job: "Captions and summaries", system: system, user: facts, json: false, maxTokens: maxTokens, temperature: temperature, timeout: 35)
        }?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Understands a question about spending. The numbers are still computed in code from the result.
    static func query(_ question: String, first: Month, last: Month) async -> SpendingQuery? {
        guard CloudAI.isEnabled else { return nil }
        let now = Month(date: .now)
        let system = """
        Turn a question about personal spending into a query. Reply with JSON only:
        {"metric": "...", "category": "...", "place": "...", "from": "YYYY-MM", "to": "YYYY-MM"}
        metric: total (how much), list (show or what did I buy), top_places, top_categories, count (how many times), \
        monthly_average, subscriptions (recurring charges).
        category: one of \(Category.pickable.map(\.rawValue).joined(separator: "; ")), or "any".
        place: the store or payee named in the question as the person wrote it, or "any". When a place is named, use "any" for category.
        Today is \(Date.now.formatted(.dateTime.year().month(.wide).day())). Data covers \(first.key) to \(last.key); \
        with no time mentioned use that whole range. "Last month" is \(now.adding(-1).key). "This year" is \(now.year)-01 to \(last.key).
        """
        let reply = await Timeout.run(30) {
            try? await CloudAI.complete(job: "Captions and summaries", system: system, user: question, json: true, maxTokens: 150, timeout: 25)
        }
        guard let reply, let o = CloudAI.object(from: reply),
              let metric = (o["metric"] as? String).flatMap({ SpendingQuery.Metric(rawValue: $0.lowercased()) }) else { return nil }
        let categoryName = (o["category"] as? String) ?? "any"
        let category = Category.pickable.first { $0.rawValue.caseInsensitiveCompare(categoryName) == .orderedSame }
        let placeText = ((o["place"] as? String) ?? "any").trimmingCharacters(in: .whitespaces)
        let place = placeText.isEmpty || placeText.lowercased() == "any" ? nil : placeText
        var from = (o["from"] as? String).flatMap(Month.init(key:)) ?? first
        var to = (o["to"] as? String).flatMap(Month.init(key:)) ?? last
        if from > to { swap(&from, &to) }
        from = max(from, first); to = min(to, last)
        if from > to { from = first; to = last }
        return SpendingQuery(metric: metric, category: place == nil ? category : nil, place: place, from: from, to: to)
    }
}
