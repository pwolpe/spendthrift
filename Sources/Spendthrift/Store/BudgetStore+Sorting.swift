import SwiftUI
import AppKit
import CryptoKit
import PDFKit
import UniformTypeIdentifiers

/// Giving every payee a name and a category: the models that sort, the lookups that help, and the logos.
extension BudgetStore {
    // MARK: - Sorting with Apple Intelligence

    /// Places the instant rules couldn't sort go to the on-device model, a few at a time.
    /// Results are applied automatically; Double-Check lets the person glance over them later.
    /// Ties every card payment that left a bank account to that card's statements.
    ///
    /// A payment is accounted for when the card's own statement shows it arriving (the same amount
    /// within a few days), or when it equals the balance of a statement that closed shortly before.
    /// A stretch between two statements that a payment was plainly made for is a statement to find;
    /// a stretch nobody paid anything for is just a month the card wasn't used.
    func reconcileCards(cardAccount: [UUID: String], cardDays: [String: Set<Int>]) -> (covered: [UUID: Bool], cards: [String: CardCoverage]) {
        var parsed: [String: Int] = [:]
        func day(_ s: String) -> Int? {
            if let d = parsed[s] { return d }
            guard let date = DateParsing.parse(s, format: "yyyy-MM-dd") else { return nil }
            let d = Int(date.timeIntervalSinceReferenceDate / 86_400)
            parsed[s] = d
            return d
        }
        func text(_ day: Int) -> String { DateParsing.iso.string(from: Date(timeIntervalSinceReferenceDate: Double(day) * 86_400 + 43_200)) }
        let names = Dictionary(library.accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })

        struct Payment { let id: UUID; let day: Int; let amount: Double; let issuer: String; var billed = false; var lineAccount: UUID? }
        struct Credit { let day: Int; let amount: Double; let account: UUID; var used = false }
        struct Statement { let account: UUID; let start: Int?; let close: Int; var purchases = 0.0; var net = 0.0 }
        var payments: [Payment] = []
        var credits: [String: [Credit]] = [:]
        var bySource: [String: (purchases: Double, net: Double)] = [:]
        var firstCharge: [String: Int] = [:]
        for e in library.entries {
            guard let d = day(e.date) else { continue }
            let info = library.merchants[e.merchantKey]
            if let issuer = cardAccount[e.accountID] {
                firstCharge[issuer] = min(firstCharge[issuer] ?? d, d)
                let upper = e.description.uppercased()
                let isPayment = e.amount < 0 && ["PAYMENT", "AUTOPAY", "PYMT", "AUTO-PMT"].contains(where: upper.contains)
                if e.amount < 0 { credits[issuer, default: []].append(Credit(day: d, amount: -e.amount, account: e.accountID)) }
                if let source = e.sourceID {
                    var sums = bySource[source] ?? (0, 0)
                    if e.amount > 0 { sums.purchases += e.amount }
                    if !isPayment { sums.net += e.amount }
                    bySource[source] = sums
                }
            } else if (e.override ?? info?.category) == .transfer, e.override == nil, e.amount > 0,
                      let name = info?.name, name.hasSuffix("Card Payment") {
                payments.append(Payment(id: e.id, day: d, amount: e.amount, issuer: Self.issuer(in: name) ?? Self.issuer(in: e.description) ?? "Other cards"))
            }
        }
        var statements: [String: [Statement]] = [:]
        for source in library.sources ?? [] {
            guard let account = source.accountID, let issuer = cardAccount[account],
                  let close = (source.periodEnd.flatMap { $0.isEmpty ? nil : day($0) }) ?? source.lastDate.flatMap(day) else { continue }
            let sums = bySource[source.id] ?? (0, 0)
            statements[issuer, default: []].append(Statement(account: account, start: source.periodStart.flatMap { $0.isEmpty ? nil : day($0) },
                                                             close: close, purchases: sums.purchases, net: sums.net))
        }

