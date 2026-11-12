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
    /// The stretch in words: "2026", "Last 12 Months", "November 2026".
    let title: String
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
    let byInvestmentCategory: [(category: Category, moneyIn: Double, moneyOut: Double)]

    // What each dollar did. Money that went out is not all one thing: some was lived on, some was
    // owed, and some was put to work and is still his. The page keeps those apart.
    private func flow(_ category: Category) -> (moneyIn: Double, moneyOut: Double) {
        byInvestmentCategory.first { $0.category == category }.map { ($0.moneyIn, $0.moneyOut) } ?? (0, 0)
    }
    /// Interest on a loan used for investing: a cost, not something built.
    var loanInterest: Double {
        investmentLines.filter { $0.category == .investmentLoan && $0.name.localizedCaseInsensitiveContains("interest") }.reduce(0) { $0 + $1.moneyOut }
    }
    /// Money put to work: capital calls, purchases, and principal paid down on the investment loan.
    var built: Double { max(0, investmentOut - loanInterest) }
    var fromInvestments: Double { flow(.investmentIncome).moneyIn }
    var soldOrRedeemed: Double { flow(.investing).moneyIn }
    var borrowed: Double { flow(.investmentLoan).moneyIn }
    var earned: Double { income + unsortedIn }

    /// Income is what was earned plus what investments paid out. Selling an investment or borrowing
    /// brings in cash too, but it is not income.
    var totalIncome: Double { earned + fromInvestments }
    /// Consumption is what is gone for good: lived on, paid in taxes, paid in interest. Investing is not in it.
    var consumed: Double { spending + taxes + loanInterest }
    /// Positive: lived within income, and this much was left to save or invest. Negative: spent more than came in.
    var surplus: Double { totalIncome - consumed }

    var everydayResult: Double { income + unsortedIn - spending - taxes }
    var investmentNet: Double { investmentIn - investmentOut }
    var netCash: Double { everydayResult + investmentNet }
    var isEmpty: Bool { months.isEmpty }

    static let laneOrder = ["Salary & income", "Lived on", "Income taxes", "Back from investments", "Invested"]
    static let laneColors: [Color] = [Category.income.color, Theme.spent, Category.taxes.color, Category.investmentIncome.color, Theme.goldDeep]

    @MainActor init(store: BudgetStore, period: ReportPeriod) {
        let inPeriod: (Month) -> Bool
        switch period {
        case .year(let y): inPeriod = { $0.year == y }
        case .last12:
            let end = store.months.last ?? Month(date: .now)
            let start = end.adding(-11)
            inPeriod = { $0 >= start && $0 <= end }
        }
        self.init(store: store, period: period, title: period.title, inPeriod: inPeriod)
    }

    /// Income and money invested, month by month, by the same definitions as the totals.
    @MainActor static func run(of months: [Month], in store: BudgetStore) -> [(income: Double, invested: Double)] {
        let place = Dictionary(uniqueKeysWithValues: months.enumerated().map { ($1, $0) })
        var run = Array(repeating: (income: 0.0, invested: 0.0), count: months.count)
        for t in store.transactions {
            guard let i = place[t.month] else { continue }
            switch t.lane {
            case .everyday: if t.isIncome || t.isUnsortedDeposit { run[i].income -= t.amount }
            case .investments:
                if t.amount > 0 { run[i].invested += t.amount } else if t.category == .investmentIncome { run[i].income -= t.amount }
            case .taxes, .transfers: break
            }
        }
        return run
    }

    /// The same sums for a single month.
    @MainActor init(store: BudgetStore, month: Month) {
        self.init(store: store, period: .year(month.year), title: month.title, inPeriod: { $0 == month })
    }

    @MainActor private init(store: BudgetStore, period: ReportPeriod, title: String, inPeriod: (Month) -> Bool) {
        self.period = period
        self.title = title
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
        var perCategory: [(category: Category, moneyIn: Double, moneyOut: Double)] = []
        for c in Category.investmentCases {
            var moneyIn = 0.0, moneyOut = 0.0
            for t in investments where t.category == c { if t.amount < 0 { moneyIn -= t.amount } else { moneyOut += t.amount } }
            perCategory.append((c, moneyIn, moneyOut))
        }
        byInvestmentCategory = perCategory
    }
}

