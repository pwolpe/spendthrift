import SwiftUI

/// "Since you last looked": what arrived while the app was closed. Statements carry the moment
/// they were added, so this is simply every charge from a statement added after the app was last
/// quit, summed. Shown once per sitting, at the top of the Overview, and put away with a click.
extension BudgetStore {
    struct Since: Hashable {
        let when: Date
        let statements: Int
        let charges: [UUID]
        let spent: Double
        /// The largest few, to name.
        let biggest: [String]
    }

    /// When the app was last quit, as it was when this sitting began.
    static let lastSeenAtLaunch: Date? = UserDefaults.standard.object(forKey: "lastSeen") as? Date

    /// When this sitting began. Read once at launch (see the store's init): a statement added after this is the
    /// person's own doing in this sitting, not something that arrived while the app was closed.
    static let launchedAt = Date.now

    /// Called as the app quits.
    /// (Not in a test or snapshot run: those are not the person looking.)
    static func noteSeen() {
        let env = ProcessInfo.processInfo.environment
        guard env["SPENDTHRIFT_HOME"] == nil, env["SPENDTHRIFT_SNAPSHOT"] == nil, env["SPENDTHRIFT_TIMING"] == nil else { return }
        UserDefaults.standard.set(Date.now, forKey: "lastSeen")
    }

    /// What arrived after `when` and before `until` (this sitting's beginning, unless said otherwise). Nil when nothing did.
    func arrived(since when: Date, until: Date? = nil) -> Since? {
        let until = until ?? Self.launchedAt
        let sources = (library.sources ?? []).filter { $0.added > when && $0.added <= until }
        guard !sources.isEmpty else { return nil }
        let ids = Set(sources.map(\.id))
        let entryIDs = library.entries.filter { $0.sourceID.map(ids.contains) == true }.map(\.id)
        let charges = transactions(withIDs: entryIDs)
        guard !charges.isEmpty else { return nil }
        let spending = charges.filter { $0.countsAsSpending && $0.amount > 0 }
        var byPayee: [String: Double] = [:]
        for t in spending { byPayee[t.merchant, default: 0] += t.amount }
        return Since(when: when, statements: sources.count, charges: charges.map(\.id), spent: spending.reduce(0) { $0 + $1.amount },
                     biggest: byPayee.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(3).map(\.key))
    }

    var sinceLastLooked: Since? {
        guard !sinceDismissed, let when = Self.lastSeenAtLaunch else { return nil }
        return cached("since") { arrived(since: when) }
    }
}

struct SinceCard: View {
    @Environment(BudgetStore.self) private var store

    var body: some View {
        if let since = store.sinceLastLooked {
            HStack(spacing: 12) {
                Image(systemName: "tray.and.arrow.down.fill").font(.title3).foregroundStyle(Theme.accent)
                Button { store.showCharges(TransactionFilter(ids: Set(since.charges), title: "Since you last looked")) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Since you last looked, \(since.when.formatted(.relative(presentation: .named)))").font(.callout.weight(.semibold))
                        Text("\(since.statements == 1 ? "1 statement" : "\(since.statements) statements") arrived with \(since.charges.count == 1 ? "1 charge" : "\(since.charges.count) charges")"
                             + (since.spent < 0.5 ? ", none of it spending." : ": \(Money.format(since.spent, cents: false)) spent"
                                + (since.biggest.isEmpty ? "." : ", most of it at \(since.biggest.joined(separator: ", ")).")))
                            .font(.callout).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("See these charges")
                Spacer()
                Button { withAnimation(.snappy) { store.sinceDismissed = true } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
                    .help("Put this away").accessibilityLabel("Put this away")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(Theme.accent.opacity(0.07), in: .rect(cornerRadius: 12, style: .continuous))
        }
    }
}
