import Foundation

/// What the statements say about one credit card: what it charges to hold, what it has paid back as
/// statement credits, what it carries, and what is worth knowing about all that. Facts only: nothing
/// here comes from the issuer's terms or the web. A benefit is known because a credit for it once
/// landed on a statement, under the name the statement gave it; "usual" always means "as it has
/// come before on this card". Pure: transactions in, findings out.
enum CardEngine {
    enum Cadence: String { case monthly, quarterly, yearly
        var each: String { ["monthly": "a month", "quarterly": "a quarter", "yearly": "a year"][rawValue]! }
        var this: String { ["monthly": "this month", "quarterly": "this quarter", "yearly": "this year"][rawValue]! }
    }

    /// One month, quarter or calendar year of a benefit: what came, against what usually comes.
    struct Use: Identifiable, Hashable {
        var id: String { label }
        var label: String
        var start: Date
        /// The first day after it.
        var end: Date
        var received: Double
        var credits: [UUID]
        /// Still running on the day the facts were worked out.
        var isCurrent: Bool
        /// Bought at the shop this credit is for, in this stretch, on a different account.
        var elsewhere: [Transaction] = []
        /// Bought there on this card.
        var here: [Transaction] = []
    }

    /// A statement credit this card pays, as the statements name it.
    struct Benefit: Identifiable, Hashable {
        var id: String
        var name: String
        var cadence: Cadence
        /// What a full month, quarter or year of it has been on this card.
        var usual: Double
        /// A yearly figure the statement line itself prints ("TRAVEL CREDIT $300/YEAR").
        var printed: Double?
        var total: Double
        var first: Date
        var last: Date
        /// The payees the credits were for, when it is only one or two (a credit for one shop).
        var shops: [String]
        /// Not seen for over fifteen months: history, not something to watch.
        var ended: Bool
        /// Oldest first, ending with the stretch now running. Empty for one that has ended.
        var uses: [Use]
        var creditIDs: [UUID]

        var current: Use? { uses.last?.isCurrent == true ? uses.last : nil }
        /// Finished stretches in which less came than usually does.
        var missed: [Use] { uses.filter { !$0.isCurrent && $0.received < usual - 1 } }
    }

    struct Fee: Identifiable, Hashable {
        var id: UUID
        var date: Date
        var amount: Double
        /// The other cardholder it was for, when the line names one.
        var who: String?
    }

    struct Year: Identifiable, Hashable {
        var id: Int { year }
        var year: Int
        var spent = 0.0
        var charges = 0
        var fees = 0.0
        var credits = 0.0
        var interest = 0.0
    }

    /// Something worth knowing, said in a sentence built from the figures, with what it opens.
    struct Finding: Identifiable, Hashable {
        enum Kind: Hashable { case waiting, missed, wrongCard, quiet, feeDue, feeRose, interest, net, share }
        var id: String
        var kind: Kind
        var text: String
        var charges: Set<UUID> = []
        var chargesTitle: String = ""
        /// How much it matters, for ordering.
        var weight: Double
    }

    enum Verdict: Hashable { case noFee, paysItsWay, costs(Double) }

    struct Card: Identifiable, Hashable {
        var id: UUID
        var name: String
        var first: Date
        var last: Date
        var fees: [Fee]
        /// When the card's own yearly fee should next appear, and what it was last time.
        var nextFee: (date: Date, amount: Double)?
        var benefits: [Benefit]
        var years: [Year]
        // The last twelve months, to the day the facts were worked out.
        var spent = 0.0, charges = 0, feesPaid = 0.0, creditsBack = 0.0, interest = 0.0
        /// Its part of everything put on cards in those twelve months, 0 to 1.
        var share = 0.0
        var categories: [(category: Category, total: Double)]
        var payees: [(name: String, category: Category, total: Double, count: Int)]
        var purchaseIDs: Set<UUID>
        var interestIDs: Set<UUID>
        var findings: [Finding]

