import SwiftUI
import Charts

struct OverviewView: View {
    @Environment(BudgetStore.self) private var store
    /// The bar under the pointer in "Month by month".
    @State private var hoveredBar: String?
    @State private var hoveredAngle: Double?
    /// Whether the notices behind the first are on show.
    @State private var showsAllNotices = false

    /// False when rendered for a test snapshot (ImageRenderer can't draw scroll views).
    var scrolls = true

    private var currentMonth: Month? { store.overviewMonth.flatMap { store.months.contains($0) ? $0 : nil } ?? store.months.last }

    var body: some View {
        if scrolls {
            ScrollView { content }.navigationTitle("Overview")
        } else {
            content
        }
    }

    private var content: some View {
        let _ = Launch.mark("overview body")
        return VStack(alignment: .leading, spacing: 20) {
            if let detail = store.overviewDetail, flowData != nil {
                detailPage(detail)
            } else {
                summary
            }
        }
        .padding(28)
        .frame(maxWidth: 1200)
        .frame(maxWidth: .infinity)
    }

    /// The stretch on screen, summed: a month, or a year.
    private var flowData: CashFlowData? {
        // Kept until the data changes: this page redraws on every hover, and the sums read every transaction.
        if store.overviewShowsYear { return currentPeriod.map { period in store.cached("flow|\(period.id)") { CashFlowData(store: store, period: period) } } }
        return currentMonth.map { month in store.cached("flow|\(month.key)") { CashFlowData(store: store, month: month) } }
    }

    // MARK: The summary: one answer, then a few cards to step into

    @ViewBuilder
    private var summary: some View {
        if !DebugHooks.off("daily") { BannerCard() }
        tray
        if store.months.count > 1 { scopePicker }
        if let data = flowData {
            // The judgment that matters most comes first: did living stay within income?
            if !DebugHooks.off("hero") {
                if store.overviewShowsYear, let period = currentPeriod {
                    // The verdict, said in the model's words when it has written some (it is asked once the page is up).
                    // Shown at once when nothing has changed since it was last checked; checked properly
                    // (the figures worked out, the sentences compared) only after the page is up.
                    let _ = store.readsChecked
                    FlowHero(data: data, written: store.glancedRead("overview-\(period.id)")) { store.stepInto(.flow) }
                        .task(id: "\(period.id)|\(store.revision)") {
                            try? await Task.sleep(for: .seconds(1))
                            guard !Task.isCancelled else { return }
                            let given = store.overviewFacts(data, period: period)
                            await store.confirmRead("overview-\(period.id)", basis: given.basis, facts: given.facts)
                        }
                } else {
                    FlowHero(data: data) { store.stepInto(.flow) }
                }
            }
            // Why it differs from usual. A month is cheap to explain; the year waits for the first frame.
            if !store.overviewShowsYear, let m = currentMonth, let why = store.changes(in: m) { ChangeCard(explanation: why) }
            if store.overviewShowsYear, let period = currentPeriod {
                AfterFirstFrame { yearChanges(period) }
            }
            let shownMonth = store.overviewShowsYear ? nil : currentMonth
            let figures = store.cached("figures|\(data.title)|\(shownMonth?.key ?? "")") { Figures(store: store, data: data, month: shownMonth) }
            HStack(alignment: .top, spacing: 16) {
                SummaryCard(title: "Spending", symbol: "creditcard.fill", color: Theme.spent,
                            figure: Money.format(data.spending, cents: false), note: figures.spendingNote, noteColor: figures.spendingNoteColor,
                            action: { store.stepInto(.spending) }) {
                    if figures.categories.isEmpty { Text("No spending in this stretch.").font(.caption).foregroundStyle(.secondary) }
                    else { MiniRing(slices: figures.categories) }
                }
                SummaryCard(title: "Income", symbol: Category.income.symbol, color: Category.income.color,
                            figure: Money.format(data.totalIncome, cents: false), note: figures.incomeNote,
                            action: { store.stepInto(.income) }) {
                    MiniBars(values: figures.income, labels: figures.labels, lit: figures.lit, color: Category.income.color)
                }
                SummaryCard(title: "Investing", symbol: "arrow.up.forward.circle.fill", color: Theme.goldDeep,
                            figure: Money.format(data.built, cents: false), note: figures.investingNote,
                            action: { store.stepInto(.investing) }) {
                    MiniBars(values: figures.invested, labels: figures.labels, lit: figures.lit, color: Theme.goldDeep)
                }
            }
            if !store.overviewShowsYear, let m = currentMonth {
                // A month: what repeats beside what was planned, then anything noticed in it.
                HStack(alignment: .top, spacing: 16) {
                    if !DebugHooks.off("coming") { recurringCard }
                    budgetCard(m)
                }
                if !DebugHooks.off("noticed") { noticed }
            } else {
                // Below the first screenful: both arrive just after the page is up.
                AfterFirstFrame {
                    HStack(alignment: .top, spacing: 16) {
                        if !DebugHooks.off("noticed") { noticed }
                        if !DebugHooks.off("coming") { recurringCard }
                    }
                }
            }
            // Ways to save are about today's habits: they have no place on a year that is over.
            if store.overviewAsOf == nil { AfterFirstFrame { SavingsStrip() } }
            if !store.overviewShowsYear, let m = currentMonth, !DebugHooks.off("stories") { storiesThisMonth(m) }
        } else {
            EmptyState(title: "Nothing here yet", message: "Drop a statement into this window and it all gets added up.", art: "welcome")
        }
    }

