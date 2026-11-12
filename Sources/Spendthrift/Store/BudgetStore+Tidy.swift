import SwiftUI

/// Acting on what `TidyEngine` finds: asking a decision model about each pair once, combining and
/// separating payees when it is sure, and keeping a record that can be shown and undone.
extension BudgetStore {
    /// The model that judges pairs. Chosen by measurement on a real library (it called real
    /// duplicates "the same" with high confidence and almost never a wrong pair).
    static let tidyModel = "google/gemini-decision-1"

    /// What was tidied automatically, newest first.
    var tidyChanges: [TidyChange] { (library.tidy?.changes ?? []).reversed() }
    var newTidyChanges: [TidyChange] { tidyChanges.filter { $0.isNew ?? false } }

    /// Looks for payees to combine or separate, and does it where the model is sure. Each pair is
    /// asked about once, ever; after the first pass this costs nothing unless new payees arrive.
    func tidyIfNeeded() async {
        guard CloudAI.isEnabled, !isTidying, !isImporting, !isSuggesting else { return }
        isTidying = true
        defer { isTidying = false }
        let byHand = Set(library.merchants.values.filter { $0.source == .user }.map(\.name))
        let spellings = TidyEngine.spellings(of: transactions, byHand: byHand)
        let pairs = TidyEngine.pairs(in: spellings, alreadyJudged: Set((library.tidy?.judged ?? [:]).keys))
        guard !pairs.isEmpty else { return }
        let states = Dictionary(pairs.map { ($0.id, TidyEngine.state(for: $0)) }, uniquingKeysWith: { first, _ in first })
        let answers = await Decisions.askAll(job: "Tidying payees", model: Self.tidyModel, states: states, questions: ["same": TidyEngine.sameBusiness])
        guard !answers.isEmpty, !isImporting else { return }

        let ranked = pairs.compactMap { pair in answers[pair.id]?["same"]?.yes.map { (pair, $0) } }
        let done = await applyTidy(ranked)
        if ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] != nil {
            print("TIDY asked about \(pairs.count) pairs, \(answers.count) answered, \(done.count) acted on, \(library.tidy?.suggestions?.count ?? 0) offered")
            for change in done { print("TIDY DONE \(sentence(for: change)) (\(change.charges) charges)") }
            for s in library.tidy?.suggestions ?? [] { print("TIDY OFFER \(s.a) = \(s.b)?") }
        }
        guard !done.isEmpty else { return }
        let charges = done.reduce(0) { $0 + $1.charges }
        showToast(done.count == 1 ? "\(sentence(for: done[0])). It can be undone on the Payees page."
                                  : "Tidied \(done.count) payees (\(charges) charges). See what changed on the Payees page.", symbol: "wand.and.stars")
        // Payees that were split off have only the statement's words for a name: have them named and filed properly.
        Task { await sortRemaining() }
    }

    /// Acts on pairs that have been judged: `probability` is how likely each is one business.
    /// Returns what was done. Separate from the asking so it can be checked without a model.
    @discardableResult
    func applyTidy(_ judged: [(pair: TidyEngine.Pair, probability: Double)]) async -> [TidyChange] {
        var book = library.tidy ?? TidyBook()
        var done: [TidyChange] = []
        var offered = book.suggestions ?? []
        let recurring = Set(recurring().filter(\.isActive).map(\.merchant))
        // The surest first, so a later, weaker pair never undoes what a stronger one settled.
        let ranked = judged.sorted { abs($0.probability - 0.5) > abs($1.probability - 0.5) }
        func record(_ change: TidyChange?) {
            guard let change else { return }
            // Several spellings moved to the one payee are one thing to tell the person about.
            if let i = done.firstIndex(where: { $0.kind == change.kind && $0.from == change.from && $0.otherKey == change.otherKey && change.otherKey != nil }) {
                done[i].charges += change.charges
                done[i].moved = (done[i].moved ?? [:]).merging(change.moved ?? [:]) { first, _ in first }
                done[i].morePairIDs = (done[i].morePairIDs ?? []) + [change.pairID]
            } else { done.append(change) }
        }
        for (pair, probability) in ranked {
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
        let byHand = Set(library.merchants.values.filter { $0.source == .user }.map(\.name))
        let spellings = TidyEngine.spellings(of: transactions, byHand: byHand)
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
        guard keep.payee != fold.payee, let target = library.merchants.values.first(where: { $0.name == keep.payee }) else { return nil }
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
        let existing = library.merchants.first { $0.value.name.caseInsensitiveCompare(name) == .orderedSame }
        let keysOfPayee = Set(library.merchants.filter { $0.value.name == payee }.map(\.key))
        let indices = library.entries.indices.filter {
            keysOfPayee.contains(library.entries[$0].merchantKey) && MerchantResolver.spelling(library.entries[$0].description).uppercased() == spelling.text
        }
        guard !indices.isEmpty else { return nil }
        // An "own:" payee made earlier for the same name takes these too; otherwise a new one is made.
        let key = existing.flatMap { $0.key.hasPrefix("own:") ? $0.key : nil } ?? "own:" + UUID().uuidString
        if library.merchants[key] == nil {
            var info = MerchantInfo(name: existing?.value.name ?? name, category: existing?.value.category, source: existing == nil ? .ai : .cloud,
                                    confirmed: false, sample: spelling.sample)
            info.domain = existing?.value.domain
            library.merchants[key] = info
        }
        var moved: [String: String] = [:]
        for i in indices {
            moved[library.entries[i].id.uuidString] = library.entries[i].merchantKey
            library.entries[i].merchantKey = key
            library.entries[i].override = nil
        }
        library.spellings = (library.spellings ?? [:]).merging([spelling.text: key]) { _, new in new }
        return TidyChange(kind: .separate, day: DateParsing.iso.string(from: .now), from: payee, other: library.merchants[key]?.name ?? name,
                          charges: indices.count, pairID: pairID, otherKey: key, moved: moved, spelling: spelling.text)
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
            var emptied: Set<String> = []
            for i in library.entries.indices {
                if let old = back[library.entries[i].id.uuidString] {
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
