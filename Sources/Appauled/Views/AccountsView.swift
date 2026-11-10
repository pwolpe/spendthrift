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
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.gold))
                    TextField("Account name", text: $name)
                        .textFieldStyle(.plain)
                        .font(.title3.weight(.semibold))
                        .onSubmit { store.renameAccount(account.id, to: name) }
                        .help("Click to rename")
                    Menu {
                        Button("Show Transactions", systemImage: "list.bullet") {
                            store.showCharges(TransactionFilter(accountID: account.id))
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
            Text("Its transactions will be removed from Appauled. What you taught me about each place is kept.")
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
        let byAccount = Dictionary(grouping: store.transactions, by: \.accountID)
        var rows = store.accounts.map { account -> Row in
            let have = Set((byAccount[account.id] ?? []).map(\.month)).union((account.statementMonths ?? []).compactMap { Month(key: $0) })
            var missing = Set(store.missingStatements.first { $0.accountID == account.id }?.months ?? [])
            // A card whose payments from the bank aren't all explained: the empty months in the
            // middle of what's here are where the unexplained spending is.
            if let card = store.cardCoverage.first(where: { $0.accounts.contains(account.name) }), card.uncoveredPayments > 0,
               let first = have.min(), let last = have.max() {
                var m = first.adding(1)
                while m < last { if !have.contains(m) { missing.insert(m) }; m = m.adding(1) }
            }
            return Row(id: account.id.uuidString, name: account.name, have: have, missing: missing)
        }
        // A card that is paid from a bank account here, but whose own statements were never added.
        for card in store.cardCoverage where card.accounts.isEmpty && card.uncoveredPayments > 0 {
            rows.append(Row(id: "card:" + card.issuer, name: "\(card.issuer) card", have: [], missing: [], neverAdded: true))
        }
        return rows
    }

    var body: some View {
        let rows = rows
        let all = store.months
        if let last = all.last, all.count > 1 {
            let first = max(all.first!, last.adding(-23))
            let months = sequence(first: first) { $0 < last ? $0.adding(1) : nil }.map { $0 }
            let missingCount = rows.reduce(0) { $0 + $1.missing.count }
            let never = rows.filter(\.neverAdded)
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(alignment: .firstTextBaseline) {
                        SectionHeader(title: "What's here, month by month",
                                      subtitle: missingCount == 0 && never.isEmpty ? "Every account has every month. Nothing is missing."
                                        : "An orange square is a month with no statement. Download it from the bank and drop it in.")
                        Spacer()
                        if missingCount == 0 && never.isEmpty {
                            Label("Complete", systemImage: "checkmark.seal.fill").foregroundStyle(.green).font(.callout.weight(.semibold))
                        }
                    }
                    Grid(alignment: .leading, horizontalSpacing: 3, verticalSpacing: 6) {
                        GridRow {
                            Text("").gridColumnAlignment(.leading)
                            ForEach(months) { m in
                                Text(m.month == 1 || m == months.first ? "\(String(m.shortName.prefix(1)))\n’\(String(format: "%02d", m.year % 100))" : String(m.shortName.prefix(1)))
                                    .font(.system(size: 9, weight: .medium))
                                    .multilineTextAlignment(.center)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        ForEach(rows) { row in
                            GridRow {
                                Text(row.name)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                    .frame(width: 190, alignment: .leading)
                                ForEach(months) { m in
                                    cell(row, m)
                                }
                            }
                        }
                    }
                    if missingCount > 0 || !never.isEmpty {
                        Divider()
                        HStack(alignment: .top, spacing: 16) {
                        SpotArt(name: "missing", height: 96)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("To download").font(.callout.weight(.semibold))
                            ForEach(rows.filter { !$0.missing.isEmpty }) { row in
                                Label("\(row.name): \(row.missing.sorted().map(\.title).joined(separator: ", "))", systemImage: "arrow.down.doc")
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

    @ViewBuilder
    private func cell(_ row: Row, _ m: Month) -> some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        Group {
            if row.neverAdded || row.missing.contains(m) {
                shape.fill(Theme.caution.opacity(0.25)).overlay(shape.strokeBorder(Theme.caution, lineWidth: 1.5))
                    .help("\(row.name): no statement for \(m.title)")
            } else if row.have.contains(m) {
                shape.fill(Theme.accent.opacity(0.85)).help("\(row.name): \(m.title) is here")
            } else {
                shape.fill(Color.primary.opacity(0.06))
            }
        }
        .frame(height: 18)
        .frame(maxWidth: .infinity)
    }
}
