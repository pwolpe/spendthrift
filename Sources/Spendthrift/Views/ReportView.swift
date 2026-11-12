import SwiftUI
import Charts
import UniformTypeIdentifiers

// MARK: - Period & data

enum ReportPeriod: Hashable, Identifiable {
    case year(Int)
    case last12

    var id: String { title }
    var title: String {
        switch self {
        case .year(let y): String(y)
        case .last12: "Last 12 Months"
        }
    }
}

/// Everything the Year in Review shows, computed once from the store's transactions.
struct ReportData {
    struct CategoryLine: Identifiable {
        var id: Category { category }
        let category: Category
        let total: Double
        let share: Double
        let monthly: [Double]   // one per month in `months`
    }
    struct Place: Identifiable {
        var id: String { name }
        let name: String
        let category: Category
        let total: Double
        let count: Int
    }
    struct MonthBar: Identifiable {
        var id: String { "\(month.key)-\(group)" }
        let month: Month
        let group: String
        let total: Double
    }
    struct Source: Identifiable {
        var id: String { name }
        let name: String
        let total: Double
    }
    struct AccountLine: Identifiable {
        var id: String { name }
        let name: String
        let spent: Double
        let count: Int
    }

    let period: ReportPeriod
    let months: [Month]
    let spent: Double
    let moneyIn: Double
    let transfers: Double
    let refunds: Double
    let purchaseCount: Int
    let categories: [CategoryLine]
    let places: [Place]
    let biggest: [Transaction]
    let bars: [MonthBar]
    let barGroups: [String]
    let monthTotals: [Month: Double]
    let incomeSources: [Source]
    let accounts: [AccountLine]

    var monthlyAverage: Double { months.isEmpty ? 0 : spent / Double(months.count) }
    var kept: Double { moneyIn - spent }
    var isEmpty: Bool { purchaseCount == 0 && moneyIn == 0 }

    var subtitle: String {
        guard let first = months.first, let last = months.last else { return "" }
        if first == last { return first.title }
        return "\(first.shortName) \(first.year == last.year ? "" : String(first.year) + " ")– \(last.shortName) \(last.year)"
            .replacingOccurrences(of: "  ", with: " ")
    }

    static let otherGroup = "Everything Else"