        var verdict: Verdict { feesPaid < 0.5 ? .noFee : creditsBack >= feesPaid ? .paysItsWay : .costs(feesPaid - creditsBack) }

        static func == (a: Card, b: Card) -> Bool { a.id == b.id && a.findings == b.findings && a.spent == b.spent && a.creditsBack == b.creditsBack }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    private static let calendar = Calendar.current

    // MARK: Reading a line

    /// The name of the benefit a credit line is for, or nil when the line is something else
    /// (a refund, a payment, a fraud reversal). "Platinum Lululemon Credit LULULEMON FLATIRON"
    /// gives "Platinum Lululemon Credit".
    static func benefitName(_ description: String) -> String? {
        let words = description.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let at = words.firstIndex(where: { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) == "credit" }), (1...4).contains(at) else { return nil }
        let lead = words[..<at]
        let not: Set<String> = ["fraud", "interest", "adjustment", "adjust", "dispute", "refund", "return", "reversal", "zelle", "ach", "payment", "branch",
                                "memo", "atm", "balance", "courtesy", "goodwill", "provisional", "temporary", "misc", "fee", "late", "finance", "statement"]
        guard !lead.contains(where: { not.contains($0.lowercased().trimmingCharacters(in: .punctuationCharacters)) }),
              lead.allSatisfy({ $0.contains(where: \.isLetter) && !$0.contains("*") && !$0.contains("#") }) else { return nil }
        return (lead + ["Credit"]).map { word in
            // Shouting is the statement's habit, not the benefit's name; a "+" or a mixed-case word is kept as written.
            word == word.uppercased() && word.count > 3 ? word.prefix(1) + word.dropFirst().lowercased() : word
        }.joined(separator: " ")
    }

