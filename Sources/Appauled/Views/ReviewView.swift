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
                    TonySays(title: "Sorting…", message: "We're working through the new places. This only takes a moment.", art: "sorting")
                } else {
                    TonySays(title: "All caught up", message: "Every place has a category. New guesses show up here whenever you add a statement.", art: "caughtup") {
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
                    .font(.system(size: 30, weight: .bold, design: .serif))
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
    @State private var said = ""
    @State private var failed = false
    @FocusState private var typing: Bool

    private func submit() {
        let text = said
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        failed = false
        Task {
            // When it works, this row leaves the list by itself.
            if await store.explain(item.key, said: text) == false { failed = true }
        }
    }

    var body: some View {
        let busy = store.explaining.contains(item.key)
        Card(padding: 14) {
          VStack(alignment: .leading, spacing: 10) {
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
            // The fast way: say what it was, in your own words. No menu, no new-category sheet.
            HStack(spacing: 8) {
                Image(systemName: "text.bubble").foregroundStyle(.secondary)
                TextField("Or just tell me what this was: “my accountant, for tax prep”", text: $said)
                    .textFieldStyle(.plain)
                    .focused($typing)
                    .onSubmit(submit)
                    .disabled(busy)
                if busy {
                    ProgressView().controlSize(.small)
                } else if !said.isEmpty {
                    Button("File It", action: submit).buttonStyle(.bordered).controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 9, style: .continuous))
            if failed {
                Text(CloudAI.isEnabled ? "I couldn't work that out. I saved your note; choose a category from the menu above."
                                       : "I saved your note. Without Smarter AI, choose the category from the menu above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
          }
        }
    }
}