    @MainActor init(store: BudgetStore, period: ReportPeriod) {
        self.period = period
        let all = store.transactions
        let inPeriod: (Month) -> Bool
        switch period {
        case .year(let y):
            inPeriod = { $0.year == y }
        case .last12:
            let end = store.months.last ?? Month(date: .now)
            let start = end.adding(-11)
            inPeriod = { $0 >= start && $0 <= end }
        }
        let txns = all.filter { inPeriod(Month(date: $0.date)) }
        let monthList = Array(Set(txns.map { Month(date: $0.date) })).sorted()
        months = monthList

        let spending = txns.filter(\.countsAsSpending)
        spent = spending.reduce(0) { $0 + $1.amount }
        refunds = spending.filter { $0.amount < 0 }.reduce(0) { $0 - $1.amount }
        purchaseCount = spending.filter { $0.amount > 0 }.count
        let income = txns.filter(\.isIncome)
        moneyIn = income.reduce(0) { $0 + abs($1.amount) }
        transfers = txns.filter { $0.isTransfer && !$0.isIncome }.reduce(0) { $0 + abs($1.amount) }

        // Categories, with a per-month series for the sparkline.
        let byCategory = Dictionary(grouping: spending, by: \.category)
        let total = max(spent, 1)
        var lines: [CategoryLine] = []
        for (category, list) in byCategory {
            let sum = list.reduce(0) { $0 + $1.amount }
            guard sum > 0.005 else { continue }
            let perMonth = Dictionary(grouping: list) { Month(date: $0.date) }
            let series = monthList.map { m in max(0, (perMonth[m] ?? []).reduce(0) { $0 + $1.amount }) }
            lines.append(CategoryLine(category: category, total: sum, share: sum / total, monthly: series))
        }
        lines.sort { $0.total > $1.total }
        categories = lines

        // Stacked monthly bars: the five biggest categories, then everything else.
        let named = lines.prefix(5).map(\.category.displayName)
        barGroups = named + (lines.count > 5 ? [Self.otherGroup] : [])
        var bars: [MonthBar] = []
        var totals: [Month: Double] = [:]
        for (i, m) in monthList.enumerated() {
            var other = 0.0
            for line in lines {
                let v = line.monthly[i]
                if named.contains(line.category.displayName) {
                    bars.append(MonthBar(month: m, group: line.category.displayName, total: v))
                } else {
                    other += v
                }
            }
            if lines.count > 5 { bars.append(MonthBar(month: m, group: Self.otherGroup, total: other)) }
            totals[m] = spending.filter { Month(date: $0.date) == m }.reduce(0) { $0 + $1.amount }
        }
        self.bars = bars
        monthTotals = totals

        // Places.
        var places: [Place] = []
        for (name, list) in Dictionary(grouping: spending, by: \.merchant) {
            let sum = list.reduce(0) { $0 + $1.amount }
            if sum > 0 { places.append(Place(name: name, category: list[0].category, total: sum, count: list.count)) }
        }
        places.sort { $0.total > $1.total }
        self.places = Array(places.prefix(10))


        // One per place, leaving out monthly bills: a bill that repeats is not a purchase.
        let recurring = Set((monthList.last.map { InsightEngine.subscriptions(asOf: $0, in: all) } ?? []).map(\.merchant))
        var seen = Set<String>()
        var big: [Transaction] = []
        for t in spending.filter({ $0.amount > 0 }).sorted(by: { $0.amount > $1.amount })
        where !recurring.contains(t.merchant) && seen.insert(t.merchant).inserted {
            big.append(t)
            if big.count == 8 { break }
        }
        biggest = big

        var sources: [Source] = []
        for (name, list) in Dictionary(grouping: income, by: \.merchant) {
            sources.append(Source(name: name, total: list.reduce(0) { $0 + abs($1.amount) }))
        }
        incomeSources = sources.sorted { $0.total > $1.total }

        var accountLines: [AccountLine] = []
        for (name, list) in Dictionary(grouping: spending, by: \.account) {
            accountLines.append(AccountLine(name: name, spent: list.reduce(0) { $0 + $1.amount }, count: list.count))
        }
        accounts = accountLines.sorted { $0.spent > $1.spent }

    }

    @MainActor static func periods(for store: BudgetStore) -> [ReportPeriod] {
        let years = Array(Set(store.months.map(\.year))).sorted(by: >)
        return years.map { .year($0) } + (store.months.count > 1 && years.count > 1 ? [.last12] : [])
    }
}

// MARK: - Content (also rendered straight into the PDF)

struct ReportContent: View {
    @Environment(BudgetStore.self) private var store
    let data: ReportData
    var interactive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            hero
            StatTiles(data: data)
            if data.isEmpty {
                Text("No spending in this period.").foregroundStyle(.secondary)
            } else {
                MonthlyChartCard(data: data)
                if interactive {
                    let months = Set(data.months)
                    TrimCard(transactions: store.cached("stretch|\(data.period.id)") { store.transactions.filter { months.contains($0.month) } },
                             stretch: data.period == .last12 ? "the last 12 months" : data.period.title)
                    SavingsCard()
                }
                CategoryTableCard(data: data, open: interactive ? open : nil)
                HStack(alignment: .top, spacing: 22) {
                    PlacesCard(places: data.places, interactive: interactive)
                    BiggestCard(transactions: data.biggest)
                }
                TaxTimeCard(months: Set(data.months), interactive: interactive)
            }
            Text("Prepared by Spendthrift on \(Date.now.formatted(date: .long, time: .omitted)). Payments between accounts are left out of spending.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        }
    }

