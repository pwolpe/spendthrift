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
    let subscriptions: [Subscription]

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
        for (name, list) in Dictionary(grouping: spending, by: \.merchantDisplay) {
            let sum = list.reduce(0) { $0 + $1.amount }
            if sum > 0 { places.append(Place(name: name, category: list[0].category, total: sum, count: list.count)) }
        }
        places.sort { $0.total > $1.total }
        self.places = Array(places.prefix(10))

        let subs: [Subscription] = monthList.last.map { InsightEngine.subscriptions(asOf: $0, in: all) } ?? []
        subscriptions = subs.sorted { $0.monthlyAmount > $1.monthlyAmount }

        // One per place, leaving out monthly bills (those are in the recurring card).
        let recurring = Set(subs.map(\.merchant))
        var seen = Set<String>()
        var big: [Transaction] = []
        for t in spending.filter({ $0.amount > 0 }).sorted(by: { $0.amount > $1.amount })
        where !recurring.contains(t.merchantDisplay) && seen.insert(t.merchantDisplay).inserted {
            big.append(t)
            if big.count == 8 { break }
        }
        biggest = big

        var sources: [Source] = []
        for (name, list) in Dictionary(grouping: income, by: \.merchantDisplay) {
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

// MARK: - Screen

struct ReportView: View {
    @Environment(BudgetStore.self) private var store
    @State private var period: ReportPeriod?

    private var periods: [ReportPeriod] { ReportData.periods(for: store) }
    private var current: ReportPeriod? { period.flatMap { periods.contains($0) ? $0 : nil } ?? periods.first }

    var body: some View {
        Group {
            if let current {
                let data = ReportData(store: store, period: current)
                ScrollView {
                    ReportContent(data: data, interactive: true)
                        .padding(28)
                        .frame(maxWidth: 1100)
                        .frame(maxWidth: .infinity)
                }
                .toolbar { toolbar(data) }
            } else {
                ContentUnavailableView("Nothing to report yet", systemImage: "chart.bar.xaxis",
                                       description: Text("Add a statement and your year in review appears here."))
            }
        }
        .navigationTitle("Year in Review")
    }

    @ToolbarContentBuilder
    private func toolbar(_ data: ReportData) -> some ToolbarContent {
        if periods.count > 1 {
            ToolbarItem(placement: .principal) {
                Picker("Period", selection: Binding(get: { current ?? .last12 }, set: { period = $0 })) {
                    ForEach(periods) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
            }
        }
        ToolbarItem {
            Button { ReportExporter.savePDF(data: data, store: store) } label: {
                Label("Save as PDF", systemImage: "square.and.arrow.down")
            }
            .help("Save this report as a PDF to print or share")
        }
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
                CategoryTableCard(data: data, open: interactive ? open : nil)
                HStack(alignment: .top, spacing: 22) {
                    PlacesCard(places: data.places)
                    BiggestCard(transactions: data.biggest)
                }
                HStack(alignment: .top, spacing: 22) {
                    RecurringCard(subscriptions: data.subscriptions)
                    MoneyInCard(data: data)
                }
            }
            Text("Prepared by The Tony Awards on \(Date.now.formatted(date: .long, time: .omitted)). Payments between accounts are left out of spending.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
        }
    }

    private func open(_ category: Category) {
        store.transactionFilter = TransactionFilter(category: category, month: data.months.count == 1 ? data.months.first : nil)
        store.selection = category == .unsorted ? .review : .transactions
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 16) {
            TonyAvatar(size: 64)
            VStack(alignment: .leading, spacing: 2) {
                Text(heroTitle)
                    .font(.system(size: 34, weight: .bold, design: .serif))
                Text(data.subtitle.isEmpty ? "The Tony Awards" : "The Tony Awards · \(data.subtitle)")
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
                    .font(.system(size: 28, weight: .bold, design: .rounded))
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
        .chartXSelection(value: $selected)
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
    }
}

// MARK: - Category table

private struct CategoryTableCard: View {
    let data: ReportData
    let open: ((Category) -> Void)?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Categories", subtitle: open == nil ? nil : "Click a category to see its transactions")
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

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Top Places")
                ForEach(Array(places.enumerated()), id: \.element.id) { i, place in
                    HStack(spacing: 12) {
                        Text("\(i + 1)")
                            .font(.callout.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(i < 3 ? AnyShapeStyle(Gold.gradient) : AnyShapeStyle(.tertiary))
                            .frame(width: 20)
                        CategoryIcon(category: place.category, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(place.name).font(.body.weight(.medium)).lineLimit(1)
                            Text(place.count == 1 ? "1 visit" : "\(place.count) visits")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Money.format(place.total, cents: false)).monospacedDigit()
                    }
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
                    HStack(spacing: 12) {
                        CategoryIcon(category: t.category, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(t.merchantDisplay).font(.body.weight(.medium)).lineLimit(1)
                            Text(t.date.formatted(.dateTime.month(.wide).day()))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Money.format(t.amount)).monospacedDigit()
                    }
                    if i < transactions.count - 1 { Divider().padding(.leading, 40) }
                }
                if transactions.isEmpty { Text("Nothing yet.").foregroundStyle(.secondary) }
            }
        }
    }
}