    @ViewBuilder
    private func yearChanges(_ period: ReportPeriod) -> some View {
        if let why = store.changes(in: period) { ChangeCard(explanation: why) }
    }

    @ViewBuilder
    private func budgetCard(_ month: Month) -> some View {
        let summary = store.budget(for: month)
        if !summary.lines.isEmpty { BudgetCard(summary: summary) }
    }

    @ViewBuilder
    private var noticed: some View {
        if store.overviewShowsYear {
            switch currentPeriod {
            case .year(let year)?: NoticedCard(scope: .year(year))
            case .last12?: NoticedCard(scope: .last12)
            case nil: EmptyView()
            }
        } else if let m = currentMonth {
            NoticedCard(scope: .month(m))
        }
    }

    /// The small figures on the cards: the run of months each sits in, and a line about each.
    private struct Figures {
        var labels: [String] = []
        let income: [Double]
        let invested: [Double]
        var lit: Int?
        var categories: [(category: Category, total: Double)] = []
        var spendingNote: String?
        var spendingNoteColor: Color = .secondary
        var incomeNote: String?
        var investingNote: String?

        @MainActor init(store: BudgetStore, data: CashFlowData, month: Month?) {
            // A month sits in the six months that end with it; a year shows its own months.
            let window: [Month]
            if let month {
                let first = store.months.first ?? month
                window = (0..<6).reversed().map { month.adding(-$0) }.filter { $0 >= first }
                lit = window.count - 1
            } else {
                window = data.months
            }
            let run = CashFlowData.run(of: window, in: store)
            income = run.map(\.income)
            invested = run.map(\.invested)
            labels = window.map { window.count > 6 ? String($0.shortName.prefix(1)) : $0.shortName }

            if let month {
                categories = store.categoryTotals(in: month)
                let before = month.adding(-1)
                if store.months.contains(before) {
                    let diff = store.totalSpent(in: month) - store.totalSpent(in: before)
                    spendingNote = "\(Money.format(abs(diff), cents: false)) \(diff <= 0 ? "less" : "more") than \(before.name)"
                    spendingNoteColor = diff <= 0 ? Theme.good : Theme.caution
                }
            } else {
                var totals: [Category: Double] = [:]
                for m in window { for item in store.categoryTotals(in: m) { totals[item.category, default: 0] += item.total } }
                categories = totals.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
                if !window.isEmpty { spendingNote = "About \(Money.format(data.spending / Double(window.count), cents: false)) a month" }
            }
            if let top = (data.incomeLines.filter { $0.moneyIn > 0.5 }).max(by: { $0.moneyIn < $1.moneyIn }) {
                incomeNote = data.incomeLines.filter { $0.moneyIn > 0.5 }.count == 1 ? "From \(top.name)" : "Mostly from \(top.name)"
            } else if data.fromInvestments > 0.5 {
                incomeNote = "Paid out by investments"
            } else {
                incomeNote = "Nothing came in"
            }
            let back = data.fromInvestments + data.soldOrRedeemed
            investingNote = data.built > 0.5 ? (back > 0.5 ? "\(Money.format(back, cents: false)) came back" : "Still yours")
                : (back > 0.5 ? "\(Money.format(back, cents: false)) came back" : "Nothing put in")
        }
    }

