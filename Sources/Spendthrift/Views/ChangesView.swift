import SwiftUI

/// Why this month (or this year) differs from usual: a headline, then the few reasons, each opening what it is about.
struct ChangeCard: View {
    private var store: BudgetStore { .shared }
    let explanation: ChangeEngine.Explanation

    private func signed(_ driver: ChangeEngine.Driver) -> String {
        let text = Money.format(abs(driver.amount), cents: driver.kind == .priceRise)
        return (driver.amount > 0 ? "+" : "\u{2212}") + text
    }

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.up.arrow.down.circle.fill").font(.callout.weight(.semibold)).foregroundStyle(Theme.accent)
                    Text("What changed").font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                }
                Text(explanation.headline).font(.title3.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                if !explanation.drivers.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(explanation.drivers.enumerated()), id: \.element.id) { index, driver in
                            if index > 0 { Divider() }
                            row(driver)
                        }
                    }
                }
            }
        }
    }

    private func row(_ driver: ChangeEngine.Driver) -> some View {
        let color = driver.amount > 0 ? Theme.caution : Theme.good
        return Button { store.show(driver) } label: {
            HStack(spacing: 12) {
                Image(systemName: driver.kind.symbol).font(.body).foregroundStyle(color).frame(width: 24)
                Text(driver.sentence).font(.body).multilineTextAlignment(.leading).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Text(signed(driver)).font(.body.weight(.semibold)).monospacedDigit().foregroundStyle(color)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open the charges behind this")
    }
}