    /// "$300/YEAR" in a credit line: the statement saying how much a year of it is.
    static func printedAllowance(_ description: String) -> Double? {
        guard description.contains("$"), let match = description.range(of: #"\$\s?[\d,]+(\.\d\d)?\s*/\s*(YEAR|YR)"#, options: [.regularExpression, .caseInsensitive]) else { return nil }
        return Double(description[match].filter { $0.isNumber || $0 == "." })
    }

    /// A yearly fee for holding the card, and the other cardholder it names, if it names one.
    static func annualFee(_ description: String) -> (isFee: Bool, who: String?) {
        // (Nearly every line is not a fee: say so cheaply before the pattern is tried.)
        guard description.range(of: " fee", options: .caseInsensitive) != nil,
              let match = description.range(of: #"(ANNUAL (MEMBERSHIP )?FEE|MEMBERSHIP FEE)"#, options: [.regularExpression, .caseInsensitive]) else { return (false, nil) }
        let before = description[..<match.lowerBound].trimmingCharacters(in: .whitespaces)
        let first = before.split(separator: " ").first.map(String.init)
        return (true, first.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() })
    }

    // MARK: Stretches of time

    private static func start(of cadence: Cadence, containing date: Date) -> Date {
        let parts = calendar.dateComponents([.year, .month], from: date)
        let month: Int = switch cadence {
        case .monthly: parts.month ?? 1
        case .quarterly: ((parts.month ?? 1) - 1) / 3 * 3 + 1
        case .yearly: 1
        }
        return calendar.date(from: DateComponents(year: parts.year, month: month, day: 1)) ?? date
    }

    private static func next(_ cadence: Cadence, after start: Date) -> Date {
        calendar.date(byAdding: .month, value: cadence == .monthly ? 1 : cadence == .quarterly ? 3 : 12, to: start) ?? start
    }

    static func label(_ cadence: Cadence, _ start: Date) -> String {
        switch cadence {
        case .monthly: return start.formatted(.dateTime.month(.abbreviated).year())
        case .yearly: return start.formatted(.dateTime.year())
        case .quarterly:
            let last = calendar.date(byAdding: .month, value: 2, to: start) ?? start
            return "\(start.formatted(.dateTime.month(.abbreviated))) to \(last.formatted(.dateTime.month(.abbreviated).year()))"
        }
    }

    /// How often a credit comes, from when it has come: most months, most quarters, or some time each year.
    static func cadence(of days: [Date], printedYearly: Bool, asOf: Date) -> Cadence {
        if printedYearly { return .yearly }
        guard let first = days.min() else { return .yearly }
        // The rhythm of the last two years, which is the benefit as it is now.
        let from = max(first, calendar.date(byAdding: .month, value: -24, to: asOf) ?? first)
        func fraction(_ cadence: Cadence) -> (with: Int, share: Double) {
            var all = 0, with = 0, at = start(of: cadence, containing: from)
            let seen = Set(days.map { start(of: cadence, containing: $0) })
            while at <= asOf { all += 1; if seen.contains(at) { with += 1 }; at = next(cadence, after: at) }
            return (with, all > 0 ? Double(with) / Double(all) : 0)
        }
        let months = fraction(.monthly), quarters = fraction(.quarterly)
        if months.with >= 4, months.share >= 0.6 { return .monthly }
        if quarters.with >= 2, quarters.share >= 0.5 { return .quarterly }
        return .yearly
    }

    // MARK: A card

    /// Everything about each card. `cards` are the accounts that are credit cards; `all` is every
    /// transaction (the other accounts are where a purchase on the wrong card would be).
    nonisolated static func cards(_ cards: [(id: UUID, name: String)], in all: [Transaction], asOf: Date) -> [Card] {
        let yearAgo = calendar.date(byAdding: .year, value: -1, to: asOf) ?? asOf
        let byAccount = Dictionary(grouping: all, by: \.accountID)
        var byPayee: [String: [Transaction]] = [:]
        for t in all where t.amount > 0 && !t.isTransfer { byPayee[t.merchant, default: []].append(t) }
        let names = Dictionary(cards.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })

        var built = cards.compactMap { card -> Card? in
            guard let lines = byAccount[card.id], let first = lines.first?.date, let last = lines.last?.date else { return nil }
            var fees: [Fee] = [], years: [Int: Year] = [:], credits: [String: [Transaction]] = [:]
            var purchases: [Transaction] = [], interest: [Transaction] = []
            for t in lines {
                let year = calendar.component(.year, from: t.date)
                if t.amount > 0 {
                    let fee = annualFee(t.description)
                    if fee.isFee {
                        fees.append(Fee(id: t.id, date: t.date, amount: t.amount, who: fee.who))
                        years[year, default: Year(year: year)].fees += t.amount
                    } else if t.category == .fees {
                        interest.append(t)
                        years[year, default: Year(year: year)].interest += t.amount
                    } else if !t.isTransfer {
                        purchases.append(t)
                        years[year, default: Year(year: year)].spent += t.amount
                        years[year, default: Year(year: year)].charges += 1
                    }
                } else if t.amount < 0, !t.isTransfer, let name = benefitName(t.description) {
                    credits[name.lowercased(), default: []].append(t)
                    years[year, default: Year(year: year)].credits += -t.amount
                }
            }

            let benefits = credits.map { key, lines in benefit(key: key, lines: lines, card: card.id, byPayee: byPayee, asOf: asOf) }
                .sorted { ($0.ended ? 0 : 1, $0.total, $1.name) > ($1.ended ? 0 : 1, $1.total, $0.name) }

            // The card's own fee is the largest of the last year or so; smaller ones beside it are for extra cards.
            let lately = fees.filter { $0.date > (calendar.date(byAdding: .month, value: -14, to: asOf) ?? asOf) }
            var nextFee: (date: Date, amount: Double)?
            if let main = lately.max(by: { ($0.amount, $0.date) < ($1.amount, $1.date) }), let due = calendar.date(byAdding: .year, value: 1, to: main.date) { nextFee = (due, main.amount) }

            let recent = purchases.filter { $0.date > yearAgo }
            let byCategory = Dictionary(grouping: recent, by: \.category).map { (category: $0.key, total: $0.value.reduce(0) { $0 + $1.amount }) }
                .sorted { ($0.total, $1.category.rawValue) > ($1.total, $0.category.rawValue) }
            let payees = Dictionary(grouping: recent, by: \.merchant).map { name, list in
                (name: name, category: list.last!.category, total: list.reduce(0) { $0 + $1.amount }, count: list.count)
            }.sorted { ($0.total, $1.name) > ($1.total, $0.name) }

            var made = Card(id: card.id, name: card.name, first: first, last: last, fees: fees, nextFee: nextFee, benefits: benefits,
                            years: years.values.sorted { $0.year < $1.year }, categories: byCategory, payees: Array(payees.prefix(8)),
                            purchaseIDs: Set(recent.map(\.id)), interestIDs: Set(interest.filter { $0.date > yearAgo }.map(\.id)), findings: [])
            made.spent = recent.reduce(0) { $0 + $1.amount }
            made.charges = recent.count
            made.feesPaid = fees.filter { $0.date > yearAgo }.reduce(0) { $0 + $1.amount }
            made.creditsBack = credits.values.joined().filter { $0.date > yearAgo }.reduce(0) { $0 - $1.amount }
            made.interest = interest.filter { $0.date > yearAgo }.reduce(0) { $0 + $1.amount }
            return made
        }
        let everything = built.reduce(0) { $0 + $1.spent }
        for i in built.indices {
            built[i].share = everything > 0 ? built[i].spent / everything : 0
            built[i].findings = findings(for: built[i], among: built.count, names: names, asOf: asOf)
        }
        // The cards doing the most first.
        return built.sorted { ($0.spent, $1.name) > ($1.spent, $0.name) }
    }

