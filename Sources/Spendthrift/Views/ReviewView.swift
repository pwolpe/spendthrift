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
                // Any row still without a best guess gets one while the page is open.
                .task(id: store.reviewItems.count) { await store.guessWhatTheyWere() }
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
                // Only worth saying when the on-device model is what the app is relying on.
                if !CloudAI.isEnabled, let reason = CategorySuggester.unavailableReason, store.reviewItems.contains(where: { $0.info.category == nil }) {
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
            Vignette(name: "v-check", size: 80)
            VStack(alignment: .leading, spacing: 4) {
                Text("A few educated guesses")
                    .font(.system(size: 30, weight: .bold, design: .serif))
                Text("These are already counted in your totals. Confirm the ones that look right, or pick a better category. I'll remember.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if store.isSuggesting {
                    Label("Still sorting a few more…", systemImage: CloudAI.isEnabled ? "sparkles" : "apple.intelligence")
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

    private var hunch: String { item.info.hunch ?? "" }
    /// How many charges a row lists before "See all".
    private let shown = 3
    private var charges: [Transaction] { store.transactions.filter { $0.merchantKey == item.key }.sorted { $0.date > $1.date } }

    /// ", Mar 2024 to Oct 2026" when the charges span more than one month.
    private func span(_ charges: [Transaction]) -> String {
        guard let first = charges.last?.date, let last = charges.first?.date, Month(date: first) != Month(date: last) else { return "" }
        let f = Date.FormatStyle.dateTime.month(.abbreviated).year()
        return " · \(first.formatted(f)) to \(last.formatted(f))"
    }

    var body: some View {
        let busy = store.explaining.contains(item.key)
        let charges = charges
        Card(padding: 14) {
          VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                MerchantIcon(name: item.info.name, category: item.info.category ?? .unsorted, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.info.name).font(.headline)
                    Text("\(item.count) \(item.total < 0 ? (item.count == 1 ? "deposit" : "deposits") : (item.count == 1 ? "charge" : "charges")) · \(item.total < 0 ? "\(Money.format(-item.total)) in" : Money.format(item.total))\(span(charges))")
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
            // What it actually was: each charge with its day, the account it was on and the line as the
            // statement prints it. Click one to see it in the original statement.
            VStack(spacing: 0) {
                ForEach(Array(charges.prefix(shown).enumerated()), id: \.element.id) { index, t in
                    if index > 0 { Divider() }
                    Button { store.showOriginal(of: t.id) } label: {
                        HStack(spacing: 10) {
                            Text(t.date.formatted(.dateTime.month(.abbreviated).day().year()))
                                .font(Theme.mono(11.5))
                                .frame(width: 92, alignment: .leading)
                            Text(t.account).font(.callout).lineLimit(1)
                                .frame(width: 150, alignment: .leading)
                            Text(t.description)
                                .font(Theme.mono(11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 8)
                            Text(Money.format(abs(t.amount)))
                                .font(Theme.mono(12, .medium))
                                .foregroundStyle(t.amount < 0 ? Theme.good : .primary)
                            Image(systemName: "doc.text.magnifyingglass").foregroundStyle(Theme.accent)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show this charge in its original statement")
                }
                if charges.count > shown {
                    Divider()
                    Button("See all \(charges.count)") {
                        store.showCharges(TransactionFilter(merchantKey: item.key, title: item.info.name))
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 2)
            .overlay { RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.hairline) }
            // The fast way: say what it was, in your own words. No menu, no new-category sheet.
            HStack(spacing: 8) {
                Image(systemName: "text.bubble").foregroundStyle(.secondary)
                // The prompt is the app's own best guess at this one, when it has one.
                TextField(hunch.isEmpty ? "Tell me what this was, in your own words" : "My guess: \(hunch). Right? Or tell me what it was", text: $said)
                    .textFieldStyle(.plain)
                    .focused($typing)
                    .onSubmit(submit)
                    .disabled(busy)
                if busy {
                    ProgressView().controlSize(.small)
                } else if !said.isEmpty {
                    Button("File It", action: submit).buttonStyle(.bordered).controlSize(.small)
                } else if !hunch.isEmpty {
                    Button("Use My Guess") { said = hunch; typing = true }
                        .buttonStyle(.bordered).controlSize(.small)
                        .help("Puts the guess in the box so you can change it or file it")
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
