import SwiftUI

struct AccountsView: View {
    @Environment(BudgetStore.self) private var store

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Accounts")
                            .font(.system(size: 28, weight: .bold, design: .rounded))
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
                            store.transactionFilter = TransactionFilter(accountID: account.id)
                            store.selection = .transactions
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
            }
        }
        .onAppear { name = account.name }
        .onChange(of: account.name) { name = account.name }
        .confirmationDialog("Remove \(account.name)?", isPresented: $confirmRemove) {
            Button("Remove Account", role: .destructive) { store.removeAccount(account.id) }
        } message: {
            Text("Its transactions will be removed from The Tony Awards. What you taught me about each place is kept.")
        }
        .confirmationDialog("Swap purchases and payments for \(account.name)?", isPresented: $confirmFlip) {
            Button("Swap Them") { store.flipAmounts(account.id) }
        } message: {
            Text("Use this if purchases show up in green as money coming in. It fixes this account now and for future statements.")
        }
    }
}
