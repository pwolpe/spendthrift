import SwiftUI
import AppKit

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

    var body: some View {
        let accounts = store.accounts.filter { $0.apart != nil }
        MaybeScroll(scrolls: scrolls) {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Kept Apart").font(.system(size: 30, weight: .bold, design: .serif))
                    Text("Accounts you look after that aren't part of your own money. Followed here in full; counted nowhere else.")
                        .font(.title3).foregroundStyle(.secondary)
                }
                if accounts.isEmpty {
                    TonySays(title: "Nothing is kept apart",
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

    @ViewBuilder private func section(_ account: Account, _ charges: [Transaction]) -> some View {
        let moneyIn = charges.filter { $0.amount < 0 }.reduce(0) { $0 - $1.amount }
        let out = charges.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount }
        let years = Dictionary(grouping: charges, by: \.month.year).sorted { $0.key > $1.key }
        let payees = Dictionary(grouping: charges, by: \.merchant).map { (name: $0.key, total: $0.value.reduce(0) { $0 + $1.amount }, category: $0.value[0].category) }
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(account.apart ?? "").font(.system(size: 22, weight: .bold, design: .serif))
                Text(account.name).font(.callout).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 18) {
                ReceiptPaper(padding: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("BY YEAR · IN, OUT AND WHAT WAS LEFT OVER").font(Theme.mono(10.5, .bold)).tracking(1.2).foregroundStyle(.secondary)
                        ReceiptRule()
                        ForEach(years, id: \.key) { year, list in
                            let i = list.filter { $0.amount < 0 }.reduce(0) { $0 - $1.amount }, o = list.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount }
                            ReceiptLine(value: (i - o < 0 ? "−" : "+") + Money.format(abs(i - o), cents: false), valueColor: i - o < 0 ? .primary : Theme.good) {
                                Text("\(String(year))  ·  in \(Money.format(i, cents: false)), out \(Money.format(o, cents: false))").font(.callout)
                            }
                        }
                        ReceiptRule()
                        ReceiptLine(value: Money.format(moneyIn, cents: false)) { Text("All money in") }
                        ReceiptLine(value: Money.format(out, cents: false)) { Text("All money out") }
                        ReceiptLine(value: (moneyIn - out < 0 ? "−" : "+") + Money.format(abs(moneyIn - out), cents: false), bold: true) {
                            Text("NET").font(Theme.mono(13, .bold))
                        }
                        Text("In less out over the statements on file. It is not the balance: the account held money before the first statement here.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: 460)
                Card(padding: 16) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("WHERE IT WENT AND CAME FROM").font(Theme.mono(10.5, .bold)).tracking(1.2).foregroundStyle(.secondary)
                        ForEach(payees.sorted { abs($0.total) > abs($1.total) }.prefix(10), id: \.name) { payee in
                            HStack(spacing: 8) {
                                Circle().fill(payee.category.color).frame(width: 8, height: 8)
                                Text(payee.name).font(.callout).lineLimit(1)
                                Spacer(minLength: 8)
                                Text((payee.total < 0 ? "+" : "") + Money.format(abs(payee.total), cents: false))
                                    .font(Theme.mono(12, .medium)).foregroundStyle(payee.total < 0 ? Theme.good : .primary)
                            }
                        }
                    }
                }
            }
            Card(padding: 8) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(charges.reversed().prefix(scrolls ? 400 : 10).enumerated()), id: \.element.id) { index, t in
                        if index > 0 { Divider().padding(.leading, 14) }
                        Button { store.showOriginal(of: t.id) } label: {
                            HStack(spacing: 10) {
                                Text(t.date.formatted(.dateTime.month(.abbreviated).day().year())).font(Theme.mono(11.5)).frame(width: 92, alignment: .leading)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(t.merchant).font(.callout.weight(.medium)).lineLimit(1)
                                    Text(t.description).font(Theme.mono(10.5)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 8)
                                Text(t.category.displayName).font(.caption).foregroundStyle(.secondary)
                                Text((t.amount < 0 ? "+" : "") + Money.format(abs(t.amount))).font(Theme.mono(12, .medium))
                                    .foregroundStyle(t.amount < 0 ? Theme.good : .primary).frame(minWidth: 90, alignment: .trailing)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Show this line in its original statement")
                    }
                }
            }
            if charges.count > 400 {
                Text("Showing the latest 400 of \(charges.count.formatted()) lines.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
