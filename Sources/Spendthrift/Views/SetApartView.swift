import SwiftUI
import AppKit
import Charts

/// Money that passes through the person's hands without being theirs: a parent's account they look
/// after, an estate, a trust. Each such account is followed here in full (what came in, what went
/// out, what is left to move) and counted nowhere else in the app.
struct SetApartView: View {
    @Environment(BudgetStore.self) private var store
    /// False when rendered for a test snapshot.
    var scrolls = true

    /// Asks what to call an account being set apart. Nil if cancelled.
    static func askName(for account: String) -> String? {
        let alert = NSAlert()
        alert.messageText = "Keep “\(account)” apart from your totals?"
        alert.informativeText = "Its statements stay on file and it gets its own page, but nothing in it counts as your spending, income or investing. Give it a name, like “Mom”."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Mom"
        alert.accessoryView = field
        alert.addButton(withTitle: "Keep Apart")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Kept Apart" : name
    }

    /// The year or the payee the lines below are narrowed to, for each account.
    @State private var year: [UUID: Int] = [:]
    @State private var payee: [UUID: String] = [:]
    @State private var pointedYear: Int?

    var body: some View {
        let accounts = store.accounts.filter { $0.apart != nil }
        MaybeScroll(scrolls: scrolls) {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Kept Apart").font(.system(size: 30, weight: .bold, design: .serif))
                    Text("Accounts you look after that aren't part of your own money. Followed here in full; counted nowhere else.")
                        .font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if accounts.isEmpty {
                    EmptyState(title: "Nothing is kept apart",
                             message: "To set an account aside (a parent's account, a trust), open Setup, click the ••• on the account and choose Keep Apart from My Totals.",
                             art: "nothing")
                }
                ForEach(accounts) { account in
                    section(account, store.setApart.filter { $0.accountID == account.id })
                }
            }
            .padding(28)
            .frame(maxWidth: 980, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Kept Apart")
    }

    private struct YearLine: Identifiable {
        var id: Int { year }
        let year: Int
        var moneyIn = 0.0, out = 0.0
    }

    private struct PayeeLineItem: Identifiable {
        var id: String { name }
        let name: String
        let category: Category
        let total: Double
        let count: Int
    }

    /// What the account has been doing lately, in a sentence built from its own lines.
    private func lately(_ charges: [Transaction]) -> String {
        guard let last = charges.last?.date, let first = charges.first?.date else { return "" }
        let money = { (v: Double) in Money.format(v, cents: false) }
        let cutoff = last.addingTimeInterval(-365 * 86_400)
        let recent = charges.filter { $0.date > cutoff }
        let i = recent.filter { $0.amount < 0 }.reduce(0) { $0 - $1.amount }, o = recent.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount }
        let span = "On file from \(first.formatted(.dateTime.month(.wide).year())) to \(last.formatted(.dateTime.month(.wide).year()))."
        if recent.count <= 24, i + o < 10_000 {
            return span + " Quiet in its last twelve months: \(money(i)) came in and \(money(o)) went out, across \(recent.count) \(recent.count == 1 ? "line" : "lines")."
        }
        return span + " In its last twelve months \(money(i)) came in and \(money(o)) went out."
    }

