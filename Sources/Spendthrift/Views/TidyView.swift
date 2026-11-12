import SwiftUI

/// What the app tidied by itself, with a way to put each thing back, and the few pairs it was not
/// sure enough about to act on. Shown at the top of the Payees page; quiet when there is nothing to say.
struct TidyCard: View {
    @Environment(BudgetStore.self) private var store
    @State private var showsAll = false

    var body: some View {
        let _ = store.readsChecked
        let changes = store.tidyChanges, allOffers = store.library.tidy?.suggestions ?? [], offers = Array(allOffers.prefix(6))
        if !changes.isEmpty || !offers.isEmpty {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        Label("Tidied for you", systemImage: "wand.and.stars").font(.headline)
                        Spacer()
                        if store.isTidying { ProgressView().controlSize(.small) }
                        if !changes.isEmpty {
                            Button(changes.count == 1 ? "Looks Good" : "All Look Good", systemImage: "checkmark") { withAnimation(.snappy) { store.keep() } }
                                .help("Keep all of these and clear the list")
                        }
                    }
                    if !changes.isEmpty {
                        Text("The same business written two ways was combined; two businesses gathered under one name were separated. Keep what is right, put back what is not; anything left here clears itself after a month.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        ForEach(changes.prefix(showsAll ? 200 : 5)) { change in
                            HStack(spacing: 10) {
                                Image(systemName: change.kind == .combine ? "arrow.triangle.merge" : "arrow.triangle.branch")
                                    .foregroundStyle(Theme.accent).frame(width: 22)
                                Button { store.showPlace(change.otherKey.flatMap { store.place($0)?.name } ?? change.from) } label: {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(store.sentence(for: change)).font(.body.weight(.medium)).lineLimit(1)
                                        Text(change.charges == 1 ? "1 charge" : "\(change.charges) charges").font(.caption).foregroundStyle(.secondary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Open the payee")
                                Spacer()
                                Button { withAnimation(.snappy) { store.keep(change) } } label: { Image(systemName: "checkmark") }
                                    .buttonStyle(.borderless)
                                    .help("This is right: keep it and take it off the list")
                                    .accessibilityLabel("Keep")
                                Button("Undo") { store.undo(change) }
                                    .buttonStyle(.borderless)
                                    .help("Put this back as it was. It won't be done again.")
                            }
                        }
                        if changes.count > 5 {
                            Button(showsAll ? "Show Fewer" : "Show All \(changes.count)") { withAnimation(.snappy) { showsAll.toggle() } }
                                .buttonStyle(.borderless).font(.callout)
                        }
                    }
                    if !offers.isEmpty {
                        if !changes.isEmpty { Divider() }
                        Text("Might be the same").font(.callout.weight(.semibold))
                        ForEach(offers) { offer in
                            HStack(spacing: 10) {
                                Image(systemName: "questionmark.circle").foregroundStyle(.secondary).frame(width: 22)
                                Text("\(offer.a)  and  \(offer.b)").lineLimit(1)
                                Spacer()
                                Button("Combine") { store.accept(offer) }.buttonStyle(.borderless)
                                Button("Not the Same") { store.decline(offer) }.buttonStyle(.borderless).foregroundStyle(.secondary)
                            }
                        }
                        if allOffers.count > offers.count {
                            Text("and \(allOffers.count - offers.count) more, once these are settled").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .onDisappear { store.markTidySeen() }
        }
    }
}

/// One line on the Overview when something was tidied since it was last looked at.
struct TidyNotice: View {
    @Environment(BudgetStore.self) private var store

    var body: some View {
        let fresh = store.newTidyChanges
        if let first = fresh.first {
            Button { store.go(to: .places) } label: {
                HStack(spacing: 12) {
                    Image(systemName: "wand.and.stars").font(.title3).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(fresh.count == 1 ? "I tidied one payee" : "I tidied \(fresh.count) payees").font(.callout.weight(.semibold))
                        Text(store.sentence(for: first) + (fresh.count > 1 ? ", and \(fresh.count - 1) more. Each can be undone." : ". It can be undone."))
                            .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Theme.accent.opacity(0.07), in: .rect(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
