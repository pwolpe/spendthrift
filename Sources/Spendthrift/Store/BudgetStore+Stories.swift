import SwiftUI
import AppKit
import CryptoKit
import PDFKit
import UniformTypeIdentifiers

/// Trips and events: charges that belong together, found and named.
extension BudgetStore {
    // MARK: - Trips and events


    /// Trips and events, newest first, without the ones the person said weren't.
    var stories: [Story] {
        // Pages ask for these constantly; they only change when the library does.
        let stamp = [library.stories?.count ?? 0, library.storyChoices?.count ?? 0, library.storyNames?.count ?? 0, library.dismissedStories?.count ?? 0]
        if let kept = storyCache, kept.stamp == stamp { return kept.stories }
        let made = assembleStories()
        storyCache = (stamp, made)
        storyOfEntry = nil
        return made
    }

    private func assembleStories() -> [Story] {
        let dismissed = library.dismissedStories ?? []
        var list = (library.stories ?? []).filter { !dismissed.contains($0.fingerprint) }
        // A name given by hand goes back on whichever trip covers those days, however it was found this time.
        var taken: Set<Int> = []
        for given in library.storyNames ?? [] {
            func shared(_ s: Story) -> Int {
                guard let from = DateParsing.parse(max(s.start, given.start), format: "yyyy-MM-dd"),
                      let to = DateParsing.parse(min(s.end, given.end), format: "yyyy-MM-dd") else { return -1 }
                return (Calendar.current.dateComponents([.day], from: from, to: to).day ?? -1) + 1
            }
            let candidates = list.indices.filter { !taken.contains($0) && list[$0].kind == given.kind && shared(list[$0]) > 0 }
            guard let index = candidates.max(by: { shared(list[$0]) < shared(list[$1]) }) else { continue }
            taken.insert(index)
            list[index].name = given.name
            list[index].start = min(list[index].start, given.start)
            list[index].end = max(list[index].end, given.end)
        }
        // What the person moved by hand wins over what the model worked out.
        let choices = library.storyChoices ?? [:]
        guard !choices.isEmpty else { return list }
        let moved = Set(choices.keys.compactMap { UUID(uuidString: $0) })
        for i in list.indices { list[i].entryIDs.removeAll { moved.contains($0) } }
        for (key, choice) in choices {
            guard let id = UUID(uuidString: key), let index = Self.resolve(choice, in: list) else { continue }
            list[index].entryIDs.append(id)
        }
        return list
    }

    /// A choice remembers the trip's name and its dates. When the model looks again it may word the
    /// name differently ("Austin" becomes "Austin weekend"), so if the name is gone, the trip that
    /// shares the most days with the remembered dates is the same trip.
    static func choice(for story: Story) -> String { "\(story.fingerprint)\t\(story.start)\t\(story.end)" }
    private static func resolve(_ choice: String, in list: [Story]) -> Int? {
        let parts = choice.components(separatedBy: "\t")
        guard parts.count == 3, !parts[0].isEmpty else { return nil }
        if let exact = list.firstIndex(where: { $0.fingerprint == parts[0] }) { return exact }
        let overlaps = list.indices.filter { list[$0].start <= parts[2] && list[$0].end >= parts[1] }
        return overlaps.max { a, b in
            func shared(_ s: Story) -> Int {
                guard let from = DateParsing.parse(max(s.start, parts[1]), format: "yyyy-MM-dd"),
                      let to = DateParsing.parse(min(s.end, parts[2]), format: "yyyy-MM-dd") else { return 0 }
                return Calendar.current.dateComponents([.day], from: from, to: to).day ?? 0
            }
            return shared(list[a]) < shared(list[b])
        }
    }

    /// For tests: the names the person has given.
    var storyNamesForTest: [String] { (library.storyNames ?? []).map(\.name) }

