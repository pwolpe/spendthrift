import Foundation
import PDFKit
import AppKit

/// Which models should the app be using? `scripts/bench-models.sh` runs this and prints the answer.
///
/// Every model in `Models` is put through the jobs it does in the app, beside the newest models that
/// could replace it, on the same cases at the same moment. Each case has an answer that no model
/// supplied: a category the person chose or the built-in list knows, a statement whose lines tie to
/// its own printed totals, a trip planted in a made-up household (`scripts/bench-data.py`), a figure
/// added up in code. Quality comes first; cost and speed only settle a tie.
///
/// The rules that turn scores into "keep" or "switch" are plain functions at the top of this file,
/// and `SelfTest` checks them, so the verdict is the same whoever reads the table.
enum ModelBench {

    // MARK: - The rules (no model, no data: checked offline)

    enum Standing: String { case better, same, worse }

    struct Comparison {
        let standing: Standing
        /// The candidate's score less the current model's, averaged over the cases (1 = a whole case).
        let difference: Double
        /// How large a difference has to be before it is more than luck on this many cases.
        let margin: Double
    }

    /// One model against another on the same cases. A case a model gave no answer to scores nothing.
    /// A difference counts only beyond two standard errors (and at least a point): on a hundred
    /// cases two models that are equally good routinely land a few apart.
    static func compare(_ candidate: [String: Double], with current: [String: Double]) -> Comparison {
        let keys = Set(candidate.keys).union(current.keys)
        guard keys.count >= 2 else { return Comparison(standing: .same, difference: 0, margin: 1) }
        let gaps = keys.map { (candidate[$0] ?? 0) - (current[$0] ?? 0) }
        let n = Double(gaps.count), mean = gaps.reduce(0, +) / n
        let spread = (gaps.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / (n - 1)).squareRoot()
        let margin = max(2 * spread / n.squareRoot(), 0.01)
        return Comparison(standing: mean > margin ? .better : mean < -margin ? .worse : .same, difference: mean, margin: margin)
    }

    /// How well a set of found trips matches the planted ones. `answers` is every charge's answer
    /// (see `scripts/bench-data.py`); `found` is the charges of each trip or event a model reported.
    ///
    /// Each planted trip scores how completely and how cleanly the best-matching found trip covers it
    /// (F1: a trip split in two, or padded with ordinary charges, scores less). Each kind of bait
    /// scores the share of it left alone. One more case scores inventing trips out of ordinary life.
    static func tripScores(answers: [UUID: String], found: [[UUID]]) -> [String: Double] {
        var planted: [String: Set<UUID>] = [:], bait: [String: Set<UUID>] = [:]
        for (id, answer) in answers where !answer.isEmpty && answer != "?" {
            if answer.hasPrefix("!") { bait[String(answer.dropFirst()), default: []].insert(id) } else { planted[answer, default: []].insert(id) }
        }
        // Charges that could fairly go either way are scored nowhere.
        let stories = found.map { Set($0.filter { answers[$0] != "?" }) }.filter { !$0.isEmpty }
        var scores: [String: Double] = [:]
        var freeStories = Set(stories.indices), freeTrips = Set(planted.keys)
        while true {
            var best: (trip: String, story: Int, shared: Int)?
            for trip in freeTrips.sorted() { for story in freeStories.sorted() {
                let shared = planted[trip]?.intersection(stories[story]).count ?? 0
                if shared > (best?.shared ?? 0) { best = (trip, story, shared) }
            } }
            guard let match = best else { break }
            scores[match.trip] = 2 * Double(match.shared) / Double((planted[match.trip]?.count ?? 0) + stories[match.story].count)
            freeTrips.remove(match.trip); freeStories.remove(match.story)
        }
        for trip in freeTrips { scores[trip] = 0 }
        let taken = stories.reduce(into: Set<UUID>()) { $0.formUnion($1) }
        for (name, ids) in bait { scores["left alone: " + name] = 1 - Double(ids.intersection(taken).count) / Double(ids.count) }
        let everyTripCharge = planted.values.reduce(into: Set<UUID>()) { $0.formUnion($1) }
        let invented = freeStories.filter { stories[$0].isDisjoint(with: everyTripCharge) && stories[$0].filter { answers[$0] == "" }.count >= 2 }.count
        scores["nothing invented"] = max(0, 1 - 0.25 * Double(invented))
        return scores
    }

    /// A model that might take over a job, as it stands against the model doing the job now.
    struct Entrant {
        let model: String
        /// Job name to how it did there against the current model.
        var standings: [String: Standing] = [:]
        /// Its average lead over the current model across the jobs (in cases won).
        var gain = 0.0
        /// What the same work cost, as a multiple of the current model (1 = the same), and how long it took
        /// on the jobs someone sits and waits for.
        var cost = 1.0
        var time = 1.0
    }

    struct Choice {
        /// The model to use: the current one unless something earned its place.
        let model: String
        /// Why each entrant was or was not chosen, in a few words.
        var reasons: [String: String] = [:]
    }

    /// Twice the price is the most a better model may cost; a model that is only as good has to be a
    /// fifth cheaper (and no more than a fifth slower where someone is waiting: the app should feel
    /// quick before it is cheap), or three tenths faster (and no dearer), to be worth a change.
    static let dearestWorthIt = 2.0, cheaperBy = 0.8, notSlowerThan = 1.2, fasterBy = 0.7, notDearerThan = 1.1

