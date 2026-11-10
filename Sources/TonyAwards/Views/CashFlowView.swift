import SwiftUI
import Charts

/// All money in and out, split into lanes so investments and taxes never blur everyday life.
struct CashFlowData {
    struct MonthBar: Identifiable {
        var id: String { "\(month.key)-\(lane)" }
        let month: Month
        let lane: String
        let amount: Double      // positive = money in, negative = money out
    }
    struct Line: Identifiable {
        var id: String { key }
        let key: String
        let name: String
        let category: Category
        let moneyIn: Double
        let moneyOut: Double
        var net: Double { moneyIn - moneyOut }
    }

    let period: ReportPeriod
    let months: [Month]
    let income: Double
    let spending: Double
    /// Part of `spending`: payments to cards whose statements aren't added.
    let uncoveredCards: Double
    let taxes: Double
    let investmentIn: Double
    let investmentOut: Double
    let transfersHidden: Double
    let unsortedIn: Double
    let bars: [MonthBar]
    let investmentLines: [Line]
    let incomeLines: [Line]
    let taxLines: [Line]
    let byInvestmentCategory: [(category: Category, moneyIn: Double, moneyOut: Double)]

    var everydayResult: Double { income + unsortedIn - spending - taxes }
    var investmentNet: Double { investmentIn - investmentOut }
    var netCash: Double { everydayResult + investmentNet }
    var isEmpty: Bool { months.isEmpty }

    static let laneOrder = ["Salary & income", "Everyday spending", "Income taxes", "Investments in", "Investments out"]
    static let laneColors: [Color] = [Category.income.color, .pink, Category.taxes.color, Theme.goldDeep, Category.investing.color]

    @MainActor init(store: BudgetStore, period: ReportPeriod) {
        self.period = period
        let inPeriod: (Month) -> Bool
        switch period {
        case .year(let y): inPeriod = { $0.year == y }
        case .last12:
            let end = store.months.last ?? Month(date: .now)
            let start = end.adding(-11)
            inPeriod = { $0 >= start && $0 <= end }
        }
        let txns = store.transactions.filter { inPeriod($0.month) }
        months = Array(Set(txns.map(\.month))).sorted()

        var income = 0.0, spending = 0.0, uncovered = 0.0, taxes = 0.0, invIn = 0.0, invOut = 0.0, hidden = 0.0, unsortedIn = 0.0
        var perMonth: [Month: [Double]] = [:]
        for t in txns {
            var row = perMonth[t.month] ?? [0, 0, 0, 0, 0]
            switch t.lane {
            case .transfers:
                hidden += abs(t.amount)
            case .taxes:
                taxes += t.amount; row[2] -= t.amount
            case .investments:
                if t.amount < 0 { invIn -= t.amount; row[3] -= t.amount } else { invOut += t.amount; row[4] -= t.amount }
            case .everyday:
                if t.isIncome {
                    income -= t.amount; row[0] -= t.amount
                } else if t.isUnsortedDeposit {
                    unsortedIn -= t.amount; row[0] -= t.amount
                } else {
                    spending += t.amount; row[1] -= t.amount
                    if t.category == .uncoveredCards { uncovered += t.amount }
                }
            }
            perMonth[t.month] = row
        }
        self.income = income; self.spending = spending; uncoveredCards = uncovered; self.taxes = taxes
        investmentIn = invIn; investmentOut = invOut; transfersHidden = hidden; self.unsortedIn = unsortedIn
        var bars: [MonthBar] = []
        for m in months {
            let row = perMonth[m] ?? [0, 0, 0, 0, 0]
            for (i, lane) in Self.laneOrder.enumerated() where abs(row[i]) > 0.005 {
                bars.append(MonthBar(month: m, lane: lane, amount: row[i]))
            }
        }
        self.bars = bars

        func lines(_ list: [Transaction]) -> [Line] {
            var out: [Line] = []
            for (key, group) in Dictionary(grouping: list, by: \.merchantKey) {
                var moneyIn = 0.0, moneyOut = 0.0
                for t in group { if t.amount < 0 { moneyIn -= t.amount } else { moneyOut += t.amount } }
                out.append(Line(key: key, name: group[0].merchant, category: group[0].category, moneyIn: moneyIn, moneyOut: moneyOut))
            }
            out.sort { a, b in (a.moneyIn + a.moneyOut) > (b.moneyIn + b.moneyOut) }
            return out
        }
        let investments = txns.filter { $0.lane == .investments }
        investmentLines = lines(investments)
        incomeLines = lines(txns.filter(\.isIncome))
        taxLines = lines(txns.filter { $0.lane == .taxes })
        var perCategory: [(category: Category, moneyIn: Double, moneyOut: Double)] = []
        for c in Category.investmentCases {
            var moneyIn = 0.0, moneyOut = 0.0
            for t in investments where t.category == c { if t.amount < 0 { moneyIn -= t.amount } else { moneyOut += t.amount } }
            perCategory.append((c, moneyIn, moneyOut))
        }
        byInvestmentCategory = perCategory
    }
}

