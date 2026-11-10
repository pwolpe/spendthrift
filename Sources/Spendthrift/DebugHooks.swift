import SwiftUI
import AppKit
import PDFKit

/// Test automation, active only when SPENDTHRIFT_SNAPSHOT is set (never for Tony).
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
        store.selection = .cashflow
        await shot("4-cashflow")
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
        // SPENDTHRIFT_TIEOUT=1: how each card's payments tie to its statements, then quit.
        if env["SPENDTHRIFT_TIEOUT"] != nil {
            await store.notePeriodsIfNeeded()
            for c in store.cardCoverage {
                print("TIEOUT \(c.issuer) \(c.accounts): \(c.payments) payments \(Int(c.paid)) | tied \(c.tied) | uncovered \(c.uncoveredPayments) (\(Int(c.uncoveredPaid)))")
                for f in c.toFind { print("   FIND \(f.account): \(f.from) to \(f.to), paid \(f.paid) on \(f.paidOn)") }
                for e in c.early { print("   EARLY \(e.date) \(e.amount)") }
                for u in c.unexplained { print("   UNEXPLAINED \(u.date) \(u.amount)") }
            }
            for m in store.missingStatements { print("TIEOUT MONTHS \(m.summary)") }
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
            await snap("36-statements", outDir) { StatementsView(scrolls: false) }
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
                print("DEBUG PICTURE asking for \(who): cloud \(CloudAI.isEnabled), highlights \(store.recentHighlights().count), busy \(DailyPicture.shared.isGenerating), photo \(DailyPicture.shared.headshot != nil)")
                await DailyPicture.shared.prepareNext(highlights: store.recentHighlights())
            }
            NSApp.terminate(nil); return
        }
        if let out = env["SPENDTHRIFT_LOCATE"] { locateEverything(URL(fileURLWithPath: out)); NSApp.terminate(nil); return }
        if env["SPENDTHRIFT_SUGGEST_ONLY"] != nil { NSApp.terminate(nil); return }
        // SPENDTHRIFT_CHAT="first question|a follow-up|another": a conversation with Ask the Academy.
        if let chat = env["SPENDTHRIFT_CHAT"] {
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
        if env["SPENDTHRIFT_SELFTEST"] != nil { await selfTest(files: files); NSApp.terminate(nil); return }

        await snap("03-review", outDir) { ReviewView(scrolls: false) }
        let confirmedForThePicture = store.reviewItems.map(\.key)
        store.confirm(confirmedForThePicture)
        try? await Task.sleep(for: .seconds(8))   // let Daily Tony and the recap finish
        await settle()
        await snap("04-overview", outDir) { OverviewView(scrolls: false) }
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
        // SPENDTHRIFT_FORECAST=1 (optionally "Place|note" first): print the estimate for next month.
        if let spec = ProcessInfo.processInfo.environment["SPENDTHRIFT_FORECAST"], let next = store.months.last?.adding(1) {
            let parts = spec.split(separator: "|", maxSplits: 1).map(String.init)
            if parts.count == 2 { store.setNote(parts[1], forPlace: store.transactions.first { $0.merchant.localizedCaseInsensitiveContains(parts[0]) }?.merchant ?? parts[0]) }
            let history = store.months.suffix(12).map { m -> String in
                let top = store.categoryTotals(in: m).prefix(6).map { "\($0.category.displayName) \(Int($0.total))" }.joined(separator: ", ")
                return "\(m.title): total \(Int(store.totalSpent(in: m))) (\(top))"
            }
            let repeating = store.subscriptions().map { "\($0.merchant): \(Money.format($0.monthlyAmount)) a month" }
            Forecaster.forget()
            let e = await Forecaster.estimate(month: next.title, history: history, repeating: repeating, notes: store.allNotes(), basis: "test-\(spec)")
            print("FORECAST \(next.title): \(e.map { "about \(Int($0.amount)) (\(Int($0.low))–\(Int($0.high))): \($0.because)" } ?? "none") | notes: \(store.allNotes().count)")
            Forecaster.forget()
        }
        for (i, kind) in PremiereCard.Kind.available(in: store).enumerated() {
            await snap("20-premiere-\(i + 1)", outDir) { PremiereCard(kind: kind).padding(.vertical, 50).frame(width: 900) }
        }
        if let busiest = Dictionary(grouping: store.transactions.filter(\.countsAsSpending), by: \.merchant).max(by: { $0.value.count < $1.value.count })?.key {
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

    /// Exercises the things Tony does by clicking: changing categories, undoing an import, re-importing.
    private static func selfTest(files: [URL]) async {
        let store = BudgetStore.shared
        func check(_ name: String, _ ok: Bool) { print("SELFTEST \(ok ? "PASS" : "FAIL") \(name)") }
        // SPENDTHRIFT_EXPLAIN="Whitfield|my accountant, for tax prep": say what a place was and print what happened.
        if let spec = ProcessInfo.processInfo.environment["SPENDTHRIFT_EXPLAIN"]?.split(separator: "|", maxSplits: 1).map(String.init), spec.count == 2,
           let t = store.transactions.first(where: { $0.merchant.localizedCaseInsensitiveContains(spec[0]) }) {
            let before = "\(t.merchant) | \(t.category.displayName)"
            let ok = await store.explain(t.merchantKey, said: spec[1])
            let after = store.transactions.first { $0.id == t.id }
            print("EXPLAIN \(ok ? "ok" : "failed"): \(before)  →  \(after?.merchant ?? "?") | \(after?.category.displayName ?? "?") | note: \(after?.note ?? "-") | needs check: \(after?.needsCheck ?? true)")
        }
        if store.stories.count >= 2, let moving = store.transactions(in: store.stories[0]).first?.id {
            let from = store.stories[0], to = store.stories[1]
            let before = store.transactions(in: to).count
            store.move([moving], to: to)
            check("move a charge between trips", store.story(containing: moving)?.fingerprint == to.fingerprint
                  && store.stories.first { $0.fingerprint == to.fingerprint }.map { store.transactions(in: $0).count } == before + 1)
            store.move([moving], to: nil)
            check("take a charge out of every trip", store.story(containing: moving) == nil)
            store.move([moving], to: from)
        }
        guard let t = store.transactions.first(where: { $0.countsAsSpending && $0.category != .gifts }) else { return check("has data", false) }
        let samePlace = store.transactions.filter { $0.merchantKey == t.merchantKey }.count

        store.setCategory(.gifts, for: [t.id], wholePlace: false)
        check("only-this-charge changes one", store.transactions.filter { $0.merchantKey == t.merchantKey && $0.category == .gifts }.count == 1)
        check("override is flagged", store.transactions.first { $0.id == t.id }?.isOverride == true)

        store.setCategory(.travel, for: [t.id], wholePlace: true)
        check("whole-place changes all \(samePlace)", store.transactions.filter { $0.merchantKey == t.merchantKey && $0.category == .travel }.count == samePlace)
        check("whole-place marks as user's choice", store.place(t.merchantKey)?.source == .user && store.place(t.merchantKey)?.confirmed == true)

        store.renamePlace(t.merchantKey, to: "Renamed Place")
        check("rename applies everywhere", store.transactions.filter { $0.merchant == "Renamed Place" }.count == samePlace)

        // Custom categories
        let pets = store.saveCategory(CustomCategory(name: "Pets", symbol: "pawprint.fill", color: "teal"))
        check("create custom category", pets != nil && Category.spendingCases.contains(Category("Pets")) && Category("Pets").symbol == "pawprint.fill")
        check("duplicate name refused", store.saveCategory(CustomCategory(name: "pets", symbol: "tag.fill", color: "red")) == nil
              && store.saveCategory(CustomCategory(name: "Dining", symbol: "tag.fill", color: "red")) == nil)
        if let pets {
            store.setCategory(pets, forPlace: t.merchantKey)
            check("file a place under it", store.transactions.filter { $0.category == pets }.count == samePlace)
            var edited = store.customCategories[0]; edited.name = "Dog"
            store.saveCategory(edited)
            check("rename keeps its charges", store.transactions.filter { $0.category == Category("Dog") }.count == samePlace && !Category.allCases.contains(pets))
            check("AI schema offers it", Category.spendingCases.map(\.rawValue).contains("Dog") && AISchemas.merchantGuesses(count: 1, purchasesOnly: true) != nil)
            store.deleteCategory(store.customCategories[0])
            check("delete moves charges to Other", store.transactions.filter { $0.merchantKey == t.merchantKey && $0.category == .other }.count == samePlace && Category.custom.isEmpty)
            store.setCategory(.travel, forPlace: t.merchantKey)
        }

        let before = store.transactions.count, accountsBefore = store.accounts.count
        store.importFiles(files)
        try? await Task.sleep(for: .seconds(3))
        check("re-import adds nothing (\(store.transactions.count) vs \(before))", store.transactions.count == before && store.accounts.count == accountsBefore)
        check("choices survive re-import", store.transactions.filter { $0.merchantKey == t.merchantKey && $0.category == .travel }.count == samePlace)

        if let account = store.accounts.first {
            let spent = store.spent(in: account)
            store.flipAmounts(account.id)
            check("flip swaps signs", abs(store.spent(in: account) + spent) < 0.01 || spent == 0)
            store.flipAmounts(account.id)
            check("flip twice restores", abs(store.spent(in: account) - spent) < 0.01)
            let n = store.transactionCount(for: account)
            store.removeAccount(account.id)
            check("remove account drops its \(n) transactions", store.transactions.count == before - n)
        }
        // Saved library reloads identically.
        try? await Task.sleep(for: .seconds(1))
        let reloaded = Library.load(paths: store.paths).0
        check("saved to disk (\(reloaded.entries.count) entries)", reloaded.entries.count == store.transactions.count)
    }

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