    /// Keep or switch. Quality decides: a model worse at any job is out, however cheap. Among the rest
    /// a better one wins (the largest lead; the cheaper on a tie). If none is better, the cheapest
    /// wins when it is clearly cheaper, else the fastest when it is clearly faster, else nothing changes.
    /// `allowed` rules models out for reasons that are not about quality (see the second reader).
    static func choose(current: String, entrants: [Entrant], allowed: (String) -> Bool = { _ in true }) -> Choice {
        var choice = Choice(model: current)
        func times(_ x: Double) -> String { String(format: x >= 9.95 ? "%.0fx" : x < 0.095 ? "%.2fx" : "%.1fx", x) }
        var better: [Entrant] = [], cheaper: [Entrant] = [], faster: [Entrant] = []
        for e in entrants {
            let worse = e.standings.filter { $0.value == .worse }.keys.sorted()
            let wins = e.standings.filter { $0.value == .better }.keys.sorted()
            let price = "costs \(times(e.cost)), takes \(times(e.time)) as long where you wait"
            if !allowed(e.model) { choice.reasons[e.model] = "no: from the same maker as the writing model"; continue }
            if !worse.isEmpty { choice.reasons[e.model] = "no: worse at \(worse.joined(separator: ", "))"; continue }
            if !wins.isEmpty {
                if e.cost > dearestWorthIt { choice.reasons[e.model] = "no: better at \(wins.joined(separator: ", ")), but \(price)" }
                else { better.append(e); choice.reasons[e.model] = "better at \(wins.joined(separator: ", ")); \(price)" }
            } else if e.cost <= cheaperBy, e.time <= notSlowerThan {
                cheaper.append(e); choice.reasons[e.model] = "as good; \(price)"
            } else if e.time <= fasterBy, e.cost <= notDearerThan {
                faster.append(e); choice.reasons[e.model] = "as good; \(price)"
            } else { choice.reasons[e.model] = "no: as good, but \(price)" }
        }
        let winner = better.max { ($0.gain, -$0.cost, $1.model) < ($1.gain, -$1.cost, $0.model) }
            ?? cheaper.min { ($0.cost, $0.model) < ($1.cost, $1.model) }
            ?? faster.min { ($0.time, $0.model) < ($1.time, $1.model) }
        if let winner {
            choice = Choice(model: winner.model, reasons: choice.reasons)
            choice.reasons[winner.model] = "SWITCH: " + (choice.reasons[winner.model] ?? "")
            for other in better + cheaper + faster where other.model != winner.model {
                choice.reasons[other.model] = "no: \(winner.model.split(separator: "/").last ?? "another") did better (\(choice.reasons[other.model] ?? ""))"
            }
        } else if !allowed(current) {
            // The current model may not stay (it shares a maker with the new writing model): the best of the
            // rest that is no worse takes over, cheapest first.
            let rest = entrants.filter { allowed($0.model) && !$0.standings.values.contains(.worse) }
            if let next = rest.min(by: { ($0.cost, $0.model) < ($1.cost, $1.model) }) {
                choice = Choice(model: next.model, reasons: choice.reasons)
                choice.reasons[next.model] = "SWITCH: the current one shares a maker with the writing model; this is as good and from another"
            }
        }
        return choice
    }

    /// A model as OpenRouter lists it.
    struct Listed {
        let id: String
        /// Seconds since 1970.
        let created: Double
        /// Dollars per million tokens read.
        let price: Double
        var maker: String { String(id.split(separator: "/").first ?? "") }
    }

    /// Which listed models are worth trying in place of `current`: from each maker on the list, the
    /// two newest that cost about the same (half to twice the price) and the newest that costs less.
    /// Nothing dearer than twice the price, nothing that came out more than 120 days ago, and from the
    /// current model's own maker only what came out after it. Variants (":batch", ":free", "~latest"
    /// pointers) are left out, as is a model named like another with something added at the same
    /// price ("x-pro" beside "x"): the plain one stands for both.
    static func candidates(for current: Listed, among listed: [Listed], makers: Set<String>, now: Date = .now) -> [String] {
        let oldest = now.timeIntervalSince1970 - 120 * 86_400
        var pool = listed.filter { m in
            makers.contains(m.maker) && m.id != current.id && !m.id.contains(":") && !m.id.hasPrefix("~") && m.created >= oldest
                && m.price <= current.price * 2 && (m.maker != current.maker || m.created > current.created)
        }.sorted { ($0.created, $1.id) > ($1.created, $0.id) }
        pool = pool.filter { m in !pool.contains { $0.id != m.id && m.id.hasPrefix($0.id + "-") && $0.price == m.price } }
        var out: [String] = []
        for maker in makers.sorted() {
            let theirs = pool.filter { $0.maker == maker }
            out += theirs.filter { $0.price >= current.price / 2 }.prefix(2).map(\.id)
            out += theirs.filter { $0.price < current.price / 2 }.prefix(1).map(\.id)
        }
        return out
    }

    // MARK: - Measuring

    /// What one model's requests cost and how long they took, added up as they finish.
    final class Meter: @unchecked Sendable {
        /// The meter of the work in progress: every reply's cost lands here (see `CloudSpend.note`).
        @TaskLocal static var current: Meter?
        private let lock = NSLock()
        private var _cost = 0.0, _seconds = 0.0
        var cost: Double { lock.lock(); defer { lock.unlock() }; return _cost }
        var seconds: Double { lock.lock(); defer { lock.unlock() }; return _seconds }
        func add(cost: Double) { lock.lock(); _cost += cost; lock.unlock() }
        private func add(seconds: Double) { lock.lock(); _seconds += seconds; lock.unlock() }
        /// Runs one piece of work and counts how long it took, however many others ran beside it.
        func timed<T>(_ work: () async -> T) async -> T {
            let began = Date.now
            let value = await work()
            add(seconds: Date.now.timeIntervalSince(began))
            return value
        }
    }

    /// One model's result on one job.
    struct Result {
        var cases: [String: Double] = [:]
        var cost = 0.0
        var seconds = 0.0
        /// How many cases there were (a model may have answered fewer).
        var asked = 0
        var mean: Double { asked == 0 ? 0 : cases.values.reduce(0, +) / Double(asked) }
    }

    struct Job {
        let key: String
        /// What the table calls it, and what `choose` names in its reasons.
        let title: String
        /// The names this work goes by in the cost ledger, so jobs weigh what they really cost this household.
        let ledger: [String]
        /// How a result is shown in the table.
        var show: (Result) -> String = { String(format: "%.0f%%", $0.mean * 100) }
        /// False for work done behind the scenes, where a slower model keeps nobody waiting.
        var waitedFor = true
        /// True where an answer is acted on without asking: being wrong more often is then a failing
        /// of its own, whatever the overall score.
        var actsAlone = false
        var cases = 0
        /// Model to its result.
        var results: [String: Result] = [:]
    }

    private static func say(_ text: String) { print("BENCH " + text) }