    private func open(_ category: Category) {
        if category == .unsorted { store.go(to: .review); return }
        store.go(to: .transactions) { store.transactionFilter = TransactionFilter(category: category, month: data.months.count == 1 ? data.months.first : nil) }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 16) {
            Vignette(name: "v-review", size: 88)
            VStack(alignment: .leading, spacing: 2) {
                Text(heroTitle)
                    .font(.system(size: 34, weight: .bold, design: .serif))
                Text(data.subtitle.isEmpty ? "Spendthrift" : "Spendthrift · \(data.subtitle)")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var heroTitle: String {
        switch data.period {
        case .year(let y): "\(y) in Review"
        case .last12: "The Last 12 Months"
        }
    }
}

// MARK: - Stat tiles

private struct StatTiles: View {
    let data: ReportData

    var body: some View {
        HStack(spacing: 16) {
            StatTile(title: "Spent", value: Money.format(data.spent, cents: false),
                     detail: "\(data.purchaseCount) purchases", symbol: "creditcard.fill", tint: .pink)
            StatTile(title: "Monthly Average", value: Money.format(data.monthlyAverage, cents: false),
                     detail: data.months.count == 1 ? "1 month" : "over \(data.months.count) months",
                     symbol: "calendar", tint: .blue)
            if data.moneyIn > 0 {
                StatTile(title: "Money In", value: Money.format(data.moneyIn, cents: false),
                         detail: data.incomeSources.first.map { "mostly \($0.name)" } ?? "",
                         symbol: "arrow.down.circle.fill", tint: .green)
                StatTile(title: data.kept >= 0 ? "Kept" : "Over",
                         value: Money.format(abs(data.kept), cents: false),
                         detail: data.kept >= 0
                            ? "\(Int((data.kept / data.moneyIn * 100).rounded()))% of what came in"
                            : "more out than in",
                         symbol: data.kept >= 0 ? "banknote.fill" : "exclamationmark.circle.fill",
                         tint: data.kept >= 0 ? .mint : .orange)
            } else {
                StatTile(title: "Refunds", value: Money.format(data.refunds, cents: false),
                         detail: "credited back", symbol: "arrow.uturn.backward.circle.fill", tint: .teal)
            }
        }
    }
}

private struct StatTile: View {
    let title: String
    let value: String
    let detail: String
    let symbol: String
    let tint: Color

    var body: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: symbol)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(tint)
                Text(value)
                    .font(.system(size: 30, weight: .bold, design: .serif))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Monthly chart

private struct MonthlyChartCard: View {
    let data: ReportData
    @State private var selected: Date?

    private var selectedMonth: Month? { selected.map { Month(date: $0) } }

    private var colors: [Color] {
        data.barGroups.map { name in
            Category.allCases.first { $0.displayName == name }?.color ?? Color.secondary.opacity(0.5)
        }
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    SectionHeader(title: "Month by Month", subtitle: "Spending, by category")
                    Spacer()
                    if let m = selectedMonth, let total = data.monthTotals[m] {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(m.title).font(.caption).foregroundStyle(.secondary)
                            Text(Money.format(total, cents: false)).font(.title3.weight(.semibold)).monospacedDigit()
                        }
                    } else {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("Average").font(.caption).foregroundStyle(.secondary)
                            Text(Money.format(data.monthlyAverage, cents: false)).font(.title3.weight(.semibold)).monospacedDigit()
                        }
                    }
                }
                chart
                    .frame(height: 260)
            }
        }
    }

    private var chart: some View {
        Chart {
            ForEach(data.bars) { bar in
                BarMark(x: .value("Month", bar.month.firstDay, unit: .month),
                        y: .value("Spent", bar.total),
                        width: .ratio(0.62))
                    .foregroundStyle(by: .value("Category", bar.group))
                    .opacity(selectedMonth == nil || selectedMonth == bar.month ? 1 : 0.45)
            }
            RuleMark(y: .value("Average", data.monthlyAverage))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(.secondary)
        }
        .chartForegroundStyleScale(domain: data.barGroups, range: colors)
        .chartLegend(position: .bottom, alignment: .leading, spacing: 14)
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated), centered: true)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(Money.format(v, cents: false)) }
                }
            }
        }
        .animation(.snappy, value: selectedMonth)
        // The month under the pointer is the one a click opens.
        .chartOverlay { proxy in
            Color.clear.monthPointer(proxy, hover: { selected = $0?.firstDay }) { BudgetStore.shared.showSpending(in: $0) }
        }
        .help("Click a month to see what was spent in it")
    }
}

// MARK: - Category table

