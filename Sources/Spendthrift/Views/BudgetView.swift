import SwiftUI

/// A thin bar: how much of the target is used. Over the target it turns the caution colour.
private struct BudgetBar: View {
    let spent: Double
    let target: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(color.gradient).frame(width: max(4, geo.size.width * min(1, max(0, spent / max(target, 1)))))
            }
        }
        .frame(height: 6)
    }
}

/// The Overview's Budget card: one figure, a bar, and how many categories are keeping pace.
struct BudgetCard: View {
    private var store: BudgetStore { .shared }
    let summary: BudgetEngine.Summary

    var body: some View {
        let over = summary.over
        Card {
            Button { store.stepInto(.budgets) } label: {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        Image(systemName: "gauge.with.needle.fill").font(.callout.weight(.semibold)).foregroundStyle(Theme.accent)
                        Text("Budget").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    Text("\(Money.format(summary.spent, cents: false)) of \(Money.format(summary.target, cents: false))")
                        .font(.system(size: 32, weight: .bold, design: .rounded)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.55)
                    BudgetBar(spent: summary.spent, target: summary.target, color: over > 0 ? Theme.caution : Theme.accent)
                    Text("\(summary.onPace) \(summary.onPace == 1 ? "category" : "categories") on pace, \(over) over")
                        .font(.callout).foregroundStyle(over > 0 ? Theme.caution : .secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// The Budget page: a row for each category.
struct BudgetView: View {
    @Environment(BudgetStore.self) private var store
    let month: Month

    var body: some View {
        let summary = store.budget(for: month)
        VStack(alignment: .leading, spacing: 20) {
            BigFigure(title: "Spent of budget in \(month.name)", amount: summary.spent,
                      subtitle: "of \(Money.format(summary.target, cents: false)) · \(summary.onPace) \(summary.onPace == 1 ? "category" : "categories") on pace, \(summary.over) over")
            if summary.lines.isEmpty {
                EmptyState(title: "No budget yet", message: "Once there are three months of spending in a category, its usual amount shows up here.", art: "welcome")
            } else {
                Card {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Each is what you usually spend: the middle of your last six months, trips left out.")
                            .font(.callout).foregroundStyle(.secondary).padding(.bottom, 8)
                        ForEach(Array(summary.lines.enumerated()), id: \.element.id) { index, line in
                            if index > 0 { Divider() }
                            BudgetRow(line: line, month: month, inProgress: summary.isInProgress)
                        }
                    }
                }
                if summary.leftOut >= 1 {
                    Button {
                        store.showCharges(TransactionFilter(ids: summary.leftOutIDs, title: "Trips and events in \(month.title)"))
                    } label: {
                        Label("\(Money.format(summary.leftOut, cents: false)) on trips and events this month is not counted.", systemImage: "airplane")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct BudgetRow: View {
    private var store: BudgetStore { .shared }
    let line: BudgetEngine.Line
    let month: Month
    let inProgress: Bool
    @State private var editing = false
    @State private var text = ""

    private var note: (String, Color) {
        if line.spent > line.target {
            // Whole dollars: a few cents over is not "over by $0".
            let over = line.spent - line.target
            return (over >= 0.5 ? "over by \(Money.format(over, cents: false))" : "just over", Theme.caution)
        }
        var words = "left \(Money.format(line.left, cents: false))"
        if let projected = line.projected { words += " · heading for \(Money.format(projected, cents: false))" }
        return (words, line.pace == .over ? Theme.caution : .secondary)
    }

    var body: some View {
        HStack(spacing: 12) {
            Button { store.showBudgetCharges(line, in: month) } label: {
                HStack(spacing: 12) {
                    CategoryIcon(category: line.category, size: 34)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(line.category.displayName).font(.body.weight(.medium)).lineLimit(1)
                            Spacer(minLength: 8)
                            Text(note.0).font(.callout).foregroundStyle(note.1).monospacedDigit()
                        }
                        BudgetBar(spent: line.spent, target: line.target, color: line.pace == .over ? Theme.caution : line.category.color)
                    }
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(line.category.displayName) in \(month.name)")
            HStack(spacing: 4) {
                Text("\(Money.format(line.spent, cents: false)) of").foregroundStyle(.secondary)
                Button {
                    text = String(Int(line.target.rounded()))
                    editing = true
                } label: {
                    Text(Money.format(line.target, cents: false)).fontWeight(.semibold).underline(color: .secondary.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help(line.isOverride ? "Your own amount. Click to change it." : "Worked out from your last six months. Click to set your own.")
                .popover(isPresented: $editing, arrowEdge: .bottom) { editor }
            }
            .font(.callout).monospacedDigit()
            .frame(minWidth: 150, alignment: .trailing)
        }
        .padding(.vertical, 8)
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Monthly amount for \(line.category.displayName)").font(.headline)
            HStack {
                Text(Money.currencyCode == "USD" ? "$" : Money.currencyCode)
                TextField("Amount", text: $text).frame(width: 100).onSubmit(save)
            }
            if let computed = line.computed {
                Text("Worked out: \(Money.format(computed, cents: false))").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                if line.isOverride, line.computed != nil {
                    Button("Set Automatically") { store.setBudget(line.category, to: nil); editing = false }
                }
                Spacer()
                Button("Set", action: save).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    private func save() {
        let cleaned = text.filter { $0.isNumber || $0 == "." }
        if let amount = Double(cleaned), amount > 0 { store.setBudget(line.category, to: amount) }
        editing = false
    }
}
