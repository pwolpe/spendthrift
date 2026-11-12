import SwiftUI

/// Where to trim: everything spent in a stretch, ranked, by payee or by category. With "chosen"
/// on, only what was a choice is counted, so the mortgage does not sit on top of a list of things
/// nobody could cut.
struct TrimCard: View {
    @Environment(BudgetStore.self) private var store
    /// The charges of the stretch on screen, and what to call it ("November", "the last 12 months").
    let transactions: [Transaction]
    let stretch: String
    /// The month, when the stretch is one: category rows then open that month's charges.
    var month: Month?
    @AppStorage("trimByPayee") private var byPayee = true
    @AppStorage("trimChosenOnly") private var chosenOnly = true
    @State private var showsAll = false

    var body: some View {
        let all = TrimEngine.lines(transactions, byPayee: byPayee, optional: store.isOptional)
        let lines = chosenOnly ? all.filter { $0.optionalShare >= 0.5 } : all
        let total = all.reduce(0) { $0 + $1.total }
        let shown = lines.reduce(0) { $0 + $1.total }
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    SectionHeader(title: "Where to trim",
                                  subtitle: chosenOnly ? "\(Money.format(shown, cents: false)) of the \(Money.format(total, cents: false)) spent in \(stretch) was chosen, not needed. Largest first."
                                                       : "Everything spent in \(stretch), largest first.")
                    Spacer()
                    Picker("Rank", selection: $byPayee) {
                        Text("Payees").tag(true)
                        Text("Categories").tag(false)
                    }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                    Toggle("Chosen only", isOn: $chosenOnly).toggleStyle(.switch).controlSize(.small)
                        .help("Leave out what a household needs (housing, utilities, insurance, groceries) and rank only what was a choice")
                }
                if lines.isEmpty {
                    Text("Nothing here for \(stretch).").foregroundStyle(.secondary)
                }
                let top = lines.first?.total ?? 1
                ForEach(Array(lines.prefix(showsAll ? 60 : 10).enumerated()), id: \.element.id) { index, line in
                    Button { open(line) } label: {
                        HStack(spacing: 12) {
                            Text("\(index + 1)").font(.callout.weight(.bold)).monospacedDigit().foregroundStyle(.tertiary).frame(width: 22, alignment: .trailing)
                            if byPayee { MerchantIcon(name: line.name, category: line.category, size: 30) } else { CategoryIcon(category: line.category, size: 30) }
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(line.name).font(.body.weight(.medium)).lineLimit(1)
                                    Spacer()
                                    Text(Money.format(line.total, cents: false)).monospacedDigit()
                                    Text((line.total / max(shown, 1)).formatted(.percent.precision(.fractionLength(0))))
                                        .font(.callout).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
                                }
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.primary.opacity(0.06))
                                        Capsule().fill(line.category.color.gradient).frame(width: max(4, geo.size.width * line.total / top))
                                    }
                                }
                                .frame(height: 5)
                                Text((byPayee ? "\(line.category.displayName) · " : "") + (line.count == 1 ? "1 charge" : "\(line.count) charges")
                                     + (line.count > 1 ? " · \(Money.format(line.total / Double(line.count), cents: false)) each on average" : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if lines.count > 10 {
                    Button(showsAll ? "Show the Top 10" : "Show More") { withAnimation(.snappy) { showsAll.toggle() } }
                        .buttonStyle(.borderless).font(.callout)
                }
            }
        }
    }

    private func open(_ line: TrimEngine.Line) {
        if byPayee { store.showPlace(line.name) }
        else { store.showCharges(TransactionFilter(ids: Set(line.chargeIDs), title: "\(line.name) in \(stretch)")) }
    }
}