        var covered: [UUID: Bool] = [:]
        var cards: [String: CardCoverage] = [:]
        payments.sort { $0.day < $1.day }
        let allDays = cardDays.values.reduce(into: Set<Int>()) { $0.formUnion($1) }
        for i in payments.indices {
            let p = payments[i]
            var card = cards[p.issuer] ?? CardCoverage(issuer: p.issuer)
            card.paid += p.amount; card.payments += 1
            // The card's statement shows this payment arriving.
            var line = false
            if let index = credits[p.issuer]?.firstIndex(where: { !$0.used && abs($0.amount - p.amount) < 0.005 && (-4...7).contains($0.day - p.day) }) {
                credits[p.issuer]![index].used = true
                payments[i].lineAccount = credits[p.issuer]![index].account
                line = true
            }
            // It pays off, to the cent, a statement that closed in the weeks before.
            let billed = (statements[p.issuer] ?? []).contains { s in
                (1...75).contains(p.day - s.close) && (abs(s.purchases - p.amount) < 0.005 || abs(s.net - p.amount) < 0.005)
            }
            payments[i].billed = billed
            // Or, for a card not paid in full, that card's purchases are simply here for the weeks before.
            let days = p.issuer == "Other cards" ? allDays : (cardDays[p.issuer] ?? [])
            let inRange = (15...50).contains { days.contains(p.day - $0) }
            covered[p.id] = line || billed || inRange
            if line || billed || inRange {
                card.tied += 1
            } else {
                card.uncoveredPaid += p.amount; card.uncoveredPayments += 1
                let loose = LoosePayment(id: p.id, date: text(p.day), amount: p.amount)
                let begins = (statements[p.issuer] ?? []).map(\.close).min() ?? firstCharge[p.issuer]
                if let begins, p.day < begins + 45 { card.early.append(loose) } else if begins != nil { card.unexplained.append(loose) }
            }
            cards[p.issuer] = card
        }