    @ViewBuilder private func section(_ account: Account, _ charges: [Transaction]) -> some View {
        let moneyIn = charges.filter { $0.amount < 0 }.reduce(0) { $0 - $1.amount }
        let out = charges.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount }
        let years: [YearLine] = Dictionary(grouping: charges, by: \.month.year).map { year, list in
            YearLine(year: year, moneyIn: list.filter { $0.amount < 0 }.reduce(0) { $0 - $1.amount }, out: list.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount })
        }.sorted { $0.year < $1.year }
        let payees = Dictionary(grouping: charges, by: \.merchant).map { PayeeLineItem(name: $0.key, category: $0.value[0].category, total: $0.value.reduce(0) { $0 + $1.amount }, count: $0.value.count) }
        let sources = payees.filter { $0.total < 0 }.sorted { $0.total < $1.total }
        let sinks = payees.filter { $0.total > 0 }.sorted { $0.total > $1.total }
        let onlyYear = year[account.id], onlyPayee = payee[account.id]
        let shown = charges.filter { (onlyYear == nil || $0.month.year == onlyYear) && (onlyPayee == nil || $0.merchant == onlyPayee) }

        VStack(alignment: .leading, spacing: 18) {
            // Who it is, and the three figures that sum it up.
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(account.apart ?? "").font(.system(size: 26, weight: .bold, design: .serif))
                    Text(account.name).font(.callout).foregroundStyle(.secondary)
                }
                Text(lately(charges)).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Card {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 36) {
                        figure("Came in", moneyIn, Theme.good)
                        figure("Went out", out, .primary)
                        figure(moneyIn >= out ? "More came in, by" : "More went out, by", abs(moneyIn - out), .primary)
                        Spacer(minLength: 0)
                    }
                    if years.count > 1 {
                        // Each year, what came in beside what went out. Click a year to see only its lines.
                        Chart {
                            ForEach(years) { line in
                                BarMark(x: .value("Year", String(line.year)), y: .value("Amount", line.moneyIn), width: .ratio(0.85))
                                    .position(by: .value("Which", "In")).foregroundStyle(Theme.good.gradient).cornerRadius(3)
                                    .opacity(onlyYear == nil || onlyYear == line.year ? 1 : 0.35)
                                BarMark(x: .value("Year", String(line.year)), y: .value("Amount", line.out), width: .ratio(0.85))
                                    .position(by: .value("Which", "Out")).foregroundStyle(Theme.inkFill.gradient).cornerRadius(3)
                                    .opacity(onlyYear == nil || onlyYear == line.year ? 1 : 0.35)
                            }
                        }
                        .chartLegend(.hidden)
                        .chartYAxis { AxisMarks(position: .leading) { value in
                            AxisGridLine().foregroundStyle(Theme.hairline)
                            AxisValueLabel { if let v = value.as(Double.self) { Text(Money.format(v, cents: false)) } }
                        } }
                        .chartOverlay { proxy in
                            GeometryReader { geo in
                                Rectangle().fill(.clear).contentShape(Rectangle())
                                    .onTapGesture { point in
                                        guard let plot = proxy.plotFrame, let label: String = proxy.value(atX: point.x - geo[plot].origin.x), let hit = Int(label) else { return }
                                        withAnimation(.snappy(duration: 0.2)) { year[account.id] = onlyYear == hit ? nil : hit }
                                    }
                            }
                        }
                        .frame(height: 170)
                        .help("Click a year to see only its lines")
                        HStack(spacing: 16) {
                            legend("Came in", Theme.good)
                            legend("Went out", Theme.inkFill)
                            Spacer()
                            Text("In less out over the statements on file. It is not the balance: the account held money before the first statement here.")
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            // Where the money came from, and where it went: two lists, not one mixed together.
            HStack(alignment: .top, spacing: 18) {
                if !sources.isEmpty { ledger("Where it came from", sources, sign: "+", color: Theme.good, account: account.id) }
                if !sinks.isEmpty { ledger("Where it went", sinks, sign: "", color: .primary, account: account.id) }
            }
            StatementStrip(account: account.id, fallbackEnd: charges.last?.date ?? .now)
            // Every line, or the ones a year or a payee was clicked for.
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Text(onlyYear == nil && onlyPayee == nil ? "Every line" : [onlyPayee, onlyYear.map(String.init)].compactMap { $0 }.joined(separator: ", "))
                        .font(.title3.weight(.semibold))
                    Text("\(shown.count.formatted()) \(shown.count == 1 ? "line" : "lines")").font(.callout).foregroundStyle(.secondary)
                    if onlyYear != nil || onlyPayee != nil {
                        Button("Show Every Line", systemImage: "xmark.circle.fill") { withAnimation(.snappy(duration: 0.2)) { year[account.id] = nil; payee[account.id] = nil } }
                            .buttonStyle(.borderless).font(.callout)
                    }
                    Spacer()
                }
                Card(padding: 8) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(shown.reversed().prefix(scrolls ? 400 : 8).enumerated()), id: \.element.id) { index, t in
                            if index > 0 { Divider().padding(.leading, 56) }
                            Button { store.showOriginal(of: t.id) } label: {
                                HStack(spacing: 12) {
                                    MerchantIcon(name: t.merchant, category: t.category, size: 32)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(t.merchant).font(.callout.weight(.medium)).lineLimit(1)
                                        Text("\(t.date.formatted(.dateTime.month(.abbreviated).day().year())) · \(t.category.displayName)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    Text((t.amount < 0 ? "+" : "") + Money.format(abs(t.amount))).font(Theme.mono(13, .medium))
                                        .foregroundStyle(t.amount < 0 ? Theme.good : .primary)
                                    Image(systemName: "doc.text.magnifyingglass").font(.caption).foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Show this line in its original statement: \(t.description)")
                        }
                    }
                }
                if shown.count > 400 {
                    Text("Showing the latest 400 of \(shown.count.formatted()) lines. Click a year or a payee above to reach the rest.").font(.callout).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func figure(_ title: String, _ amount: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(Money.format(amount, cents: false)).font(.system(size: 26, weight: .bold, design: .rounded)).monospacedDigit().foregroundStyle(color)
        }
    }

    private func legend(_ title: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// One side of the account: who paid in, or who was paid. Click a name to see only its lines below.
    private func ledger(_ title: String, _ list: [PayeeLineItem], sign: String, color: Color, account: UUID) -> some View {
        Card(padding: 16) {
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(title: title).padding(.bottom, 6)
                ForEach(Array(list.prefix(7).enumerated()), id: \.element.id) { index, item in
                    PayeeLine(name: item.name, category: item.category, detail: item.count == 1 ? "once" : "\(item.count) times",
                              amount: abs(item.total), iconSize: 30, amountText: sign + Money.format(abs(item.total), cents: false),
                              amountColor: color, help: "See only \(item.name)'s lines below") {
                        withAnimation(.snappy(duration: 0.2)) { payee[account] = payee[account] == item.name ? nil : item.name }
                    }
                    .opacity(payee[account] == nil || payee[account] == item.name ? 1 : 0.45)
                }
                if list.count > 7 {
                    Text("and \(list.count - 7) more").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