struct CashFlowView: View {
    @Environment(BudgetStore.self) private var store
    @State private var period: ReportPeriod?

    private var periods: [ReportPeriod] { ReportData.periods(for: store) }
    private var current: ReportPeriod? { period.flatMap { periods.contains($0) ? $0 : nil } ?? periods.first }

    var body: some View {
        Group {
            if let current {
                ScrollView {
                    CashFlowContent(data: CashFlowData(store: store, period: current), interactive: true)
                        .padding(28)
                        .frame(maxWidth: 1100)
                        .frame(maxWidth: .infinity)
                }
                .toolbar {
                    if periods.count > 1 {
                        ToolbarItem(placement: .principal) {
                            Picker("Period", selection: Binding(get: { current }, set: { period = $0 })) {
                                ForEach(periods) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .fixedSize()
                        }
                    }
                }
            } else {
                TonySays(title: "Nothing here yet", message: "Add your bank and card statements and I'll show where every dollar came from and went.")
            }
        }
        .navigationTitle("Cash Flow")
    }
}

struct CashFlowContent: View {
    @Environment(BudgetStore.self) private var store
    let data: CashFlowData
    var interactive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 16) {
                TonyAvatar(size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("The whole picture")
                        .font(.system(size: 30, weight: .bold, design: .serif))
                    Text("Everyday life on one side, investments on the other, taxes on their own line. \(data.period.title).")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            HStack(alignment: .top, spacing: 22) {
                StatementCard(data: data, open: interactive ? open : nil)
                VStack(spacing: 22) {
                    MonthlyFlowCard(data: data)
                    if !store.cardCoverage.isEmpty { CardCoverageCard(coverage: store.cardCoverage) }
                }
                .frame(minWidth: 380)
            }
            if !data.investmentLines.isEmpty { InvestmentsCard(data: data, open: interactive ? openPlace : nil) }
            Text("Money moved between your own accounts and payments to cards whose statements are here are left out (\(Money.format(data.transfersHidden, cents: false)) in all), so nothing is counted twice.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
        }
    }

    private func open(_ category: Category) {
        store.transactionFilter = TransactionFilter(category: category)
        store.selection = .transactions
    }
    private func openPlace(_ key: String) {
        store.transactionFilter = TransactionFilter(merchantKey: key)
        store.selection = .transactions
    }
}

// MARK: - The statement

private struct StatementCard: View {
    let data: CashFlowData
    let open: ((Category) -> Void)?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                heading("Everyday", symbol: "house.fill", color: .pink)
                row("Salary & income", data.income, sign: 1, category: .income)
                if data.unsortedIn > 0 {
                    row("Deposits not labelled yet", data.unsortedIn, sign: 1, category: .unsorted,
                        note: "Label these in Double-Check so they land in the right place")
                }
                row("Everyday spending", data.spending, sign: -1, category: nil,
                    note: data.uncoveredCards > 0 ? "includes \(Money.format(data.uncoveredCards, cents: false)) paid to cards whose statements aren't added yet" : nil)
                row("Income taxes", data.taxes, sign: -1, category: .taxes)
                total("Everyday result", data.everydayResult,
                      note: data.everydayResult < 0 ? "Everyday life cost more than salary brought in. Investments covered the rest." : nil)

                Divider().padding(.vertical, 4)
                heading("Investments", symbol: "chart.line.uptrend.xyaxis", color: Category.investmentIncome.color)
                ForEach(data.byInvestmentCategory, id: \.category) { item in
                    if item.moneyIn > 0 || item.moneyOut > 0 {
                        row(item.category.displayName, item.moneyIn - item.moneyOut, sign: 0, category: item.category,
                            note: "\(Money.format(item.moneyIn, cents: false)) in · \(Money.format(item.moneyOut, cents: false)) out")
                    }
                }
                total("Investments, net", data.investmentNet, note: nil)

                Divider().padding(.vertical, 4)
                HStack(alignment: .firstTextBaseline) {
                    Text("Net cash flow").font(.title3.weight(.bold))
                    Spacer()
                    Text(signed(data.netCash))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(data.netCash >= 0 ? Theme.good : Color.primary)
                }
            }
        }
    }

    private func signed(_ v: Double) -> String {
        (v >= 0 ? "+" : "−") + Money.format(abs(v), cents: false)
    }

    private func heading(_ title: String, symbol: String, color: Color) -> some View {
        Label(title.uppercased(), systemImage: symbol)
            .font(.caption.weight(.bold))
            .tracking(1.1)
            .foregroundStyle(color)
    }

    /// - sign: +1 always shown as money in, -1 as money out, 0 = `amount` is already signed.
    private func row(_ title: String, _ amount: Double, sign: Int, category: Category?, note: String? = nil) -> some View {
        let value = sign == 0 ? amount : Double(sign) * amount
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.medium))
                if let note { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer()
            Text(signed(value)).monospacedDigit().foregroundStyle(value > 0 ? Theme.good : Color.primary)
            if open != nil, category != nil {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if let category { open?(category) } }
    }

    private func total(_ title: String, _ amount: Double, note: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(signed(amount)).font(.headline).monospacedDigit().foregroundStyle(amount >= 0 ? Theme.good : Color.primary)
            }
            if let note { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
        .padding(.top, 4)
    }
}

