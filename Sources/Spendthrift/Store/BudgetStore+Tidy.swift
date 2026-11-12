import SwiftUI

/// Acting on what `TidyEngine` finds: asking a decision model about each pair once, combining and
/// separating payees when it is sure, and keeping a record that can be shown and undone.
extension BudgetStore {
    /// The model that judges pairs. Chosen by measurement on a real library (it called real
    /// duplicates "the same" with high confidence and almost never a wrong pair).
    static let tidyModel = "google/gemini-decision-1"

    /// What was tidied automatically, newest first.
    /// (A split-off payee that the sorter then gave its old name back is no change at all, and is left out.)
    var tidyChanges: [TidyChange] {
        (library.tidy?.changes ?? []).reversed().filter { change in
            change.kind == .combine || change.otherKey.flatMap { library.merchants[$0]?.name } != change.from
        }
    }
    var newTidyChanges: [TidyChange] { tidyChanges.filter { $0.isNew ?? false } }

    /// Looks for payees to combine or separate, and does it where the model is sure. Each pair is
    /// asked about once, ever; after the first pass this costs nothing unless new payees arrive.
    func tidyIfNeeded() async {
        guard CloudAI.isEnabled, !isTidying, !isImporting, !isSuggesting else { return }
        isTidying = true
        defer {
            isTidying = false
            // A sort that was asked for while payees were being compared runs now (and so does the one this tidy-up wants).
            if sortAfterTidy { sortAfterTidy = false; Task { await sortRemaining() } }
        }
        let spellings = TidyEngine.spellings(of: transactions, byHand: byHandNames())
        // A pair the model gave no answer to (-2) is asked once more; any other answer is final.
        let skip = (library.tidy ?? TidyBook()).settled
        let pairs = TidyEngine.pairs(in: spellings, alreadyJudged: skip)
        guard !pairs.isEmpty else { return }
        let states = Dictionary(pairs.map { ($0.id, TidyEngine.state(for: $0)) }, uniquingKeysWith: { first, _ in first })
        let answers = await Decisions.askAll(job: "Tidying payees", model: Self.tidyModel, states: states, questions: ["same": TidyEngine.sameBusiness])
        // Nothing at all came back: the model was out of reach, which says nothing about the pairs.
        guard !answers.isEmpty else { return }
        // The answers took a while. If statements are being read or sorted meanwhile, wait for them
        // (their results and these would otherwise rewrite the same payees); give up after a minute.
        for _ in 0..<60 where isImporting || isSuggesting { try? await Task.sleep(for: .seconds(1)) }
        guard !isImporting, !isSuggesting else { return }

        let ranked = pairs.compactMap { pair in answers[pair.id]?["same"]?.yes.map { (pair, $0) } }
        let unanswered = pairs.filter { answers[$0.id]?["same"]?.yes == nil }.map(\.id)
        let done = await applyTidy(ranked, unanswered: unanswered)
        if ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] != nil {
            print("TIDY asked about \(pairs.count) pairs, \(answers.count) answered, \(done.count) acted on, \(library.tidy?.suggestions?.count ?? 0) offered")
            for change in done { print("TIDY DONE \(sentence(for: change)) (\(change.charges) charges)") }
            for s in library.tidy?.suggestions ?? [] { print("TIDY OFFER \(s.a) = \(s.b)?") }
        }
        guard !done.isEmpty else { return }
        let charges = done.reduce(0) { $0 + $1.charges }
        showToast(done.count == 1 ? "\(sentence(for: done[0])). It can be undone on the Payees page."
                                  : "Tidied \(done.count) payees (\(charges) charges). See what changed on the Payees page.", symbol: "wand.and.stars")
        // Payees that were split off have only the statement's words for a name: have them named and filed properly
        // (once this tidy-up has ended, which is when a waiting sort is let go).
        sortAfterTidy = true
    }

    /// The payees the person named, renamed, filed or confirmed: nothing automatic moves charges out
    /// of them, renames them or folds them into another.
    func byHandNames() -> Set<String> {
        Set(library.merchants.values.filter { $0.source == .user || $0.confirmed }.map(\.name))
    }

    /// The record that speaks for a payee name when several share it: one the person set, then the
    /// one with most charges, then the smallest key (so every run picks the same).
    private func bestRecord(named name: String, caseInsensitive: Bool = false, counts: [String: Int]? = nil) -> (key: String, info: MerchantInfo)? {
        let counts = counts ?? Dictionary(grouping: library.entries, by: \.merchantKey).mapValues(\.count)
        let same = library.merchants.filter { caseInsensitive ? $0.value.name.caseInsensitiveCompare(name) == .orderedSame : $0.value.name == name }
        let candidates = same.map { (key: $0.key, byPerson: $0.value.source == .user || $0.value.confirmed, charges: counts[$0.key] ?? 0) }
        return TidyEngine.bestKey(among: candidates).flatMap { key in same[key].map { (key, $0) } }
    }

    /// Acts on pairs that have been judged: `probability` is how likely each is one business.
    /// Returns what was done. Separate from the asking so it can be checked without a model.
    @discardableResult
    func applyTidy(_ judged: [(pair: TidyEngine.Pair, probability: Double)], unanswered: [String] = []) async -> [TidyChange] {
        var book = library.tidy ?? TidyBook()
        var done: [TidyChange] = []
        var offered = book.suggestions ?? []
        let recurring = Set(recurring().filter(\.isActive).map(\.merchant))
        // The surest first, so a later, weaker pair never undoes what a stronger one settled; ties by id, so every run does the same.
        let ranked = judged.sorted { l, r in
            let x = abs(l.probability - 0.5), y = abs(r.probability - 0.5)
            return x != y ? x > y : l.pair.id < r.pair.id
        }
        // Who counts as named by hand is worked out now: the answers may have taken minutes to arrive.
        let hand = byHandNames()
        // Pairs the model did not answer: asked once more, then left (-2, then -3).
        for id in unanswered { book.judged[id] = book.judged[id] == -2 ? -3 : -2 }
        func record(_ change: TidyChange?) {
            guard let change else { return }
            // Several spellings moved to the one payee are one thing to tell the person about.
            if let i = done.firstIndex(where: { $0.kind == change.kind && $0.from == change.from && $0.otherKey == change.otherKey && change.otherKey != nil }) {
                done[i].charges += change.charges
                done[i].moved = (done[i].moved ?? [:]).merging(change.moved ?? [:]) { first, _ in first }
                done[i].morePairIDs = (done[i].morePairIDs ?? []) + [change.pairID]
            } else { done.append(change) }
        }
        for (given, probability) in ranked {
            let pair = TidyEngine.Pair(kind: given.kind, a: given.a.marked(byHand: hand.contains(given.a.payee)), b: given.b.marked(byHand: hand.contains(given.b.payee)))
            book.judged[pair.id] = probability
            switch TidyEngine.verdict(for: pair, probabilitySame: probability, recurring: recurring) {
            case .combine: record(combine(pair))
            case .rehome: record(await separate(pair.a, from: pair.a.payee, to: pair.b.payee, pairID: pair.id))
            case .separate: record(await separate(pair.b, from: pair.a.payee, to: nil, pairID: pair.id))
            case .suggest:
                if !offered.contains(where: { $0.pairID == pair.id }) { offered.append(TidySuggestion(pairID: pair.id, a: pair.a.payee, b: pair.b.payee)) }
            case .leave: break
            }
        }
        book.changes += done
        // A suggestion about a payee that no longer exists (it was combined meanwhile) is no suggestion.
        let names = Set(library.merchants.values.map(\.name))
        book.suggestions = offered.filter { names.contains($0.a) && names.contains($0.b) && $0.a != $0.b }
        library.tidy = book
        if !done.isEmpty { pruneUnusedPlaces() }
        withAnimation(.snappy) { changed() }
        return done
    }

    /// Whether any payee record called `name` is the person's own word (named, renamed, filed or confirmed).
    private func isByHand(payee name: String) -> Bool {
        library.merchants.values.contains { $0.name == name && ($0.source == .user || $0.confirmed) }
    }

    /// What a change did, in words, with the payee called whatever it is called now.
    func sentence(for change: TidyChange) -> String {
        let other = change.otherKey.flatMap { library.merchants[$0]?.name } ?? change.other
        switch change.kind {
        case .combine: return "Combined \(other) into \(change.from)"
        case .separate: return "Separated \(other) from \(change.from)"
        }
    }

    /// Combines two payees because the person said so, after the app had only suggested it.
    func accept(_ suggestion: TidySuggestion) {
        guard var book = library.tidy else { return }
        let spellings = TidyEngine.spellings(of: transactions, byHand: byHandNames())
        book.suggestions?.removeAll { $0.pairID == suggestion.pairID }
        if let a = spellings[suggestion.a]?.first, let b = spellings[suggestion.b]?.first,
           let change = combine(TidyEngine.Pair(kind: .combine, a: a, b: b)) {
            var change = change
            change.pairID = suggestion.pairID
            change.isNew = false
            book.changes.append(change)
        }
        library.tidy = book
        pruneUnusedPlaces()
        withAnimation(.snappy) { changed() }
    }

    func decline(_ suggestion: TidySuggestion) {
        guard var book = library.tidy else { return }
        book.suggestions?.removeAll { $0.pairID == suggestion.pairID }
        book.judged[suggestion.pairID] = -1
        library.tidy = book
        withAnimation(.snappy) { changed() }
    }

    /// Two payees that are one business: the smaller takes the larger's name and category.
    /// A name the person gave by hand is the one that is kept.
    private func combine(_ pair: TidyEngine.Pair) -> TidyChange? {
        let (keep, fold) = pair.b.byHand && !pair.a.byHand ? (pair.b, pair.a) : (pair.a, pair.b)
        guard keep.payee != fold.payee, let target = bestRecord(named: keep.payee)?.info else { return nil }
        let keys = library.merchants.filter { $0.value.name == fold.payee }.map(\.key)
        guard !keys.isEmpty else { return nil }
        var before: [String: TidyChange.Before] = [:]
        for key in keys {
            guard let info = library.merchants[key] else { continue }
            before[key] = .init(name: info.name, category: info.category?.rawValue, source: info.source.rawValue, confirmed: info.confirmed, domain: info.domain)
            library.merchants[key]?.name = target.name
            if let category = target.category { library.merchants[key]?.category = category }
            if let domain = target.domain { library.merchants[key]?.domain = domain }
        }
        let moved = Set(keys)
        return TidyChange(kind: .combine, day: DateParsing.iso.string(from: .now), from: target.name, other: fold.payee,
                          charges: library.entries.filter { moved.contains($0.merchantKey) }.count, pairID: pair.id, otherKey: nil, renamed: before)
    }

    /// Charges written one way leave the payee they were gathered under. With `to`, they join that
    /// payee; without, they become a payee of their own, named from the statement's words for now
    /// (the sorter gives it a proper name and a category straight after).
    private func separate(_ spelling: TidyEngine.Spelling, from payee: String, to target: String?, pairID: String) async -> TidyChange? {
        let name = target ?? KeywordExtractor.displayName(for: spelling.sample)
        guard !name.isEmpty, name.caseInsensitiveCompare(payee) != .orderedSame else { return nil }
        // Looked at again now, not as it was when the question was asked: a payee the person has named since is theirs.
        guard !isByHand(payee: payee) else { return nil }
        let counts = Dictionary(grouping: library.entries, by: \.merchantKey).mapValues(\.count)
        let existing = bestRecord(named: name, caseInsensitive: true, counts: counts).map { (key: $0.key, value: $0.info) }
        let keysOfPayee = Set(library.merchants.filter { $0.value.name == payee }.map(\.key))
        let indices = library.entries.indices.filter {
            // A charge the person filed under a category of its own stays where it is.
            library.entries[$0].override == nil && keysOfPayee.contains(library.entries[$0].merchantKey) && MerchantResolver.spelling(library.entries[$0].description).uppercased() == spelling.text
        }
        guard !indices.isEmpty else { return nil }
        // An "own:" payee made earlier for the same name takes these too; otherwise a new one is made.
        let ownKey = library.merchants.filter { $0.key.hasPrefix("own:") && $0.value.name.caseInsensitiveCompare(name) == .orderedSame }.keys.sorted().first
        let key = ownKey ?? "own:" + UUID().uuidString
        if library.merchants[key] == nil {
            var info = MerchantInfo(name: existing?.value.name ?? name, category: existing?.value.category, source: existing == nil ? .ai : .cloud,
                                    confirmed: false, sample: spelling.sample)
            info.domain = existing?.value.domain
            library.merchants[key] = info
        }
        var moved: [String: String] = [:]
        // What each emptied payee record was, in case it is cleared away before an Undo needs it back.
        var before: [String: TidyChange.Before] = [:]
        for i in indices {
            let old = library.entries[i].merchantKey
            moved[library.entries[i].id.uuidString] = old
            if before[old] == nil, let info = library.merchants[old] {
                before[old] = .init(name: info.name, category: info.category?.rawValue, source: info.source.rawValue, confirmed: info.confirmed,
                                    domain: info.domain, sample: info.sample)
            }
            library.entries[i].merchantKey = key
        }
        library.spellings = (library.spellings ?? [:]).merging([spelling.text: key]) { _, new in new }
        return TidyChange(kind: .separate, day: DateParsing.iso.string(from: .now), from: payee, other: library.merchants[key]?.name ?? name,
                          charges: indices.count, pairID: pairID, otherKey: key, renamed: before, moved: moved, spelling: spelling.text)
    }

    /// Puts things back exactly as they were, and remembers never to do that one again.
    func undo(_ change: TidyChange) {
        guard var book = library.tidy, let index = book.changes.firstIndex(where: { $0.id == change.id }) else { return }
        switch change.kind {
        case .combine:
            for (key, before) in change.renamed ?? [:] where library.merchants[key] != nil {
                library.merchants[key]?.name = before.name
                library.merchants[key]?.category = before.category.map { Category($0) }
                library.merchants[key]?.source = MerchantInfo.Source(rawValue: before.source) ?? .cloud
                library.merchants[key]?.confirmed = before.confirmed
                library.merchants[key]?.domain = before.domain
            }
        case .separate:
            let back = change.moved ?? [:]
            // (Changes made before the record above was kept: the payee they came from is the best account of what they were.)
            let like = bestRecord(named: change.from)?.info
            // Only charges still on the key the tidy-up gave them go back: one moved by hand since stays where the person put it.
            let given = change.otherKey
            let stillThere = Set(library.entries.filter { back[$0.id.uuidString] != nil && (given == nil || $0.merchantKey == given) }.compactMap { back[$0.id.uuidString] })
            // A payee record left with no charges may have been cleared away since: make it again as it was.
            for (key, before) in change.renamed ?? [:] where library.merchants[key] == nil && stillThere.contains(key) {
                var info = MerchantInfo(name: before.name, category: before.category.map { Category($0) },
                                        source: MerchantInfo.Source(rawValue: before.source) ?? .cloud, confirmed: before.confirmed, sample: before.sample ?? before.name)
                info.domain = before.domain
                library.merchants[key] = info
            }
            for key in stillThere where library.merchants[key] == nil {
                var info = MerchantInfo(name: change.from, category: like?.category, source: .cloud, confirmed: false, sample: change.spelling ?? change.from)
                info.domain = like?.domain
                library.merchants[key] = info
            }
            var emptied: Set<String> = []
            for i in library.entries.indices {
                if let old = back[library.entries[i].id.uuidString], given == nil || library.entries[i].merchantKey == given {
                    emptied.insert(library.entries[i].merchantKey)
                    library.entries[i].merchantKey = old
                }
            }
            if let spelling = change.spelling { library.spellings?[spelling] = nil }
            let used = Set(library.entries.map(\.merchantKey))
            for key in emptied where !used.contains(key) { library.merchants[key] = nil }
        }
        book.changes.remove(at: index)
        for id in [change.pairID] + (change.morePairIDs ?? []) { book.judged[id] = -1 }
        library.tidy = book
        withAnimation(.snappy) { changed() }
        showToast("Put back. I won't do that one again.", symbol: "arrow.uturn.backward.circle.fill")
    }

    /// The list has been looked at: nothing in it is news any more.
    func markTidySeen() {
        guard var book = library.tidy, book.changes.contains(where: { $0.isNew ?? false }) else { return }
        for i in book.changes.indices { book.changes[i].isNew = false }
        library.tidy = book
        changed()
    }
}
