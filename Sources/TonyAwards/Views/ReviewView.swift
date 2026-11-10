import SwiftUI

/// Everything is sorted automatically. This screen is the optional glance over the guesses
/// Apple Intelligence made, biggest first: one click to agree, or pick something else.
struct ReviewView: View {
    @Environment(BudgetStore.self) private var store
    /// False when rendered for a test snapshot (ImageRenderer can't draw scroll views).
    var scrolls = true

    private var confirmable: [ReviewItem] { store.reviewItems.filter { $0.info.category != nil } }

    var body: some View {
        if scrolls {
            ScrollView { content }.navigationTitle("Double-Check")
        } else {
            content
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            if store.reviewItems.isEmpty {
                if store.isSuggesting {
                    TonySays(title: "Sorting…", message: "Apple Intelligence is working through the new places. This only takes a moment.")
                } else {
                    TonySays(title: "All caught up!", message: "Every place has a category. I'll flag new guesses here whenever you add a statement.") {
                        Button("Back to Overview") { store.selection = .overview }
                    }
                }
            } else {
                header
                if let reason = CategorySuggester.unavailableReason, store.reviewItems.contains(where: { $0.info.category == nil }) {
                    Label(reason, systemImage: "apple.intelligence")
                        .font(.callout)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.caution.opacity(0.12), in: .rect(cornerRadius: 12, style: .continuous))
                }
                LazyVStack(spacing: 10) {
                    ForEach(store.reviewItems) { item in
                        ReviewRow(item: item)
                            .transition(.asymmetric(insertion: .opacity, removal: .move(edge: .trailing).combined(with: .opacity)))
                    }
                }
            }
        }
        .padding(28)
        .frame(maxWidth: 860)
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            TonyAvatar(size: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text("A few educated guesses")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text("These are already counted in your totals. Confirm the ones that look right, or pick a better category. I'll remember.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if store.isSuggesting {
                    Label("Still sorting a few more…", systemImage: "apple.intelligence")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .symbolEffect(.pulse)
                }
            }
            Spacer()
            if confirmable.count > 1 {
                Button {
                    store.confirm(confirmable.map(\.key))
                } label: {
                    Label("All \(confirmable.count) Look Right", systemImage: "checkmark")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }
}

private struct ReviewRow: View {
    @Environment(BudgetStore.self) private var store
    let item: ReviewItem

    var body: some View {
        Card(padding: 14) {
            HStack(spacing: 14) {
                MerchantIcon(name: item.info.name, category: item.info.category ?? .unsorted, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.info.name).font(.headline)
                    Text(item.info.sample)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("\(item.count == 1 ? "1 charge" : "\(item.count) charges") · \(item.total < 0 ? "\(Money.format(-item.total)) in" : Money.format(item.total))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                CategoryPill(category: item.info.category) { store.setCategory($0, forPlace: item.key) }
                Button {
                    store.confirm([item.key])
                } label: {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 22, height: 18)
                }
                .buttonStyle(.borderedProminent)
                .disabled(item.info.category == nil)
                .help("Looks right")
            }
        }
    }
}
