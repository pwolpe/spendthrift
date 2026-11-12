import SwiftUI

struct AccountsView: View {
    @Environment(BudgetStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Accounts")
                            .font(.system(size: 30, weight: .bold, design: .serif))
                        Text("To update one, download a newer statement and drop it anywhere in this window. I'll find the right account and skip anything already here.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button { store.presentOpenPanel() } label: { Label("Add Statement", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                DownloadsBanner()
                CoverageCard()
                if !store.cardCoverage.isEmpty { CardCoverageCard(coverage: store.cardCoverage) }
                SpendCard()
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16)], spacing: 16) {
                    ForEach(store.accounts) { AccountCard(account: $0) }
                }
            }
            .padding(28)
            .frame(maxWidth: 1000)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Accounts")
    }
}

private struct AccountCard: View {
    @Environment(BudgetStore.self) private var store
    let account: Account
    @State private var name = ""
    @State private var confirmRemove = false
    @State private var confirmFlip = false

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "creditcard.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accent))
                    TextField("Account name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.title3.weight(.semibold))
                        .onSubmit { store.renameAccount(account.id, to: name) }
                        .help("Click to rename")
                    Menu {
                        Button("Show Transactions", systemImage: "list.bullet") {
                            if account.apart != nil { store.go(to: .apart) } else { store.showCharges(TransactionFilter(accountID: account.id)) }
                        }
                        if account.apart != nil {
                            Button("Count in My Totals Again", systemImage: "tray.and.arrow.down") { store.keepApart(account.id, as: nil) }
                        } else {
                            Button("Keep Apart from My Totals…", systemImage: "tray.full") {
                                if let name = SetApartView.askName(for: account.name) { store.keepApart(account.id, as: name) }
                            }
                        }
                        Button("Amounts Look Backwards…", systemImage: "arrow.up.arrow.down") { confirmFlip = true }
                        Divider()
                        Button("Remove Account…", systemImage: "trash", role: .destructive) { confirmRemove = true }
                    } label: {
                        Image(systemName: "ellipsis.circle").font(.title3)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More for this account").accessibilityLabel("More for \(account.name)")
                }
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    GridRow {
                        Text("Transactions").foregroundStyle(.secondary)
                        Text("\(store.transactionCount(for: account))").monospacedDigit()
                    }
                    GridRow {
                        Text("Spent").foregroundStyle(.secondary)
                        Text(Money.format(store.spent(in: account), cents: false)).monospacedDigit()
                    }
                    if let range = store.dateRange(for: account) {
                        GridRow {
                            Text("Covers").foregroundStyle(.secondary)
                            Text("\(range.lowerBound.formatted(.dateTime.month(.abbreviated).day())) – \(range.upperBound.formatted(.dateTime.month(.abbreviated).day().year()))")
                        }
                    }
                    if let last = account.lastImport {
                        GridRow {
                            Text("Updated").foregroundStyle(.secondary)
                            Text(last.formatted(.relative(presentation: .named)))
                        }
                    }
                }
                .font(.callout)
                if let missing = store.missingStatements.first(where: { $0.accountID == account.id }) {
                    Label("No statement for \(missing.months.prefix(6).map(\.shortName).joined(separator: ", "))\(missing.months.count > 6 ? " and \(missing.months.count - 6) more" : ""). Download \(missing.months.count == 1 ? "it" : "them") from the bank and I'll add \(missing.months.count == 1 ? "it" : "them").",
                          systemImage: "calendar.badge.exclamationmark")
                        .font(.callout)
                        .foregroundStyle(Theme.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { name = account.name }
        .onChange(of: account.name) { name = account.name }
        .confirmationDialog("Remove \(account.name)?", isPresented: $confirmRemove) {
            Button("Remove Account", role: .destructive) { store.removeAccount(account.id) }
        } message: {
            Text("Its transactions will be removed from Spendthrift. What you taught me about each payee is kept.")
        }
        .confirmationDialog("Swap purchases and payments for \(account.name)?", isPresented: $confirmFlip) {
            Button("Swap Them") { store.flipAmounts(account.id) }
        } message: {
            Text("Use this if purchases show up in green as money coming in. It fixes this account now and for future statements.")
        }
    }
}

/// One glance at what's here and what isn't: a row for each account, a square for each month.
/// A missing statement is the easiest mistake to make and the hardest to notice, because a month
/// that isn't there doesn't look wrong; the totals are simply too small.
struct CoverageCard: View {
    private var store: BudgetStore { .shared }

    private struct Row: Identifiable {
        let id: String
        let name: String
        let have: Set<Month>
        let missing: Set<Month>
        var neverAdded = false
    }

