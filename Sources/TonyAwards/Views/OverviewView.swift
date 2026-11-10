import SwiftUI
import Charts

struct OverviewView: View {
    @Environment(BudgetStore.self) private var store
    @State private var month: Month?
    @State private var hoveredAngle: Double?

    /// False when rendered for a test snapshot (ImageRenderer can't draw scroll views).
    var scrolls = true

    private var currentMonth: Month? { month ?? store.months.last }

    var body: some View {
        if scrolls {
            ScrollView { content }.navigationTitle("Overview")
        } else {
            content
        }
    }

    private var content: some View {
            VStack(alignment: .leading, spacing: 20) {
                DailyTonyCard()
                DownloadsBanner()
                if !store.reviewItems.isEmpty, !store.isSuggesting { reviewBanner }

                if let m = currentMonth {
                    header(m)
                    beyondEveryday(m)
                    HStack(alignment: .top, spacing: 20) {
                        breakdownCard(m)
                        VStack(spacing: 20) {
                            trendCard(m)
                            topPlacesCard(m)
                        }
                        .frame(minWidth: 300, maxWidth: 420)
                    }
                    CeremonyCard(month: m)
                } else {
                    TonySays(title: "Nothing here yet", message: "Drop a statement into this window and the show begins.")
                }
            }
            .padding(28)
            .frame(maxWidth: 1200)
            .frame(maxWidth: .infinity)
    }

    // MARK: Header

    private func header(_ m: Month) -> some View {
        let total = store.totalSpent(in: m)
        let previous = store.totalSpent(in: m.adding(-1))
        let hasPrevious = store.months.contains(m.adding(-1))
        let months = store.months
        let index = months.firstIndex(of: m) ?? 0

        return HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Spent in \(m.name)")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(Money.format(total))
                    .font(.system(size: 54, weight: .bold, design: .rounded))
                    .contentTransition(.numericText(value: total))
                    .monospacedDigit()
                if hasPrevious, previous > 0 {
                    let diff = total - previous
                    Label {
                        Text("\(Money.format(abs(diff), cents: false)) \(diff <= 0 ? "less" : "more") than \(m.adding(-1).name)")
                    } icon: {
                        Image(systemName: diff <= 0 ? "arrow.down.right" : "arrow.up.right")
                    }
                    .font(.callout.weight(.medium))
                    .foregroundStyle(diff <= 0 ? Theme.good : Theme.caution)
                }
            }
            Spacer()
            HStack(spacing: 4) {
                Button { withAnimation { month = months[index - 1] } } label: {
                    Image(systemName: "chevron.left").frame(width: 20, height: 20)
                }
                .disabled(index == 0)
                Text(m.title)
                    .font(.headline)
                    .frame(minWidth: 130)
                Button { withAnimation { month = months[index + 1] } } label: {
                    Image(systemName: "chevron.right").frame(width: 20, height: 20)
                }
                .disabled(index >= months.count - 1)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
    }

    /// Salary, taxes and investments for the month: visible, but apart from spending.
    @ViewBuilder
    private func beyondEveryday(_ m: Month) -> some View {
        let month = store.transactions.filter { $0.month == m }
        let salary = month.filter(\.isIncome).reduce(0) { $0 - $1.amount }
        let taxes = month.filter { $0.lane == .taxes }.reduce(0) { $0 + $1.amount }
        let investments = month.filter { $0.lane == .investments }.reduce(0) { $0 - $1.amount }
        if salary != 0 || taxes != 0 || investments != 0 {
            Button { store.selection = .cashflow } label: {
                HStack(spacing: 22) {
                    Text("Also this month").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                    if salary != 0 { aside("Salary & income", salary, Category.income) }
                    if taxes != 0 { aside("Income taxes", -taxes, Category.taxes) }
                    if investments != 0 { aside("Investments, net", investments, Category.investmentIncome) }
                    Spacer()
                    Label("Cash Flow", systemImage: "chevron.right")
                        .labelStyle(.titleAndIcon)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.tint)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func aside(_ title: String, _ amount: Double, _ category: Category) -> some View {
        HStack(spacing: 6) {
            Image(systemName: category.symbol).font(.caption.weight(.bold)).foregroundStyle(category.color)
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text((amount >= 0 ? "+" : "−") + Money.format(abs(amount), cents: false))
                .font(.callout.weight(.semibold)).monospacedDigit()
        }
    }

    private var reviewBanner: some View {
        let n = store.reviewItems.count
        return Card(padding: 14) {
            HStack(spacing: 14) {
                Image(systemName: "sparkles")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(Theme.gold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Everything is sorted. \(n) \(n == 1 ? "guess is" : "guesses are") worth a glance.")
                        .font(.headline)
                    Text("Apple Intelligence sorted \(n == 1 ? "a place" : "some places") it hadn't seen before.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Double-Check") { store.selection = .review }
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
                    Chart(totals, id: \.category) { item in
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
                                    Text(Money.format(hovered.flatMap { h in totals.first { $0.category == h }?.total } ?? sum, cents: false))
                                        .font(.title2.weight(.bold))
                                        .monospacedDigit()
                                }
                                .position(x: frame.midX, y: frame.midY)
                            }
                        }
                    }
                    .frame(height: 240)
                    .animation(.snappy, value: hovered)

                    VStack(spacing: 4) {
                        ForEach(totals, id: \.category) { item in
                            CategoryRow(category: item.category, total: item.total, fraction: item.total / max(sum, 1)) {
                                store.transactionFilter = TransactionFilter(category: item.category, month: m)
                                store.selection = .transactions
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
                SectionHeader(title: "Month by month")
                Chart(data, id: \.month) { item in
                    BarMark(x: .value("Month", item.month.shortName),
                            y: .value("Spent", max(item.total, 0)),
                            width: .ratio(0.6))
                        .cornerRadius(6)
                        .foregroundStyle(item.month == m ? Theme.accent.gradient : Theme.accent.opacity(0.3).gradient)
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let v = value.as(Double.self) { Text(Money.format(v, cents: false)) }
                        }
                    }
                }
                .frame(height: 150)
            }
        }
    }

    // MARK: Top places

    private func topPlacesCard(_ m: Month) -> some View {
        let top = store.topMerchants(in: m)
        return Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Top places")
                ForEach(Array(top.enumerated()), id: \.offset) { _, item in
                    Button {
                        store.transactionFilter = TransactionFilter(month: m, merchantKey: item.key)
                        store.selection = .transactions
                    } label: {
                    HStack(spacing: 12) {
                        CategoryIcon(category: item.category, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name).font(.body.weight(.medium)).lineLimit(1)
                            Text(item.count == 1 ? "1 visit" : "\(item.count) visits")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Money.format(item.total)).monospacedDigit()
                    }
                    .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
