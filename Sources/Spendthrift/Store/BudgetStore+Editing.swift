import SwiftUI
import AppKit
import CryptoKit
import PDFKit
import UniformTypeIdentifiers

/// Changes made by hand: categories, payees, notes, and the person's own categories.
extension BudgetStore {
    // MARK: - Changing categories by hand

    /// - wholePlace: true changes every charge from that place, now and in future (the usual case).
    func setCategory(_ category: Category, for ids: Set<UUID>, wholePlace: Bool) {
        let chosen = transactions.filter { ids.contains($0.id) }
        guard !chosen.isEmpty else { return }
        if wholePlace {
            let keys = Set(chosen.map(\.merchantKey))
            for key in keys {
                library.merchants[key]?.category = category
                library.merchants[key]?.source = .user
                library.merchants[key]?.confirmed = true
            }
            for i in library.entries.indices where keys.contains(library.entries[i].merchantKey) { library.entries[i].override = nil }
            let name = keys.count == 1 ? chosen[0].merchant : "\(keys.count) payees"
            showToast("\(name) is now \(category.displayName), every time.", symbol: category.symbol)
            learnFromCorrection()
        } else {
            for i in library.entries.indices where ids.contains(library.entries[i].id) { library.entries[i].override = category }
            showToast(ids.count == 1 ? "Just this one is now \(category.displayName)." : "\(ids.count) charges are now \(category.displayName).",
                      symbol: category.symbol)
        }
        withAnimation(.snappy) { changed() }
    }

    func setCategory(_ category: Category, forPlace key: String) {
        guard library.merchants[key] != nil else { return }
        library.merchants[key]?.category = category
        library.merchants[key]?.source = .user
        library.merchants[key]?.confirmed = true
        for i in library.entries.indices where library.entries[i].merchantKey == key { library.entries[i].override = nil }
        withAnimation(.snappy) { changed() }
        learnFromCorrection()
    }