private struct CategoryTableCard: View {
    let data: ReportData
    let open: ((Category) -> Void)?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Categories", subtitle: open == nil ? nil : "Click a category to see its charges")
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 0) {
                    GridRow {
                        Text("Category")
                        Text("Trend").gridColumnAlignment(.center)
                        Text("Per Month").gridColumnAlignment(.trailing)
                        Text("Total").gridColumnAlignment(.trailing)
                        Text("Share").gridColumnAlignment(.trailing)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.bottom, 8)

                    ForEach(data.categories) { line in
                        Divider().gridCellUnsizedAxes(.horizontal)
                        CategoryLineRow(line: line, months: max(data.months.count, 1), open: open)
                    }
                }
            }
        }
    }
}

private struct CategoryLineRow: View {
    let line: ReportData.CategoryLine
    let months: Int
    let open: ((Category) -> Void)?
    @State private var hovering = false

    var body: some View {
        GridRow {
            HStack(spacing: 10) {
                CategoryIcon(category: line.category, size: 26)
                Text(line.category.displayName).font(.body.weight(.medium))
                if hovering {
                    Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Sparkline(values: line.monthly, color: line.category.color)
                .frame(width: 110, height: 26)
            Text(Money.format(line.total / Double(months), cents: false))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(Money.format(line.total, cents: false))
                .font(.body.weight(.semibold))
                .monospacedDigit()
            ShareBar(share: line.share, color: line.category.color)
        }
        .padding(.vertical, 8)
        .background(Color.primary.opacity(hovering ? 0.04 : 0))
        .contentShape(Rectangle())
        .onHover { hovering = open != nil && $0 }
        .onTapGesture { open?(line.category) }
        .accessibilityAddTraits(open != nil ? .isButton : [])
    }
}

private struct ShareBar: View {
    let share: Double
    let color: Color

    var body: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule().fill(color.gradient).frame(width: max(3, 60 * share))
            }
            .frame(width: 60, height: 6)
            Text(share.formatted(.percent.precision(.fractionLength(0))))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }
}

struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        if values.count > 1 {
            Chart(Array(values.enumerated()), id: \.offset) { item in
                AreaMark(x: .value("i", item.offset), y: .value("v", item.element))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("i", item.offset), y: .value("v", item.element))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                    .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
        } else {
            Capsule().fill(color.opacity(0.5)).frame(height: 3)
        }
    }
}

// MARK: - Places & purchases

private struct PlacesCard: View {
    let places: [ReportData.Place]
    var interactive = true

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Top Payees")
                ForEach(Array(places.enumerated()), id: \.element.id) { i, place in
                    PayeeLine(name: place.name, category: place.category,
                              detail: place.count == 1 ? "1 visit" : "\(place.count) visits",
                              amount: place.total, rank: i + 1, iconSize: 28,
                              amountText: Money.format(place.total, cents: false),
                              help: "Open \(place.name): every charge, by month",
                              action: interactive ? { BudgetStore.shared.showPlace(place.name) } : nil)
                    if i < places.count - 1 { Divider().padding(.leading, 72) }
                }
                if places.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
            }
        }
    }
}

private struct BiggestCard: View {
    let transactions: [Transaction]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Biggest Purchases")
                ForEach(Array(transactions.enumerated()), id: \.element.id) { i, t in
                    PayeeLine(name: t.merchant, category: t.category, detail: t.date.formatted(.dateTime.month(.wide).day()), amount: t.amount) {
                        BudgetStore.shared.showCharges(TransactionFilter(ids: [t.id], title: t.merchant))
                    }
                    if i < transactions.count - 1 { Divider().padding(.leading, 40) }
                }
                if transactions.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
            }
        }
    }
}

// MARK: - For tax time

/// The figures an accountant asks for, gathered in one place. Not tax advice: just the totals,
/// with what each one is made of, so nothing has to be dug out of statements in April.
private struct TaxTimeCard: View {
    private var store: BudgetStore { .shared }   // not from the environment: menus and sheets don't always pass it down
    let months: Set<Month>
    var interactive = true

    private struct Line: Identifiable {
        var id: String { title }
        let title: String
        let note: String
        let total: Double
        let symbol: String
        let color: Color
        let details: [(String, Double)]
        let ids: Set<UUID>
    }

    private var lines: [Line] {
        let key = "tax-lines|" + months.sorted().map(\.key).joined(separator: ",")
        return store.cached(key) { makeLines() }
    }