    /// Runs `work` for every model at once (so each meets the same network and the same hour), each
    /// under its own meter, as the writing model where the job is a writing job.
    private static func measure(_ job: inout Job, models: [String], cases: Int, _ work: @escaping @Sendable (String, Meter) async -> [String: Double]) async {
        job.cases = cases
        guard cases > 0 else { say("\(job.title): nothing to test with, skipped"); return }
        say("\(job.title): \(cases) cases, \(models.count) models…")
        var results: [String: Result] = [:]
        await withTaskGroup(of: (String, Result).self) { group in
            for model in models {
                group.addTask {
                    let meter = Meter()
                    let scores = await CloudAI.$benchmarking.withValue(true) {
                        await CloudAI.$modelOverride.withValue(model) {
                            await Meter.$current.withValue(meter) { await work(model, meter) }
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(300))      // the last reply's cost is noted a moment after it arrives
                    return (model, Result(cases: scores, cost: meter.cost, seconds: meter.seconds, asked: cases))
                }
            }
            for await (model, result) in group {
                results[model] = result
                say("  \(model): \(job.show(result)), $\(String(format: "%.3f", result.cost)), \(Int(result.seconds))s, answered \(result.cases.count) of \(cases)")
            }
        }
        job.results = results
    }

    /// Several pieces of work, a few at a time.
    private static func each<T: Sendable>(_ items: [T], atOnce: Int, _ work: @escaping @Sendable (T) async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            var next = 0
            func start() { guard next < items.count else { return }; let item = items[next]; next += 1; group.addTask { await work(item) } }
            for _ in 0..<atOnce { start() }
            for await _ in group { start() }
        }
    }

