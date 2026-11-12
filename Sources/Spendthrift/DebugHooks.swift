import SwiftUI
import AppKit
import PDFKit

/// Test automation, active only when SPENDTHRIFT_SNAPSHOT is set (never for real users).
///   SPENDTHRIFT_HOME=<dir>      use a scratch data folder
///   SPENDTHRIFT_IMPORT=a:b:c    files to import
///   SPENDTHRIFT_SNAPSHOT=<dir>  save a PNG of each screen there, log results, then quit
///   SPENDTHRIFT_ASK=<question>  question to ask on the Ask screen
///   SPENDTHRIFT_SUGGEST_ONLY=1  log how every place was sorted, then quit
@MainActor
enum DebugHooks {
    static let env = ProcessInfo.processInfo.environment
    static var askQuestion: String? { env["SPENDTHRIFT_ASK"] }
    private static var storiesWaited = false
    /// SPENDTHRIFT_OFF="donut,trend": leave parts of the Overview out, to track down a drawing problem.
    private static let offParts = Set((env["SPENDTHRIFT_OFF"] ?? "").split(separator: ",").map(String.init))
    static func off(_ part: String) -> Bool { offParts.contains(part) }

    /// SPENDTHRIFT_WINDOW=<folder>: photograph the real window in each of its states (the live
    /// controls, sidebar and panes, which a rendered view can't show), then quit.
    private static func windowTour(_ folder: URL) async {
        let store = BudgetStore.shared
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? await Task.sleep(for: .seconds(2.5))
        guard let window = NSApp.windows.first(where: { $0.contentView != nil && $0.frame.height > 300 }) else { NSApp.terminate(nil); return }
        window.setFrame(NSRect(x: 60, y: 60, width: 1480, height: 920), display: true)
        func shot(_ name: String, wait: Double = 1.6) async {
            try? await Task.sleep(for: .seconds(wait))
            guard let view = window.contentView?.superview ?? window.contentView, let layer = view.layer else { return }
            let scale: CGFloat = 2
            let size = view.bounds.size
            guard let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale))
            ctx.scaleBy(x: scale, y: scale)
            if !view.isFlipped { } else { ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1) }
            layer.render(in: ctx)
            guard let image = ctx.makeImage() else { return }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(name + ".png"))
            print("WINDOW \(name)")
        }
        store.stage = nil
        store.showsAsk = false; store.selection = .overview
        await shot("1-overview", wait: 2.5)
        store.showsAsk = true
        await shot("2-overview-ask")
        store.overviewShowsYear = true
        await shot("3-year")
        store.overviewShowsYear = false
        store.overviewDetail = .flow
        await shot("4-cashflow")
        store.overviewDetail = nil
        store.selection = .stories
        await shot("5-trips")
        if let trip = store.stories.max(by: { store.transactions(in: $0).count < store.transactions(in: $1).count }) {
            store.showCharges(TransactionFilter(storyID: trip.id))
            await shot("6-trip-charges")
            if let place = store.transactions(in: trip).max(by: { $0.amount < $1.amount })?.merchant {
                store.showPlace(place)
                await shot("7-place")
            }
        }
        store.selection = .transactions
        await shot("8-transactions")
        store.showsAsk = false
        await shot("9-transactions-details")
        store.selection = .review
        await shot("10-doublecheck")
        store.selection = .accounts
        await shot("11-setup")
        if env["SPENDTHRIFT_WINDOW_SHOW"] != nil {
            store.stage = .premiere
            await shot("12-premiere", wait: 2.0)
            store.stage = .working
            await shot("13-working", wait: 1.2)
        }
        NSApp.terminate(nil)
    }

    static func startIfRequested() {
        if let folder = env["SPENDTHRIFT_WINDOW"] { Task { await windowTour(URL(fileURLWithPath: folder)) }; return }
        guard let outDir = env["SPENDTHRIFT_SNAPSHOT"] else { return }
        // SPENDTHRIFT_ENRICH=1: only do the catch-up work (web lookups, things noticed), print it and quit.
        if env["SPENDTHRIFT_ENRICH"] != nil {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                let store = BudgetStore.shared
                let before = store.reviewItems.count
                @MainActor func settle() async {
                    for _ in 0..<300 {
                        try? await Task.sleep(for: .seconds(1))
                        if !store.isSuggesting, !store.isLookingUp, !store.isFindingDiscoveries, !store.isFindingStories { break }
                    }
                }
                @MainActor func flags() -> String { "sorting=\(store.isSuggesting) lookingUp=\(store.isLookingUp) noticing=\(store.isFindingDiscoveries) stories=\(store.isFindingStories) cloud=\(CloudAI.isEnabled) web=\(WebLookup.isOn) accounts=\(store.accounts.count)" }
                print("ENRICH start \(flags())")
                await settle()          // the app may already be at it (it starts on becoming active)
                print("ENRICH settled \(flags())")
                await store.catchUp()
                print("ENRICH caught up \(flags())")
                await settle()
                print("ENRICH guesses \(before) → \(store.reviewItems.count), noticed \(store.discoveries.count)")
                NSApp.terminate(nil)
            }
            return
        }
        Task { await run(outDir: URL(fileURLWithPath: outDir)) }
    }

    private static func run(outDir: URL) async {
        let store = BudgetStore.shared
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        print("DEBUG: hooks started")
        if let notice = store.startupNotice { print("DEBUG NOTICE \(notice)") }
        print("DEBUG: loaded \(store.transactions.count) saved transactions, \(store.accounts.count) accounts")
        try? await Task.sleep(for: .seconds(2))
        if store.accounts.isEmpty { await snap("01-welcome", outDir) { WelcomeView(isDropTargeted: false, scrolls: false) } }

        let files = (env["SPENDTHRIFT_IMPORT"] ?? "").split(separator: ":").map { URL(fileURLWithPath: String($0)) }
        let started = Date.now
        if !files.isEmpty {
            store.importFiles(files)
            try? await Task.sleep(for: .milliseconds(300))
        }
        for _ in 0..<600 where store.isImporting { try? await Task.sleep(for: .milliseconds(100)) }
        print("DEBUG: import took \(String(format: "%.2f", Date.now.timeIntervalSince(started)))s, \(store.transactions.count) transactions, sorted instantly: \(store.transactions.filter { !$0.isUnknown }.count)")
        for pending in store.pendingImports {
            await snap("02-import-sheet", outDir) { ImportSheet(pending: pending) }
            if let mapping = ColumnDetector.detect(pending.table) {
                store.completeImport(pending, existingAccount: nil, newName: pending.suggestedName, mapping: mapping)
            } else {
                print("DEBUG: no mapping for \(pending.fileURL.lastPathComponent)")
                store.cancelImport(pending)
            }
        }
        for issue in store.importIssues { print("DEBUG ISSUE \(issue.file): \(issue.reason)") }
        store.importIssues = []
        try? await Task.sleep(for: .milliseconds(500))
        await settle()
        print("DEBUG: all sorted after \(String(format: "%.1f", Date.now.timeIntervalSince(started)))s; needs a look: \(store.reviewItems.count)")

        for (key, txns) in Dictionary(grouping: store.transactions, by: \.merchantKey).sorted(by: { $0.key < $1.key }) {
            let t = txns[0]
            print("DEBUG SUGGEST \(t.description) → \(t.merchant) | \(t.category.rawValue) | \(t.source.rawValue)\(t.needsCheck ? " ?" : "") [\(key)] x\(txns.count)")
        }
        // SPENDTHRIFT_NOTICED=<year>: what "Things I noticed" shows for the latest months and for that year, then quit.
        if let wanted = env["SPENDTHRIFT_NOTICED"].flatMap(Int.init) {
            func show(_ scope: NoticedScope) {
                let found = store.noticed(in: scope)
                print("NOTICED \(scope.label): \(found.count)")
                for f in found.prefix(6) { print("   \(f.item.title) | \(f.charges.count) charges | \(Money.format(abs(f.charges.reduce(0) { $0 + $1.amount }), cents: false))") }
            }
            show(.last12)
            for m in store.months.suffix(3) { show(.month(m)) }
            await store.readIfNeeded(.year(wanted))
            show(.year(wanted))
            if let m = store.months.first(where: { $0.year == wanted && $0.month == 7 }) { show(.month(m)) }
            NSApp.terminate(nil); return
        }
        // SPENDTHRIFT_WINE=1: move bottle shops into Wine & Spirits, print what moved and the total, then quit.
        if env["SPENDTHRIFT_WINE"] != nil {
            await store.adoptWineCategory(force: true)
            let wine = store.transactions.filter { $0.category == .wine }
            print("WINE TOTAL \(Set(wine.map(\.merchant)).count) places, \(wine.count) charges, \(Int(wine.reduce(0) { $0 + $1.amount }))")
            NSApp.terminate(nil); return
        }
        // SPENDTHRIFT_TRIPPIC=<part of a trip's name>: draw that trip's picture, then quit.
        if let wanted = env["SPENDTHRIFT_TRIPPIC"] {
            if let story = store.stories.first(where: { $0.name.localizedCaseInsensitiveContains(wanted) }) {
                await TripPictures.shared.ensure(story, store: store)
                if let why = TripPictures.shared.failed[story.fingerprint] { print("TRIPPIC failed: \(why)") }
                print("TRIPPIC \(story.name): \(TripPictures.shared.kept[story.fingerprint].map { "\($0.file) | \($0.merchant) \($0.amount) | \($0.caption)" } ?? "nothing drawn")")
            } else { print("TRIPPIC no trip named \(wanted)") }
            NSApp.terminate(nil); return
        }
        // SPENDTHRIFT_ORDERS=a:b: read order-history exports, print how the charges match, then quit.
        if let given = env["SPENDTHRIFT_ORDERS"] {
            let started = Date.now
            await store.importFilesAndWait(given.split(separator: ":").map { URL(fileURLWithPath: String($0)) })
            print("ORDERS \(String(format: "%.2f", Date.now.timeIntervalSince(started)))s")
            if env["SPENDTHRIFT_NO_CLOUD"] == nil {
                await store.readOrderListings()
                // (A reading begun at launch may still be going: wait for it.)
                for _ in 0..<3_000 where store.isReadingOrders { try? await Task.sleep(for: .milliseconds(200)) }
                print("ORDERS listings read in \(String(format: "%.0f", Date.now.timeIntervalSince(started)))s")
                var byCategory: [String: Int] = [:]
                for row in store.orderRows { byCategory[row.category.rawValue, default: 0] += 1 }
                print("ORDERS people \(store.orderPeople) | " + byCategory.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
                for row in store.orderRows.suffix(400).shuffled().prefix(40) { print("ORDERS   \(row.category.rawValue) | \(row.name) ← \(row.item.name.prefix(70))") }
            }
            for line in store.orderReport() { print("ORDERS \(line)") }
            NSApp.terminate(nil); return
        }
        // SPENDTHRIFT_CHECKS=1: read the pictures of paid checks, print what each turned out to be, then quit.
        if env["SPENDTHRIFT_CHECKS"] != nil {
            let report = await store.readCheckPictures()
            for line in report { print("CHECKS \(line)") }
            print("CHECKS named \(report.count)")
            store.saveForQuit()
            NSApp.terminate(nil); return
        }
        // SPENDTHRIFT_SEPARATE="Paramount+|hotel|Paramount Hotel|Travel": every way the payee is written that
        // contains the word becomes the named payee, as the "Not this payee?" link on a payee's page does.
        if let spec = env["SPENDTHRIFT_SEPARATE"]?.split(separator: "|").map(String.init), spec.count == 4 {
            let spellings = Set(store.transactions.filter { $0.merchant == spec[0] }.map { MerchantResolver.spelling($0.description) })
                .filter { $0.localizedCaseInsensitiveContains(spec[1]) }
            for spelling in spellings.sorted() {
                store.separate(spelling: spelling, from: spec[0], as: spec[2], category: Category.pickable.first { $0.rawValue == spec[3] })
                print("SEPARATE \(spelling) -> \(spec[2])")
            }
            print("SEPARATE now: \(spec[0]) \(store.transactions.filter { $0.merchant == spec[0] }.count), \(spec[2]) \(store.transactions.filter { $0.merchant == spec[2] }.count)")
            try? await Task.sleep(for: .seconds(2))
            NSApp.terminate(nil); return
        }
        // SPENDTHRIFT_DECISION_BENCH="model,model": how well each decision model files payees whose category
        // the person chose by hand (the only ground truth there is), how sure it says it is, and how fast.
        if let models = env["SPENDTHRIFT_DECISION_BENCH"]?.split(separator: ",").map(String.init) {
            var amounts: [String: [Double]] = [:]
            for entry in store.library.entries { amounts[entry.merchantKey, default: []].append(entry.amount) }
            let gold = store.library.merchants.filter { key, info in
                info.source == .user && info.confirmed && info.category.map(Category.pickable.contains) == true && !(info.sample ?? "").isEmpty && amounts[key] != nil
            }.sorted { $0.key < $1.key }.prefix(Int(env["SPENDTHRIFT_BENCH_COUNT"] ?? "") ?? 200)
            var states: [String: String] = [:]
            for (key, info) in gold {
                let list = amounts[key] ?? [], mean = list.reduce(0, +) / Double(max(list.count, 1))
                states[key] = "Transaction text: \(Redactor.scrub(info.sample ?? "")). Money \(mean < 0 ? "came in" : "went out"). "
                    + "Typical amount $\(String(format: "%.2f", abs(mean))). Appears \(list.count) time\(list.count == 1 ? "" : "s")."
            }
            print("DECISION gold payees: \(states.count)")
            for model in models {
                let began = Date.now
                let answers = await Decisions.askAll(job: "Benchmark", model: model, states: states, questions: ["category": CategoryQuestion.question()])
                let seconds = Date.now.timeIntervalSince(began)
                var right = 0, sure = 0, sureRight = 0, quite = 0, quiteRight = 0
                for (key, info) in gold {
                    guard let answer = answers[key]?["category"], let choice = answer.choice else { continue }
                    let ok = choice == info.category?.rawValue
                    if ok { right += 1 }
                    if (answer.confidence ?? 0) >= 0.9 { sure += 1; if ok { sureRight += 1 } }
                    if (answer.confidence ?? 0) >= 0.7 { quite += 1; if ok { quiteRight += 1 } }
                }
                let n = max(answers.count, 1)
                print(String(format: "DECISION %@: answered %d/%d, right %d%%, when >=0.9 sure: %d%% right over %d%% of payees, when >=0.7: %d%% right over %d%%, %.1fs (%.0f ms each)",
                             model, answers.count, states.count, right * 100 / n, sureRight * 100 / max(sure, 1), sure * 100 / n, quiteRight * 100 / max(quite, 1), quite * 100 / n,
                             seconds, seconds * 1000 / Double(n)))
            }
            for line in CloudSpend.shared.lines(days: 1) where line.job == "Benchmark" { print("DECISION cost \(line)") }
            NSApp.terminate(nil); return
        }
        // SPENDTHRIFT_READ=1: print the figures given for the Overview's short version, and what was written from them.
        if env["SPENDTHRIFT_READ"] != nil, let period = ReportData.periods(for: store).first(where: { $0 == .last12 }) ?? ReportData.periods(for: store).first {
            let given = store.overviewFacts(CashFlowData(store: store, period: period), period: period)
            for fact in given.facts { print("READ FACT \(fact)") }
            print("READ TEXT \(await store.read("overview-\(period.id)", basis: given.basis, facts: given.facts) ?? "(nothing written)")")
            store.saveNow()
            NSApp.terminate(nil); return
        }
        // SPENDTHRIFT_ASKIDEAS=1: print the findings and the questions proposed from them (twice: the second set must differ), then quit.
        if env["SPENDTHRIFT_ASKIDEAS"] != nil {
            for _ in 0..<50 where store.orderRows.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            for fact in store.askIdeaFacts() { print("IDEAS FACT \(fact)") }
            await store.refreshAskIdeas()
            for idea in store.keptAskIdeas ?? [] { print("IDEAS FIRST \(idea)") }
            await store.refreshAskIdeas(different: true)
            for idea in store.keptAskIdeas ?? [] { print("IDEAS OTHER \(idea)") }
            store.saveNow()
            NSApp.terminate(nil); return
        }
        // SPENDTHRIFT_TIDY=1: compare payees, act where the model is sure, print every pair and what was done, then quit.
        if env["SPENDTHRIFT_TIDY"] != nil {
            for _ in 0..<100 where store.isSuggesting || store.isTidying { try? await Task.sleep(for: .milliseconds(200)) }
            await store.tidyIfNeeded()
            await store.learnFactsIfNeeded()
            for _ in 0..<600 where store.isLearningFacts { try? await Task.sleep(for: .milliseconds(300)) }
            // Payees split off by the tidy-up get a proper name and category before quitting.
            for _ in 0..<10 where store.isSuggesting { try? await Task.sleep(for: .milliseconds(300)) }
            await store.sortRemaining()
            for _ in 0..<200 where store.isSuggesting { try? await Task.sleep(for: .milliseconds(300)) }
            store.saveNow()
            NSApp.terminate(nil); return
        }
        // SPENDTHRIFT_BENCH=1: how long the things pages do over and over take, then quit.
        if env["SPENDTHRIFT_BENCH"] != nil {
            func time(_ name: String, _ work: () -> Void) {
                let began = Date.now
                for _ in 0..<5 { work() }
                print(String(format: "BENCH %6.1f ms  %@", Date.now.timeIntervalSince(began) * 200, name))
            }
            if let month = store.months.dropLast().last, let period = ReportData.periods(for: store).first {
                time("a change (rebuild everything derived)") { store.changed() }
                time("money in and out, year") { _ = CashFlowData(store: store, period: period) }
                time("money in and out, month") { _ = CashFlowData(store: store, month: month) }
                time("year report") { _ = ReportData(store: store, period: period) }
                time("insights for a month, first time") { store.insightCache = [:]; _ = store.insights(for: month) }
                time("insights for a month, again") { _ = store.insights(for: month) }
                time("awards for a month, again") { _ = store.awards(for: month) }
                time("year report, again") { _ = store.report(for: period) }
                time("subscriptions") { _ = store.subscriptions() }
                time("things noticed, year") { _ = store.noticed(in: .last12) }
                time("on this day") { _ = store.onThisDay() }
                time("recent highlights") { _ = store.recentHighlights() }
                time("trip highlights") { _ = store.tripHighlights() }
                time("category totals + top payees, month") { _ = store.categoryTotals(in: month); _ = store.topMerchants(in: month) }
                time("charges for one category") { _ = store.transactions(matching: TransactionFilter(category: .dining)) }
                time("stories") { _ = store.stories }
                time("categories summary") { _ = store.categorySummary() }
                time("review items / missing statements") { _ = store.reviewItems.count; _ = store.missingStatements.count }
            }
            NSApp.terminate(nil); return
        }
        // SPENDTHRIFT_CLEANUP=1: re-key lines the app now reads better, print what changed, then quit.
        if env["SPENDTHRIFT_CLEANUP"] != nil {
            for line in store.cleanUpPayees() { print("CLEANUP \(line)") }
            NSApp.terminate(nil); return
        }
        // SPENDTHRIFT_REREAD=1: read ledger-style statements again with today's reader, print what changed, then quit.
        if env["SPENDTHRIFT_REREAD"] != nil {
            let before = store.transactions.count
            let report = await store.rereadLedgerStatements()
            for line in report { print("REREAD-REPORT \(line)") }
            print("REREAD-REPORT entries \(before) → \(store.transactions.count); statements re-read \(report.filter { $0.hasPrefix("REREAD") }.count), left \(report.filter { $0.hasPrefix("LEFT") }.count)")
            NSApp.terminate(nil); return
        }
        // SPENDTHRIFT_TIEOUT=1: how each card's payments tie to its statements, then quit.
        if env["SPENDTHRIFT_TIEOUT"] != nil {
            await store.notePeriodsIfNeeded()
            for c in store.cardCoverage {
                print("TIEOUT \(c.issuer) \(c.accounts): \(c.payments) payments \(Int(c.paid)) | tied \(c.tied) | uncovered \(c.uncoveredPayments) (\(Int(c.uncoveredPaid)))")
                for f in c.toFind { print("   FIND \(f.account): \(f.from) to \(f.to), paid \(f.paid) on \(f.paidOn)") }
                for e in c.early { print("   EARLY \(e.date) \(e.amount)") }
                for u in c.unexplained { print("   UNEXPLAINED \(u.date) \(u.amount)") }
            }
            for m in store.missingStatements { print("TIEOUT MONTHS \(m.account): \(CoverageCard.stretches(m.months))") }
            NSApp.terminate(nil); return
        }
        // SPENDTHRIFT_HUNCH=1: ask for a best guess at every place on Double-Check, print them, then quit.
        if env["SPENDTHRIFT_HUNCH"] != nil {
            await store.guessWhatTheyWere()
            for item in store.reviewItems { print("HUNCH \(item.info.name) [\(item.info.sample.prefix(40))] \(item.count)x \(Int(item.total)) → \(item.info.hunch ?? "(none)")") }
            NSApp.terminate(nil); return
        }
        // SPENDTHRIFT_PIECES=1: pictures of the small parts (masthead, a chat answer, a charge's receipt), then quit.
        if env["SPENDTHRIFT_PIECES"] != nil {
            await snap("30-masthead", outDir, width: 230) { Masthead().padding(16) }
            await snap("35-story", outDir, width: 700) { StoryView(scrolls: false) }
            await snap("44-editable", outDir, width: 560) {
                VStack(alignment: .leading, spacing: 20) {
                    EditableName(text: .constant("Wire Transfer to Jane Roe"), font: .system(size: 30, weight: .bold, design: .serif), commit: {})
                    EditableName(text: .constant("Pastis"), font: .system(size: 19, weight: .bold, design: .serif), centered: true, commit: {}).frame(maxWidth: .infinity)
                }.padding(24)
            }
            if !store.orderRows.isEmpty {
                await snap("45-orders", outDir) { OrdersView(scrolls: false) }
                if env["SPENDTHRIFT_ORDERREAD"] != nil {
                    for scope in [BudgetStore.OrderScope.all, .year(store.orderRows.last?.month.year ?? 2026)] {
                        store.orderScope = scope
                        print("ORDERREAD \(scope): \(await OrdersView(scrolls: false).shortVersionForTest() ?? "(nothing)")")
                    }
                    store.orderScope = .all
                }
                if let latest = store.orderRows.last {
                    store.orderScope = .year(latest.month.year)
                    await snap("45-orders-year", outDir) { OrdersView(scrolls: false) }
                    store.orderScope = .month(latest.month.adding(-1)); store.orderWho = store.orderPeople.last
                    await snap("45-orders-month", outDir) { OrdersView(scrolls: false) }
                    store.orderScope = .all; store.orderWho = nil
                }
                store.orderSearch = "coffee"
                await snap("46-orders-search", outDir) { OrdersView(scrolls: false) }
                store.orderSearch = ""
                let spent = store.transactions.filter { $0.amount > 0 }
                let picks: [(String, Transaction?)] = [
                    ("47-receipt-items", spent.first { (store.orderDetail(for: $0.id)?.items.count ?? 0) >= 3 && store.orderDetail(for: $0.id)?.kind == .exact }),
                    ("48-receipt-credit", spent.first { store.orderDetail(for: $0.id)?.kind == .lessCredit }),
                    ("49-receipt-nomatch", spent.first { store.orderGap(for: $0) != nil }),
                ]
                for (name, pick) in picks {
                    if let pick { await snap(name, outDir, width: 380) { TransactionInspector(transaction: pick, scrolls: false) } }
                }
            }
            if !store.setApart.isEmpty { await snap("50-kept-apart", outDir) { SetApartView(scrolls: false) } }
            for story in store.stories where !(BudgetStore.shared.storyNamesForTest.isEmpty) && BudgetStore.shared.storyNamesForTest.contains(story.name) {
                print("STORYNAME \(story.name) | \(story.start) to \(story.end) | \(story.entryIDs.count) charges")
            }
            await snap("36-statements", outDir) { StatementsView(scrolls: false) }
            if let month = store.lastFullMonth {
                for (i, kind) in PremiereCard.Kind.available(in: store, month: month).enumerated() {
                    await snap("40-recap-\(i + 1)", outDir, width: 900) { PremiereCard(kind: kind, month: month).padding(.vertical, 40) }
                }
            }
            await snap("41-onthisday", outDir, width: 900) { OnThisDayLine().padding(20) }
            if let memory = store.onThisDay() { print("ONTHISDAY \(memory.years)y \(memory.charge.merchant) \(memory.charge.amount)") } else { print("ONTHISDAY none") }
            if let period = ReportData.periods(for: store).first {
                await snap("42-verdict", outDir, width: 900) { FlowHero(data: CashFlowData(store: store, period: period)).padding(20) }
            }
            if let card = PictureSharing.card(DailyPicture.shared), let data = IconRenderer.png(card) { try? data.write(to: outDir.appendingPathComponent("43-share.png")) }
            print("TRIPS \(store.tripHighlights().count): " + store.tripHighlights().prefix(6).map { "\($0.trip ?? "") / \($0.merchant) \($0.amount)" }.joined(separator: "; "))
            store.placeSearch = env["SPENDTHRIFT_FIND"] ?? "pastis"
            await snap("38-places", outDir, width: 900) { PlacesView(scrolls: false) }
            store.placeSearch = ""
            await store.notePeriodsIfNeeded()
            await snap("37-tieout", outDir, width: 944) { CardCoverageCard(coverage: store.cardCoverage).padding(20) }
            let q = "Where did most of my money go in October?"
            let query = await QueryParser.parse(q, months: store.months)
            var answer = AnswerEngine.answer(q, query: query, store: store)
            if let m = store.months.dropLast().last {
                answer.chart = store.categoryTotals(in: m).prefix(6).map { ChatAnalyst.ChartBar(label: $0.category.displayName, value: $0.total, category: $0.category) }
            }
            answer.understood = "October by category · October's largest charges"
            await snap("31-answer", outDir, width: 380) { AnswerBubble(answer: answer).padding(18) }
            if let t = store.transactions.last(where: { $0.countsAsSpending && $0.amount > 40 }) {
                await snap("32-receipt", outDir, width: 300) { TransactionInspector(transaction: t, scrolls: false) }
            }
            if let m = store.months.dropLast().last ?? store.months.last {
                await snap("33-itemized", outDir) { CeremonyCard(month: m).padding(28) }
            }
            await snap("34-banner", outDir) { BannerCard().padding(28) }
            NSApp.terminate(nil); return
        }
        // SPENDTHRIFT_PICTURES=tony,paul,both: draw one banner picture for each, then quit.
        if let casts = env["SPENDTHRIFT_PICTURES"] {
            for who in casts.split(separator: ",").map(String.init) {
                DailyPicture.shared.allowAnother()
                DailyPicture.shared.forcedCast = who
                DailyPicture.shared.forcedTrip = env["SPENDTHRIFT_TRIP"] != nil
                print("DEBUG PICTURE asking for \(who): cloud \(CloudAI.isEnabled), highlights \(store.recentHighlights().count), busy \(DailyPicture.shared.isGenerating), photo \(DailyPicture.shared.headshot != nil)")
                await DailyPicture.shared.prepareNext(highlights: store.recentHighlights(), trips: store.tripHighlights())
            }
            NSApp.terminate(nil); return
        }
        if let out = env["SPENDTHRIFT_LOCATE"] { locateEverything(URL(fileURLWithPath: out)); NSApp.terminate(nil); return }
        if env["SPENDTHRIFT_SUGGEST_ONLY"] != nil { NSApp.terminate(nil); return }
        // SPENDTHRIFT_CHAT="first question|a follow-up|another": a conversation with Ask the Academy.
        if let chat = env["SPENDTHRIFT_CHAT"] {
            // SPENDTHRIFT_CHAT_ON=amazon:2026 asks as if that page were in front.
            if let on = env["SPENDTHRIFT_CHAT_ON"], on.hasPrefix("amazon") {
                store.selection = .orders
                if let year = Int(on.dropFirst(7)) { store.orderScope = .year(year) }
                print("CHAT screen: \(store.screenContext ?? "none")")
            }
            var turns: [ChatAnalyst.Turn] = []
            for q in chat.split(separator: "|").map(String.init) {
                let started = Date.now
                if let (answer, turn) = await ChatAnalyst.answer(q, history: turns, store: store) {
                    turns.append(turn)
                    print("CHAT Q: \(q)\n  A (\(String(format: "%.1f", Date.now.timeIntervalSince(started)))s): \(answer.headline)\n  looked up: \(answer.understood ?? "-") | rows \(answer.rows.count) | chart bars \(answer.chart.count)\(answer.chartIsLine ? " (line)" : "")")
                    for row in answer.rows.prefix(4) { print("    \(row.label) — \(row.detail) — \(row.value)") }
                } else { print("CHAT Q: \(q)\n  (no answer from the cloud)") }
            }
            NSApp.terminate(nil); return
        }
        if env["SPENDTHRIFT_SELFTEST"] != nil { await SelfTest.run(files: files); NSApp.terminate(nil); return }

        await snap("03-review", outDir) { ReviewView(scrolls: false) }
        let confirmedForThePicture = store.reviewItems.map(\.key)
        store.confirm(confirmedForThePicture)
        try? await Task.sleep(for: .seconds(8))   // let the daily picture and the recap finish
        await settle()
        // The page as it opens (the last twelve months), then one month and that month's pages.
        store.overviewShowsYear = true
        await snap("04-overview", outDir) { OverviewView(scrolls: false) }
        // The year's Spending page (where to trim, ways to save) before switching to one month.
        store.overviewDetail = .spending
        await snap("04-overview-spending-year", outDir) { OverviewView(scrolls: false) }
        store.overviewDetail = nil
        store.overviewShowsYear = false
        await snap("04-overview-month", outDir) { OverviewView(scrolls: false) }
        for detail in [BudgetStore.OverviewDetail.spending, .income, .investing, .flow, .recurring, .budgets] {
            store.overviewDetail = detail
            await snap("04-overview-\(detail.rawValue)", outDir) { OverviewView(scrolls: false) }
        }
        store.overviewDetail = nil
        store.overviewShowsYear = true
        // SPENDTHRIFT_YEAR=2023 picks the year; any other value shows the latest.
        if let year = env["SPENDTHRIFT_YEAR"].flatMap(Int.init) { store.overviewPeriod = .year(year) }
        await snap("04-overview-year", outDir) { OverviewView(scrolls: false) }
        store.overviewShowsYear = true
        store.overviewPeriod = nil
        if let p = ReportData.periods(for: store).first {
            let data = ReportData(store: store, period: p)
            await snap("07-report", outDir) { ReportContent(data: data, interactive: false).padding(28) }
            print("DEBUG: report pdf \(ReportExporter.write(data: data, store: store, to: outDir.appendingPathComponent("report.pdf")))")
        }
        if let p = ReportData.periods(for: store).first {
            let flow = CashFlowData(store: store, period: p)
            await snap("05-cashflow", outDir) { CashFlowContent(data: flow, interactive: false).padding(28) }
            print("DEBUG FLOW income \(Int(flow.income)) spending \(Int(flow.spending)) (uncovered cards \(Int(flow.uncoveredCards))) taxes \(Int(flow.taxes)) invIn \(Int(flow.investmentIn)) invOut \(Int(flow.investmentOut)) hidden \(Int(flow.transfersHidden)) unsortedIn \(Int(flow.unsortedIn)) net \(Int(flow.netCash))")
            for c in flow.byInvestmentCategory { print("DEBUG FLOW   \(c.category.rawValue): in \(Int(c.moneyIn)) out \(Int(c.moneyOut))") }
            for c in store.cardCoverage { print("DEBUG CARD \(c.issuer): paid \(Int(c.paid)) x\(c.payments), uncovered \(Int(c.uncoveredPaid)) x\(c.uncoveredPayments), accounts \(c.accounts), statement spend \(Int(c.statementSpend))") }
        }
        // Trips and events are found after sorting finishes; give that pass time to run.
        for _ in 0..<420 where store.isFindingStories || (CloudAI.isEnabled && store.stories.isEmpty && store.transactions.count >= 20 && !storiesWaited) {
            try? await Task.sleep(for: .milliseconds(500))
            if !store.isFindingStories, store.stories.isEmpty { storiesWaited = true }
        }
        for s in store.stories {
            let t = store.transactions(in: s)
            print("DEBUG STORY \(s.kind.rawValue) | \(s.name) | \(s.place ?? "-") | \(s.start)…\(s.end) | \(t.count) charges | \(Int(t.reduce(0) { $0 + $1.amount })) | \(s.summary)")
        }
        await snap("06-stories", outDir) { StoriesView(scrolls: false) }
        await snap("11-coverage", outDir) { CoverageCard().padding(28).frame(width: 1000) }
        for (i, kind) in PremiereCard.Kind.available(in: store).enumerated() {
            await snap("20-premiere-\(i + 1)", outDir) { PremiereCard(kind: kind).padding(.vertical, 50).frame(width: 900) }
        }
        // SPENDTHRIFT_PLACE="DoorDash" picks the payee; otherwise the busiest one.
        if let busiest = env["SPENDTHRIFT_PLACE"] ?? Dictionary(grouping: store.transactions.filter(\.countsAsSpending), by: \.merchant).max(by: { $0.value.count < $1.value.count })?.key {
            await snap("12-place", outDir) { PlaceView(name: busiest, scrolls: false).frame(width: 1000) }
        }
        if let trip = store.stories.max(by: { store.transactions(in: $0).count < store.transactions(in: $1).count }) {
            await snap("13-charges", outDir) { ChargesView(filter: TransactionFilter(storyID: trip.id), scrolls: false).frame(width: 1000) }
        }
        await snap("09-allcaughtup", outDir) { ReviewView(scrolls: false) }
        // Put the guesses back: the picture needed an empty list, the library doesn't.
        store.unconfirm(confirmedForThePicture)
        await snap("10-new-category", outDir) {
            CategoryEditorSheet(request: CategoryEditorRequest(editing: CustomCategory(name: "Pets", symbol: "pawprint.fill", color: "teal")))
        }

        if let m = store.months.last {
            print("DEBUG month \(m.key): spent \(store.totalSpent(in: m))")
            for (c, t) in store.categoryTotals(in: m) { print("DEBUG   cat \(c.rawValue): \(t)") }
            for a in AwardEngine.awards(for: m, in: store.transactions) { print("DEBUG   award \(a.title): \(a.winner) \(a.value)") }
            for i in store.insights(for: m) { print("DEBUG   insight \(i.title) — \(i.detail)") }
            let recap = await RecapWriter.recap(month: m, total: store.totalSpent(in: m), previous: store.totalSpent(in: m.adding(-1)),
                                                awards: AwardEngine.awards(for: m, in: store.transactions), insights: store.insights(for: m))
            print("DEBUG   recap: \(recap)")
        }
        for q in ["How much did I spend on dining in October?", "What are my subscriptions?", "Top places this year", "How much did I spend at Whole Foods last month?", "How many times did I go to Starbucks in September?", "Groceries from August to October", "What did I buy at Amazon?"] {
            let query = await QueryParser.parse(q, months: store.months)
            let a = AnswerEngine.answer(q, query: query, store: store)
            print("DEBUG ASK \(q)\n   → \(query.metric.rawValue) cat=\(query.category?.rawValue ?? "any") place=\(query.place ?? "any") \(query.from.key)…\(query.to.key)\n   → \(a.headline)")
        }
        print("DEBUG: done. accounts=\(store.accounts.map(\.name)) transactions=\(store.transactions.count)")
        NSApp.terminate(nil)
    }

    /// SPENDTHRIFT_LOCATE=<folder>: look every charge up in its original, count how many are pinpointed,
    /// and save pictures of a few pages with the line marked.
    private static func locateEverything(_ folder: URL) {
        let store = BudgetStore.shared
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var docs: [String: PDFDocument] = [:], sheets: [String: SourceLocator.Sheet] = [:]
        var tally: [String: (sure: Int, close: Int, none: Int, unlinked: Int)] = [:]
        var pictures: [String: Int] = [:]
        let started = Date.now
        for t in store.transactions {
            guard let entry = store.entry(t.id) else { continue }
            var row = tally[t.account] ?? (0, 0, 0, 0)
            defer { tally[t.account] = row }
            let candidates = store.sourceCandidates(for: entry)
            if entry.sourceID == nil { row.unlinked += 1 }
            guard let source = OriginalChooser.best(for: entry, among: candidates, store: store) else { row.none += 1; continue }
            let target = SourceLocator.Target(entry)
            if source.isPDF {
                if docs[source.id] == nil { docs[source.id] = PDFDocument(url: store.sourceURL(source)) }
                guard let doc = docs[source.id], let hit = SourceLocator.locate(target, in: doc) else {
                    row.none += 1; print("LOCATE none | \(t.account) | \(entry.date) \(entry.description) \(entry.amount) | \(source.name)"); continue
                }
                if hit.isSure { row.sure += 1 } else { row.close += 1; print("LOCATE close \(String(format: "%.1f", hit.score)) | \(t.account) | \(entry.date) \(entry.description) \(entry.amount) | \(source.name) p\(hit.pageIndex + 1)") }
                let kind = t.account + (hit.isSure ? "" : "-close")
                if pictures[kind, default: 0] < 2, let page = doc.page(at: hit.pageIndex) {
                    pictures[kind, default: 0] += 1
                    let box = page.bounds(for: .mediaBox), scale: CGFloat = 1.6
                    let image = NSImage(size: NSSize(width: box.width * scale, height: box.height * scale), flipped: false) { _ in
                        guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
                        ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: box.width * scale, height: box.height * scale))
                        ctx.scaleBy(x: scale, y: scale)
                        page.draw(with: .mediaBox, to: ctx)
                        ctx.setFillColor(NSColor.systemYellow.withAlphaComponent(0.3).cgColor)
                        if let r = hit.row?.bounds(for: page) { ctx.fill(CGRect(x: 0, y: r.minY, width: box.width, height: r.height)) }
                        ctx.setStrokeColor(NSColor.systemRed.cgColor); ctx.setLineWidth(1.5)
                        ctx.stroke(hit.amount.bounds(for: page).insetBy(dx: -3, dy: -2))
                        return true
                    }
                    let name = "\(kind.filter { $0.isLetter || $0.isNumber || $0 == "-" })-\(pictures[kind]!).png"
                    try? IconRenderer.png(image)?.write(to: folder.appendingPathComponent(name))
                    print("LOCATE PICTURE \(name): \(entry.date) \(entry.description) \(entry.amount)")
                }
            } else if !source.isPicture {
                if sheets[source.id] == nil { sheets[source.id] = SourceLocator.sheet(at: store.sourceURL(source), ext: source.ext) }
                guard let sheet = sheets[source.id], let hit = SourceLocator.locate(target, in: sheet) else {
                    row.none += 1; print("LOCATE none | \(t.account) | \(entry.date) \(entry.description) \(entry.amount) | \(source.name)"); continue
                }
                if hit.isSure { row.sure += 1 } else { row.close += 1; print("LOCATE close | \(t.account) | \(entry.date) \(entry.description) \(entry.amount) | row \(hit.row + 1): \(sheet.rows[hit.row])") }
                if pictures["table", default: 0] < 1 {
                    pictures["table", default: 0] += 1
                    print("LOCATE TABLE \(source.name) row \(hit.row + 1) col \(hit.column ?? -1): \(sheet.header) / \(sheet.rows[hit.row])")
                }
            } else { row.none += 1 }
        }
        for (account, r) in tally.sorted(by: { $0.key < $1.key }) {
            print("LOCATE TALLY \(account): pinpointed \(r.sure), closest \(r.close), not found \(r.none) (not linked at import: \(r.unlinked))")
        }
        print("LOCATE DONE \(store.transactions.count) charges, \(store.sourceFiles.count) originals, \(String(format: "%.1f", Date.now.timeIntervalSince(started)))s")
    }

    /// Exercises the things a person does by clicking: changing categories, undoing an import, re-importing.
    private static func settle() async {
        for _ in 0..<240 {
            try? await Task.sleep(for: .milliseconds(500))
            let s = BudgetStore.shared
            if !s.isSuggesting && !s.isImporting && !DailyPicture.shared.isGenerating { break }
        }
        try? await Task.sleep(for: .seconds(1))
    }

    /// Renders a screen's content to a PNG. (ImageRenderer can't draw scroll views, tables or
    /// AppKit-backed controls such as menus and text fields; those show as blank or yellow boxes.)
    private static func snap(_ name: String, _ dir: URL, width fixed: CGFloat? = nil, @ViewBuilder _ view: () -> some View) async {
        // SPENDTHRIFT_WIDTH: the width a page really gets (about 870 beside the question pane).
        // SPENDTHRIFT_DARK: the same pages in Dark Mode.
        let width = fixed ?? env["SPENDTHRIFT_WIDTH"].flatMap(Double.init).map { CGFloat($0) } ?? 1000
        let dark = env["SPENDTHRIFT_DARK"] != nil
        let content = view()
            .environment(BudgetStore.shared)
            .tint(Theme.accent)
            .frame(width: width)
            .frame(minHeight: fixed == nil ? 500 : 40)
            .background(Theme.paper)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1.5
        if let image = renderer.nsImage, let data = IconRenderer.png(image) {
            try? data.write(to: dir.appendingPathComponent("\(name).png"))
        }
        print("DEBUG: snapped \(name)")
    }
}