    /// Tony just taught the app something. A few seconds later (in case he's changing several),
    /// the model takes another look at its remaining guesses with his choices as fresh examples.
    private func learnFromCorrection() {
        guard CloudAI.isEnabled else { return }
        relearnTask?.cancel()
        relearnTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            let guesses = library.merchants.filter { !$0.value.confirmed && $0.value.source == .cloudGuess }.map(\.key)
            guard !guesses.isEmpty else { return }
            relearnKeys.formUnion(guesses)
            cloudAttempted.subtract(guesses)
            await sortRemaining()
        }
    }

    /// "Looks right": keeps the AI's guess and stops asking about it.
    func confirm(_ keys: [String]) {
        for key in keys where library.merchants[key]?.category != nil { library.merchants[key]?.confirmed = true }
        withAnimation(.snappy) { changed() }
    }

    /// What the person wrote about a place, if anything.
    func note(forPlace name: String) -> String {
        library.merchants.values.first { $0.name == name && !($0.note ?? "").isEmpty }?.note ?? ""
    }

    /// Saves a note about a place. If the place is still a guess, the note is the person saying
    /// what it is, so it is acted on; either way the estimate of what's coming is worked out again.
    func setNote(_ text: String, forPlace name: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard note(forPlace: name) != trimmed else { return }
        let keys = library.merchants.filter { $0.value.name == name }.map(\.key)
        for key in keys { library.merchants[key]?.note = trimmed.isEmpty ? nil : trimmed }
        changed()
        Forecaster.forget()
        if !trimmed.isEmpty, CloudAI.isEnabled, let guess = keys.first(where: { library.merchants[$0]?.confirmed == false }) {
            Task { await explain(guess, said: trimmed) }
        }
    }

    /// Every note the person has written, about places and about single charges: what the model
    /// should know before it answers a question or estimates what's coming.
    func allNotes(limit: Int = 40) -> [String] {
        var lines: [String] = []
        var seen: Set<String> = []
        for info in library.merchants.values {
            if let note = info.note, !note.isEmpty, seen.insert(info.name).inserted { lines.append("\(info.name): \(note)") }
        }
        for t in transactions.reversed() {
            if let note = t.note, !note.isEmpty {
                lines.append("\(t.merchant), \(DateParsing.iso.string(from: t.date)), \(Money.format(t.amount)): \(note)")
            }
            if lines.count >= limit { break }
        }
        return Array(lines.prefix(limit))
    }


    /// "It was my accountant, for tax prep": in one step, files the place where that belongs (making
    /// a category if none fits), gives it a name that says what it is, and keeps the words as a note.
    /// Returns false if it couldn't be worked out, so the caller can fall back to the category menu.
    @discardableResult
    func explain(_ key: String, said text: String) async -> Bool {
        let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !said.isEmpty, let info = library.merchants[key], !explaining.contains(key) else { return false }
        // The words are kept either way.
        for i in library.entries.indices where library.entries[i].merchantKey == key && (library.entries[i].note ?? "").isEmpty {
            library.entries[i].note = said
        }
        changed()
        guard CloudAI.isEnabled else { return false }
        explaining.insert(key)
        defer { explaining.remove(key) }
        let amounts = library.entries.filter { $0.merchantKey == key }.map(\.amount)
        let typical = amounts.isEmpty ? 0 : amounts.reduce(0, +) / Double(amounts.count)
        guard let verdict = await Explainer.decide(statementText: info.sample, currentName: info.name, amount: typical, said: said) else { return false }
        var category = Category.pickable.first { $0.rawValue == verdict.category }
        var made = false
        if category == nil {
            let symbol = verdict.symbol.flatMap { CustomCategory.symbols.contains($0) ? $0 : nil } ?? "tag.fill"
            let color = CustomCategory.palette[(customCategories.count * 5 + 3) % CustomCategory.palette.count].name
            category = saveCategory(CustomCategory(name: verdict.category, symbol: symbol, color: color))
            made = category != nil
        }
        guard let category else { return false }
        library.merchants[key]?.name = verdict.name
        setCategory(category, forPlace: key)
        showToast(made ? "Filed \(verdict.name) under a new category, \(category.displayName)." : "Filed \(verdict.name) under \(category.displayName).",
                  symbol: "checkmark.circle.fill")
        return true
    }

    /// Returns places to the Double-Check list (used by the test pictures, which confirm everything briefly).
    func unconfirm(_ keys: [String]) {
        for key in keys where library.merchants[key]?.source != .user { library.merchants[key]?.confirmed = false }
        changed()
    }

    func renamePlace(_ key: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, library.merchants[key] != nil, library.merchants[key]?.name != trimmed else { return }
        library.merchants[key]?.name = trimmed
        changed()
    }

    func place(_ key: String) -> MerchantInfo? { library.merchants[key] }

    /// One charge that isn't what the rest of its group is (a wire among wires, a check among checks):
    /// it becomes its own payee, with the name and category the person gives it. The others stay put.
    func setPayee(of id: Transaction.ID, name: String, category: Category?) {
        guard let info = moveToOwnPayee([id], name: name, category: category)?.info else { return }
        showToast("That one is now \(info.name)\(info.category.map { ", filed under \($0.displayName)" } ?? ""). The rest are unchanged.", symbol: "person.crop.circle.badge.checkmark")
    }

    /// One way a payee is written turns out to be someone else (a hotel gathered under a streaming
    /// service of the same name). Every charge written that way moves to its own payee, and so does
    /// any that arrives later.
    func separate(spelling: String, from payee: String, as name: String, category: Category?) {
        let ids = Set(transactions.filter { $0.merchant == payee && MerchantResolver.spelling($0.description) == spelling }.map(\.id))
        guard let moved = moveToOwnPayee(ids, name: name, category: category) else { return }
        library.spellings = (library.spellings ?? [:]).merging([spelling.uppercased(): moved.key]) { _, new in new }
        changed()
        showToast("\(ids.count == 1 ? "1 charge is" : "\(ids.count) charges are") now \(moved.info.name). Lines written that way will go there from now on.", symbol: "arrow.triangle.branch")
    }

    /// Moves charges out of whatever payee they were gathered under into one of their own.
    /// A name that is already a payee joins that payee, and takes its category unless one is given.
    private func moveToOwnPayee(_ ids: Set<Transaction.ID>, name: String, category: Category?) -> (key: String, info: MerchantInfo)? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let indices = library.entries.indices.filter { ids.contains(library.entries[$0].id) }
        guard !trimmed.isEmpty, let first = indices.first else { return nil }
        let entry = library.entries[first]
        let old = library.merchants[entry.merchantKey]
        let existing = library.merchants.first { $0.value.name.caseInsensitiveCompare(trimmed) == .orderedSame && $0.key != entry.merchantKey }?.value
        let key = "own:" + UUID().uuidString
        var info = MerchantInfo(name: existing?.name ?? trimmed, category: category ?? existing?.category ?? old?.category,
                                source: .user, confirmed: true, sample: entry.description)
        info.domain = existing?.domain
        library.merchants[key] = info
        for i in indices {
            library.entries[i].merchantKey = key
            library.entries[i].override = nil
        }
        pruneUnusedPlaces()
        withAnimation(.snappy) { changed() }
        return (key, info)
    }

    /// Saves what the person remembers about one charge. If the place is still a guess, the note is
    /// reason enough to have the model look at it again.
    func setNote(_ text: String, for id: Transaction.ID) {
        guard let i = library.entries.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (library.entries[i].note ?? "") != trimmed else { return }
        library.entries[i].note = trimmed.isEmpty ? nil : trimmed
        let key = library.entries[i].merchantKey
        changed()
        // A note on a place that is still a guess is the person telling us what it was: act on it.
        if !trimmed.isEmpty, library.merchants[key]?.confirmed == false, CloudAI.isEnabled {
            Task { await explain(key, said: trimmed) }
        }
    }

    func transactions(matching f: TransactionFilter) -> [Transaction] {
        var list = transactions
        if let c = f.category { list = list.filter { $0.category == c } }
        if let m = f.month { list = list.filter { $0.month == m } }
        if let a = f.accountID { list = list.filter { $0.accountID == a } }
        if let k = f.merchantKey { list = list.filter { $0.merchantKey == k } }
        if let name = f.merchant { list = list.filter { $0.merchant == name } }
        if let s = f.storyID, let story = stories.first(where: { $0.id == s }) {
            let ids = Set(story.entryIDs)
            list = list.filter { ids.contains($0.id) }
        }
        if let ids = f.ids { list = list.filter { ids.contains($0.id) } }
        if f.needsCheck { list = list.filter(\.needsCheck) }
        return list
    }

    /// Opens the page for one place: everything ever spent there.
    /// A charge from this same day in an earlier year, worth being reminded of: the largest that
    /// wasn't a bill or a subscription.
    func onThisDay(_ today: Date = .now) -> (years: Int, charge: Transaction)? {
        let cal = Calendar.current
        let now = cal.dateComponents([.year, .month, .day], from: today)
        let routine = Set(subscriptions().map(\.merchant))
        var best: (years: Int, charge: Transaction)?
        for t in transactions where t.countsAsSpending && t.amount >= 15 {
            let c = cal.dateComponents([.year, .month, .day], from: t.date)
            guard c.month == now.month, c.day == now.day, let year = c.year, let thisYear = now.year, year < thisYear,
                  !routine.contains(t.merchant), ![Category.home, .bills, .fees].contains(t.category) else { continue }
            if best == nil || t.amount > best!.charge.amount { best = (thisYear - year, t) }
        }
        return best
    }

    /// Two names for one business: everything filed under `other` becomes part of `name` from now on.
    func combinePlaces(_ other: String, into name: String) {
        let target = library.merchants.values.first { $0.name == name }
        var moved = 0
        for (key, info) in library.merchants where info.name == other {
            library.merchants[key]?.name = name
            if let category = target?.category { library.merchants[key]?.category = category }
            library.merchants[key]?.domain = target?.domain ?? info.domain
            library.merchants[key]?.source = .user
            library.merchants[key]?.confirmed = true
            moved += 1
        }
        guard moved > 0 else { return }
        withAnimation(.snappy) { changed() }
        showToast("“\(other)” is now part of \(name).", symbol: "checkmark.circle.fill")
    }

    // MARK: - Tony's own categories

    var customCategories: [CustomCategory] { library.customCategories ?? [] }

    /// Opens the "New Category" sheet; `then` gets the new category (e.g. to apply it right away).
    func newCategory(then: @escaping (Category) -> Void = { _ in }) {
        categoryEditor = CategoryEditorRequest(editing: nil, then: then)
    }

    func isCategoryNameTaken(_ name: String, except id: UUID? = nil) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        if Category.allCases.contains(where: { $0.isBuiltIn && ($0.rawValue.lowercased() == n || $0.displayName.lowercased() == n) }) { return true }
        return customCategories.contains { $0.id != id && $0.name.lowercased() == n }
    }

    /// Creates a category, or updates one (renaming moves everything filed under the old name).
    @discardableResult
    func saveCategory(_ category: CustomCategory) -> Category? {
        var c = category
        c.name = c.name.trimmingCharacters(in: .whitespaces)
        guard !c.name.isEmpty, !isCategoryNameTaken(c.name, except: c.id) else { return nil }
        var list = customCategories
        if let i = list.firstIndex(where: { $0.id == c.id }) {
            let old = Category(list[i].name)
            list[i] = c
            if old.rawValue != c.name { refile(from: old, to: Category(c.name)) }
        } else {
            list.append(c)
        }
        library.customCategories = list
        CustomCategories.set(list)
        aiAttempted.removeAll()   // the AI may now have a better home for unsorted places
        withAnimation(.snappy) { changed() }
        return Category(c.name)
    }

    /// Deletes a custom category; anything filed there goes to "Other".
    func deleteCategory(_ category: CustomCategory) {
        refile(from: Category(category.name), to: .other)
        let list = customCategories.filter { $0.id != category.id }
        library.customCategories = list
        CustomCategories.set(list)
        if transactionFilter.category == Category(category.name) { transactionFilter.category = nil }
        withAnimation(.snappy) { changed() }
        showToast("Deleted \(category.name). Its charges moved to Other.", symbol: "trash.fill")
    }

    private func refile(from old: Category, to new: Category) {
        for key in library.merchants.keys where library.merchants[key]?.category == old { library.merchants[key]?.category = new }
        for i in library.entries.indices where library.entries[i].override == old { library.entries[i].override = new }
    }

    /// All-time totals per category, for the Categories screen.
    func categorySummary() -> [(category: Category, total: Double, count: Int)] {
        let groups = Dictionary(grouping: transactions, by: \.category)
        return Category.allCases.map { c in
            let list = groups[c] ?? []
            return (c, list.reduce(0) { $0 + abs($1.amount) * ($1.amount < 0 && c.isSpending ? -1 : 1) }, list.count)
        }
    }
}