// MARK: - Month by month

private struct MonthlyFlowCard: View {
    let data: CashFlowData

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Month by Month", subtitle: "Money in above the line, money out below")
                Chart {
                    ForEach(data.bars) { bar in
                        BarMark(x: .value("Month", bar.month.firstDay, unit: .month),
                                y: .value("Amount", bar.amount), width: .ratio(0.62))
                            .foregroundStyle(by: .value("Lane", bar.lane))
                    }
                    RuleMark(y: .value("Zero", 0)).foregroundStyle(Color.primary.opacity(0.35)).lineStyle(StrokeStyle(lineWidth: 1))
                }
                .chartForegroundStyleScale(domain: CashFlowData.laneOrder, range: CashFlowData.laneColors)
                .chartLegend(position: .bottom, alignment: .leading, spacing: 12)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .month)) { _ in
                        AxisValueLabel(format: .dateTime.month(.narrow), centered: true)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                        AxisGridLine()
                        AxisValueLabel {
                            if let v = value.as(Double.self) { Text(compact(v)) }
                        }
                    }
                }
                .frame(height: 260)
            }
        }
    }

    private func compact(_ v: Double) -> String {
        let a = abs(v)
        let s = a >= 1_000_000 ? String(format: "$%.1fM", a / 1_000_000) : a >= 1000 ? String(format: "$%.0fK", a / 1000) : String(format: "$%.0f", a)
        return v < 0 ? "−" + s : s
    }
}

// MARK: - Card coverage

struct CardCoverageCard: View {
    let coverage: [CardCoverage]

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Credit Cards", subtitle: "What your bank paid them, and whether I can see what it bought")
                ForEach(coverage) { c in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: c.uncoveredPayments == 0 ? "checkmark.circle.fill" : (c.accounts.isEmpty ? "creditcard.trianglebadge.exclamationmark" : "circle.lefthalf.filled"))
                            .font(.title3)
                            .foregroundStyle(c.uncoveredPayments == 0 ? Theme.good : Theme.caution)
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(c.issuer).font(.body.weight(.semibold))
                                Spacer()
                                Text(Money.format(c.paid, cents: false)).monospacedDigit()
                            }
                            Text(detail(c))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    private func detail(_ c: CardCoverage) -> String {
        let n = c.payments == 1 ? "1 payment" : "\(c.payments) payments"
        if c.uncoveredPayments == 0 { return "\(n), all explained by the statements you've added." }
        if c.accounts.isEmpty {
            return "\(n). No statements added, so these count as spending in “Cards Not Added Yet”. Add this card's statements to see what it bought."
        }
        return "\(n). \(c.uncoveredPayments) of them (\(Money.format(c.uncoveredPaid, cents: false))) aren't covered by the statements added so far. Add the missing months to break that down."
    }
}

// MARK: - Investments by fund

private struct InvestmentsCard: View {
    let data: CashFlowData
    let open: ((String) -> Void)?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "The Investment Side", subtitle: "Kept apart from salary and spending")
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 0) {
                    GridRow {
                        Text("Where")
                        Text("Money In").gridColumnAlignment(.trailing)
                        Text("Money Out").gridColumnAlignment(.trailing)
                        Text("Net").gridColumnAlignment(.trailing)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.bottom, 8)
                    ForEach(data.investmentLines) { line in
                        Divider().gridCellUnsizedAxes(.horizontal)
                        GridRow {
                            HStack(spacing: 10) {
                                CategoryIcon(category: line.category, size: 26)
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(line.name).font(.body.weight(.medium)).lineLimit(1)
                                    Text(line.category.displayName).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(line.moneyIn > 0 ? Money.format(line.moneyIn, cents: false) : "–").monospacedDigit().foregroundStyle(Theme.good)
                            Text(line.moneyOut > 0 ? Money.format(line.moneyOut, cents: false) : "–").monospacedDigit()
                            Text((line.net >= 0 ? "+" : "−") + Money.format(abs(line.net), cents: false))
                                .font(.body.weight(.semibold)).monospacedDigit()
                        }
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                        .onTapGesture { open?(line.key) }
                    }
                }
            }
        }
    }
}
