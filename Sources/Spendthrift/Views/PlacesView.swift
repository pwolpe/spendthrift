import SwiftUI

/// Every payee money went to, with a box to find one by name: "barrys", "pastis".
/// Click a payee for everything ever spent there.
struct PlacesView: View {
    @Environment(BudgetStore.self) private var store
    /// False when rendered for a test snapshot.
    var scrolls = true

    enum Span: String, CaseIterable, Identifiable {
        case all = "All Time", year = "This Year", last12 = "Last 12 Months"
        var id: String { rawValue }
    }

    struct Place: Identifiable {
        var id: String { name }
        let name: String
        let category: Category
        var total = 0.0
        var visits = 0
        var last = Date.distantPast
        var first = Date.distantFuture
        /// The name and every way statements spell it, squeezed to letters and digits for matching.
        var haystack = ""
    }

    /// Letters and digits only, so "barrys" finds "Barry's" and "wholefoods" finds "Whole Foods".
    static func squeeze(_ text: String) -> String {
        String(text.lowercased().folding(options: .diacriticInsensitive, locale: nil).filter { $0.isLetter || $0.isNumber })
    }

    private func places() -> [Place] {
        let latest = store.months.last ?? Month(date: .now)
        let from: Month? = switch store.placeSpan {
        case .all: nil
        case .year: Month(year: latest.year, month: 1)
        case .last12: latest.adding(-11)
        }
        var byName: [String: Place] = [:]
        var spellings: [String: Set<String>] = [:]
        for t in store.transactions where !t.isTransfer {
            if let from, t.month < from { continue }
            var place = byName[t.merchant] ?? Place(name: t.merchant, category: t.category)
            place.total += t.amount
            place.visits += 1
            place.last = max(place.last, t.date)
            place.first = min(place.first, t.date)
            byName[t.merchant] = place
            spellings[t.merchant, default: []].insert(t.description)
        }
        let query = Self.squeeze(store.placeSearch)
        var list = byName.values.map { place -> Place in
            var p = place
            p.haystack = Self.squeeze(place.name) + " " + (spellings[place.name] ?? []).map(Self.squeeze).joined(separator: " ")
            return p
        }
        if !query.isEmpty { list = list.filter { $0.haystack.contains(query) } }
        // A name that starts with what was typed comes first; then the most money.
        return list.sorted { a, b in
            if !query.isEmpty {
                let (pa, pb) = (Self.squeeze(a.name).hasPrefix(query), Self.squeeze(b.name).hasPrefix(query))
                if pa != pb { return pa }
            }
            return abs(a.total) > abs(b.total)
        }
    }

    private static func when(_ place: Place) -> String {
        let f = Date.FormatStyle.dateTime.month(.abbreviated).year()
        let (a, b) = (place.first.formatted(f), place.last.formatted(f))
        return a == b ? "last in \(b)" : "\(a) to \(b)"
    }

    private func rows(_ places: ArraySlice<Place>) -> some View {
        Card(padding: 8) {
            LazyVStack(spacing: 0) {
                ForEach(Array(places.enumerated()), id: \.element.id) { index, p in
                    if index > 0 { Divider().padding(.leading, 56) }
                    PayeeLine(name: p.name, category: p.category,
                              detail: "\(p.category.displayName) · \(p.visits == 1 ? "once" : "\(p.visits) times") · \(Self.when(p))",
                              amount: abs(p.total), iconSize: 36,
                              amountFont: Theme.mono(14, .semibold), amountColor: p.total < 0 ? Theme.good : .primary,
                              help: "Open \(p.name): every charge, by month") { store.showPlace(p.name) }
                }
            }
        }
    }

    var body: some View {
        @Bindable var store = store
        let list = places()
        let finding = !store.placeSearch.trimmingCharacters(in: .whitespaces).isEmpty
        let query = Self.squeeze(store.placeSearch)
        MaybeScroll(scrolls: scrolls) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Payees").font(.system(size: 30, weight: .bold, design: .serif))
                    Text("Everyone and everything you paid. Type a name to see what you spent.")
                        .font(.title3).foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    SearchField(prompt: "Find a payee: Pastis, Barry's, Amazon…", text: $store.placeSearch, autofocus: true) {
                        if let first = list.first { store.showPlace(first.name) }
                    }
                    Picker("When", selection: $store.placeSpan) {
                        ForEach(Span.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                }

                if !finding { TidyCard() }
                if list.isEmpty {
                    EmptyState(title: "No payee by that name",
                             message: "Nothing matches “\(store.placeSearch)”\(store.placeSpan == .all ? "" : " in \(store.placeSpan.rawValue.lowercased())"). Try part of the name, or how it's spelled on your statement.",
                             art: "nothing")
                } else {
                    // A name that matches is the answer. A payee found only by how a statement spells it
                    // ("amzn.com/bill" for "bill") is listed after, and kept out of the sum.
                    let named = finding ? list.filter { Self.squeeze($0.name).contains(query) } : list
                    let spelled = finding ? list.filter { !Self.squeeze($0.name).contains(query) } : []
                    let counted = named.isEmpty ? spelled : named
                    if finding {
                        let visits = counted.reduce(0) { $0 + $1.visits }
                        HStack(alignment: .firstTextBaseline) {
                            Text("\(counted.count == 1 ? "1 payee" : "\(counted.count) payees") · \(visits == 1 ? "1 charge" : "\(visits) charges")")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(Money.format(abs(counted.reduce(0) { $0 + $1.total }))).font(Theme.mono(15, .bold))
                        }
                        .font(.callout)
                        .padding(.horizontal, 14)
                    }
                    rows(counted.prefix(300))
                    if !named.isEmpty, !spelled.isEmpty {
                        Text("Also found in how statements spell these").font(.callout).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.top, 6)
                        rows(spelled.prefix(100))
                    }
                    if list.count > 300, !finding {
                        Text("Showing the 300 biggest of \(list.count) payees. Type a name to find any of the rest.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Payees")
        .navigationSubtitle(list.count == 1 ? "1 payee" : "\(list.count) payees")
    }
}