    private var rows: [Row] {
        var rows = store.accounts.map { account -> Row in
            let have = store.summary(of: account).months.union((account.statementMonths ?? []).compactMap { Month(key: $0) })
            var missing = Set(store.missingStatements.first { $0.accountID == account.id }?.months ?? [])
            // A stretch the tie-out proves a statement is missing for (a payment was made for it).
            if let card = store.cardCoverage.first(where: { $0.accounts.contains(account.name) }) {
                for find in card.toFind where find.account == account.name {
                    guard let from = DateParsing.parse(find.from, format: "yyyy-MM-dd"), let to = DateParsing.parse(find.to, format: "yyyy-MM-dd") else { continue }
                    var m = Month(date: from)
                    while m <= Month(date: to) { if !have.contains(m) { missing.insert(m) }; m = m.adding(1) }
                }
            }
            return Row(id: account.id.uuidString, name: account.name, have: have, missing: missing)
        }
        // A card that is paid from a bank account here, but whose own statements were never added.
        for card in store.cardCoverage where card.accounts.isEmpty && card.uncoveredPayments > 0 {
            rows.append(Row(id: "card:" + card.issuer, name: "\(card.issuer) card", have: [], missing: [], neverAdded: true))
        }
        return rows
    }

    /// How far back the person wants their records to go. Every account is measured against it.
    @AppStorage("coverageSinceYear") private var sinceYear = 0

    /// Months in a row said as one stretch: "Mar to Jun 2021", so a long list stays readable.
    static func stretches(_ months: [Month]) -> String {
        var runs: [(Month, Month)] = []
        for m in months.sorted() {
            if let last = runs.last, last.1.adding(1) == m { runs[runs.count - 1].1 = m } else { runs.append((m, m)) }
        }
        return runs.map { a, b in
            a == b ? "\(a.shortName) \(a.year)" : a.year == b.year ? "\(a.shortName) to \(b.shortName) \(b.year)" : "\(a.shortName) \(a.year) to \(b.shortName) \(b.year)"
        }.joined(separator: ", ")
    }

