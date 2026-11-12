import SwiftUI
import Charts

struct OverviewView: View {
    @Environment(BudgetStore.self) private var store
    /// The bar under the pointer in "Month by month".
    @State private var hoveredBar: String?
    @State private var hoveredAngle: Double?

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
        if store.overviewShowsYear { return currentPeriod.map { CashFlowData(store: store, period: $0) } }
        return currentMonth.map { CashFlowData(store: store, month: $0) }
    }

    // MARK: The summary: one answer, then a few cards to step into

    @ViewBuilder
    private var summary: some View {
        if !DebugHooks.off("daily") { BannerCard() }
        OnThisDayLine()
        CloudTroubleBanner()
        DownloadsBanner()
        if !store.reviewItems.isEmpty, !store.isSuggesting { reviewBanner }
        if !store.missingStatements.isEmpty, !store.isImporting { missingBanner }
        if store.months.count > 1 { scopePicker }
        if let data = flowData {
            // The judgment that matters most comes first: did living stay within income?
            FlowHero(data: data) { store.stepInto(.flow) }
            let figures = Figures(store: store, data: data, month: store.overviewShowsYear ? nil : currentMonth)
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
            HStack(alignment: .top, spacing: 16) {
                noticed
                if !DebugHooks.off("coming") { comingUpCard }
            }
            if !store.overviewShowsYear, let m = currentMonth, !DebugHooks.off("stories") { storiesThisMonth(m) }
        } else {
            EmptyState(title: "Nothing here yet", message: "Drop a statement into this window and it all gets added up.", art: "welcome")
        }
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
        if store.months.count > 1 { scopePicker }
        if let data = flowData {
            switch detail {
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
                    topPlacesCard(m)
                    ForecastCard()
                }
                .frame(minWidth: 300, maxWidth: 420)
            }
            if !DebugHooks.off("ceremony") { CeremonyCard(month: m) }
        }
    }

    // MARK: Month or year

    private var periods: [ReportPeriod] { ReportData.periods(for: store) }
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
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Charges that repeat every month, and when each is due next: no surprises.
    @ViewBuilder
    private var comingUpCard: some View {
        let today = Calendar.current.startOfDay(for: .now)
        let horizon = today.addingTimeInterval(31 * 24 * 3600)
        let upcoming: [(sub: Subscription, due: Date)] = store.subscriptions().compactMap { sub in
            var due = sub.lastCharge
            // Step forward a month at a time until the date is today or later.
            for _ in 0..<24 where due < today { due = Calendar.current.date(byAdding: .month, value: 1, to: due) ?? horizon.addingTimeInterval(1) }
            return due <= horizon ? (sub, due) : nil
        }.sorted { $0.due < $1.due }
        if !upcoming.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(title: "Coming up", subtitle: "Charges that repeat, due in the next month")
                    ForEach(Array(upcoming.prefix(7).enumerated()), id: \.offset) { _, item in
                        PayeeLine(name: item.sub.merchant, category: item.sub.category,
                                  detail: Calendar.current.isDateInToday(item.due) ? "Today"
                                      : Calendar.current.isDateInTomorrow(item.due) ? "Tomorrow"
                                      : item.due.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()),
                                  amount: item.sub.monthlyAmount) { store.showPlace(item.sub.merchant) }
                    }
                    Divider()
                    HStack {
                        Text("About").foregroundStyle(.secondary)
                        Spacer()
                        Text(Money.format(upcoming.reduce(0) { $0 + $1.sub.monthlyAmount }, cents: false)).font(.headline).monospacedDigit()
                    }
                    .font(.callout)
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
                    // Say who did the sorting: the cloud model when a key is in, Apple's on-device model otherwise.
                    Text(CloudAI.isEnabled ? "The AI sorted every payee, and flagged \(n == 1 ? "the one" : "the ones") it wasn't sure about."
                                           : "Apple Intelligence sorted \(n == 1 ? "a payee" : "some payees") it hadn't seen before.")
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

    private func topPlacesCard(_ m: Month) -> some View {
        let top = store.topMerchants(in: m)
        return Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Top payees")
                ForEach(Array(top.enumerated()), id: \.offset) { _, item in
                    PayeeLine(name: item.name, category: item.category, detail: item.count == 1 ? "1 visit" : "\(item.count) visits",
                              amount: item.total) { store.showPlace(item.name) }
                }
                if top.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
            }
        }
    }
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

/// "Next month, about $38,000": an estimate from the history, what repeats, and the person's notes.
struct ForecastCard: View {
    private var store: BudgetStore { .shared }
    @State private var estimate = Forecaster.cached

    private var next: Month? { store.months.last?.adding(1) }
    /// Changes when there is a new month of data or a new note, which is when to think again.
    private var basis: String {
        "\(store.months.last?.key ?? "")|\(store.transactions.count)|\(store.allNotes(limit: 60).joined().hashValue)"
    }

    var body: some View {
        Group {
            if let estimate, let next, CloudAI.isEnabled, store.months.count >= 3 {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionHeader(title: "Looking ahead", subtitle: "An estimate for \(next.name), not a promise")
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("About \(Money.format(estimate.amount, cents: false))")
                                .font(.system(size: 26, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            Text("likely \(Money.format(estimate.low, cents: false))–\(Money.format(estimate.high, cents: false))")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        if !estimate.because.isEmpty {
                            Text(estimate.because).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Label("Notes you leave on payees and charges make this sharper.", systemImage: "text.bubble")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .task(id: basis) {
            guard CloudAI.isEnabled, !store.isImporting, !store.isSuggesting, store.months.count >= 3, let next else { return }
            let recent = store.months.suffix(12)
            let history = recent.map { m -> String in
                let top = store.categoryTotals(in: m).prefix(6).map { "\($0.category.displayName) \(Int($0.total))" }.joined(separator: ", ")
                return "\(m.title): total \(Int(store.totalSpent(in: m))) (\(top))"
            }
            let repeating = store.subscriptions().map { "\($0.merchant): \(Money.format($0.monthlyAmount)) a month" }
            let result = await Forecaster.estimate(month: next.title, history: history, repeating: repeating,
                                                   notes: store.allNotes(), basis: basis)
            if let result { withAnimation(.snappy) { estimate = result } }
        }
    }
}

/// What the analyst noticed reading every charge. Each line opens the charges behind it.
/// One line from the person's own history: what they were buying on this day in an earlier year.
struct OnThisDayLine: View {
    private var store: BudgetStore { .shared }

    var body: some View {
        // When today's picture is already about this purchase, the picture says it; no second mention.
        if let memory = store.onThisDay(), DailyPicture.shared.entry != memory.charge.id {
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
