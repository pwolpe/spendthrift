import SwiftUI
import AppKit
import CryptoKit
import PDFKit
import UniformTypeIdentifiers

/// What the analyst noticed: findings read from the charges, for the month or year on screen.
extension BudgetStore {
    // MARK: - What the analyst noticed


    var discoveries: [Discovery] {
        let dismissed = library.dismissedDiscoveries ?? []
        let kept = (library.discoveries ?? []).filter { !dismissed.contains($0.title.lowercased()) }
        // One of each kind before a second of any: four double charges in a row read as one finding.
        var byKind: [String: [Discovery]] = [:], order: [String] = []
        for item in kept { if byKind[item.kind] == nil { order.append(item.kind) }; byKind[item.kind, default: []].append(item) }
        var mixed: [Discovery] = []
        while mixed.count < kept.count {
            for kind in order { if let next = byKind[kind]?.first { mixed.append(next); byKind[kind]?.removeFirst() } }
        }
        return mixed
    }

    func transactions(in discovery: Discovery) -> [Transaction] {
        let ids = Set(discovery.entryIDs)
        return transactions.filter { ids.contains($0.id) }
    }

    func dismissDiscovery(_ discovery: Discovery) {
        var dismissed = library.dismissedDiscoveries ?? []
        dismissed.insert(discovery.title.lowercased())
        library.dismissedDiscoveries = dismissed
        withAnimation(.snappy) { changed() }
    }

