import SwiftUI

/// Bills and subscriptions: what repeats, what it costs in a year, what crept up, what looks forgotten.
struct RecurringView: View {
    @Environment(BudgetStore.self) private var store
    /// Closed until asked for: what stopped is history, not a to-do.
    @State private var showsEnded = false

    private static let order: [RecurringEngine.Cadence] = [.monthly, .yearly, .quarterly, .weekly]

    private func monthYear(_ date: Date) -> String { date.formatted(.dateTime.month(.wide).year()) }
    private func dayMonth(_ date: Date) -> String { date.formatted(.dateTime.month(.abbreviated).day()) }

    /// What is worth a second look about one, in words.
    private func reasons(_ item: RecurringEngine.Recurring) -> [String] {
        var out: [String] = []
        if item.creep > 0 {
            out.append("up \(Money.format(item.creep)) since \(monthYear(item.first)), \(Money.format(item.extraPerYear, cents: false)) more a year")
        }
        if item.isForgotten {
            out.append("has charged you \(item.count) times since \(monthYear(item.first))")
        }
        return out
    }

    var body: some View {
        let all = store.recurring()
        let active = all.filter(\.isActive)
        let total = active.reduce(0) { $0 + $1.yearly }
        let latest = store.transactions.last?.date ?? .now
        let cutoff = Calendar.current.date(byAdding: .month, value: -18, to: latest) ?? latest
        let ended = all.filter { !$0.isActive && $0.last >= cutoff }
        let worth = active.filter { $0.creep > 0 || $0.isForgotten }
            .sorted { ($0.extraPerYear + ($0.isForgotten ? $0.yearly : 0)) > ($1.extraPerYear + ($1.isForgotten ? $1.yearly : 0)) }

        VStack(alignment: .leading, spacing: 20) {
            BigFigure(title: "Bills & subscriptions, a year", amount: total,
                      subtitle: "\(active.count) \(active.count == 1 ? "thing that repeats" : "things that repeat") · about \(Money.format(total / 12, cents: false)) a month")
            if active.isEmpty {
                EmptyState(title: "Nothing repeats yet", message: "A bill or subscription shows up here once it has been charged three times, or twice a year apart.", art: "welcome")
            }
            if !worth.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Worth a look", subtitle: "Prices that went up, and things you may have forgotten about")
                        ForEach(Array(worth.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider() }
                            row(item, detail: reasons(item).joined(separator: ". "), right: Money.format(item.yearly, cents: false), caption: "a year")
                        }
                    }
                }
            }
            ForEach(Self.order, id: \.self) { cadence in
                let group = active.filter { $0.cadence == cadence }
                if !group.isEmpty {
                    Card {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: cadence.title,
                                          subtitle: "\(group.count) \(group.count == 1 ? "payee" : "payees") · \(Money.format(group.reduce(0) { $0 + $1.yearly }, cents: false)) a year")
                            ForEach(Array(group.enumerated()), id: \.element.id) { index, item in
                                if index > 0 { Divider() }
                                row(item, detail: "\(Money.format(item.amount)) \(cadence.every)" + (item.next.map { " · next due \(dayMonth($0))" } ?? ""),
                                    right: Money.format(item.yearly, cents: false), caption: "a year")
                            }
                        }
                    }
                }
            }
            if !ended.isEmpty {
                Card {
                    DisclosureGroup(isExpanded: $showsEnded) {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(Array(ended.sorted { $0.last > $1.last }.enumerated()), id: \.element.id) { index, item in
                                if index > 0 { Divider() }
                                row(item, detail: "\(Money.format(item.amount)) \(item.cadence.every) · last charged \(dayMonth(item.last)) \(item.last.formatted(.dateTime.year()))",
                                    right: Money.format(item.yearly, cents: false), caption: "was a year")
                            }
                        }
                        .padding(.top, 12)
                    } label: {
                        SectionHeader(title: "Ended", subtitle: "\(ended.count) \(ended.count == 1 ? "has" : "have") stopped charging in the last 18 months")
                    }
                }
            }
        }
    }

    private func row(_ item: RecurringEngine.Recurring, detail: String, right: String, caption: String) -> some View {
        Button { store.showPlace(item.merchant) } label: {
            HStack(spacing: 12) {
                MerchantIcon(name: item.merchant, category: item.category, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.merchant).font(.body.weight(.medium)).lineLimit(1)
                    Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if item.creep > 0 { Sparkline(values: item.history.map(\.amount), color: Theme.caution).frame(width: 64, height: 24) }
                VStack(alignment: .trailing, spacing: 1) {
                    Text(right).font(.body.weight(.semibold)).monospacedDigit()
                    Text(caption).font(.caption).foregroundStyle(.secondary)
                }
                .frame(minWidth: 70, alignment: .trailing)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(item.merchant)")
    }
}