    /// Gives a trip or event the person's own name. It stays through every later re-reading.
    func renameStory(_ story: Story, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != story.name else { return }
        var names = library.storyNames ?? []
        // One name per stretch of days: a new name for the same trip replaces the old one.
        names.removeAll { $0.kind == story.kind && $0.start <= story.end && $0.end >= story.start }
        names.append(StoryName(name: trimmed, kind: story.kind, start: story.start, end: story.end))
        library.storyNames = names
        withAnimation(.snappy) { changed() }
        showToast("Renamed to “\(trimmed)”. The name will stay.", symbol: "pencil.line")
    }

    func story(containing id: Transaction.ID) -> Story? {
        let all = stories
        if storyOfEntry == nil {
            var index: [UUID: Int] = [:]
            for (i, story) in all.enumerated() { for entry in story.entryIDs where index[entry] == nil { index[entry] = i } }
            storyOfEntry = index
        }
        return storyOfEntry?[id].flatMap { all.indices.contains($0) ? all[$0] : nil }
    }

    /// The trips and events a set of charges touches: those the charges belong to, and those whose
    /// days a charge falls in even though it was not counted as part of them.
    func stories(touching charges: [Transaction]) -> [(story: Story, charges: [Transaction], during: Bool)] {
        var part: [UUID: [Transaction]] = [:], during: [UUID: [Transaction]] = [:]
        let all = stories
        for t in charges {
            if let story = story(containing: t.id) { part[story.id, default: []].append(t); continue }
            let day = DateParsing.iso.string(from: t.date)
            if let story = all.first(where: { $0.kind == .trip && $0.start <= day && $0.end >= day }) { during[story.id, default: []].append(t) }
        }
        // A charge that merely fell on a day away says something only when most of the payee's charges
        // did: a hotel does, a gym membership that bills every month wherever you are does not.
        let away = part.values.reduce(0) { $0 + $1.count } + during.values.reduce(0) { $0 + $1.count }
        let countsDuring = away * 2 >= charges.count
        return all.compactMap { story in
            if let list = part[story.id] { return (story, list + (countsDuring ? during[story.id] ?? [] : []), false) }
            if countsDuring, let list = during[story.id] { return (story, list, true) }
            return nil
        }
    }

    /// Puts charges in a trip or event (or in none), whatever the model thought. Remembered for good.
    func move(_ ids: Set<Transaction.ID>, to story: Story?) {
        guard !ids.isEmpty else { return }
        var choices = library.storyChoices ?? [:]
        for id in ids { choices[id.uuidString] = story.map(Self.choice(for:)) ?? "" }
        library.storyChoices = choices
        changed()
        let what = ids.count == 1 ? (transactions.first { ids.contains($0.id) }?.merchant ?? "1 charge") : "\(ids.count) charges"
        showToast(story.map { "Moved \(what) to “\($0.name)”." } ?? "\(what): no longer part of a trip or event.", symbol: "checkmark.circle.fill")
    }

    func transactions(in story: Story) -> [Transaction] {
        transactions(withIDs: story.entryIDs)
    }

    func dismissStory(_ story: Story) {
        var dismissed = library.dismissedStories ?? []
        dismissed.insert(story.fingerprint)
        library.dismissedStories = dismissed
        if transactionFilter.storyID == story.id { transactionFilter.storyID = nil }
        withAnimation(.snappy) { changed() }
        showToast("Removed “\(story.name)”. Its charges are untouched.", symbol: "checkmark.circle.fill")
    }

    /// What the stories were last worked out from: when the data changes, look again.
    /// Work that may be owed from an earlier session (the app was quit mid-way, or a feature is
    /// new since the last import): look up the remaining guesses, then read for things to notice.
    func catchUp() async {
        guard CloudAI.isEnabled, !isImporting, !isSuggesting, !accounts.isEmpty else { return }
        await adoptWineCategory()
        await lookUpGuesses()
        await guessWhatTheyWere()
        await readCheckPictures()
        await findStoriesIfNeeded()
        await findDiscoveriesIfNeeded()
    }
}
