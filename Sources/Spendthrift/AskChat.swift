import SwiftUI

/// Ask, as a conversation (needs the cloud model).
///
/// Three steps, so the model never does arithmetic:
///   1. it reads the question (and the conversation so far) and says which figures it needs,
///   2. the app computes those figures from the saved transactions,
///   3. it writes a short answer using only those figures. Any dollar amount in the answer
///      that the app didn't compute gets the answer thrown out in favour of a plain one.
enum ChatAnalyst {
    struct Turn {
        let question: String
        let plan: String
        let answer: String
    }

    struct ChartBar: Hashable {
        let label: String
        let value: Double
        let category: Category?
    }

    // MARK: Step 1: what to compute

    private struct Query {
        var name = "result"
        var lane = "everyday"
        var categories: Set<Category> = []
        var place: String?
        var account: String?
        var trip: String?
        var from: Date?
        var to: Date?
        var minAmount: Double?
        var maxAmount: Double?
        var direction = "any"
        var groupBy = "none"
        var measure = "total"
        var top = 12

        init(_ o: [String: Any]) {
            name = (o["name"] as? String) ?? name
            groupBy = ((o["group_by"] as? String) ?? groupBy).lowercased()
            measure = ((o["measure"] as? String) ?? measure).lowercased()
            top = min(max((o["top"] as? Int) ?? top, 1), 40)
            let f = (o["filters"] as? [String: Any]) ?? [:]
            lane = ((f["lane"] as? String) ?? lane).lowercased()
            for name in (f["categories"] as? [String]) ?? [] {
                if let c = Category.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(name) == .orderedSame || $0.displayName.caseInsensitiveCompare(name) == .orderedSame }) {
                    categories.insert(c)
                }
            }
            func text(_ key: String) -> String? {
                guard let s = (f[key] as? String)?.trimmingCharacters(in: .whitespaces), !s.isEmpty, s.lowercased() != "any" else { return nil }
                return s
            }
            place = text("place"); account = text("account"); trip = text("trip")
            from = text("from").flatMap { DateParsing.parse(String($0.prefix(10)), format: "yyyy-MM-dd") ?? DateParsing.parse($0 + "-01", format: "yyyy-MM-dd") }
            to = text("to").flatMap { s -> Date? in
                if let d = DateParsing.parse(String(s.prefix(10)), format: "yyyy-MM-dd") { return d }
                // "2026-10" means through the end of October.
                return Month(key: s).map { $0.adding(1).firstDay.addingTimeInterval(-1) }
            }
            minAmount = f["min_amount"] as? Double ?? (f["min_amount"] as? Int).map(Double.init)
            maxAmount = f["max_amount"] as? Double ?? (f["max_amount"] as? Int).map(Double.init)
            direction = ((f["direction"] as? String) ?? direction).lowercased()
        }
    }

    @MainActor
    private static func planPrompt(store: BudgetStore) -> String {
        let first = store.months.first?.key ?? "", last = store.months.last?.key ?? ""
        let trips = store.stories.prefix(30).map { "\($0.name) (\($0.start) to \($0.end))" }.joined(separator: "; ")
        return """
        You help someone understand their own spending. You cannot see the transactions; instead you ask the app \
        to compute figures, and it will. Read the question (and the conversation so far, for follow-ups such as \
        "and last year?" or "what about dining?") and reply with the figures you need, as JSON only:

        {"queries": [{"name": "a short label", "filters": {"lane": "everyday", "categories": [], "place": "", "account": "", \
        "trip": "", "from": "YYYY-MM-DD", "to": "YYYY-MM-DD", "min_amount": null, "max_amount": null, "direction": "any"}, \
        "group_by": "none", "measure": "total", "top": 10}], "show": "the name of the query to display", "chart": "bar"}

        - lane: "everyday" (ordinary spending; the default), "income", "investments", "taxes", "transfers", or "all".
        - categories: any of \(Category.pickable.map(\.rawValue).joined(separator: "; ")). Leave empty for all.
        - place: part of a merchant's name ("whole foods", "uber"). account: part of an account's name.
        - trip: the name of one of the trips or events below, to look only at its charges.
        - from / to: dates (YYYY-MM-DD) or months (YYYY-MM). Omit for the whole history.
        - direction: "out", "in", or "any". min_amount / max_amount: per transaction.
        - group_by: "none", "category", "place", "month", "week", "day_of_week", "account", or "trip".
        - measure: "total", "count", "average" (per month over the range), or "list" (the individual transactions, largest first).
        - top: how many groups or transactions to return (1 to 40).
        - Ask for several queries when the question needs them. For "why was October so high?" ask for October by \
        category, the month before by category, and October's largest transactions. For a comparison ask for each side.
        - show: the single query whose rows are most useful to look at. chart: "bar", "line" (for months or weeks), or "none".

        Today is \(Date.now.formatted(.dateTime.year().month(.wide).day())). The data covers \(first) to \(last). \
        "This year" is \(Month(date: .now).year). Accounts: \(store.accounts.map(\.name).joined(separator: "; ")).
        Trips and events on record: \(trips.isEmpty ? "none" : trips).
        """
    }

    // MARK: Step 2: computing

    private struct Computed {
        let name: String
        let total: Double
        let count: Int
        let groups: [(label: String, value: Double, count: Int, category: Category?)]
        let transactions: [Transaction]
        let isMoney: Bool
    }

    @MainActor
    private static func compute(_ q: Query, store: BudgetStore) -> Computed {
        let tripIDs: Set<UUID>? = q.trip.flatMap { name in
            store.stories.first { $0.name.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains($0.name) }
        }.map { Set($0.entryIDs) }
        let storyOf: [UUID: String] = q.groupBy == "trip"
            ? Dictionary(store.stories.flatMap { s in s.entryIDs.map { ($0, s.name) } }, uniquingKeysWith: { a, _ in a }) : [:]
        // Money coming in is stored as negative; show income and "in" questions as positive amounts.
        let flip = q.lane == "income" || q.direction == "in"
        let matches = store.transactions.filter { t in
            if !q.categories.isEmpty { guard q.categories.contains(t.category) else { return false } }
            else {
                switch q.lane {
                case "income": guard t.isIncome else { return false }
                case "investments": guard t.lane == .investments else { return false }
                case "taxes": guard t.lane == .taxes else { return false }
                case "transfers": guard t.lane == .transfers else { return false }
                case "all": break
                default: guard t.countsAsSpending else { return false }
                }
            }
            if let from = q.from, t.date < from { return false }
            if let to = q.to, t.date > to { return false }
            if let p = q.place, !(t.merchant.localizedCaseInsensitiveContains(p) || t.description.localizedCaseInsensitiveContains(p) || (t.note?.localizedCaseInsensitiveContains(p) ?? false)) { return false }
            if let a = q.account, !t.account.localizedCaseInsensitiveContains(a) { return false }
            if let ids = tripIDs, !ids.contains(t.id) { return false }
            if q.trip != nil, tripIDs == nil { return false }
            if q.direction == "out", t.amount <= 0 { return false }
            if q.direction == "in", t.amount >= 0 { return false }
            if let lo = q.minAmount, abs(t.amount) < lo { return false }
            if let hi = q.maxAmount, abs(t.amount) > hi { return false }
            return true
        }
        let value = { (t: Transaction) in flip ? -t.amount : t.amount }
        let total = matches.reduce(0) { $0 + value($1) }

        func key(_ t: Transaction) -> (sort: String, label: String)? {
            switch q.groupBy {
            case "category": return (t.category.rawValue, t.category.displayName)
            case "place": return (t.merchantKey, t.merchant)
            case "month": return (t.month.key, t.month.title)
            case "week":
                let start = Calendar.current.dateInterval(of: .weekOfYear, for: t.date)?.start ?? t.date
                return (DateParsing.iso.string(from: start), "Week of " + start.formatted(.dateTime.month(.abbreviated).day()))
            case "day_of_week":
                let d = Calendar.current.component(.weekday, from: t.date)
                return (String(d), Calendar.current.weekdaySymbols[d - 1])
            case "account": return (t.account, t.account)
            case "trip": return storyOf[t.id].map { ($0, $0) }
            default: return nil
            }
        }
        var groups: [(sort: String, label: String, value: Double, count: Int, category: Category?)] = []
        if q.groupBy != "none" {
            var index: [String: Int] = [:]
            for t in matches {
                guard let k = key(t) else { continue }
                if let i = index[k.sort] { groups[i].value += value(t); groups[i].count += 1 }
                else {
                    index[k.sort] = groups.count
                    groups.append((k.sort, k.label, value(t), 1, ["category", "place"].contains(q.groupBy) ? t.category : nil))
                }
            }
            let chronological = ["month", "week", "day_of_week"].contains(q.groupBy)
            groups.sort { chronological ? $0.sort < $1.sort : (q.measure == "count" ? $0.count > $1.count : $0.value > $1.value) }
            if !chronological { groups = Array(groups.prefix(q.top)) } else { groups = Array(groups.suffix(40)) }
        }
        let monthsInRange = max(1, Set(matches.map(\.month)).count)
        let isMoney = q.measure != "count"
        let shownTotal = q.measure == "average" ? total / Double(monthsInRange) : (q.measure == "count" ? Double(matches.count) : total)
        return Computed(name: q.name, total: shownTotal, count: matches.count,
                        groups: groups.map { ($0.label, q.measure == "count" ? Double($0.count) : $0.value, $0.count, $0.category) },
                        transactions: Array(matches.sorted { abs($0.amount) > abs($1.amount) }.prefix(q.measure == "list" || q.groupBy == "none" ? q.top : 0)),
                        isMoney: isMoney)
    }

    private static func describe(_ c: Computed, flip: Bool = false) -> [String: Any] {
        let money = { (v: Double) in Money.format(v) }
        var out: [String: Any] = ["name": c.name, "transactions_matched": c.count,
                                  c.isMoney ? "total" : "count": c.isMoney ? money(c.total) : String(Int(c.total))]
        if !c.groups.isEmpty {
            out["groups"] = c.groups.map { ["label": $0.label, "value": c.isMoney ? money($0.value) : String(Int($0.value)), "charges": $0.count] as [String: Any] }
        }
        if !c.transactions.isEmpty {
            out["largest_transactions"] = c.transactions.prefix(15).map {
                ["date": $0.date.formatted(.dateTime.month(.wide).day().year()), "place": $0.merchant, "amount": money(abs($0.amount)), "category": $0.category.displayName] as [String: Any]
            }
        }
        return out
    }

    // MARK: The whole exchange

    @MainActor
    static func answer(_ question: String, history: [Turn], store: BudgetStore) async -> (Answer, Turn)? {
        guard CloudAI.isEnabled, let first = store.months.first, let last = store.months.last else { return nil }
        var conversation = ""
        for turn in history.suffix(4) {
            conversation += "Earlier question: \(turn.question)\nFigures you asked for: \(turn.plan)\nYour answer: \(turn.answer)\n\n"
        }
        let system = planPrompt(store: store)
        let ask = conversation + "Question: \(question)"
        let planReply = await Timeout.run(45) {
            try? await CloudAI.complete(job: "Answering questions", system: system, user: ask, json: true, maxTokens: 6_000, timeout: 40)
        }
        guard let planReply, let plan = CloudAI.object(from: planReply),
              let wanted = plan["queries"] as? [[String: Any]], !wanted.isEmpty else { return nil }
        let queries = wanted.prefix(6).map(Query.init)
        let results = queries.map { compute($0, store: store) }
        let shownName = plan["show"] as? String
        let shown = results.first { $0.name == shownName } ?? results.first { !$0.groups.isEmpty } ?? results[0]

        // Step 3: the write-up, from these figures only.
        let facts = results.map { describe($0) }
        let factsText = (try? JSONSerialization.data(withJSONObject: ["figures": facts], options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        // What the person has written about places and charges: context for the wording, never a source of amounts.
        let notes = store.allNotes(limit: 25)
        let notesText = notes.isEmpty ? "" : "\n\nNotes the person wrote (context only; take no dollar amounts from them):\n" + notes.joined(separator: "\n")
        let writer = """
        You are the voice of Spendthrift, a friendly personal spending app. Answer the question in one to three \
        plain sentences, like a sharp friend who has looked at the numbers. Lead with the answer.
        Use ONLY the figures provided. Copy every dollar amount exactly as written, cents included; never round, add, \
        subtract or work out a percentage yourself. To compare two things, state both amounts. If the figures show \
        nothing matched, say so simply and suggest what to try. No lists, no headings, no emoji.
        """
        let written = await Timeout.run(45) {
            try? await CloudAI.complete(job: "Answering questions", system: writer, user: "\(conversation)Question: \(question)\n\nFigures computed by the app:\n\(factsText)\(notesText)",
                                        json: false, maxTokens: 4_000, temperature: 0.3, timeout: 40)
        }?.trimmingCharacters(in: .whitespacesAndNewlines)

        // Every dollar amount in the answer must be one the app computed.
        let allowed = Set(dollarAmounts(in: factsText))
        var headline = written ?? ""
        if headline.isEmpty || !dollarAmounts(in: headline).allSatisfy(allowed.contains) {
            headline = shown.count == 0 ? "I didn't find anything that matches."
                : (shown.isMoney ? "\(shown.name): \(Money.format(shown.total)) across \(shown.count) \(shown.count == 1 ? "charge" : "charges")."
                                 : "\(shown.name): \(Int(shown.total)).")
        }

        var rows: [(label: String, detail: String, value: String, category: Category?)] = []
        var bars: [ChartBar] = []
        if !shown.groups.isEmpty {
            rows = shown.groups.prefix(12).map { g in
                (g.label, g.count == 1 ? "1 charge" : "\(g.count) charges", shown.isMoney ? Money.format(g.value) : String(Int(g.value)), g.category)
            }
            if shown.groups.count >= 2, (plan["chart"] as? String) != "none" {
                bars = shown.groups.prefix(24).map { ChartBar(label: $0.label, value: $0.value, category: $0.category) }
            }
        } else {
            rows = shown.transactions.prefix(10).map {
                ($0.merchant, $0.date.formatted(.dateTime.month(.abbreviated).day().year()), Money.format(abs($0.amount)), $0.category)
            }
        }
        var answer = Answer(question: question, query: SpendingQuery(from: first, to: last), headline: headline, rows: rows)
        answer.chart = bars
        answer.chartIsLine = (plan["chart"] as? String) == "line"
        answer.understood = queries.map(\.name).joined(separator: " · ")
        return (answer, Turn(question: question, plan: String(planReply.prefix(1_500)), answer: headline))
    }

    /// "$1,234.56" style amounts in a piece of text.
    static func dollarAmounts(in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"\$[\d,]*\d(?:\.\d{2})?"#) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
}