    private static func benefit(key: String, lines: [Transaction], card: UUID, byPayee: [String: [Transaction]], asOf: Date) -> Benefit {
        let name = benefitName(lines[0].description) ?? key
        let printed = lines.compactMap { printedAllowance($0.description) }.last
        let days = lines.map(\.date)
        let first = days.min()!, last = days.max()!
        let rhythm = cadence(of: days, printedYearly: printed != nil, asOf: asOf)
        let ended = last < (calendar.date(byAdding: .month, value: -15, to: asOf) ?? asOf)
        // The shops, when the credit is for one or two of them (a restaurant credit that roams is for none in particular).
        let payees = Array(Set(lines.map(\.merchant))).sorted()
        let shops = payees.count <= 2 ? payees.filter { byPayee[$0] != nil } : []

        var uses: [Use] = []
        if !ended {
            // Monthly: a year of it. Quarterly: two years. Yearly: five.
            let back = rhythm == .monthly ? 11 : rhythm == .quarterly ? 7 : 4
            var at = start(of: rhythm, containing: asOf)
            for _ in 0..<back { at = calendar.date(byAdding: .month, value: rhythm == .monthly ? -1 : rhythm == .quarterly ? -3 : -12, to: at) ?? at }
            let from = start(of: rhythm, containing: first)
            while at <= asOf {
                let end = next(rhythm, after: at)
                if at >= from {
                    let got = lines.filter { $0.date >= at && $0.date < end }
                    var use = Use(label: label(rhythm, at), start: at, end: end, received: got.reduce(0) { $0 - $1.amount }, credits: got.map(\.id), isCurrent: end > asOf)
                    for shop in shops {
                        for t in byPayee[shop] ?? [] where t.date >= at && t.date < end {
                            if t.accountID == card { use.here.append(t) } else { use.elsewhere.append(t) }
                        }
                    }
                    uses.append(use)
                }
                at = end
            }
        }
        // A full stretch of it: the figure the statement prints, or what most finished stretches came to.
        var usual = printed ?? 0
        if printed == nil {
            let sums = Dictionary(grouping: (uses.isEmpty ? [lines.reduce(0) { $0 - $1.amount }] : uses.filter { $0.received > 0.5 }.map(\.received)).map { ($0 * 100).rounded() / 100 }, by: { $0 })
            usual = sums.max { ($0.value.count, $0.key) < ($1.value.count, $1.key) }?.key ?? 0
        }
        return Benefit(id: key, name: name, cadence: rhythm, usual: usual, printed: printed, total: lines.reduce(0) { $0 - $1.amount },
                       first: first, last: last, shops: shops, ended: ended, uses: uses, creditIDs: lines.map(\.id))
    }

