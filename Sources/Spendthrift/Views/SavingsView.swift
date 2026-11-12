import SwiftUI

extension BudgetStore {
    /// Ways to save that the person has not waved away, kept until the library changes.
    func savingsIdeas() -> [SavingsEngine.Idea] {
        let all: [SavingsEngine.Idea] = cached("savings") {
            SavingsEngine.ideas(in: transactions, recurring: recurring(), asOf: transactions.last?.date ?? .now, optional: isOptional)
        }
        return all.filter { !library.dismissedInsights.contains($0.id) }
    }

    func show(_ idea: SavingsEngine.Idea) {
        if let payee = idea.payee { showPlace(payee) }
        else { showCharges(TransactionFilter(ids: Set(idea.chargeIDs), title: idea.title)) }
    }

    func dismiss(_ idea: SavingsEngine.Idea) {
        withAnimation { _ = library.dismissedInsights.insert(idea.id) }
        changed()
    }
}

/// The ideas, each with what it would save in a year and a way to the charges behind it.
struct SavingsCard: View {
    @Environment(BudgetStore.self) private var store

    var body: some View {
        let ideas = store.savingsIdeas()
        if !ideas.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        SectionHeader(title: "Ways to save", subtitle: "Found by reading every charge. Worth about \(Money.format(ideas.reduce(0) { $0 + $1.yearly }, cents: false)) a year between them.")
                        Spacer()
                    }
                    ForEach(Array(ideas.enumerated()), id: \.element.id) { index, idea in
                        if index > 0 { Divider().padding(.leading, 40) }
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: idea.symbol).font(.title2).foregroundStyle(Theme.accent).frame(width: 28)
                            Button { store.show(idea) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(alignment: .firstTextBaseline) {
                                        Text(idea.title).font(.body.weight(.semibold)).multilineTextAlignment(.leading)
                                        Spacer(minLength: 8)
                                        Text("\(Money.format(idea.yearly, cents: false)) a year").font(.body.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.good)
                                    }
                                    Text(idea.detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu { Button("Not Interested", systemImage: "xmark.circle") { store.dismiss(idea) } }
                        }
                    }
                }
            }
        }
    }
}

/// One line for the Overview: how much there is to be had, and the way to it.
struct SavingsStrip: View {
    @Environment(BudgetStore.self) private var store

    var body: some View {
        let ideas = store.savingsIdeas()
        if !ideas.isEmpty {
            Button { store.stepInto(.spending) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "leaf.fill").font(.title3).foregroundStyle(Theme.good)
                    Text(ideas.count == 1 ? "One way to save about \(Money.format(ideas[0].yearly, cents: false)) a year"
                                          : "\(ideas.count) ways to save about \(Money.format(ideas.reduce(0) { $0 + $1.yearly }, cents: false)) a year")
                        .font(.callout.weight(.semibold))
                    Text(ideas.prefix(2).map(\.title).joined(separator: " · ")).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Theme.good.opacity(0.08), in: .rect(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