    func findDiscoveriesIfNeeded() async {
        guard CloudAI.isEnabled, !isFindingDiscoveries, !isImporting, !isSuggesting, let last = months.last else { return }
        // The last twelve months of real spending: recent enough to act on. Only a change inside
        // those months is a reason to read them again; an old statement added today is not.
        let start = last.adding(-11)
        let recentBasis = { () -> String in
            let recent = self.transactions.filter { $0.month >= start }
            return "\(start.key)|\(recent.count)|\(Int(recent.reduce(0) { $0 + abs($1.amount) }))"
        }
        let basis = recentBasis()
        guard library.discoveriesBasis != basis else { return }
        isFindingDiscoveries = true
        defer { isFindingDiscoveries = false }
        guard let found = await discover(in: transactions.filter { $0.month >= start }) else { return }
        guard recentBasis() == basis else { return }
        library.discoveries = found
        library.discoveriesBasis = basis
        withAnimation(.snappy) { changed() }
        if ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] != nil {
            for d in discoveries {
                let list = transactions(in: d)
                print("DEBUG NOTICED [\(d.kind)] \(d.title) | \(list.count) charges | \(Int(list.reduce(0) { $0 + $1.amount })) | \(d.detail)")
            }
        }
    }

    /// Has the analyst read one stretch of charges and say what stands out in it.
    func discover(in stretch: [Transaction]) async -> [Discovery]? {
        let recent = stretch.filter { !$0.isTransfer && !$0.isUnknown && $0.lane != .investments }.suffix(3_000)
        let lines = recent.map { t in
            StoryFinder.Line(id: t.id, date: DateParsing.iso.string(from: t.date),
                             text: t.note.map { "\(t.merchant) (\(Redactor.scrub(t.description))) [note: \(Redactor.scrub(String($0.prefix(120))))]" } ?? "\(t.merchant) (\(Redactor.scrub(t.description).prefix(40)))",
                             amount: t.amount, category: t.category.displayName)
        }
        guard let found = await Discoverer.find(lines, notes: allNotes(limit: 20)) else { return nil }
        return found.map { finding in
            Discovery(title: finding.title, detail: finding.detail, kind: finding.kind, entryIDs: finding.lines.map { lines[$0 - 1].id })
        }
    }

    // MARK: What was noticed in the month or year on screen


    /// Whether a month falls inside the rolling year the main list was worked out from.
    private func isRecent(_ month: Month) -> Bool { months.last.map { month >= $0.adding(-11) } ?? false }

    private func yearBasis(_ year: Int) -> String {
        let list = library.entries.filter { $0.date.hasPrefix(String(year)) }
        return "\(list.count)|\(Int(list.reduce(0) { $0 + abs($1.amount) }))"
    }

    /// What was noticed that touches this month or year, with only the charges that fall inside it.
    func noticed(in scope: NoticedScope) -> [(item: Discovery, charges: [Transaction])] {
        let dismissed = library.dismissedDiscoveries ?? []
        let source: [Discovery]
        let inside: (Transaction) -> Bool
        switch scope {
        case .last12:
            source = discoveries; inside = { _ in true }
        case .year(let year):
            source = library.discoveriesByYear?[String(year)]?.items ?? []
            inside = { $0.month.year == year }
        case .month(let month):
            source = isRecent(month) ? discoveries : (library.discoveriesByYear?[String(month.year)]?.items ?? [])
            inside = { $0.month == month }
        }
        let byID = Dictionary(transactions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return source.filter { !dismissed.contains($0.title.lowercased()) }.compactMap { item in
            let charges = item.entryIDs.compactMap { byID[$0] }.filter(inside)
            return charges.isEmpty ? nil : (item, charges)
        }
    }

    /// True while the year this scope depends on is still being read.
    func isReading(_ scope: NoticedScope) -> Bool {
        switch scope {
        case .last12: isFindingDiscoveries
        case .year(let year): readingYears.contains(year)
        case .month(let month): isRecent(month) ? isFindingDiscoveries : readingYears.contains(month.year)
        }
    }

    /// An earlier year is read the first time it is looked at, and kept.
    func readIfNeeded(_ scope: NoticedScope) async {
        let year: Int
        switch scope {
        case .last12: return
        case .year(let y): year = y
        case .month(let month):
            guard !isRecent(month) else { return }
            year = month.year
        }
        let basis = yearBasis(year)
        guard CloudAI.isEnabled, !isImporting, !readingYears.contains(year), library.discoveriesByYear?[String(year)]?.basis != basis else { return }
        readingYears.insert(year)
        defer { readingYears.remove(year) }
        guard let found = await discover(in: transactions.filter { $0.month.year == year }) else { return }
        var all = library.discoveriesByYear ?? [:]
        all[String(year)] = YearFindings(basis: basis, items: found)
        library.discoveriesByYear = all
        withAnimation(.snappy) { changed() }
        if ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] != nil {
            for d in found { print("DEBUG NOTICED \(year) [\(d.kind)] \(d.title) | \(d.entryIDs.count) charges | \(d.detail)") }
        }
    }

    var storiesBasis: String {
        "\(library.entries.count)|\(Int(library.entries.reduce(0) { $0 + abs($1.amount) }))"
    }

    /// What the trip finder reads: every charge that counts as spending.
    private func storyLines() -> [StoryFinder.Line] {
        transactions.filter { $0.countsAsSpending && !$0.isUnknown }.map { t in
            StoryFinder.Line(id: t.id, date: DateParsing.iso.string(from: t.date),
                             text: t.note.map { "\(Redactor.scrub(t.description)) [the person's note: \(Redactor.scrub(String($0.prefix(160))))]" } ?? Redactor.scrub(t.description),
                             amount: t.amount, category: t.category.displayName)
        }
    }
    nonisolated private static func basis(_ lines: [StoryFinder.Line]) -> String {
        "\(lines.count)|\(Int(lines.reduce(0) { $0 + abs($1.amount) }))"
    }

    func findStoriesIfNeeded() async {
        guard CloudAI.isEnabled, !isFindingStories, !isImporting, !isSuggesting else { return }
        let basis = storiesBasis
        // Trips found before the app kept track year by year: if they are up to date, note each
        // year as read, so the next statement added doesn't send every year again.
        if library.storyYears == nil, library.storiesBasis == basis, library.stories != nil {
            library.storyYears = Dictionary(grouping: storyLines(), by: { String($0.date.prefix(4)) }).mapValues(Self.basis)
            changed()
        }
        guard library.storiesBasis != basis else { return }
        isFindingStories = true
        defer { isFindingStories = false }
        let lines = storyLines()
        let before = Set(stories.map(\.fingerprint))
        if lines.count <= 3_500 {
            // A short history goes in one request, so a trip over New Year isn't cut in two.
            guard let found = await StoryFinder.find(lines) else { return }      // offline: try again next time
            guard storiesBasis == basis else { return }                          // more arrived meanwhile; a newer pass will run
            library.stories = found
            library.storyYears = Dictionary(grouping: lines, by: { String($0.date.prefix(4)) }).mapValues(Self.basis)
        } else {
            // A long history is read a calendar year at a time, and only the years whose spending
            // changed since they were last read. Adding old statements leaves the other years alone.
            let byYear = Dictionary(grouping: lines, by: { String($0.date.prefix(4)) })
            let known = library.storyYears ?? [:]
            let stale = byYear.filter { known[$0.key] != Self.basis($0.value) }.keys.sorted()
            var read: [String: [Story]] = [:]
            await withTaskGroup(of: (String, [Story]?).self) { group in
                var next = 0
                func start() { if next < stale.count { let year = stale[next]; next += 1; let list = byYear[year] ?? []; group.addTask { (year, await StoryFinder.find(list)) } } }
                for _ in 0..<3 { start() }
                for await (year, found) in group { if let found { read[year] = found }; start() }
            }
            // Keep what came back for a year only if that year still looks the way it did when it was sent.
            let now = Dictionary(grouping: storyLines(), by: { String($0.date.prefix(4)) })
            let fresh = read.filter { Self.basis(now[$0.key] ?? []) == Self.basis(byYear[$0.key] ?? []) }
            var yearOf: [UUID: String] = [:]
            for entry in library.entries { yearOf[entry.id] = String(entry.date.prefix(4)) }
            let kept = (library.stories ?? []).filter { story in !story.entryIDs.contains { fresh[yearOf[$0] ?? ""] != nil } }
            library.stories = (kept + fresh.values.flatMap { $0 }).sorted { $0.start > $1.start }
            var years = known.filter { now[$0.key] != nil }
            for year in fresh.keys { years[year] = Self.basis(byYear[year] ?? []) }
            library.storyYears = years
            if ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] != nil {
                print("DEBUG STORIES years read again: \(stale) of \(byYear.keys.sorted()); kept \(kept.count) trips from the others")
            }
            guard fresh.count == stale.count, storiesBasis == basis else { withAnimation(.snappy) { changed() }; return }   // the rest next time
        }
        library.storiesBasis = basis
        withAnimation(.snappy) { changed() }
        if let fresh = stories.first(where: { !before.contains($0.fingerprint) }), !before.isEmpty || stories.count == 1 {
            Notifier.post(title: fresh.kind == .trip ? "I noticed a trip" : "I noticed something",
                          body: "\(fresh.name): \(Money.format(transactions(in: fresh).reduce(0) { $0 + $1.amount }, cents: false)) across \(fresh.entryIDs.count) charges.")
        }
    }
}