struct CashFlowContent: View {
    @Environment(BudgetStore.self) private var store
    let data: CashFlowData
    var interactive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Money In and Out")
                    .font(.system(size: 30, weight: .bold, design: .serif))
                Text("Where the money came from and what it did. \(data.title).")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            FlowHero(data: data)
            HStack(alignment: .top, spacing: 22) {
                StatementCard(data: data, open: interactive ? open : nil)
                // (Which card statements are here lives in Setup, with the rest of what's missing.)
                MonthlyFlowCard(data: data)
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
        store.showCharges(TransactionFilter(category: category, month: nil))
    }
    private func openPlace(_ key: String) {
        store.showPlace(key: key)
    }
}

// MARK: - The verdict

// MARK: - What the money did

/// Two bars on one scale: where the money came from, and what it did. The second bar is the point
/// of the page. Money lived on is gone; money invested is not. They must never look the same.
private struct PurposeCard: View {
    let data: CashFlowData

    private struct Part: Identifiable {
        var id: String { name }
        let name: String
        let amount: Double
        let color: Color
        var note: String? = nil
        var kept = false
    }

    var body: some View {
        let sources = [
            Part(name: "Salary & income", amount: data.earned, color: Category.income.color),
            Part(name: "Paid out by investments", amount: data.fromInvestments, color: Category.investmentIncome.color),
            Part(name: "Sold or redeemed", amount: data.soldOrRedeemed, color: Category.investing.color.opacity(0.7)),
            Part(name: "Borrowed", amount: data.borrowed, color: Category.investmentLoan.color),
        ].filter { $0.amount > 0.5 }
        let uses = [
            Part(name: "Invested", amount: data.built, color: Theme.goldDeep, note: "still yours", kept: true),
            Part(name: "Lived on", amount: data.spending, color: Theme.spent),
            Part(name: "Income taxes", amount: data.taxes, color: Category.taxes.color),
            Part(name: "Loan interest", amount: data.loanInterest, color: Category.investmentLoan.color.opacity(0.7)),
        ].filter { $0.amount > 0.5 }
        let totalIn = sources.reduce(0) { $0 + $1.amount }, totalOut = uses.reduce(0) { $0 + $1.amount }
        let scale = max(totalIn, totalOut, 1)
        let consumed = data.spending + data.taxes + data.loanInterest

        Card {
            VStack(alignment: .leading, spacing: 20) {
                // The sentence that says what the picture means.
                VStack(alignment: .leading, spacing: 6) {
                    if data.built > 0.5 {
                        (Text(Money.format(data.built, cents: false)).foregroundStyle(Theme.goldDeep).fontWeight(.bold)
                         + Text(" was invested for the future. ")
                         + Text(Money.format(consumed, cents: false)).fontWeight(.bold)
                         + Text(" was spent: lived on, paid in taxes\(data.loanInterest > 0.5 ? " or paid in interest" : "")."))
                            .font(.system(size: 22, weight: .regular, design: .serif))
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        (Text(Money.format(consumed, cents: false)).fontWeight(.bold) + Text(" went out: lived on or paid in taxes."))
                            .font(.system(size: 22, weight: .regular, design: .serif))
                    }
                    Text(explanation(totalIn: totalIn, consumed: consumed))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                bar("Where it came from", sources, total: totalIn, scale: scale)
                bar("What it did", uses, total: totalOut, scale: scale)
            }
        }
    }

    private func explanation(totalIn: Double, consumed: Double) -> String {
        let cash = data.netCash
        let change = "Cash in these accounts went \(cash >= 0 ? "up" : "down") by \(Money.format(abs(cash), cents: false))"
        if data.built > 0.5, cash < 0 {
            return change + ", but not because that much was spent: money moved into investments is counted here as going out, and it is still yours."
        }
        if data.built > 0.5 { return change + ", after putting \(Money.format(data.built, cents: false)) to work." }
        return change + "."
    }

    private func bar(_ title: String, _ parts: [Part], total: Double, scale: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased()).font(.caption.weight(.bold)).tracking(1.1).foregroundStyle(.secondary)
                Spacer()
                Text(Money.format(total, cents: false)).font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let gaps = CGFloat(max(parts.count - 1, 0)) * 3
                let usable = max(0, geo.size.width * CGFloat(total / scale) - gaps)
                HStack(spacing: 3) {
                    ForEach(parts) { part in
                        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
                        shape.fill(part.color.gradient)
                            // What was kept gets a gold rim: the one piece of the bar that isn't gone.
                            .overlay(shape.strokeBorder(Theme.gold, lineWidth: part.kept ? 2 : 0))
                            .frame(width: max(4, usable * CGFloat(part.amount / max(total, 1))))
                    }
                }
            }
            .frame(height: 30)
            FlowLayout(spacing: 18) {
                ForEach(parts) { part in
                    HStack(spacing: 6) {
                        if part.kept {
                            Image(systemName: "arrow.up.forward.circle.fill").foregroundStyle(Theme.goldDeep).font(.callout)
                        } else {
                            Circle().fill(part.color).frame(width: 9, height: 9)
                        }
                        Text(part.name).font(.callout.weight(part.kept ? .semibold : .regular))
                        Text(Money.format(part.amount, cents: false)).font(.callout.weight(.semibold)).monospacedDigit()
                        Text("\(Int((part.amount / max(total, 1) * 100).rounded()))%").font(.caption).foregroundStyle(.secondary)
                        if let note = part.note {
                            Text(note).font(.caption.weight(.semibold)).foregroundStyle(Theme.goldDeep)
                                .lineLimit(1).fixedSize()
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Theme.goldDeep.opacity(0.12), in: .capsule)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - The statement

private struct StatementCard: View {
    let data: CashFlowData
    let open: ((Category) -> Void)?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                heading("Everyday", symbol: "house.fill", color: Theme.spent)
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
                            note: item.category == .investing
                                ? "\(Money.format(item.moneyOut, cents: false)) invested · \(Money.format(item.moneyIn, cents: false)) came back"
                                : "\(Money.format(item.moneyIn, cents: false)) in · \(Money.format(item.moneyOut, cents: false)) out",
                            invested: true)
                    }
                }
                total("Investments, net", data.investmentNet,
                      note: data.investmentNet < 0 ? "More went into investments than came out. That is money put to work, not money spent." : nil,
                      invested: true)

                Divider().padding(.vertical, 4)
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Change in cash").font(.headline)
                        Text("Not a score: investing lowers it, and that's a good thing.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(signed(data.netCash))
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(data.netCash >= 0 ? Theme.good : Color.secondary)
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
    private func row(_ title: String, _ amount: Double, sign: Int, category: Category?, note: String? = nil, invested: Bool = false) -> some View {
        let value = sign == 0 ? amount : Double(sign) * amount
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.body.weight(.medium))
                if let note { Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer()
            // Money going into investments is gold, never the color of spending.
            Text(signed(value)).monospacedDigit().foregroundStyle(value > 0 ? Theme.good : invested ? Theme.goldDeep : Color.primary)
            if open != nil, category != nil {
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if let category { open?(category) } }
        .accessibilityAddTraits(open != nil && category != nil ? .isButton : [])
    }

    private func total(_ title: String, _ amount: Double, note: String?, invested: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text(signed(amount)).font(.headline).monospacedDigit().foregroundStyle(amount >= 0 ? Theme.good : invested ? Theme.goldDeep : Color.primary)
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

/// Do the cards tie out? Every payment a bank account made to a card, matched to that card's
/// statements, and exactly which statement to look for when one doesn't.
struct CardCoverageCard: View {
    private var store: BudgetStore { .shared }
    let coverage: [CardCoverage]

    private func day(_ iso: String) -> Date? { DateParsing.parse(iso, format: "yyyy-MM-dd") }
    private func long(_ iso: String) -> String { day(iso)?.formatted(.dateTime.month(.abbreviated).day().year()) ?? iso }
    private func span(_ from: String, _ to: String) -> String {
        guard let a = day(from), let b = day(to) else { return "\(from) to \(to)" }
        let sameYear = Calendar.current.component(.year, from: a) == Calendar.current.component(.year, from: b)
        return "\(a.formatted(sameYear ? .dateTime.month(.abbreviated).day() : .dateTime.month(.abbreviated).day().year())) to \(b.formatted(.dateTime.month(.abbreviated).day().year()))"
    }

    var body: some View {
        let toFind = coverage.reduce(0) { $0 + $1.toFind.count }
        let notAdded = coverage.filter { $0.accounts.isEmpty && $0.uncoveredPayments > 0 }.count
        let loose = coverage.reduce(0) { $0 + $1.unexplained.count }
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Do the cards tie out?",
                              subtitle: "Every payment your bank made to a card, matched to that card's own statements")
                // The answer first.
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: toFind + notAdded + loose == 0 ? "checkmark.seal.fill" : "doc.badge.ellipsis")
                        .font(.title2)
                        .foregroundStyle(toFind + notAdded + loose == 0 ? Theme.good : Theme.caution)
                    Text(verdict(toFind: toFind, notAdded: notAdded, loose: loose))
                        .font(.body.weight(.medium))
                        .fixedSize(horizontal: false, vertical: true)
                    if toFind + notAdded + loose == 0 {
                        Spacer(minLength: 8)
                        Stamp(text: "TIED OUT")
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background((toFind + notAdded + loose == 0 ? Theme.good : Theme.caution).opacity(0.08), in: .rect(cornerRadius: 10, style: .continuous))

                ForEach(Array(coverage.enumerated()), id: \.element.id) { index, c in
                    if index > 0 { Divider() }
                    row(c)
                }
            }
        }
    }

    private func verdict(toFind: Int, notAdded: Int, loose: Int) -> String {
        if toFind + notAdded + loose == 0 {
            return "Yes. Every card payment is matched to a statement that's here, so no statement is missing and nothing is counted twice."
        }
        var parts: [String] = []
        if toFind > 0 { parts.append(toFind == 1 ? "1 statement to find" : "\(toFind) statements to find") }
        if notAdded > 0 { parts.append(notAdded == 1 ? "1 card whose statements were never added" : "\(notAdded) cards whose statements were never added") }
        if loose > 0 { parts.append(loose == 1 ? "1 payment that matches no statement" : "\(loose) payments that match no statement") }
        return "Not quite: " + parts.joined(separator: ", ") + ". The details are below."
    }

    @ViewBuilder private func row(_ c: CardCoverage) -> some View {
        let fine = c.isComplete
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: fine ? "checkmark.circle.fill" : (c.accounts.isEmpty ? "creditcard.trianglebadge.exclamationmark" : "exclamationmark.circle.fill"))
                .font(.title3)
                .foregroundStyle(fine ? Theme.good : Theme.caution)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(c.accounts.isEmpty ? c.issuer : c.accounts.joined(separator: ", ")).font(.body.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Text(Money.format(c.paid, cents: false)).monospacedDigit()
                }
                if c.accounts.isEmpty {
                    Text("\(count(c.payments)) from your bank, but none of this card's statements are here. Until they are, the payments count as spending under “Cards Not Added Yet”. Add its statements to see what they bought.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("\(c.tied) of \(count(c.payments)) matched to a statement.\(fine && c.early.isEmpty ? " Nothing missing." : "")")
                        .font(.callout).foregroundStyle(.secondary)
                    ForEach(c.toFind) { find in
                        note("magnifyingglass", Theme.caution,
                             "Find the \(find.account) statement for \(span(find.from, find.to)).",
                             "\(Money.format(find.paid)) was paid for it on \(long(find.paidOn)), so it exists. Its purchases aren't in your totals yet.")
                    }
                    ForEach(c.unexplained) { p in
                        Button { store.showOriginal(of: p.id) } label: {
                            note("questionmark.circle", Theme.caution,
                                 "\(Money.format(p.amount)) on \(long(p.date)) matches no statement.",
                                 "It may have paid a different card from this bank. It counts as spending until its statement is added. Click to see the payment.")
                        }
                        .buttonStyle(.plain)
                    }
                    if !c.early.isEmpty {
                        let total = c.early.reduce(0) { $0 + $1.amount }
                        note("clock.arrow.circlepath", .secondary,
                             c.early.count == 1 ? "\(Money.format(total)) on \(long(c.early[0].date)) is from before your records begin."
                                                : "\(c.early.count) payments (\(Money.format(total))) are from before your records begin.",
                             "\(c.early.count == 1 ? "It" : "They") paid for a statement older than the first one here. Nothing to do, unless you want that earlier statement too.")
                    }
                }
            }
        }
    }

    private func count(_ n: Int) -> String { n == 1 ? "1 payment" : "\(n) payments" }

    private func note(_ symbol: String, _ color: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .contentShape(Rectangle())
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
                                MerchantIcon(name: line.name, category: line.category, size: 26)
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
                        .accessibilityAddTraits(open != nil ? .isButton : [])
                    }
                }
            }
        }
    }
}