    // MARK: What is worth knowing

    private static func findings(for card: Card, among count: Int, names: [UUID: String], asOf: Date) -> [Finding] {
        let money = { (v: Double) in Money.format(v, cents: false) }
        var found: [Finding] = []
        let day = Date.FormatStyle.dateTime.month(.abbreviated).day()

        for benefit in card.benefits where !benefit.ended && benefit.usual > 0.5 {
            // The stretch now running, when nothing (or not all of it) has come yet. Yearly ones are
            // left alone: the statements cannot say which day an issuer's year begins.
            // Said only once this card's statements reach well into the stretch (a third of a quarter, most
            // of a month): a credit that has not come by the 2nd is not news.
            if benefit.cadence != .yearly, let now = benefit.current, now.received < benefit.usual - 1,
               card.last.timeIntervalSince(now.start) >= now.end.timeIntervalSince(now.start) * (benefit.cadence == .monthly ? 0.6 : 0.33) {
                let left = calendar.dateComponents([.day], from: asOf, to: now.end).day ?? 0
                let lastDay = calendar.date(byAdding: .day, value: -1, to: now.end) ?? now.end
                let got = now.received > 0.5 ? "\(money(now.received)) of the usual \(money(benefit.usual)) has come" : "Nothing has come yet"
                found.append(Finding(id: "waiting-\(benefit.id)", kind: .waiting,
                                     text: "\(benefit.name): \(got) \(benefit.cadence.this). It usually pays \(money(benefit.usual)) \(benefit.cadence.each), and \(benefit.cadence.this) ends \(lastDay.formatted(day)).",
                                     charges: Set(benefit.creditIDs), chargesTitle: benefit.name, weight: benefit.usual - now.received + (left < 21 ? 50 : 0)))
            }
            // Finished stretches of the last year where it did not come, and where the money went instead.
            let yearAgo = calendar.date(byAdding: .year, value: -1, to: asOf) ?? asOf
            let lately = benefit.missed.filter { $0.end > yearAgo && benefit.cadence != .yearly }
            let short = lately.reduce(0) { $0 + benefit.usual - $1.received }
            let astray = lately.flatMap(\.elsewhere)
            if !astray.isEmpty, let shop = benefit.shops.first {
                let where_ = Set(astray.compactMap { names[$0.accountID] ?? $0.account }).sorted().joined(separator: " and ")
                found.append(Finding(id: "wrong-\(benefit.id)", kind: .wrongCard,
                                     text: "\(money(astray.reduce(0) { $0 + $1.amount })) went to \(shop) on \(where_) in \(lately.filter { !$0.elsewhere.isEmpty }.map(\.label).joined(separator: " and ")), when the \(benefit.name) on this card did not come in full.",
                                     charges: Set(astray.map(\.id)), chargesTitle: "\(shop) on another card", weight: short + 100))
            } else if short > 1 {
                let which = lately.count <= 3 ? lately.map(\.label).joined(separator: ", ") : "\(lately.count) of the last \(benefit.uses.filter { !$0.isCurrent && $0.end > yearAgo }.count) \(benefit.cadence == .monthly ? "months" : "quarters")"
                let nothing = lately.allSatisfy { $0.received < 0.5 }
                found.append(Finding(id: "missed-\(benefit.id)", kind: .missed,
                                     text: nothing ? "\(benefit.name) usually pays \(money(benefit.usual)) \(benefit.cadence.each). Nothing came in \(which)."
                                                   : "\(benefit.name) usually pays \(money(benefit.usual)) \(benefit.cadence.each). In \(which) it came short, by \(money(short)) in all.",
                                     charges: Set(benefit.creditIDs), chargesTitle: benefit.name, weight: short))
            }
        }

        if let fee = card.nextFee {
            let days = calendar.dateComponents([.day], from: asOf, to: fee.date).day ?? 0
            if days <= 75 {
                found.append(Finding(id: "fee-due", kind: .feeDue,
                                     text: days < 0 ? "The \(money(fee.amount)) yearly fee was due around \(fee.date.formatted(day)) and is not on a statement yet."
                                                    : "The \(money(fee.amount)) yearly fee comes round about \(fee.date.formatted(day)): \(days) days from now.",
                                     charges: Set(card.fees.map(\.id)), chargesTitle: "Yearly fees on \(card.name)", weight: fee.amount / 4 + 60))
            }
        }
        // The card's own fee each year is the largest fee charged that year; when the latest is more than the one before, it rose.
        let own = Dictionary(grouping: card.fees, by: { calendar.component(.year, from: $0.date) }).compactMap { $0.value.max { $0.amount < $1.amount } }.sorted { $0.date < $1.date }
        if own.count >= 2, let latest = own.last, own[own.count - 2].amount < latest.amount - 1, latest.date > (calendar.date(byAdding: .month, value: -18, to: asOf) ?? asOf) {
            found.append(Finding(id: "fee-rose", kind: .feeRose,
                                 text: "The yearly fee went from \(money(own[own.count - 2].amount)) to \(money(latest.amount)) in \(latest.date.formatted(.dateTime.month(.wide).year())).",
                                 charges: Set(own.map(\.id)), chargesTitle: "Yearly fees on \(card.name)", weight: latest.amount - own[own.count - 2].amount))
        }
        if card.feesPaid > 0.5, card.charges < 12 {
            found.append(Finding(id: "quiet", kind: .quiet,
                                 text: card.charges == 0 ? "Nothing was bought on this card in the last twelve months, and it charged \(money(card.feesPaid)) in fees."
                                                         : "Only \(card.charges) \(card.charges == 1 ? "purchase" : "purchases") in the last twelve months, against \(money(card.feesPaid)) in fees.",
                                 charges: card.purchaseIDs, chargesTitle: "Bought on \(card.name), last 12 months", weight: card.feesPaid))
        }
        if card.interest > 1 {
            found.append(Finding(id: "interest", kind: .interest,
                                 text: "\(money(card.interest)) went on interest and other charges in the last twelve months, on top of any yearly fee.",
                                 charges: card.interestIDs, chargesTitle: "Interest and other charges on \(card.name)", weight: card.interest))
        }
        if card.feesPaid > 0.5 {
            let net = card.creditsBack - card.feesPaid
            found.append(Finding(id: "net", kind: .net,
                                 text: net >= 0 ? "Over the last twelve months it charged \(money(card.feesPaid)) in fees and paid \(money(card.creditsBack)) back in credits: \(money(net)) ahead."
                                                : "Over the last twelve months it charged \(money(card.feesPaid)) in fees and paid \(money(card.creditsBack)) back in credits: \(money(-net)) short of covering itself.",
                                 weight: 20))
        }
        if count > 1, card.spent > 0.5 {
            let top = card.categories.first.map { " Mostly \($0.category.displayName.lowercased()): \(Int(($0.total / card.spent * 100).rounded()))% of it." } ?? ""
            found.append(Finding(id: "share", kind: .share,
                                 text: "It carried \(card.share < 0.01 ? "less than 1" : String(Int((card.share * 100).rounded())))% of everything you put on cards in the last twelve months.\(top)",
                                 charges: card.purchaseIDs, chargesTitle: "Bought on \(card.name), last 12 months", weight: 10))
        }
        return found.sorted { ($0.weight, $1.id) > ($1.weight, $0.id) }
    }
}