    // MARK: A card, stepped into

    @ViewBuilder
    private func detailPage(_ detail: BudgetStore.OverviewDetail) -> some View {
        if detail != .recurring, store.months.count > 1 { scopePicker }
        if let data = flowData {
            switch detail {
            case .recurring: RecurringView()
            case .budgets:
                if !store.overviewShowsYear, let m = currentMonth {
                    BudgetView(month: m)
                } else {
                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("A budget is set one month at a time.").font(.body)
                            Button("Look at One Month") { store.overviewShowsYear = false }
                        }
                    }
                }
            case .flow: CashFlowContent(data: data, interactive: true)
            case .income: IncomeDetail(data: data)
            case .investing: InvestingDetail(data: data)
            case .spending: spendingDetail
            }
        }
    }

    /// Everyday spending, close up: where it went, the run of months, what's ahead.
    @ViewBuilder
    private var spendingDetail: some View {
        if store.overviewShowsYear, let period = currentPeriod {
            ReportContent(data: store.report(for: period), interactive: true)
        } else if let m = currentMonth {
            header(m)
            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 20) {
                    if !DebugHooks.off("donut") { breakdownCard(m) }
                }
                VStack(spacing: 20) {
                    if !DebugHooks.off("trend") { trendCard(m) }
                }
                .frame(minWidth: 300, maxWidth: 420)
            }
            // Every payee and category of the month, ranked: where a cut would count for most.
            TrimCard(transactions: store.spending(in: m), stretch: m.name, month: m)
            // The ideas are always about the last twelve months, whatever month is on screen.
            SavingsCard(besides: store.trimTop(store.spending(in: m), stretch: m.name, month: m))
            if !DebugHooks.off("ceremony") { CeremonyCard(month: m) }
        }
    }

    // MARK: Month or year

    /// The last twelve months first: twelve months ending with the newest month on file, which may
    /// still be in progress (the figures that compare it with the year before say so). Then each
    /// calendar year, newest first.
    private var periods: [ReportPeriod] {
        let all = ReportData.periods(for: store)
        return all.filter { $0 == .last12 } + all.filter { $0 != .last12 }
    }
    private var currentPeriod: ReportPeriod? { store.overviewPeriod.flatMap { periods.contains($0) ? $0 : nil } ?? periods.first }

    private var scopePicker: some View {
        @Bindable var store = store
        return HStack(spacing: 12) {
            Picker("Show", selection: $store.overviewShowsYear) {
                Text("Month").tag(false)
                Text("Year").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .controlSize(.large)
            if store.overviewShowsYear, let current = currentPeriod {
                if periods.count > 1 {
                    Picker("Period", selection: Binding(get: { current }, set: { store.overviewPeriod = $0 })) {
                        ForEach(periods) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Spacer()
                if store.overviewDetail == .spending {
                    Button {
                        ReportExporter.savePDF(data: store.report(for: current), store: store)
                    } label: {
                        Label("Save as PDF", systemImage: "square.and.arrow.down")
                    }
                    .help("Save the year as a PDF to print or share")
                }
            } else if let m = currentMonth {
                StretchStepper(title: m.title,
                               older: store.months.last { $0 < m }.map { earlier in { store.overviewMonth = earlier } },
                               newer: store.months.first { $0 > m }.map { later in { store.overviewMonth = later } })
                Spacer()
            } else {
                Spacer()
            }
        }
    }

    // MARK: Header

    private func header(_ m: Month) -> some View {
        let total = store.totalSpent(in: m)
        let before = m.adding(-1)
        let previous = store.months.contains(before) ? store.totalSpent(in: before) : 0
        return VStack(alignment: .leading, spacing: 6) {
            BigFigure(title: "Spent in \(m.name)", amount: total)
            if previous > 0 {
                let diff = total - previous
                Label {
                    Text("\(Money.format(abs(diff), cents: false)) \(diff <= 0 ? "less" : "more") than \(before.name)")
                } icon: {
                    Image(systemName: diff <= 0 ? "arrow.down.right" : "arrow.up.right")
                }
                .font(.callout.weight(.medium))
                .foregroundStyle(diff <= 0 ? Theme.good : Theme.caution)
            }
            // Refunds are taken off the figure above; say so, or a month with a big one just looks cheap.
            let refunds = store.refunds(in: m)
            if !refunds.isEmpty {
                let back = -refunds.reduce(0) { $0 + $1.amount }
                let from = Dictionary(grouping: refunds, by: \.merchant).map { (name: $0.key, back: -$0.value.reduce(0) { $0 + $1.amount }) }
                    .sorted { ($0.back, $0.name) > ($1.back, $1.name) }
                let names = from.prefix(2).map(\.name).joined(separator: ", ") + (from.count > 2 ? " and \(from.count - 2) more" : "")
                LinkText(text: "\(Money.format(total + back, cents: false)) charged, less \(Money.format(back, cents: false)) refunded (\(names))",
                         help: "See the refunds and credits that came back in \(m.name)") {
                    store.showCharges(TransactionFilter(ids: Set(refunds.map(\.id)), title: "Refunds in \(m.title)"))
                }
                .font(.callout)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What repeats, what it costs a year, and what is due next; the header opens the whole page.
    @ViewBuilder
    private var recurringCard: some View {
        // A past year or month shows the bills of that time, not today's.
        let asOf = store.overviewAsOf
        let active = store.recurring(asOf: asOf).filter(\.isActive)
        if !active.isEmpty {
            let total = active.reduce(0) { $0 + $1.yearly }
            // Now: what is due next. Then: what cost the most.
            let due = asOf == nil ? active.filter { $0.next != nil }.sorted { ($0.next ?? .distantFuture) < ($1.next ?? .distantFuture) }.prefix(4) : active.prefix(4)
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Button { store.stepInto(.recurring) } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 7) {
                                Image(systemName: "repeat.circle.fill").font(.callout.weight(.semibold)).foregroundStyle(.purple)
                                Text("Bills & Subscriptions").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            Text("\(Money.format(total, cents: false)) a year")
                                .font(.system(size: 32, weight: .bold, design: .rounded)).monospacedDigit()
                                .lineLimit(1).minimumScaleFactor(0.55)
                            Text(asOf.map { "\(active.count) \(active.count == 1 ? "thing" : "things") repeating at the end of \($0.formatted(.dateTime.month(.wide).year()))" }
                                 ?? "\(active.count) \(active.count == 1 ? "thing that repeats" : "things that repeat")")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider()
                    ForEach(Array(due), id: \.id) { item in
                        PayeeLine(name: item.merchant, category: item.category,
                                  detail: asOf == nil ? "Due " + (item.next?.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) ?? "")
                                                      : item.cadence.every.prefix(1).uppercased() + item.cadence.every.dropFirst(),
                                  amount: item.amount) { store.showPlace(item.merchant) }
                    }
                }
            }
        }
    }

    /// Trips and events that touch this month, so a big month explains itself.
    @ViewBuilder
    private func storiesThisMonth(_ m: Month) -> some View {
        let key = m.key
        let stories = store.stories.filter { $0.start.prefix(7) <= key && $0.end.prefix(7) >= key }
        if !stories.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionHeader(title: stories.count == 1 ? "This month's story" : "This month's stories")
                    Spacer()
                    Button("All Trips & Events") { store.go(to: .stories) }.buttonStyle(.borderless)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 320), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                    ForEach(stories) { StoryCard(story: $0, compact: true) }
                }
            }
        }
    }

    /// The picture is only as complete as the statements in it: say what's missing, in one line.
    // MARK: Notices: the one that matters most, and a way to the rest

    /// Everything that can ask for attention above the figures, most pressing first.
    private enum Notice: String, CaseIterable, Identifiable {
        case cloud, downloads, missing, card, since, review, tidy, memory
        var id: String { rawValue }
        /// For the "and two more" line.
        var name: String {
            switch self {
            case .cloud: "the AI has paused"
            case .downloads: "new statements in Downloads"
            case .missing: "missing statements"
            case .card: "a card"
            case .since: "what arrived since you last looked"
            case .review: "guesses to check"
            case .tidy: "payees tidied"
            case .memory: "on this day"
            }
        }
    }

    private func has(_ notice: Notice) -> Bool {
        switch notice {
        case .cloud: CloudStatus.shared.stopped != nil && CloudStatus.shared.hasKey
        case .downloads: !store.downloadCandidates.isEmpty
        case .missing: !store.missingStatements.isEmpty && !store.isImporting
        // (These two are worked out after the page is up.)
        case .card: Boot.shared.drawn && store.overviewAsOf == nil && store.hasCards && (!store.creditArrivals().isEmpty || store.cardNudge() != nil)
        case .since: Boot.shared.drawn && store.sinceLastLooked != nil
        case .review: !store.reviewItems.isEmpty && !store.isSuggesting
        case .tidy: !store.newTidyChanges.isEmpty
        case .memory: OnThisDayLine.hasSomething
        }
    }

    @ViewBuilder private func show(_ notice: Notice) -> some View {
        switch notice {
        case .cloud: CloudTroubleBanner()
        case .downloads: DownloadsBanner()
        case .missing: missingBanner
        case .card: CardNotice()
        case .since: SinceCard()
        case .review: reviewBanner
        case .tidy: TidyNotice()
        case .memory: OnThisDayLine()
        }
    }

    /// One notice, the most pressing; the others wait behind a line that says how many and what.
    /// (A page that opens with six banners has said nothing.)
    @ViewBuilder private var tray: some View {
        let _ = store.readsChecked
        let waiting = Notice.allCases.filter(has)
        VStack(alignment: .leading, spacing: 10) {
            if let first = waiting.first {
                show(first)
                if waiting.count > 1 {
                    if showsAllNotices { ForEach(Array(waiting.dropFirst())) { show($0) } }
                    Button { withAnimation(.snappy(duration: 0.25)) { showsAllNotices.toggle() } } label: {
                        HStack(spacing: 6) {
                            Image(systemName: showsAllNotices ? "chevron.up" : "chevron.down").font(.caption2.weight(.bold))
                            Text(showsAllNotices ? "Show only the first"
                                                 : "And \(waiting.count - 1) more: " + waiting.dropFirst().map(\.name).joined(separator: ", "))
                                .font(.callout).lineLimit(1)
                        }
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(showsAllNotices ? "Put the others away" : "Show the other notices")
                }
            }
        }
        // The card facts are worked out in the background whether or not a card has anything to say yet.
        .task(id: store.revision) {
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, store.hasCards else { return }
            await store.warmCardFacts()
        }
    }

    private var missingBanner: some View {
        let missing = store.missingStatements
        let count = missing.reduce(0) { $0 + $1.months.count }
        return Button { store.go(to: .accounts) } label: {
            HStack(spacing: 12) {
                Image(systemName: "calendar.badge.exclamationmark").font(.title3).foregroundStyle(Theme.caution)
                VStack(alignment: .leading, spacing: 1) {
                    Text(count == 1 ? "One statement seems to be missing" : "\(count) statements seem to be missing")
                        .font(.callout.weight(.semibold))
                    Text(missing.prefix(2).map(\.summary).joined(separator: ". ") + (missing.count > 2 ? ", and \(missing.count - 2) more accounts." : "."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Theme.caution.opacity(0.08), in: .rect(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var reviewBanner: some View {
        let n = store.reviewItems.count
        return Card(padding: 14) {
            HStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Theme.accent))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Everything is sorted. \(n) \(n == 1 ? "guess is" : "guesses are") worth a glance.")
                        .font(.headline)
                    Text("The AI sorted every payee, and flagged \(n == 1 ? "the one" : "the ones") it wasn't sure about.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Double-Check") { store.go(to: .review) }
                    .controlSize(.large)
            }
        }
    }

    // MARK: Breakdown (donut + list)

    private func breakdownCard(_ m: Month) -> some View {
        let totals = store.categoryTotals(in: m)
        let sum = totals.reduce(0) { $0 + $1.total }
        let hovered = hoveredCategory(totals)

        return Card {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeader(title: "Where it went")
                if totals.isEmpty {
                    Text("No spending this month.").foregroundStyle(.secondary)
                } else {
                    // Slivers too thin to see are left out of the ring (they're still in the list below).
                    Chart(totals.filter { $0.total >= sum * 0.004 }, id: \.category) { item in
                        SectorMark(angle: .value("Amount", item.total),
                                   innerRadius: .ratio(0.64),
                                   outerRadius: hovered == item.category ? .ratio(1) : .ratio(0.94),
                                   angularInset: 1.5)
                            .cornerRadius(5)
                            .foregroundStyle(item.category.color.gradient)
                            .opacity(hovered == nil || hovered == item.category ? 1 : 0.4)
                    }
                    .chartAngleSelection(value: $hoveredAngle)
                    .chartBackground { proxy in
                        GeometryReader { geo in
                            if let anchor = proxy.plotFrame {
                                let frame = geo[anchor]
                                VStack(spacing: 2) {
                                    Text(hovered?.displayName ?? "Total")
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                    Text(Money.format(hovered.flatMap { h in totals.first { $0.category == h }?.total } ?? store.totalSpent(in: m), cents: false))
                                        .font(.title2.weight(.bold))
                                        .monospacedDigit()
                                }
                                .position(x: frame.midX, y: frame.midY)
                            }
                        }
                    }
                    // A fixed size: Swift Charts crashes drawing a ring into a sliver, which a card
                    // can briefly be handed while the row beside it is laying itself out.
                    .frame(width: 240, height: 240)
                    // A click on a slice opens that category's charges for the month, like its row below.
                    .onTapGesture { if let hovered { store.showCharges(TransactionFilter(category: hovered, month: m)) } }
                    .frame(maxWidth: .infinity)
                    .animation(.snappy, value: hovered)
                    // Swift Charts crashes when it animates a ring from one set of slices into another
                    // (a place changing category, statements arriving). Giving the ring a new identity
                    // whenever its data changes makes it redraw from scratch instead; hovering still animates.
                    .id(totals.map { "\($0.category.rawValue)=\(Int(($0.total * 100).rounded()))" }.joined(separator: "|"))
                    .transition(.identity)

                    VStack(spacing: 4) {
                        ForEach(totals, id: \.category) { item in
                            CategoryRow(category: item.category, total: item.total, fraction: item.total / max(sum, 1)) {
                                store.showCharges(TransactionFilter(category: item.category, month: m))
                            }
                        }
                    }
                }
            }
        }
    }

    private func hoveredCategory(_ totals: [(category: Category, total: Double)]) -> Category? {
        guard let hoveredAngle else { return nil }
        var running = 0.0
        for item in totals {
            running += item.total
            if hoveredAngle <= running { return item.category }
        }
        return nil
    }

    // MARK: Trend

    private func trendCard(_ m: Month) -> some View {
        let range = (0..<6).reversed().map { m.adding(-$0) }
        let first = store.months.first ?? m
        let data = range.filter { $0 >= first }.map { (month: $0, total: store.totalSpent(in: $0)) }

        return Card {
            VStack(alignment: .leading, spacing: 16) {
                SectionHeader(title: "Month by month", subtitle: "Click a bar to see what's in it.")
                Chart(data, id: \.month) { item in
                    BarMark(x: .value("Month", item.month.shortName),
                            y: .value("Spent", max(item.total, 0)),
                            width: .ratio(0.6))
                        .cornerRadius(6)
                        .foregroundStyle(item.month == m || hoveredBar == item.month.shortName ? Theme.accent.gradient : Theme.accent.opacity(0.3).gradient)
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let v = value.as(Double.self) { Text(Money.format(v, cents: false)) }
                        }
                    }
                }
                // Anywhere in a bar's column counts, so a short bar is as easy to hit as a tall one.
                .chartOverlay { proxy in
                    Color.clear.barPointer(proxy, hover: { hoveredBar = $0 }) { label in
                        if let picked = data.first(where: { $0.month.shortName == label }) { store.showSpending(in: picked.month) }
                    }
                }
                .animation(.easeOut(duration: 0.12), value: hoveredBar)
                .frame(height: 150)
            }
        }
    }

    // MARK: Top places

}

private struct CategoryRow: View {
    let category: Category
    let total: Double
    let fraction: Double
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                CategoryIcon(category: category, size: 30)
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(category.displayName).font(.body.weight(.medium))
                        Spacer()
                        Text(Money.format(total)).monospacedDigit()
                        Text(fraction.formatted(.percent.precision(.fractionLength(0))))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.primary.opacity(0.06))
                            Capsule().fill(category.color.gradient)
                                .frame(width: max(4, geo.size.width * fraction))
                        }
                    }
                    .frame(height: 5)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(isHovered ? 1 : 0)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(isHovered ? 0.05 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

/// What the analyst noticed reading every charge. Each line opens the charges behind it.
/// One line from the person's own history: what they were buying on this day in an earlier year.
struct OnThisDayLine: View {
    private var store: BudgetStore { .shared }

    /// Whether there is a memory to show today that the picture is not already showing.
    @MainActor static var hasSomething: Bool {
        guard !DailyPicture.shared.showsMemory, let memory = BudgetStore.shared.onThisDay() else { return false }
        return DailyPicture.shared.entry != memory.charge.id
    }

    var body: some View {
        // One memory a day. When today's picture is itself an "on this day", the picture is the memory
        // (whichever purchase it is of); this line is only for days when the picture is about something else.
        if !DailyPicture.shared.showsMemory, let memory = store.onThisDay(), DailyPicture.shared.entry != memory.charge.id {
            let ago = ["One year", "Two years", "Three years", "Four years", "Five years", "Six years"]
            let when = memory.years <= ago.count ? ago[memory.years - 1] : "\(memory.years) years"
            Button { store.showPlace(memory.charge.merchant) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(Theme.accent)
                    Text("ON THIS DAY").font(Theme.mono(10, .bold)).tracking(1.2).foregroundStyle(Theme.accent)
                    (Text("\(when) ago today: ") + Text(Money.format(memory.charge.amount)).fontWeight(.semibold)
                     + Text(" at ") + Text(memory.charge.merchant).fontWeight(.semibold) + Text("."))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .font(.callout)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Theme.sheet, in: .rect(cornerRadius: 11, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.hairline) }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Everything you've spent at \(memory.charge.merchant)")
        }
    }
}

struct NoticedCard: View {
    private var store: BudgetStore { .shared }
    /// The month or year on screen: only what was noticed in it is shown, with that stretch's amounts.
    var scope: NoticedScope = .last12

    var body: some View {
        let found = store.noticed(in: scope)
        let reading = store.isReading(scope)
        // A stack, not a group: it has to exist even while empty, or an earlier year would never be read.
        VStack(spacing: 0) {
            if !found.isEmpty || reading {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Things I noticed", subtitle: scope.label)
                        if found.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Reading every charge…").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(Array(found.prefix(6).enumerated()), id: \.element.item.id) { i, entry in
                            let item = entry.item
                            let net = entry.charges.reduce(0) { $0 + $1.amount }
                            // A charge and its refund net to nothing; show what was charged rather than "$0".
                            let total = abs(net) >= 1 ? net : entry.charges.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount }
                            Button {
                                store.showCharges(TransactionFilter(ids: Set(entry.charges.map(\.id)), title: item.title))
                            } label: {
                                HStack(alignment: .top, spacing: 11) {
                                    Image(systemName: item.symbol).font(.title2).foregroundStyle(Theme.accent).frame(width: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(alignment: .firstTextBaseline) {
                                            Text(item.title).font(.body.weight(.semibold)).multilineTextAlignment(.leading)
                                                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                                            Spacer(minLength: 6)
                                            Text(Money.format(abs(total), cents: false)).font(.body.weight(.semibold)).monospacedDigit()
                                        }
                                        Text(item.detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu { Button("Not Interesting", systemImage: "xmark.circle") { store.dismissDiscovery(item) } }
                            if i < min(found.count, 6) - 1 { Divider().padding(.leading, 39) }
                        }
                    }
                }
            }
        }
        // A year further back than the last twelve months is read the first time it is looked at.
        .task(id: scope) { await store.readIfNeeded(scope) }
    }
}
