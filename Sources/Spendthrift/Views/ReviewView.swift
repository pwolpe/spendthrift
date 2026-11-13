import SwiftUI

/// Everything is sorted automatically. This screen is the optional glance over the guesses
/// the model made, biggest first: one click to agree, or pick something else.
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
                    EmptyState(title: "Sorting…", message: "We're working through the new payees. This only takes a moment.", art: "sorting")
                } else {
                    EmptyState(title: "All caught up", message: "Every payee has a category. New guesses show up here whenever you add a statement.", art: "caughtup") {
                        Button("Back to Overview") { store.go(to: .overview) }
                    }
                }
            } else {
                header
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
                    Label("Still sorting a few more…", systemImage: "sparkles")
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
    @State private var name = ""
    /// The one charge being given its own payee, if any.
    @State private var separating: Transaction.ID?
    @State private var failed = false
    @State private var filed = false
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
    private var charges: [Transaction] { store.charges(withKey: item.key) }

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
                    EditableName(text: $name, font: .headline, help: "Rename this payee",
                                 commit: { store.renamePlace(item.key, to: name) }, cancel: { name = item.info.name })
                        .onAppear { name = item.info.name }
                        .onChange(of: item.info.name) { name = item.info.name }
                    Text("\(item.count) \(item.total < 0 ? (item.count == 1 ? "deposit" : "deposits") : (item.count == 1 ? "charge" : "charges")) · \(item.total < 0 ? "\(Money.format(-item.total)) in" : Money.format(item.total))\(span(charges))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                CategoryPill(category: item.info.category) { store.setCategory($0, forPlace: item.key) }
                Button {
                    // The stamp lands, then the row leaves. Other rows stay live the whole time.
                    filed = true
                    let key = item.key
                    Task { try? await Task.sleep(for: .milliseconds(380)); store.confirm([key]) }
                } label: {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .frame(width: 22, height: 18)
                }
                .buttonStyle(.borderedProminent)
                .disabled(item.info.category == nil || filed)
                .help("Looks right")
            }
            .overlay(alignment: .center) { if filed { Stamp(text: "FILED", color: Theme.accent, size: 20, angle: -6) } }
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
                    // A group can hold different things (every wire reads alike): any one line can be named by itself.
                    .overlay(alignment: .trailing) {
                        if charges.count > 1 {
                            Button { separating = t.id } label: { Image(systemName: "pencil.line") }
                                .buttonStyle(.borderless)
                                .help("This one is something else: name just this line")
                                .accessibilityLabel("Name just this line")
                                .padding(.trailing, 26)
                                .popover(isPresented: Binding(get: { separating == t.id }, set: { if !$0 { separating = nil } }), arrowEdge: .bottom) {
                                    PayeeEditor(charges: [t]) { separating = nil }
                                }
                        }
                    }
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
                                       : "I saved your note. The AI can't be reached, so choose the category from the menu above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
          }
        }
    }
}

/// Says that some charges are a different payee from the one they were gathered under: one charge,
/// or every charge written one way on statements.
struct PayeeEditor: View {
    @Environment(BudgetStore.self) private var store
    let charges: [Transaction]
    /// Set when the charges are everything written this way: the choice then holds for future statements too.
    var spelling: String?
    var done: () -> Void = {}
    @State private var name = ""
    @State private var category: Category?
    @FocusState private var typing: Bool

    private func file() {
        if let spelling, let payee = charges.first?.merchant {
            store.separate(spelling: spelling, from: payee, as: name, category: category)
        } else if let one = charges.first {
            store.setPayee(of: one.id, name: name, category: category)
        }
        done()
    }

    var body: some View {
        let total = charges.reduce(0) { $0 + abs($1.amount) }
        VStack(alignment: .leading, spacing: 12) {
            Text(spelling == nil ? "Just this one" : "A different payee").font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                if let spelling {
                    Text("\(charges.count == 1 ? "1 charge" : "\(charges.count) charges") · \(Money.format(total))").font(Theme.mono(12, .medium))
                    Text(spelling).font(Theme.mono(11)).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                } else if let one = charges.first {
                    Text("\(one.date.formatted(.dateTime.month(.abbreviated).day().year())) · \(Money.format(total))").font(Theme.mono(12, .medium))
                    Text(one.description).font(Theme.mono(11)).foregroundStyle(.secondary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
            }
            TextField("Who was it paid to?", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($typing)
                .onSubmit { if !name.trimmingCharacters(in: .whitespaces).isEmpty { file() } }
            HStack {
                CategoryPill(category: category) { category = $0 }
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button(spelling == nil ? "File Just This One" : "Separate", action: file)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text(spelling == nil ? "The other lines in the group stay as they are."
                                 : "Everything else stays where it is. Lines written this way go to the new payee from now on.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 380)
        .onAppear {
            // For a whole spelling, the statement's own words are the best first guess at the name.
            if spelling != nil, let sample = charges.first?.description { name = KeywordExtractor.displayName(for: sample) }
            typing = true
        }
    }
}