    private func makeLines() -> [Line] {
        let txns = store.transactions.filter { months.contains($0.month) }
        func gather(_ title: String, _ note: String, _ symbol: String, _ color: Color, _ keep: (Transaction) -> Bool) -> Line? {
            let list = txns.filter(keep)
            let total = list.reduce(0) { $0 + $1.amount }
            guard abs(total) > 0.005 else { return nil }
            let byPlace = Dictionary(grouping: list, by: \.merchant).map { ($0.key, $0.value.reduce(0) { $0 + $1.amount }) }
                .sorted { abs($0.1) > abs($1.1) }
            return Line(title: title, note: note, total: total, symbol: symbol, color: color, details: Array(byPlace.prefix(4)), ids: Set(list.map(\.id)))
        }
        let named = { (t: Transaction, words: [String]) in words.contains { t.merchant.localizedCaseInsensitiveContains($0) } }
        return [
            gather("Income tax payments", "Estimated and balance-due payments, less any refunds", "doc.text.fill", Category.taxes.color) { $0.lane == .taxes },
            gather("Property tax", "Paid directly, not through a mortgage", "house.fill", Category.home.color) { named($0, ["Property Tax"]) },
            gather("Mortgage and home loan payments", "Total paid; the interest part is on Form 1098 from the lender", "building.columns.fill", Category.home.color) {
                $0.category == .home && named($0, ["Mortgage", "Loan"]) && !named($0, ["Property Tax"])
            },
            gather("Charitable giving", "Everything filed under Gifts & Giving", "gift.fill", Category.gifts.color) { $0.category == .gifts },
            gather("Investment loan interest", "Interest paid on the loan used for investing", "percent", Category.investmentLoan.color) {
                $0.category == .investmentLoan && named($0, ["Interest"])
            },
            gather("Medical and health", "Everything filed under Health & Fitness, gym included", "heart.fill", Category.health.color) { $0.category == .health },
        ].compactMap { $0 }
    }

    var body: some View {
        let lines = lines
        if !lines.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "For Tax Time", subtitle: "The totals your accountant will ask for. A starting point, not tax advice.")
                    ForEach(lines) { line in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: line.symbol)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(line.color.gradient))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.title).font(.body.weight(.medium))
                                Text(line.note).font(.caption).foregroundStyle(.secondary)
                                if interactive {
                                    FlowLayout(spacing: 6) {
                                        ForEach(Array(line.details.enumerated()), id: \.offset) { i, detail in
                                            HStack(spacing: 4) {
                                                LinkText(text: detail.0, font: .caption, help: "Open \(detail.0): every charge, by month") { store.showPlace(detail.0) }
                                                Text(Money.format(detail.1, cents: false) + (i < line.details.count - 1 ? "  ·" : ""))
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                } else {
                                    Text(line.details.map { "\($0.0) \(Money.format($0.1, cents: false))" }.joined(separator: "  ·  "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                            if interactive {
                                LinkText(text: Money.format(line.total), font: .body.weight(.semibold), color: .primary,
                                         help: "Open the charges behind this total") {
                                    store.showCharges(TransactionFilter(ids: line.ids, title: line.title))
                                }
                                .monospacedDigit()
                            } else {
                                Text(Money.format(line.total)).font(.body.weight(.semibold)).monospacedDigit()
                            }
                        }
                        if line.id != lines.last?.id { Divider().padding(.leading, 40) }
                    }
                }
            }
        }
    }
}

// MARK: - PDF export

@MainActor
enum ReportExporter {
    static func savePDF(data: ReportData, store: BudgetStore) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "Spendthrift – \(data.period.title).pdf"
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if write(data: data, store: store, to: url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            store.showToast("Couldn't save the PDF.", symbol: "exclamationmark.triangle.fill")
        }
    }

    /// Renders the report (in light mode, like paper) to a single tall PDF page.
    @discardableResult
    static func write(data: ReportData, store: BudgetStore, to url: URL) -> Bool {
        let content = ReportContent(data: data, interactive: false)
            .padding(36)
            .frame(width: 960)
            .background(Theme.paper)
            .environment(store)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        var ok = false
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
            ctx.beginPDFPage(nil)
            draw(ctx)
            ctx.endPDFPage()
            ctx.closePDF()
            ok = true
        }
        return ok
    }
}