// MARK: - Recurring & money in

private struct RecurringCard: View {
    let subscriptions: [Subscription]

    var body: some View {
        let monthly = subscriptions.reduce(0) { $0 + $1.monthlyAmount }
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    SectionHeader(title: "Every Month, Like Clockwork", subtitle: "Charges that repeat each month")
                    Spacer()
                }
                if subscriptions.isEmpty {
                    Text("No repeating charges found yet. These show up after two months of statements.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(subscriptions) { s in
                        HStack(spacing: 12) {
                            CategoryIcon(category: s.category, size: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(s.merchant).font(.body.weight(.medium)).lineLimit(1)
                                Text("Last charged \(s.lastCharge.formatted(.dateTime.month(.abbreviated).day()))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 1) {
                                Text("\(Money.format(s.monthlyAmount))/mo").monospacedDigit()
                                Text("\(Money.format(s.monthlyAmount * 12, cents: false))/yr")
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                    Divider()
                    HStack {
                        Text("Together").font(.headline)
                        Spacer()
                        Text("\(Money.format(monthly))/mo · \(Money.format(monthly * 12, cents: false))/yr")
                            .font(.headline)
                            .monospacedDigit()
                    }
                }
            }
        }
    }
}

private struct MoneyInCard: View {
    let data: ReportData

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Money In & Accounts")
                if data.incomeSources.isEmpty {
                    Text("No income found. Add a checking account statement to see paychecks and deposits.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(data.incomeSources) { source in
                        row(symbol: "arrow.down.circle.fill", tint: .green, title: source.name,
                            value: "+" + Money.format(source.total, cents: false), valueColor: .green)
                    }
                }
                if data.transfers > 0 {
                    row(symbol: "arrow.left.arrow.right.circle.fill", tint: .gray, title: "Payments & transfers",
                        value: Money.format(data.transfers, cents: false), valueColor: .secondary,
                        detail: "Moved between accounts, not counted as spending")
                }
                if !data.accounts.isEmpty {
                    Divider().padding(.vertical, 2)
                    Text("SPENDING BY ACCOUNT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(data.accounts) { a in
                        row(symbol: "creditcard.fill", tint: .accentColor, title: a.name,
                            value: Money.format(a.spent, cents: false), valueColor: .primary,
                            detail: "\(a.count) transactions")
                    }
                }
            }
        }
    }

    private func row(symbol: String, tint: Color, title: String, value: String, valueColor: Color, detail: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.medium)).lineLimit(1)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(valueColor)
        }
    }
}

enum Gold {
    static let gradient = LinearGradient(colors: [Color(red: 0.98, green: 0.82, blue: 0.36), Color(red: 0.78, green: 0.56, blue: 0.13)],
                                         startPoint: .top, endPoint: .bottom)
}

// MARK: - PDF export

@MainActor
enum ReportExporter {
    static func savePDF(data: ReportData, store: BudgetStore) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = "Tony Awards – \(data.period.title).pdf"
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
            .background(Color(nsColor: .windowBackgroundColor))
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