        // Holes between one statement and the next. A payment made for the hole proves a statement is missing.
        for (issuer, list) in statements {
            for (account, mine) in Dictionary(grouping: list.filter { $0.start != nil }, by: \.account) where mine.count >= 3 {
                let ordered = mine.sorted { $0.close < $1.close }
                for (a, b) in zip(ordered, ordered.dropFirst()) {
                    guard let nextStart = b.start, nextStart - a.close > 7 else { continue }
                    let from = a.close + 1, to = nextStart - 1
                    // What was due for a statement closing in the hole would be paid two to five weeks after it closed.
                    let proof = payments.first { p in
                        p.issuer == issuer && !p.billed && (p.lineAccount == nil || p.lineAccount == account) && (from + 15...to + 35).contains(p.day)
                    }
                    guard let proof else { continue }
                    cards[issuer]?.toFind.append(StatementToFind(account: names[account] ?? issuer, from: text(from), to: text(to),
                                                                 paid: proof.amount, paidOn: text(proof.day)))
                }
            }
        }
        for issuer in cards.keys { cards[issuer]?.toFind.sort { $0.from < $1.from } }
        return (covered, cards)
    }

    /// Statements added before the app noted the billing period they print: read it from the kept copies.
    func notePeriodsIfNeeded() async {
        let waiting = (library.sources ?? []).filter { $0.isPDF && $0.periodStart == nil }
        guard !waiting.isEmpty else { return }
        let files = waiting.map { ($0.id, paths.statementFile($0)) }
        let found = await Task.detached(priority: .utility) { () -> [String: (String, String)] in
            var out: [String: (String, String)] = [:]
            for (id, url) in files {
                guard let data = try? Data(contentsOf: url) else { continue }
                out[id] = PDFStatement.period(ofPDF: data).map { ($0.start, $0.end) } ?? ("", "")
            }
            return out
        }.value
        guard !found.isEmpty else { return }
        for i in (library.sources ?? []).indices {
            if let period = found[library.sources![i].id] { library.sources![i].periodStart = period.0; library.sources![i].periodEnd = period.1 }
        }
        changed()
    }

    func sortRemaining() async {
        guard !isSuggesting else { return }
        isSuggesting = true
        defer {
            isSuggesting = false
            // Once everything has a category, look for the trips and events in it, and find logos.
            Task { await findStoriesIfNeeded() }
            Task { await findLogosIfNeeded() }
            Task { await findDiscoveriesIfNeeded() }
            Task { await tidyIfNeeded() }
            Task { await learnFactsIfNeeded() }
            announceNewFindings()
        }
        // With a cloud key, the powerful model decides everything the built-in list doesn't know.
        if CloudAI.isEnabled { await sortWithCloud(); await lookUpGuesses() }
        guard aiAvailable else { return }
        while true {
            let used = Dictionary(grouping: library.entries, by: \.merchantKey)
            let waiting = library.merchants
                .filter { $0.value.category == nil && !aiAttempted.contains($0.key) && used[$0.key] != nil }
                .map { key, info -> (SuggestionInput, Double) in
                    let entries = used[key] ?? []
                    let total = entries.reduce(0) { $0 + $1.amount }
                    return (SuggestionInput(keyword: key, description: info.sample, averageAmount: total / Double(max(entries.count, 1))), abs(total))
                }
                .sorted { $0.1 > $1.1 }   // biggest first, so the totals settle quickly
                .map(\.0)
            guard !waiting.isEmpty else { break }
            // The person's own choices teach the model their habits.
            let examples = library.merchants.values
                .filter { $0.confirmed && $0.category != nil }
                .map { MerchantRule(name: $0.name, category: $0.category!) }
            for batch in waiting.chunked(into: 8) {
                aiAttempted.formUnion(batch.map(\.keyword))
                let results = await CategorySuggester.suggest(batch, examples: examples)
                for (key, suggestion) in results where library.merchants[key]?.category == nil {
                    library.merchants[key]?.category = suggestion.category
                    library.merchants[key]?.name = suggestion.name
                    library.merchants[key]?.source = .ai
                }
                if !results.isEmpty { withAnimation(.snappy) { changed() } }
            }
        }
    }

    /// The cloud model reviews every place that isn't the person's own choice or a business the app knows
    /// for certain: unsorted places, on-device guesses, the bank's broad categories and word matches.
    /// What it's sure of is simply filed; only what it calls a guess goes to Double-Check.
    /// A first, instant pass over a large batch of new payees. A decision model answers "which
    /// category?" for each in a few hundredths of a second; where it is at least nine parts in ten
    /// sure (it then agrees with the careful model 99 times in 100, measured on a real library), the
    /// category is shown straight away. The careful pass that follows still names every payee and
    /// has the last word on every category: this only means the page fills in while it works.
    private func fileTheObviousAtOnce(_ items: [CloudItem]) async {
        let fresh = items.filter { library.merchants[$0.key]?.category == nil }
        guard fresh.count >= 20 else { return }
        var states: [String: String] = [:]
        for item in fresh {
            states[item.key] = "Transaction text: \(Redactor.scrub(item.description)). Money \(item.averageAmount < 0 ? "came in" : "went out"). "
                + "Typical amount $\(String(format: "%.2f", abs(item.averageAmount))). Appears \(item.count) time\(item.count == 1 ? "" : "s")."
        }
        let answers = await Decisions.askAll(job: "Sorting payees, first pass", model: Self.factsModel, states: states,
                                             questions: ["category": CategoryQuestion.question()], atOnce: 24)
        var filed = 0
        for (key, answer) in answers {
            guard let pick = answer["category"], (pick.confidence ?? 0) >= 0.9, let choice = pick.choice,
                  let category = Category.pickable.first(where: { $0.rawValue == choice }),
                  library.merchants[key] != nil, library.merchants[key]?.category == nil else { continue }
            library.merchants[key]?.category = category
            filed += 1
        }
        if ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] != nil { print("DEBUG FIRST PASS asked \(states.count), filed \(filed)") }
        if filed > 0 { withAnimation(.snappy) { changed() } }
    }

    private func sortWithCloud() async {
        while true {
            let used = Dictionary(grouping: library.entries, by: \.merchantKey)
            var waiting: [(item: CloudItem, weight: Double)] = []
            for (key, info) in library.merchants {
                guard !info.confirmed, [.ai, .bank, .generic].contains(info.source) || relearnKeys.contains(key), !cloudAttempted.contains(key),
                      let entries = used[key], !entries.isEmpty else { continue }
                let total = entries.reduce(0) { $0 + $1.amount }
                var item = CloudItem(key: key, description: info.sample, averageAmount: total / Double(entries.count),
                                     count: entries.count, bankCategory: entries.compactMap(\.bankCategory).first)
                item.amounts = Array(entries.suffix(8).map { abs($0.amount) })
                item.notes = ([info.note].compactMap { $0 } + entries.compactMap(\.note)).filter { !$0.isEmpty }.suffix(4).map { String($0.prefix(200)) }
                if let guess = info.category { item.appGuess = "\(info.name): \(guess.rawValue)" }
                waiting.append((item, abs(total)))
            }
            guard !waiting.isEmpty else { relearnKeys.removeAll(); return }
            waiting.sort { $0.weight > $1.weight }
            await fileTheObviousAtOnce(waiting.map(\.item))
            let examples = library.merchants.values
                .filter { $0.confirmed && $0.category != nil }
                .map { MerchantRule(name: $0.name, category: $0.category!) }
            // Several batches at once, biggest places first. A batch that fails is retried in halves;
            // only if nothing at all gets through do we assume the cloud is unreachable and stop.
            var batches = waiting.map(\.item).chunked(into: 15)
            cloudAttempted.formUnion(waiting.map(\.item.key))
            var anySucceeded = false
            await withTaskGroup(of: ([CloudItem], [String: CloudVerdict]?).self) { group in
                var running = 0
                func start() {
                    // Measured on 567 real places: forty small batches in flight finish in under ten
                    // seconds; five at a time took a minute. The answers are the same.
                    while running < 40, !batches.isEmpty {
                        let batch = batches.removeFirst()
                        running += 1
                        group.addTask { (batch, await CloudSorter.sortTwice(batch, examples: examples)) }
                    }
                }
                start()
                for await (batch, verdicts) in group {
                    running -= 1
                    if let verdicts {
                        anySucceeded = true
                        for (key, verdict) in verdicts where library.merchants[key]?.confirmed == false {
                            library.merchants[key]?.category = verdict.category
                            library.merchants[key]?.name = verdict.name
                            library.merchants[key]?.source = verdict.confident ? .cloud : .cloudGuess
                            library.merchants[key]?.domain = verdict.domain
                        }
                        if !verdicts.isEmpty { withAnimation(.snappy) { changed() } }
                    } else if batch.count > 4, anySucceeded || batch.count > 15 {
                        // Too big a bite, or a hiccup: try again in two halves.
                        let half = batch.count / 2
                        batches.append(Array(batch[..<half])); batches.append(Array(batch[half...]))
                    }
                    start()
                }
            }
            if !anySucceeded { return }
        }
    }

    /// Called when a key is added in Settings: everything uncertain gets a second, better look.
    func cloudBecameAvailable() {
        cloudAttempted.removeAll()
        Task { await sortRemaining() }
    }

    // MARK: - Logos


    /// The website of the business with this name, if known (its logo is fetched from there).
    func domain(forPlace name: String) -> String? { domainByName[name] }

    /// Businesses the app recognized by itself (Starbucks, Con Edison…) never went to the cloud
    /// model, so nobody has said what their website is. Ask once, in the background.
    private func findLogosIfNeeded() async {
        guard CloudAI.isEnabled, !isFindingLogos else { return }
        let used = Set(library.entries.map(\.merchantKey))
        let unknown = library.merchants.filter { $0.value.domain == nil && used.contains($0.key) }
        guard !unknown.isEmpty else { return }
        isFindingLogos = true
        defer { isFindingLogos = false }
        for batch in Array(unknown).chunked(into: 80) {
            guard let found = await LogoFinder.domains(for: batch.map(\.value.name)) else { return }
            for (key, info) in batch { library.merchants[key]?.domain = found[info.name] ?? "" }
            changed()
        }
    }

    // MARK: - Looking places up on the web


    /// The guesses that matter most by dollars are searched for on the web, once each.
    func lookUpGuesses() async {
        guard CloudAI.isEnabled, WebLookup.isOn, !isLookingUp else { return }
        let used = Dictionary(grouping: library.entries, by: \.merchantKey)
        var waiting: [(item: CloudItem, weight: Double)] = []
        for (key, info) in library.merchants where info.source == .cloudGuess && !info.confirmed && info.lookedUp != true {
            guard let entries = used[key], !entries.isEmpty, WebLookup.isSearchable(info.sample) else { continue }
            let total = entries.reduce(0) { $0 + $1.amount }
            var item = CloudItem(key: key, description: info.sample, averageAmount: total / Double(entries.count),
                                 count: entries.count, bankCategory: nil)
            item.appGuess = "\(info.name): \(info.category?.rawValue ?? "unknown")"
            waiting.append((item, abs(total)))
        }
        guard !waiting.isEmpty else { return }
        let cap = ProcessInfo.processInfo.environment["SPENDTHRIFT_LOOKUP_CAP"].flatMap(Int.init) ?? 40
        let chosen = waiting.sorted { $0.weight > $1.weight }.prefix(cap).map(\.item)
        isLookingUp = true
        defer { isLookingUp = false }
        let batches = chosen.chunked(into: 5)
        await withTaskGroup(of: ([CloudItem], [String: CloudVerdict]).self) { group in
            for batch in batches { group.addTask { (batch, await WebLookup.identify(batch)) } }
            for await (batch, verdicts) in group {
                for item in batch { library.merchants[item.key]?.lookedUp = true }
                for (key, verdict) in verdicts where library.merchants[key]?.confirmed == false {
                    if ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] != nil {
                        print("DEBUG LOOKUP \(library.merchants[key]?.sample ?? "") → \(verdict.name) | \(verdict.category.rawValue) | \(verdict.domain ?? "-")")
                    }
                    library.merchants[key]?.name = verdict.name
                    library.merchants[key]?.category = verdict.category
                    library.merchants[key]?.source = .cloud
                    if let domain = verdict.domain, !domain.isEmpty { library.merchants[key]?.domain = domain }
                }
                withAnimation(.snappy) { changed() }
            }
        }
    }

    /// Libraries from before wires were told apart hold every international wire as one payee.
    /// Once, each wire is given to its own recipient. A recipient that is new starts with the old
    /// payee's category as a guess and goes to Double-Check to be named.
    func splitWiresByRecipient() {
        guard library.adopted?.contains("wires") != true else { return }
        library.adopted = (library.adopted ?? []).union(["wires"])
        // Which recipients each old payee turns into.
        var becomes: [String: Set<String>] = [:]
        for entry in library.entries where !entry.merchantKey.hasPrefix("known:") {
            guard let recipient = KeywordExtractor.wireRecipient(entry.description), "WIRE " + recipient != entry.merchantKey else { continue }
            becomes[entry.merchantKey, default: []].insert("WIRE " + recipient)
        }
        guard !becomes.isEmpty else { return }
        for i in library.entries.indices {
            let entry = library.entries[i]
            guard let targets = becomes[entry.merchantKey], let recipient = KeywordExtractor.wireRecipient(entry.description) else { continue }
            let key = "WIRE " + recipient
            if library.merchants[key] == nil, let old = library.merchants[entry.merchantKey] {
                if targets.count == 1 {
                    // It was one recipient all along: everything the person decided about it carries over.
                    library.merchants[key] = old
                } else {
                    var info = MerchantResolver.instant(description: entry.description, amount: entry.amount, bankCategory: nil)
                    info.category = old.category
                    library.merchants[key] = info
                }
            }
            library.entries[i].merchantKey = key
        }
        // The lumped payees are empty now; a confirmed one would otherwise linger as a name with nothing in it.
        for old in becomes.keys { library.merchants[old] = nil }
        pruneUnusedPlaces()
        library.save(paths: paths)
    }

    // MARK: - A category added after a library was sorted

    /// "Wine & Spirits" arrived after people's statements were already sorted, when wine shops went
    /// under Groceries. Once, the places that might belong to it are shown to the model again, and only
    /// the ones it files there are moved. Nothing else changes category, and anything the person
    /// chose themselves is left alone.
    func adoptWineCategory(force: Bool = false) async {
        // Remembered in the library itself, so each library gets this exactly once, on any Mac.
        func done() { library.adopted = (library.adopted ?? []).union(["wine"]); changed() }
        guard CloudAI.isEnabled, !isImporting, !isSuggesting, force || library.adopted?.contains("wine") != true else { return }
        guard !library.entries.isEmpty else { return }
        let used = Dictionary(grouping: library.entries, by: \.merchantKey)
        let hints = ["wine", "liquor", "spirit", "whisk", "bourbon", "cellar", "vineyard", "winery", "vino", "distill", "bottle", "vintner", "champagne"]
        var waiting: [(item: CloudItem, weight: Double)] = []
        for (key, info) in library.merchants where !info.confirmed && info.source != .user {
            guard let entries = used[key], !entries.isEmpty, let category = info.category else { continue }
            let text = (info.name + " " + info.sample).lowercased()
            // Where a bottle shop would have been filed before, or anything that sounds like one.
            guard [Category.groceries, .shopping, .other].contains(category) || hints.contains(where: text.contains) else { continue }
            let total = entries.reduce(0) { $0 + $1.amount }
            guard total > 0 else { continue }
            var item = CloudItem(key: key, description: info.sample, averageAmount: total / Double(entries.count), count: entries.count, bankCategory: nil)
            item.appGuess = "\(info.name): \(category.rawValue)"
            waiting.append((item, total))
        }
        let batches = waiting.sorted { $0.weight > $1.weight }.prefix(900).map(\.item).chunked(into: 15)
        var moved = 0, answered = 0
        await withTaskGroup(of: [String: CloudVerdict]?.self) { group in
            for batch in batches { group.addTask { await CloudSorter.sortTwice(batch, examples: []) } }
            for await verdicts in group {
                guard let verdicts else { continue }
                answered += 1
                for (key, verdict) in verdicts where verdict.category == .wine && library.merchants[key]?.confirmed == false {
                    if ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] != nil {
                        print("DEBUG WINE \(library.merchants[key]?.name ?? key) [\(library.merchants[key]?.category?.rawValue ?? "-")] \(verdict.confident ? "" : "(guess)")")
                    }
                    library.merchants[key]?.category = .wine
                    library.merchants[key]?.source = verdict.confident ? .cloud : .cloudGuess
                    moved += 1
                }
            }
        }
        // Only count it done if the model was reachable; otherwise try again next time.
        if answered > 0 || batches.isEmpty { done() }
        if moved > 0 {
            withAnimation(.snappy) { changed() }
            showToast("New category: Wine & Spirits. \(moved) \(moved == 1 ? "payee" : "payees") moved into it from Groceries and Shopping.", symbol: "wineglass.fill")
        }
    }

    // MARK: - A best guess at each unconfirmed place


    /// For every place on Double-Check that has no guess yet: ask once what it most likely was.
    func guessWhatTheyWere() async {
        guard CloudAI.isEnabled, !isGuessing, !isImporting else { return }
        let waiting = reviewItems.filter { $0.info.hunch == nil || $0.info.hunchSorted != true }
        guard !waiting.isEmpty else { return }
        isGuessing = true
        defer { isGuessing = false }
        let byKey = Dictionary(grouping: transactions, by: \.merchantKey)
        let subjects = waiting.prefix(60).map { item -> Huncher.Subject in
            let charges = (byKey[item.key] ?? []).sorted { $0.date > $1.date }
            return Huncher.Subject(key: item.key, name: item.info.name, line: item.info.sample,
                                   category: item.info.category?.rawValue ?? "not sorted",
                                   account: charges.first?.account ?? "",
                                   charges: charges.prefix(8).map { "\(DateParsing.iso.string(from: $0.date)) \(Money.format(abs($0.amount))) \($0.amount < 0 ? "in" : "out")" },
                                   count: charges.count)
        }
        let guesses = await Huncher.guess(Array(subjects), notes: allNotes(limit: 25))
        guard !guesses.isEmpty else { return }
        for (key, guess) in guesses {
            // Still an unconfirmed guess? (The person may have settled it while the model was thinking.)
            guard let info = library.merchants[key], info.isUnconfirmedGuess else { continue }
            library.merchants[key]?.hunch = guess.text
            library.merchants[key]?.hunchSorted = true
            // The category on the row follows the guess, so "looks right" can be one click. It stays a guess.
            if let category = guess.category, !guess.text.isEmpty, category != info.category {
                library.merchants[key]?.category = category
                if info.source != .ai { library.merchants[key]?.source = .cloudGuess }
            }
            if ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] != nil {
                print("DEBUG HUNCH \(info.name): \(guess.text) | \(info.category?.rawValue ?? "-") → \(guess.category?.rawValue ?? "-")")
            }
        }
        withAnimation(.snappy) { changed() }
    }
}
