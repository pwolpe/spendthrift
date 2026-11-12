import Foundation
import PDFKit
import AppKit
import Observation

// MARK: - Noticing trips and events

/// Nothing in a statement says "trip". But a flight, then a week of charges in another country,
/// then a flight home, is a story anyone would recognize. The model finds those runs; the app
/// adds up what they cost.
enum StoryFinder {
    struct Line: Sendable {
        let id: UUID
        let date: String
        let text: String
        let amount: Double
        let category: String
    }

    private static let system = """
    You are looking at a person's card and bank spending, one transaction per line:
    number | date | merchant text (often ends with a city and state or country) | amount | category

    Work out where home is (where most everyday purchases happen). Then find:

    1. TRIPS: travel away from home. A trip is a run of days with spending in another city, state or country, \
    plus the flights, trains, hotels, rental cars and tours that belong to it even when they were paid weeks earlier. \
    One trip per journey; if several places were visited on one journey, it is one trip.
    2. EVENTS: a cluster of unusual, related spending that is clearly one occasion or project, such as a wedding, a big party, \
    a move, a renovation, or a medical episode. Be conservative: ordinary life is not an event.

    Do not include everyday spending at home, commuting, regular subscriptions, or single purchases. \
    Only include a transaction when you are reasonably sure it belongs. A weekend away with two or three charges still counts as a trip.
    A booking paid in advance belongs to the trip it was for, not to whichever trip was under way when it was paid: \
    a tour operator, outfitter, lodge or airline whose name or location points to one destination goes with the trip to \
    that destination (an Andes trekking company belongs to the Peru trip even if it was charged during a trip to \
    Italy months earlier). If a large travel charge doesn't fit the destination of the dates around it, look for the \
    trip it does fit; if there is none, leave it out.

    For each one give:
    - kind: "trip" or "event"
    - name: short and natural, like "Mongolia", "Las Vegas weekend", "Ireland and Northern Ireland", "Kitchen renovation"
    - place: the main place (city, region or country), or null for an event with no particular place
    - start and end: YYYY-MM-DD, the days actually away (or the span of the event), not the booking dates
    - summary: one warm, specific sentence about what the spending shows. Do not mention any amounts.
    - lines: the numbers of every transaction that belongs to it

    Reply with JSON only: {"home": "...", "stories": [{"kind": "trip", "name": "", "place": "", "start": "", "end": "", "summary": "", "lines": [1, 2]}]}
    """

    /// Nil when the cloud couldn't be used. Each transaction lands in at most one story.
    static func find(_ lines: [Line]) async -> [Story]? {
        guard CloudAI.isEnabled, lines.count >= 20 else { return [] }
        // Everything in one request when it fits (a holiday trip shouldn't be cut in two at New Year);
        // only a very long history is split, a calendar year at a time.
        var stories: [Story] = []
        var used: Set<UUID> = []
        let groups: [(key: String, value: [Line])] = lines.count <= 3_500
            ? [("all", lines)]
            : Dictionary(grouping: lines, by: { String($0.date.prefix(4)) }).sorted(by: { $0.key < $1.key })
        for (_, year) in groups {
            let numbered = year.sorted { $0.date < $1.date }
            let listing = numbered.enumerated().map { i, l in
                "\(i + 1) | \(l.date) | \(String(Redactor.scrub(l.text).prefix(60))) | \(String(format: "%.2f", l.amount)) | \(l.category)"
            }.joined(separator: "\n")
            let reply = await Timeout.run(600) {
                try? await CloudAI.complete(job: "Finding trips", system: system, user: listing, json: true, maxTokens: 64_000, timeout: 590, effort: "medium")
            }
            if ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] != nil {
                print("DEBUG STORIES sent \(numbered.count) lines (\(listing.count) chars); reply \(reply?.count ?? -1) chars; ends: \(String((reply ?? "").suffix(80)).replacingOccurrences(of: "\n", with: " "))")
            }
            guard let reply, let found = CloudAI.object(from: reply)?["stories"] as? [[String: Any]] else { return nil }
            for item in found {
                guard let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                      let numbers = item["lines"] as? [Any] else { continue }
                let ids = numbers.compactMap { ($0 as? Int) ?? ($0 as? String).flatMap(Int.init) }
                    .filter { (1...numbered.count).contains($0) }
                    .map { numbered[$0 - 1].id }
                    .filter { used.insert($0).inserted }
                guard ids.count >= 2 else { continue }
                let dates = numbered.filter { ids.contains($0.id) }.map(\.date).sorted()
                let valid = { (s: Any?) -> String? in
                    guard let s = s as? String, DateParsing.parse(s, format: "yyyy-MM-dd") != nil else { return nil }
                    return String(s.prefix(10))
                }
                stories.append(Story(kind: (item["kind"] as? String) == "event" ? .event : .trip,
                                     name: String(name.prefix(60)),
                                     place: (item["place"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                     start: valid(item["start"]) ?? dates.first ?? "", end: valid(item["end"]) ?? dates.last ?? "",
                                     summary: ((item["summary"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                     entryIDs: ids))
            }
        }
        return stories.sorted { $0.start > $1.start }
    }
}