    var body: some View {
        let rows = rows
        let all = store.months
        if let last = all.last, let earliest = all.first, all.count > 1 {
            // Until a goal is chosen: the first year with more than a stray month or two in it.
            let firstFull = Dictionary(grouping: all, by: \.year).filter { $0.value.count >= 3 }.keys.min() ?? earliest.year
            let since = sinceYear == 0 ? firstFull : min(sinceYear, last.year)
            let years = Array(since...last.year)
            let start = Month(year: since, month: 1)
            let missingCount = rows.reduce(0) { $0 + $1.missing.filter { $0 >= start }.count }
            let never = rows.filter(\.neverAdded)
            let reaching = rows.filter { !$0.neverAdded && ($0.have.min() ?? last) <= start }.count
            let real = rows.filter { !$0.neverAdded }.count
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        SectionHeader(title: "What's here, month by month",
                                      subtitle: "\(reaching) of \(real) accounts go back to January \(String(since))."
                                        + (missingCount == 0 && never.isEmpty ? " No month in between is missing." : " An orange square is a month with no statement."))
                        Spacer()
                        // The goal: how far back the records should reach.
                        Picker("Back to", selection: Binding(get: { since }, set: { sinceYear = $0 })) {
                            ForEach(Array((min(earliest.year, since) - 3)...last.year).reversed(), id: \.self) { Text("Back to \(String($0))").tag($0) }
                        }
                        .labelsHidden().fixedSize()
                        .help("How far back you want your statements to go")
                    }
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 9) {
                        GridRow {
                            Text("")
                            HStack(spacing: 5) {
                                ForEach(years, id: \.self) { year in
                                    Text(years.count > 12 ? "’" + String(format: "%02d", year % 100) : String(year))
                                        .font(Theme.mono(10, .medium)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                                }
                            }
                        }
                        ForEach(rows) { row in
                            GridRow(alignment: .center) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(row.name).font(.callout.weight(.medium)).lineLimit(1)
                                    status(row, start: start, last: last)
                                }
                                .frame(width: 200, alignment: .leading)
                                // A block of twelve for each year, so a whole decade reads at a glance.
                                HStack(spacing: 5) {
                                    ForEach(years, id: \.self) { year in
                                        HStack(spacing: 1.5) {
                                            ForEach(1...12, id: \.self) { cell(row, Month(year: year, month: $0), last: last) }
                                        }
                                        .frame(maxWidth: .infinity)
                                    }
                                }
                            }
                        }
                    }
                    HStack(spacing: 14) {
                        key(Theme.accent.opacity(0.85), "Statement here")
                        key(Theme.caution.opacity(0.9), "Missing")
                        key(Color.primary.opacity(0.07), "No charges that month")
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2).strokeBorder(Color.primary.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [2, 2])).frame(width: 10, height: 12)
                            Text("Before the first statement here")
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if missingCount > 0 || !never.isEmpty {
                        Divider()
                        HStack(alignment: .top, spacing: 16) {
                        SpotArt(name: "missing", height: 96)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("To download").font(.callout.weight(.semibold))
                            ForEach(rows.filter { !$0.missing.filter { $0 >= start }.isEmpty }) { row in
                                Label("\(row.name): \(Self.stretches(row.missing.filter { $0 >= start }))", systemImage: "arrow.down.doc")
                                    .font(.callout)
                                    .foregroundStyle(Theme.caution)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            ForEach(never) { row in
                                Label("\(row.name): you pay it from your bank account, but none of its statements are here, so what was bought on it is unknown.",
                                      systemImage: "creditcard.trianglebadge.exclamationmark")
                                    .font(.callout)
                                    .foregroundStyle(Theme.caution)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        }
                    }
                }
            }
        }
    }

    /// One line under the account's name: does it reach the goal, and is anything missing on the way?
    @ViewBuilder private func status(_ row: Row, start: Month, last: Month) -> some View {
        let missing = row.missing.filter { $0 >= start }.count
        if row.neverAdded {
            Text("No statements here").font(.caption).foregroundStyle(Theme.caution)
        } else if let first = row.have.min() {
            if missing > 0 {
                Text("\(missing) \(missing == 1 ? "month" : "months") missing").font(.caption).foregroundStyle(Theme.caution)
            } else if first <= start {
                Label("Complete since \(start.shortName) \(String(start.year))", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(Theme.good).labelStyle(.titleAndIcon)
            } else {
                Text("Starts \(first.shortName) \(String(first.year)), nothing earlier").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func key(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) { RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 12); Text(text) }
    }

    @ViewBuilder
    private func cell(_ row: Row, _ m: Month, last: Month) -> some View {
        let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
        Group {
            if m > last {
                Color.clear
            } else if row.neverAdded || row.missing.contains(m) {
                shape.fill(Theme.caution.opacity(0.9)).help("\(row.name): no statement for \(m.title)")
            } else if row.have.contains(m) {
                shape.fill(Theme.accent.opacity(0.85)).help("\(row.name): \(m.title) is here")
            } else if let first = row.have.min(), m < first {
                shape.strokeBorder(Color.primary.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .help("\(row.name): nothing before \(first.title). If the account was open in \(m.title), that statement isn't here.")
            } else {
                shape.fill(Color.primary.opacity(0.07)).help("\(row.name): no charges in \(m.title)")
            }
        }
        .frame(height: 20)
        .frame(maxWidth: .infinity)
    }
}

/// What the AI model cost, by job: where the money goes, so it can be steered.
struct SpendCard: View {
    @State private var spend = CloudSpend.shared
    @AppStorage("spendSpan") private var span = 1

    var body: some View {
        let lines = spend.lines(days: span)
        if !spend.days.isEmpty {
            let total = lines.reduce(0) { $0 + $1.tally.cost }
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        SectionHeader(title: "What the AI cost", subtitle: "Each request to the model, as OpenRouter priced it, added up by job.")
                        Spacer()
                        Picker("When", selection: $span) {
                            Text("Today").tag(1); Text("7 Days").tag(7); Text("30 Days").tag(30)
                        }
                        .pickerStyle(.segmented).labelsHidden().fixedSize()
                    }
                    if lines.isEmpty {
                        Text("Nothing was asked of the model in this stretch.").font(.callout).foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 7) {
                            ForEach(lines) { line in
                                ReceiptLine(value: Self.money(line.tally.cost)) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(line.job).font(.callout)
                                        Text("\(line.tally.requests) \(line.tally.requests == 1 ? "request" : "requests") · \(line.model.components(separatedBy: "/").last ?? line.model) · \((line.tally.input / 1000).formatted())k in, \((line.tally.output / 1000).formatted())k out")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            ReceiptRule()
                            ReceiptLine(value: Self.money(total), bold: true) { Text("TOTAL").font(Theme.mono(13, .bold)) }
                        }
                    }
                }
            }
        }
    }

    private static func money(_ cost: Double) -> String { cost < 1 ? String(format: "$%.3f", cost) : Money.format(cost) }
}