    /// A place to gather scores from pieces of work running side by side.
    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var scores: [String: Double] = [:]
        func set(_ key: String, _ value: Double) { lock.lock(); scores[key] = value; lock.unlock() }
        var all: [String: Double] { lock.lock(); defer { lock.unlock() }; return scores }
    }

    // MARK: - The cases, and where their answers come from

    /// Lines nothing in the statement explains: payments to people, checks, wires, deposits, cash.
    private static func unknowable(_ line: String) -> Bool {
        let upper = line.uppercased()
        return TidyEngine.isPerson(line) || ["DEPOSIT", "WITHDRAW", "ATM "].contains { upper.contains($0) }
    }

    /// Whether a statement line really is the well-known business the built-in list took it for. The
    /// list matches a word anywhere in the line, so a sauna called "STEAM ROOM" is filed as Steam and a
    /// theatre's "SPECTRUM" stage as the cable company; only a line that leads with the business's name is an answer.
    private static func leads(_ line: String, with name: String) -> Bool {
        guard let first = TidyEngine.nameWords(name).first, let lead = TidyEngine.words(line).first else { return false }
        return lead == first
    }

    /// Payees whose category is known without asking a model: the made-up households' regular
    /// payees, businesses on the built-in list (when the line leads with their name), and payees the
    /// person filed or confirmed by hand. Lines nothing in a statement explains are left out.
    /// (What the person corrected leans against the current model and what they confirmed leans
    /// towards it; both are in, so neither lean decides.)
    @MainActor
    private static func goldPayees(_ store: BudgetStore, households: [Household], limit: Int) -> [(item: CloudItem, category: Category)] {
        var out: [(item: CloudItem, category: Category)] = []
        for home in households {
            let regular = Dictionary(grouping: home.lines.filter { home.answers[$0.id]?.isEmpty == true || home.answers[$0.id]?.hasPrefix("!") == true }, by: \.text)
            for (text, lines) in regular.sorted(by: { $0.key < $1.key }) where lines.count >= 5 {
                guard let category = Category.pickable.first(where: { $0.rawValue == lines[0].category }) else { continue }
                var item = CloudItem(key: "made-up: \(text)", description: text, averageAmount: lines.reduce(0) { $0 + $1.amount } / Double(lines.count), count: lines.count, bankCategory: nil)
                item.amounts = Array(lines.prefix(8).map(\.amount))
                out.append((item, category))
            }
        }
        let used = Dictionary(grouping: store.library.entries, by: \.merchantKey)
        let usable = store.library.merchants.filter { key, info in
            info.category.map(Category.pickable.contains) == true && !info.sample.isEmpty && !unknowable(info.sample) && used[key]?.isEmpty == false
                && (info.source == .known ? leads(info.sample, with: info.name) : info.confirmed)
        }
        let byHand = usable.filter { $0.value.source != .known }.sorted { $0.key < $1.key }
        let known = usable.filter { $0.value.source == .known }.sorted { $0.key < $1.key }
        for (key, info) in (byHand + known).prefix(max(0, limit - out.count)) {
            guard let entries = used[key], let category = info.category else { continue }
            let total = entries.reduce(0) { $0 + $1.amount }
            var item = CloudItem(key: key, description: info.sample, averageAmount: total / Double(entries.count), count: entries.count,
                                 bankCategory: entries.compactMap(\.bankCategory).first)
            item.amounts = Array(entries.suffix(8).map { abs($0.amount) })
            item.notes = ([info.note].compactMap { $0 } + entries.compactMap(\.note)).filter { !$0.isEmpty }.suffix(4).map { String($0.prefix(200)) }
            out.append((item, category))
        }
        return out
    }

    /// Pairs of statement lines known to be one business or two, with what a decision model is shown.
    /// Three sources: the made-up pairs in Tests/Bench; two ways of writing one business on the
    /// built-in list (both lines leading with its name); and combinations and separations the person kept.
    /// (The kept ones were first judged by the current decision model, so there it can only be equalled.)
    @MainActor
    private static func goldPairs(_ store: BudgetStore, fixtures: URL?, limit: Int) -> [(id: String, state: String, same: Bool)] {
        func spelling(_ text: String, _ count: Int, _ typical: Double) -> TidyEngine.Spelling {
            TidyEngine.Spelling(payee: "", text: text, count: count, typical: typical, category: .other, byHand: false, sample: text)
        }
        var out: [(id: String, state: String, same: Bool)] = [], taken: Set<String> = []
        func add(_ source: String, _ a: TidyEngine.Spelling, _ b: TidyEngine.Spelling, same: Bool) {
            let id = [a.text, b.text].sorted().joined(separator: "|")
            guard a.text != b.text, taken.insert(id).inserted else { return }
            out.append((source + ": " + id, TidyEngine.state(for: TidyEngine.Pair(kind: .combine, a: a, b: b)), same))
        }
        if let text = fixtures.flatMap({ try? String(contentsOf: $0.appendingPathComponent("pairs.tsv"), encoding: .utf8) }) {
            for row in text.split(separator: "\n").dropFirst() {
                let parts = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 7, let seenA = Int(parts[2]), let typicalA = Double(parts[3]), let seenB = Int(parts[5]), let typicalB = Double(parts[6]) else { continue }
                add("made-up", spelling(parts[1], seenA, typicalA), spelling(parts[4], seenB, typicalB), same: parts[0] == "same")
            }
        }
        let library = store.library
        var seen: [String: (count: Int, total: Double)] = [:]
        var byKey: [String: [String: Int]] = [:]
        for entry in library.entries {
            let text = MerchantResolver.spelling(entry.description).uppercased()
            let old = seen[text] ?? (0, 0)
            seen[text] = (old.count + 1, old.total + abs(entry.amount))
            byKey[entry.merchantKey, default: [:]][text, default: 0] += 1
        }
        func known(_ text: String) -> TidyEngine.Spelling? { seen[text].map { spelling(text, $0.count, $0.total / Double($0.count)) } }
        // Two ways of writing one business the built-in list knows, when they differ in more than a store number.
        // Hotels are left out: two hotels of one chain are two places, and the app leaves those alone.
        var listed = 0
        for key in byKey.keys.sorted() where key.hasPrefix("known:") && listed < limit / 4 {
            guard let info = library.merchants[key], info.category?.isSpending == true, info.category != .travel else { continue }
            let ways = (byKey[key] ?? [:]).sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map(\.key).filter { leads($0, with: info.name) && !unknowable($0) }
            guard let main = ways.first, let other = ways.dropFirst().first(where: { Set(TidyEngine.words($0).prefix(2)) != Set(TidyEngine.words(main).prefix(2)) }),
                  let a = known(main), let b = known(other) else { continue }
            let before = out.count
            add("built-in list", a, b, same: true)
            if out.count > before { listed += 1 }
        }
        let book = library.tidy ?? TidyBook()
        var kept: [(String, String, Bool)] = []
        for change in book.changes where change.kept == true {
            for id in [change.pairID] + (change.morePairIDs ?? []) {
                let parts = id.components(separatedBy: "|")
                guard parts.count == 3, let p = book.judged[id], p >= 0 else { continue }
                kept.append((parts[1], parts[2], p >= 0.5))
            }
        }
        for (first, second, same) in kept.sorted(by: { ($0.0, $0.1) < ($1.0, $1.1) }).prefix(limit / 2) {
            if let a = known(first), let b = known(second) { add("kept", a, b, same: same) }
        }
        return out
    }

    /// Payees that are plainly a need or plainly a choice by the question's own wording: the category
    /// is one the question names on one side, and it came from the person or the built-in list.
    @MainActor
    private static func goldNeeds(_ store: BudgetStore, limit: Int) -> [(key: String, state: String, optional: Bool)] {
        let chosen: Set<Category> = [.dining, .travel, .entertainment, .wine], needed: Set<Category> = [.groceries, .bills]
        let used = Dictionary(grouping: store.library.entries, by: \.merchantKey)
        return store.library.merchants.sorted { $0.key < $1.key }.compactMap { key, info -> (String, String, Bool)? in
            guard info.source == .known ? leads(info.sample, with: info.name) : (info.source == .user && info.confirmed), !unknowable(info.sample),
                  let category = info.category, chosen.contains(category) || needed.contains(category), let entries = used[key], !entries.isEmpty else { return nil }
            let typical = entries.reduce(0) { $0 + abs($1.amount) } / Double(entries.count)
            return (key, BudgetStore.optionalState(name: info.name, sample: info.sample, category: category, typical: typical, count: entries.count), chosen.contains(category))
        }.prefix(limit).map { $0 }
    }

    struct Statement: Sendable {
        let id: String
        let text: String
        let closing: Date
        /// The lines the library holds for it, which tie to the totals the statement prints.
        let lines: [CanonicalRow]
    }

    /// Statements whose lines are known to the cent: the library's reading of each ties to the totals
    /// printed on it. The longest from each account (long statements are where lines get dropped),
    /// so every bank's layout is in.
    @MainActor
    private static func goldStatements(_ store: BudgetStore, folder: URL?, limit: Int) -> [Statement] {
        guard let folder else { return [] }
        let lines = Dictionary(grouping: store.library.entries.filter { $0.sourceID != nil }, by: { $0.sourceID ?? "" })
        let usable = (store.library.sources ?? []).filter { s in
            s.isPDF && s.check == "verified" && (10...200).contains(s.rows) && lines[s.id]?.count == s.rows
                && FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(s.id).\(s.ext)").path)
        }
        let longest = Dictionary(grouping: usable, by: { $0.accountID?.uuidString ?? "" }).values
            .compactMap { $0.max { ($0.rows, $1.id) < ($1.rows, $0.id) } }.sorted { ($0.rows, $1.id) > ($1.rows, $0.id) }
        return longest.prefix(limit).compactMap { source in
            guard let doc = PDFDocument(url: folder.appendingPathComponent("\(source.id).\(source.ext)")), !doc.isLocked else { return nil }
            let pages = (0..<min(doc.pageCount, 200)).compactMap { doc.page(at: $0) }
            let closing = PDFStatement.detectClosingDate(pages.compactMap(\.string).joined(separator: "\n")) ?? .now
            let rows = (lines[source.id] ?? []).map { CanonicalRow(date: $0.date, description: $0.description, amount: $0.amount) }
            return Statement(id: source.id, text: pages.map(PDFStatement.positionalText).joined(separator: "\n"), closing: closing, lines: rows)
        }
    }

    /// One case per line a statement really has (found, with the right amount and within a few days,
    /// or not), and one more for adding lines that are not there.
    static func lineScores(read: [CanonicalRow], truth: [CanonicalRow]) -> [Double] {
        var rest = read, scores: [Double] = []
        for line in truth {
            let day = OrderMatcher.dayNumber(line.date)
            let near = rest.indices.filter { abs(rest[$0].amount - line.amount) < 0.005 && abs(OrderMatcher.dayNumber(rest[$0].date) - day) <= 5 }
            if let hit = near.min(by: { abs(OrderMatcher.dayNumber(rest[$0].date) - day) < abs(OrderMatcher.dayNumber(rest[$1].date) - day) }) {
                rest.remove(at: hit); scores.append(1)
            } else { scores.append(0) }
        }
        return scores + [max(0, 1 - Double(rest.count) / Double(max(truth.count, 1)))]
    }

    struct Household: Sendable {
        let name: String
        let lines: [StoryFinder.Line]
        let answers: [UUID: String]
    }

    /// The made-up households in Tests/Bench, each charge with its answer.
    private static func loadHouseholds(in folder: URL?) -> [Household] {
        guard let folder, let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.lastPathComponent.hasPrefix("trips-") && $0.pathExtension == "tsv" }.sorted { $0.path < $1.path }.compactMap { file in
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            var lines: [StoryFinder.Line] = [], answers: [UUID: String] = [:]
            for row in text.split(separator: "\n").dropFirst() {
                let parts = row.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard parts.count >= 5, let amount = Double(parts[2]) else { continue }
                let id = UUID()
                lines.append(StoryFinder.Line(id: id, date: parts[0], text: parts[1], amount: amount, category: parts[3]))
                answers[id] = parts[4]
            }
            let name = file.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "trips-", with: "")
            return lines.count >= 20 ? Household(name: name, lines: lines, answers: answers) : nil
        }
    }

    /// A question (or a question and its follow-up) whose answer the app can add up without a model,
    /// worded so it can only mean one thing. `expect` must appear in the last answer.
    struct Asked {
        let id: String
        let questions: [String]
        let expect: String
    }

    /// Questions about the last full calendar year (and one about last month), about payees and
    /// categories with no refunds in the stretch asked about, so "spent" cannot fairly mean two
    /// different sums. They range from one figure to ones that need a threshold, a span of months,
    /// a ranking, or the thread of a conversation.
    @MainActor
    private static func goldQuestions(_ store: BudgetStore) -> [Asked] {
        guard let last = store.months.max() else { return [] }
        let year = last.month == 12 ? last.year : last.year - 1
        let inYear = store.transactions.filter { $0.month.year == year }
        let spending = inYear.filter(\.countsAsSpending)
        guard spending.count >= 200 else { return [] }
        let names = Calendar.current.monthSymbols, days = Calendar.current.weekdaySymbols
        func name(_ month: Int) -> String { names.indices.contains(month - 1) ? names[month - 1] : "\(month)" }
        func sum(_ list: [Transaction]) -> Double { list.reduce(0) { $0 + $1.amount } }
        /// The clear leader of some totals: ahead of the runner-up by a tenth or more.
        func leader<K>(_ totals: [K: Double]) -> K? {
            let ranked = totals.sorted { $0.value > $1.value }
            return ranked.count >= 2 && ranked[0].value > ranked[1].value * 1.1 ? ranked[0].key : nil
        }
        var out: [Asked] = []
        func ask(_ id: String, _ questions: String..., expect: String) { if !out.contains(where: { $0.id == id }) { out.append(Asked(id: id, questions: questions, expect: expect)) } }

        // Categories, busiest first, with no refunds in the year: every way of adding them up agrees.
        let byCategory = Dictionary(grouping: spending, by: \.category).filter { $0.key != .other && $0.value.count >= 12 && $0.value.allSatisfy { $0.amount > 0 } }
            .sorted { ($0.value.count, $1.key.rawValue) > ($1.value.count, $0.key.rawValue) }
        for (i, (category, charges)) in byCategory.prefix(4).enumerated() {
            let what = category.rawValue, byMonth = Dictionary(grouping: charges, by: \.month.month)
            let full = byMonth.filter { $0.value.count >= 3 }.keys.sorted()
            if let month = full.last {
                let first = "How much did I spend on \(what) in \(name(month)) \(year)?"
                ask("a month of \(what)", first, expect: Money.format(sum(byMonth[month] ?? [])))
                if i == 0, month > 2, let before = byMonth[month - 1], let earlier = byMonth[month - 2] {
                    ask("follow-up: the month before", first, "And the month before?", expect: Money.format(sum(before)))
                    ask("follow-up: two months before", first, "And the month before?", "And the one before that?", expect: Money.format(sum(earlier)))
                    ask("follow-up: how many", first, "How many charges was that?", expect: "\(byMonth[month]?.count ?? 0)")
                }
            }
            if let top = charges.max(by: { $0.amount < $1.amount }), charges.filter({ $0.amount == top.amount }).count == 1 {
                ask("largest \(what) charge", "What was my single largest \(what) charge in \(year)?", expect: Money.format(top.amount))
            }
            if let month = leader(byMonth.mapValues(sum)) {
                ask("biggest month for \(what)", "In which month of \(year) did I spend the most on \(what)?", expect: name(month))
            }
            // A span of months, named in words.
            let spring = charges.filter { (4...6).contains($0.month.month) }
            if spring.count >= 3 { ask("a quarter of \(what)", "How much did I spend on \(what) from April through June of \(year)?", expect: Money.format(sum(spring))) }
            // A threshold: a round figure about a tenth of the charges reach, and none sits right on.
            let sorted = charges.map(\.amount).sorted()
            let mark = [1000.0, 500, 250, 200, 100, 50, 25].first { level in
                let over = sorted.filter { $0 >= level }.count
                return over >= 3 && over * 3 <= sorted.count && !sorted.contains { abs($0 - level) < 1 }
            }
            if let mark {
                let over = charges.filter { $0.amount >= mark }
                ask("counting large \(what) charges", "How many \(what) charges of $\(Int(mark)) or more did I have in \(year)?", expect: "\(over.count)")
                if i < 2 { ask("adding up large \(what) charges", "What did my \(what) charges of $\(Int(mark)) or more add up to in \(year)?", expect: Money.format(sum(over))) }
            }
            // A ranking by payee, and by day of the week.
            if i < 2, let payee = leader(Dictionary(grouping: charges, by: \.merchant).mapValues(sum)), payee.count >= 4 {
                ask("top payee for \(what)", "Which single payee did I spend the most at for \(what) in \(year)?", expect: payee)
            }
            if i < 2, let day = leader(Dictionary(grouping: charges, by: { Calendar.current.component(.weekday, from: $0.date) }).mapValues(sum)), days.indices.contains(day - 1) {
                ask("biggest day of the week for \(what)", "On which day of the week did I spend the most on \(what) in \(year), in total?", expect: days[day - 1])
            }
        }
        // "Last month" has to be worked out from today's date.
        let previous = Month(date: .now).adding(-1)
        if let (category, _) = byCategory.first {
            let then = store.transactions.filter { $0.month == previous && $0.category == category }
            if then.count >= 3, then.allSatisfy({ $0.amount > 0 }) { ask("last month", "How much did I spend on \(category.rawValue) last month?", expect: Money.format(sum(then))) }
        }
        // Payees whose name picks out exactly their own charges, and no refunds among them.
        let byPayee = Dictionary(grouping: spending, by: \.merchant).filter { payee, charges in
            payee.count >= 5 && charges.count >= 4 && charges.allSatisfy { $0.amount > 0 }
                && inYear.filter { $0.merchant.localizedCaseInsensitiveContains(payee) || $0.description.localizedCaseInsensitiveContains(payee) || ($0.note?.localizedCaseInsensitiveContains(payee) ?? false) }.count == charges.count
        }.sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }
        for (i, (payee, charges)) in byPayee.prefix(4).enumerated() {
            if i < 2 { ask("a year at a payee (\(i + 1))", "How much did I spend at \(payee) in \(year)?", expect: Money.format(sum(charges))) }
            else { ask("counting charges (\(i - 1))", "How many charges did I have at \(payee) in \(year)?", expect: "\(charges.count)") }
        }
        return out
    }

    /// Whether `expect` is in `text` as a whole figure or word: "12" is not in "$112.00", "12.50" or "12,000".
    static func mentions(_ text: String, _ expect: String) -> Bool {
        let pattern = #"(?<![\w$])(?<!\d[.,])"# + NSRegularExpression.escapedPattern(for: expect) + #"(?!\w)(?![.,]\d)"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // MARK: - The run

    /// What was asked for, read from the environment (`scripts/bench-models.sh` sets these).
    struct Setup {
        var makers: Set<String> = ["anthropic", "google", "meta", "openai"]
        /// Models named by hand, tried whatever their price or maker.
        var named: [String] = []
        /// Job keys to run; empty means all.
        var only: Set<String> = []
        /// Stop starting new jobs once this many dollars are spent.
        var budget = 10.0
        var statements: URL?
        var fixtures: URL?
        var ledger: URL?
    }

    /// Acts like a decision made at a threshold: right when sure is a case won, wrong when sure costs
    /// two (the app would have acted on it by itself), unsure is nothing gained or lost.
    static func acted(sure: Bool, right: Bool) -> Double { sure ? (right ? 1 : -2) : 0 }
    private static let showActed: (Result) -> String = { r in
        let right = r.cases.values.filter { $0 > 0 }.count, wrong = r.cases.values.filter { $0 < 0 }.count
        return "\(right * 100 / max(r.asked, 1))% settled, \(wrong) wrong"
    }

    @MainActor
    static func run(store: BudgetStore, out: URL, setup: Setup) async {
        let began = Date.now
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        guard CloudKey.exists else { say("There is no OpenRouter key on this Mac, so there is nothing to test with."); return }

        // Who is in the running.
        async let textList = listing(decisions: false), decisionList = listing(decisions: true)
        let text = await textList, deciders = await decisionList
        guard !text.isEmpty else { say("OpenRouter's list of models could not be read. Check the connection and try again."); return }
        func entry(_ id: String, _ list: [Listed]) -> Listed { list.first { $0.id == id } ?? Listed(id: id, created: 0, price: .infinity) }
        let namedDeciders = setup.named.filter { id in deciders.contains { $0.id == id } }
        let namedWriters = setup.named.filter { !namedDeciders.contains($0) }
        func unique(_ list: [String]) -> [String] { var seen: Set<String> = []; return list.filter { seen.insert($0).inserted } }
        let writers = unique([Models.writing] + candidates(for: entry(Models.writing, text), among: text, makers: setup.makers) + namedWriters)
        let readers = unique([Models.secondReader] + candidates(for: entry(Models.secondReader, text), among: text, makers: setup.makers) + namedWriters)
        let judges = unique([Models.decision] + candidates(for: entry(Models.decision, deciders), among: deciders, makers: setup.makers) + namedDeciders)
        let passedOver = Set(deciders.map(\.maker)).subtracting(setup.makers).count
        say("writing: \(writers.joined(separator: ", "))")
        say("second reader: \(readers.joined(separator: ", "))")
        say("decision: \(judges.joined(separator: ", "))")

        // The cases.
        let households = loadHouseholds(in: setup.fixtures)
        let payees = goldPayees(store, households: households, limit: 200), pairs = goldPairs(store, fixtures: setup.fixtures, limit: 200), needs = goldNeeds(store, limit: 120)
        let statements = goldStatements(store, folder: setup.statements, limit: 6)
        let questions = goldQuestions(store)
        var spent = 0.0
        var skipped: [String] = []
        func wanted(_ key: String) -> Bool {
            guard setup.only.isEmpty || setup.only.contains(key) else { return false }
            if spent >= setup.budget { skipped.append(key); return false }
            return true
        }
        func done(_ job: Job) -> Job { spent += job.results.values.reduce(0) { $0 + $1.cost }; return job }

        var sorting = Job(key: "payees", title: "sorting payees", ledger: ["Sorting payees"])
        if wanted(sorting.key) {
            await measure(&sorting, models: writers, cases: payees.count) { _, meter in
                let tally = Tally()
                await each(payees.map(\.item).chunked(into: 15), atOnce: 6) { batch in
                    guard let verdicts = await meter.timed({ await CloudSorter.sort(batch, examples: []) }) else { return }
                    for (item, category) in payees where verdicts[item.key] != nil { tally.set(item.key, verdicts[item.key]?.category == category ? 1 : 0) }
                }
                return tally.all
            }
            sorting = done(sorting)
        }

        var reading = Job(key: "statements", title: "reading statement lines", ledger: ["Reading statements", "Reading statements: second opinion"])
        reading.show = { String(format: "%.1f%%", $0.mean * 100) }
        if wanted(reading.key) {
            await measure(&reading, models: unique(writers + readers), cases: statements.reduce(0) { $0 + $1.lines.count + 1 }) { _, meter in
                let tally = Tally()
                await each(statements, atOnce: 4) { statement in
                    guard let read = await meter.timed({ await CloudStatementReader.read(text: statement.text, closing: statement.closing) }) else { return }
                    for (i, score) in lineScores(read: read.rows, truth: statement.lines).enumerated() { tally.set("\(statement.id) \(i)", score) }
                }
                return tally.all
            }
            reading = done(reading)
        }

        var trips = Job(key: "trips", title: "finding trips", ledger: ["Finding trips"])
        trips.waitedFor = false         // found in the background, after an import has finished
        trips.show = { String(format: "%.1f%%", $0.mean * 100) }
        if wanted(trips.key) {
            let planted = households.reduce(0) { $0 + tripScores(answers: $1.answers, found: []).count }
            await measure(&trips, models: writers, cases: planted) { _, meter in
                let tally = Tally()
                await each(households, atOnce: 2) { home in
                    guard let found = await meter.timed({ await StoryFinder.find(home.lines) }) else { return }
                    for (name, score) in tripScores(answers: home.answers, found: found.map(\.entryIDs)) { tally.set("\(home.name): \(name)", score) }
                }
                return tally.all
            }
            trips = done(trips)
        }

        var asking = Job(key: "questions", title: "answering questions", ledger: ["Answering questions"])
        asking.show = { "\(Int($0.cases.values.reduce(0, +))) of \($0.asked)" }
        if wanted(asking.key) {
            await measure(&asking, models: writers, cases: questions.count) { _, meter in
                let tally = Tally()
                for asked in questions {
                    var turns: [ChatAnalyst.Turn] = [], last: String?
                    for question in asked.questions {
                        guard let (answer, turn) = await meter.timed({ await ChatAnalyst.answer(question, history: turns, store: store) }) else { last = nil; break }
                        turns.append(turn); last = answer.headline
                    }
                    if let last { tally.set(asked.id, mentions(last, asked.expect) ? 1 : 0) }
                }
                return tally.all
            }
            asking = done(asking)
        }

        var filing = Job(key: "first-pass", title: "filing payees at once", ledger: ["Sorting payees, first pass"], show: showActed, actsAlone: true)
        if wanted(filing.key) {
            var states: [String: String] = [:]
            for (item, _) in payees {
                states[item.key] = "Transaction text: \(Redactor.scrub(item.description)). Money \(item.averageAmount < 0 ? "came in" : "went out"). "
                    + "Typical amount $\(String(format: "%.2f", abs(item.averageAmount))). Appears \(item.count) time\(item.count == 1 ? "" : "s")."
            }
            let question = ["category": CategoryQuestion.question()], asked = states
            let truth = Dictionary(payees.map { ($0.item.key, $0.category.rawValue) }, uniquingKeysWith: { a, _ in a })
            await measure(&filing, models: judges, cases: payees.count) { model, meter in
                let answers = await meter.timed { await Decisions.askAll(job: "Benchmark", model: model, states: asked, questions: question, atOnce: 12) }
                // The app files a payee at once when the model is nine parts in ten sure.
                return answers.compactMapValues { $0["category"] }.reduce(into: [:]) { out, pick in
                    out[pick.key] = acted(sure: (pick.value.confidence ?? 0) >= 0.9, right: pick.value.choice == truth[pick.key])
                }
            }
            filing = done(filing)
        }

        var grouping = Job(key: "grouping", title: "grouping payees", ledger: ["Tidying payees"], show: showActed, waitedFor: false, actsAlone: true)
        if wanted(grouping.key) {
            let states = Dictionary(pairs.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a })
            let truth = Dictionary(pairs.map { ($0.id, $0.same) }, uniquingKeysWith: { a, _ in a })
            await measure(&grouping, models: judges, cases: pairs.count) { model, meter in
                let answers = await meter.timed { await Decisions.askAll(job: "Benchmark", model: model, states: states, questions: ["same": TidyEngine.sameBusiness], atOnce: 12) }
                return answers.compactMapValues { $0["same"]?.yes }.reduce(into: [:]) { out, pick in
                    let p = pick.value, same = truth[pick.key] ?? false
                    out[pick.key] = acted(sure: p >= TidyEngine.sureSame || p <= TidyEngine.sureDifferent, right: (p >= 0.5) == same)
                }
            }
            grouping = done(grouping)
        }

        var choosing = Job(key: "needs", title: "telling needs from wants", ledger: ["Needs and wants"])
        choosing.waitedFor = false
        if wanted(choosing.key) {
            let states = Dictionary(needs.map { ($0.key, $0.state) }, uniquingKeysWith: { a, _ in a })
            let truth = Dictionary(needs.map { ($0.key, $0.optional) }, uniquingKeysWith: { a, _ in a })
            await measure(&choosing, models: judges, cases: needs.count) { model, meter in
                let answers = await meter.timed { await Decisions.askAll(job: "Benchmark", model: model, states: states, questions: ["optional": BudgetStore.optionalQuestion], atOnce: 12) }
                return answers.compactMapValues { $0["optional"]?.yes }.reduce(into: [:]) { out, pick in out[pick.key] = (pick.value >= 0.5) == truth[pick.key] ? 1 : 0 }
            }
            choosing = done(choosing)
        }

        // Does each writing model answer the tiny request the welcome screen sends to prove a key works?
        var keyCheckFails: Set<String> = []
        if setup.only.isEmpty {
            await withTaskGroup(of: (String, Bool).self) { group in
                for model in writers {
                    group.addTask { (model, await CloudAI.$benchmarking.withValue(true) { await CloudAI.$modelOverride.withValue(model) { await CloudAI.test() == nil } }) }
                }
                for await (model, ok) in group where !ok { keyCheckFails.insert(model) }
            }
        }

        // The verdicts.
        let ledger = (setup.ledger.flatMap { try? Data(contentsOf: $0) }).flatMap { try? JSONDecoder().decode([String: [String: CloudSpend.Tally]].self, from: $0) } ?? [:]
        var paid: [String: Double] = [:]
        for jobs in ledger.values { for (key, tally) in jobs { paid[key.components(separatedBy: "\t")[0], default: 0] += tally.cost } }

        var report: [String] = []
        var record: [String: Any] = ["day": DateParsing.iso.string(from: .now)]
        func role(_ title: String, current: String, models: [String], jobs: [Job], needsKeyCheck: Bool = false, allowed: (String) -> Bool = { _ in true }) -> String {
            let ran = jobs.filter { $0.results[current] != nil && $0.cases > 0 }
            report.append("")
            report.append("\(title.uppercased()): now \(current)")
            guard !ran.isEmpty else { report.append("  Not tested in this run."); return current }
            // Jobs weigh what they have really cost this household; evenly when there is no history.
            var weight = Dictionary(uniqueKeysWithValues: ran.map { job in (job.key, job.ledger.reduce(0) { $0 + (paid[$1] ?? 0) }) })
            if weight.values.contains(where: { $0 <= 0 }) { for key in weight.keys { weight[key] = 1 } }
            var entrants: [Entrant] = [], marks: [String: [String: String]] = [:]
            for model in models where model != current {
                var entrant = Entrant(model: model)
                var gains: [Double] = [], cost = 0.0, costWeight = 0.0, waited = 0.0, waitedNow = 0.0
                for job in ran {
                    guard let mine = job.results[model], let theirs = job.results[current] else { continue }
                    let against = compare(mine.cases, with: theirs.cases)
                    var standing = against.standing
                    // Where answers are acted on unasked, more wrong ones is worse, however many more were right.
                    if job.actsAlone, compare(mine.cases.mapValues { min($0, 0) }, with: theirs.cases.mapValues { min($0, 0) }).standing == .worse { standing = .worse }
                    entrant.standings[job.title] = standing
                    marks[model, default: [:]][job.key] = standing == .better ? " ▲" : standing == .worse ? " ▼" : ""
                    gains.append(against.difference)
                    let w = weight[job.key] ?? 1
                    if theirs.cost > 0, mine.cost > 0 { cost += w * mine.cost / theirs.cost; costWeight += w }
                    else if theirs.cost > 0, !mine.cases.isEmpty { costWeight += w }      // a model that is free costs nothing
                    if job.waitedFor, theirs.seconds > 0, mine.seconds > 0 { waited += mine.seconds; waitedNow += theirs.seconds }
                }
                guard !entrant.standings.isEmpty else { continue }
                entrant.gain = gains.reduce(0, +) / Double(gains.count)
                entrant.cost = costWeight > 0 ? cost / costWeight : 1
                entrant.time = waitedNow > 0 ? waited / waitedNow : 1
                entrants.append(entrant)
            }
            var choice = choose(current: current, entrants: entrants, allowed: allowed)
            for model in keyCheckFails where needsKeyCheck && choice.reasons[model] != nil {
                choice.reasons[model] = (choice.reasons[model] ?? "") + " (the welcome screen's key check gets no answer from it: loosen that first)"
            }
            // The table.
            var rows: [[String]] = [["model"] + ran.map { "\($0.title) (\($0.cases))" } + ["cost", "time", ""]]
            for model in [current] + entrants.map(\.model) {
                let cost = ran.reduce(0) { $0 + ($1.results[model]?.cost ?? 0) }, seconds = ran.reduce(0) { $0 + ($1.results[model]?.seconds ?? 0) }
                var row = [model]
                for job in ran { row.append(job.results[model].map { job.show($0) + (marks[model]?[job.key] ?? "") } ?? "-") }
                row += [String(format: "$%.3f", cost), "\(Int(seconds))s", model == current ? "current" : (choice.reasons[model] ?? "")]
                rows.append(row)
            }
            let widths = (0..<rows[0].count).map { column in rows.map { $0[column].count }.max() ?? 0 }
            for row in rows { report.append("  " + row.enumerated().map { $1.padding(toLength: widths[$0], withPad: " ", startingAt: 0) }.joined(separator: "   ").trimmingCharacters(in: .whitespaces)) }
            report.append(choice.model == current ? "  → Keep \(current)." : "  → Switch to \(choice.model).")
            record[title] = ["current": current, "choice": choice.model, "reasons": choice.reasons,
                             "jobs": Dictionary(uniqueKeysWithValues: ran.map { job in (job.key, job.results.mapValues { ["score": $0.mean, "cost": $0.cost, "seconds": $0.seconds, "cases": $0.cases] as [String: Any] }) })]
            return choice.model
        }

        let writing = role("Writing model", current: Models.writing, models: writers, jobs: [sorting, reading, trips, asking], needsKeyCheck: true)
        let maker = { (id: String) in String(id.split(separator: "/").first ?? "") }
        // The second reading only means something when it comes from a different maker than the first.
        let second = role("Second reader", current: Models.secondReader, models: readers, jobs: [reading]) { maker($0) != maker(writing) }
        let decision = role("Decision model", current: Models.decision, models: judges, jobs: [filing, grouping, choosing])

        let took = Int(Date.now.timeIntervalSince(began))
        var head = ["Spendthrift model benchmark, \(DateParsing.iso.string(from: .now))",
                    "Spent $\(String(format: "%.2f", spent)) in \(took / 60)m \(took % 60)s. ▲ better and ▼ worse than the current model by more than chance; unmarked is a tie."]
        if store.transactions.isEmpty { head.append("There is no library on this Mac, so only the made-up households were used (trips).") }
        if !skipped.isEmpty { head.append("Stopped at the $\(String(format: "%.0f", setup.budget)) limit before: \(skipped.joined(separator: ", ")). Raise it with --budget.") }
        var foot = ["", "WHAT TO DO"]
        let changes = [("writing", Models.writing, writing), ("secondReader", Models.secondReader, second), ("decision", Models.decision, decision)].filter { $0.1 != $0.2 }
        if changes.isEmpty { foot.append("  Nothing. The models in Cloud/ModelNames.swift are still the ones to use.") }
        else {
            foot.append("  In Sources/Spendthrift/Cloud/ModelNames.swift:")
            for (name, _, new) in changes { foot.append("      static let \(name) = \"\(new)\"") }
            if changes.contains(where: { $0.0 == "decision" }) {
                foot.append("  The decision model's thresholds (0.9 to file, \(TidyEngine.sureSame) and \(TidyEngine.sureDifferent) to group) were kept as they are in the test, so they need no change.")
            }
        }
        foot.append("")
        foot.append("Not tested: the image model, and the writing model's smaller jobs (order items, paid checks, captions, things noticed, web lookups).")
        if passedOver > 0 { foot.append("Decision models from \(passedOver) other makers were not tried. To include a maker: --makers \(setup.makers.sorted().joined(separator: ",")),name") }
        let whole = (head + report + foot).joined(separator: "\n")
        try? whole.write(to: out.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
        record["spent"] = spent
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: out.appendingPathComponent("results.json")) }
        say("done")
    }

    /// OpenRouter's list of models that write text and can reply in JSON, or of decision models.
    /// Asks for nothing but the public list; no key and nothing about the person is sent.
    private static func listing(decisions: Bool) async -> [Listed] {
        guard let url = URL(string: "https://openrouter.ai/api/v1/models" + (decisions ? "?output_modalities=decisions" : "")),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let list = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]] else { return [] }
        return list.compactMap { m in
            guard let id = m["id"] as? String, let pricing = m["pricing"] as? [String: Any], let price = (pricing["prompt"] as? String).flatMap(Double.init) else { return nil }
            let outputs = ((m["architecture"] as? [String: Any])?["output_modalities"] as? [String]) ?? []
            let accepts = (m["supported_parameters"] as? [String]) ?? []
            guard decisions ? outputs == ["decisions"] : (outputs == ["text"] && accepts.contains("response_format")) else { return nil }
            return Listed(id: id, created: (m["created"] as? Double) ?? (m["created"] as? Int).map(Double.init) ?? 0, price: price * 1_000_000)
        }
    }
}