// MARK: - Details reached from the Overview

/// Who paid, and how much: every source of income in the stretch.
struct IncomeDetail: View {
    @Environment(BudgetStore.self) private var store
    let data: CashFlowData

    var body: some View {
        let paidOut = data.investmentLines.filter { $0.category == .investmentIncome && $0.moneyIn > 0.5 }
        VStack(alignment: .leading, spacing: 22) {
            BigFigure(title: "Income", amount: data.totalIncome, subtitle: "What came in. \(data.title).")
            HStack(alignment: .top, spacing: 22) {
                VStack(spacing: 22) {
                    lines("Salary & income", "What you were paid", data.incomeLines.filter { $0.moneyIn > 0.5 }, total: data.income)
                    if !paidOut.isEmpty { lines("Paid out by investments", "Dividends, interest and distributions", paidOut, total: data.fromInvestments) }
                    if data.unsortedIn > 0.5 {
                        Text("\(Money.format(data.unsortedIn, cents: false)) more came in as deposits nobody has named yet.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if data.months.count > 1 { MonthlyFlowCard(data: data).frame(minWidth: 360) }
            }
        }
    }

    private func lines(_ title: String, _ subtitle: String, _ lines: [CashFlowData.Line], total: Double) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    SectionHeader(title: title, subtitle: subtitle)
                    Spacer()
                    Text(Money.format(total, cents: false)).font(.headline).monospacedDigit()
                }
                if lines.isEmpty { Text("Nothing in this stretch.").foregroundStyle(.secondary) }
                ForEach(lines.prefix(14)) { line in
                    PayeeLine(name: line.name, category: line.category, amount: line.moneyIn) { store.showPlace(key: line.key) }
                }
            }
        }
    }
}

/// The investment side on its own: what was put to work, and what came back.
struct InvestingDetail: View {
    @Environment(BudgetStore.self) private var store
    let data: CashFlowData

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            BigFigure(title: "Investing", amount: data.built, subtitle: "Money put to work. It isn't spending: it's still yours. \(data.title).")
            PurposeCard(data: data)
            if data.investmentLines.isEmpty {
                Text("Nothing on the investment side in this stretch.").foregroundStyle(.secondary)
            } else {
                InvestmentsCard(data: data, open: { store.showPlace(key: $0) })
            }
        }
    }
}

