import SwiftUI

/// The top of the Overview: did living stay within what was earned?
///
/// Income is the whole track. Income taxes come off first (they were never yours to spend), then
/// what was lived on and paid in interest. What is left is gold: kept or invested, it is still yours.
/// Investing never counts against the verdict. Within a hundredth of income either way is called even.
struct FlowHero: View {
    let data: CashFlowData
    /// A few sentences written about these figures, shown in place of the plain sum when present.
    var written: String?
    var action: (() -> Void)?
    @State private var hovered = false

    enum Verdict { case within, even, over, unknown }

    private struct Part: Identifiable {
        var id: String { name }
        let name: String
        let amount: Double
        let color: Color
    }

    static func verdict(for data: CashFlowData) -> Verdict {
        guard data.totalIncome > 0.5 else { return .unknown }
        if abs(data.surplus) < data.totalIncome * 0.01 { return .even }
        return data.surplus > 0 ? .within : .over
    }

    var body: some View {
        let income = data.totalIncome
        let verdict = Self.verdict(for: data)
        let parts = [
            Part(name: "Income taxes", amount: data.taxes, color: Category.taxes.color),
            Part(name: "Lived on", amount: data.spending, color: Theme.spent),
            Part(name: "Loan interest", amount: data.loanInterest, color: Category.investmentLoan.color.opacity(0.7)),
        ].filter { $0.amount > 0.5 }
        let used = parts.reduce(0) { $0 + $1.amount }
        let left = max(0, income - used)
        let scale = max(income, used, 1)

        let card = Card(padding: 22) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .center, spacing: 18) {
                    if verdict == .within || verdict == .over { SpotArt(name: verdict == .within ? "within" : "over", height: 92) }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(data.title.uppercased())
                            .font(Theme.mono(10, .bold)).tracking(1.2).foregroundStyle(.secondary)
                        Text(headline(verdict))
                            .font(.system(size: 26, weight: .bold, design: .serif))
                            .fixedSize(horizontal: false, vertical: true)
                        // The read a model wrote from these same figures, when there is one; else the sum in plain words.
                        Text(written ?? sentence(verdict))
                            .font(.body).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.opacity)
                    }
                    Spacer(minLength: 0)
                    // The stamp lands a beat after the page is up (it animates in anyway); its place is kept.
                    ZStack {
                        AfterFirstFrame {
                            switch verdict {
                            case .within: Stamp(text: "WITHIN MEANS", color: Theme.good, size: 13)
                            case .even: Stamp(text: "ABOUT EVEN", color: Theme.caution, size: 13)
                            case .over: Stamp(text: "OVER", color: Theme.spent, size: 13)
                            case .unknown: EmptyView()
                            }
                        }
                    }
                    .frame(width: verdict == .unknown ? 0 : 172, height: 44)
                    .padding(.trailing, 6)
                    if action != nil {
                        Image(systemName: "chevron.right").font(.callout.weight(.semibold))
                            .foregroundStyle(hovered ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                    }
                }
                if used > 0.5 || income > 0.5 {
                    GeometryReader { geo in
                        let width = geo.size.width
                        ZStack(alignment: .leading) {
                            HStack(spacing: 2) {
                                ForEach(parts) { part in
                                    Rectangle().fill(part.color.gradient)
                                        .frame(width: max(3, (width - CGFloat(parts.count) * 2) * part.amount / scale))
                                }
                                // What wasn't consumed: kept or put to work. Gold, because it is still yours.
                                if left > 0.5 { Rectangle().fill(Theme.goldDeep.gradient) }
                                Spacer(minLength: 0)
                            }
                            .clipShape(Capsule())
                            // Lived past what came in: mark where income ended.
                            if income > 0.5, used > income + 0.5 {
                                Rectangle().fill(Color.primary).frame(width: 2, height: 28).offset(x: width * income / scale - 1)
                            }
                        }
                    }
                    .frame(height: 18)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 118), spacing: 14, alignment: .leading)], alignment: .leading, spacing: 10) {
                        figure("Came in", income, nil)
                        ForEach(parts) { figure($0.name, $0.amount, $0.color) }
                        if left > 0.5 { figure("Left to keep or invest", left, Theme.goldDeep) }
                    }
                    payAlone
                }
            }
        }
        // With somewhere to go it is a button; on the page it leads to, it is just the card.
        if let action {
            Button(action: action) { card.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .onHover { hovered = $0 }
                .help("See all the money in and out")
        } else {
            card
        }
    }

    private func headline(_ verdict: Verdict) -> String {
        switch verdict {
        case .within: "You lived within your income"
        case .even: "You lived on about what you took home"
        case .over: "You lived on \(Money.format(-data.surplus, cents: false)) more than you took home"
        case .unknown: data.spending > 0.5 ? "\(Money.format(data.spending, cents: false)) spent so far" : "Nothing here yet"
        }
    }

    /// The sum, in words: what came in, less tax, against what was lived on.
    private func sentence(_ verdict: Verdict) -> String {
        guard verdict != .unknown else { return "No income has shown up for \(data.period == .last12 ? "the last 12 months" : data.title) yet, so there is nothing to measure it against." }
        let money = { (v: Double) in Money.format(v, cents: false) }
        let takeHome = data.totalIncome - data.taxes
        var text = data.taxes > 0.5 ? "After \(money(data.taxes)) in income taxes, \(money(takeHome)) was yours. "
                                    : "\(money(takeHome)) came in. "
        text += "You lived on \(money(data.spending))"
        if data.loanInterest > 0.5 { text += " and paid \(money(data.loanInterest)) in loan interest" }
        switch verdict {
        case .within: text += ", and \(money(data.surplus)) was left to keep or invest."
        case .even: text += data.surplus >= 0 ? ", which left \(money(data.surplus))." : ", \(money(-data.surplus)) more than that."
        default: text += "."
        }
        return text + (data.built > 0.5 ? " Money you invested is never counted as spending." : "")
    }

    /// The stricter question: never mind what investments paid out, did pay alone cover how you lived?
    /// Shown whenever there is pay to measure against.
    @ViewBuilder
    private var payAlone: some View {
        let pay = data.income, lived = data.spending
        if pay > 0.5, lived > 0.5 {
            let kept = pay - lived
            let share = lived / pay
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("ON YOUR PAY ALONE").font(Theme.mono(10, .bold)).tracking(1.2).foregroundStyle(.secondary)
                    Spacer()
                    Text(kept >= 0 ? "\(Self.percent(kept / pay)) of your pay kept" : "\(Self.percent(-kept / pay)) over your pay")
                        .font(.callout.weight(.semibold)).foregroundStyle(kept >= 0 ? Theme.good : Theme.spent)
                }
                // Pay is the track; what was needed fills it first, then what was chosen.
                let needed = max(0, lived - data.optionalSpending), chosen = min(lived, data.optionalSpending)
                GeometryReader { geo in
                    let width = geo.size.width, scale = max(pay, lived)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.good.opacity(0.18)).frame(width: width * pay / scale)
                        HStack(spacing: 2) {
                            Rectangle().fill(Theme.spent.opacity(0.55)).frame(width: max(2, width * needed / scale))
                            Rectangle().fill(Theme.spent.gradient).frame(width: max(2, width * chosen / scale))
                        }
                        .clipShape(Capsule())
                        if lived > pay { Rectangle().fill(Color.primary).frame(width: 2, height: 16).offset(x: width * pay / scale - 1) }
                    }
                }
                .frame(height: 8)
                Text((kept >= 0
                      ? "Your pay was \(Money.format(pay, cents: false)) and you lived on \(Money.format(lived, cents: false)), \(Self.percent(share)) of it. \(kept >= 0.5 ? "\(Money.format(kept, cents: false)) of your pay was left to save." : "None of your pay was left to save.")"
                      : "Your pay was \(Money.format(pay, cents: false)) and you lived on \(Money.format(lived, cents: false)). The other \(Money.format(-kept, cents: false)) came from what your investments paid out, or from savings.")
                     + (chosen > 0.5 ? " \(Money.format(chosen, cents: false)) of what you lived on was chosen, not needed: dinners out, trips, things bought for pleasure. That is \(Self.percent(chosen / pay)) of your pay." : ""))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func percent(_ fraction: Double) -> String { fraction.formatted(.percent.precision(.fractionLength(0))) }

    private func figure(_ name: String, _ amount: Double, _ color: Color?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                if let color { Circle().fill(color).frame(width: 7, height: 7) }
                Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Text(Money.format(amount, cents: false))
                .font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.7)
        }
    }

}

/// One quiet card on the Overview: a figure, a line about it, a small picture, and a way in.
struct SummaryCard<Visual: View>: View {
    let title: String
    let symbol: String
    let color: Color
    let figure: String
    var note: String?
    var noteColor: Color = .secondary
    let action: () -> Void
    @ViewBuilder var visual: Visual
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Card(padding: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        Image(systemName: symbol).font(.callout.weight(.semibold)).foregroundStyle(color)
                        Text(title).font(.callout.weight(.semibold)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            .foregroundStyle(hovered ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                    }
                    Text(figure)
                        .font(.system(size: 32, weight: .bold, design: .rounded)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.55)
                    Text(note ?? " ").font(.callout).foregroundStyle(noteColor).lineLimit(1)
                    visual.frame(height: 58).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

/// A handful of bars with one of them lit: the run of months a figure sits in.
struct MiniBars: View {
    let values: [Double]
    let labels: [String]
    var lit: Int?
    let color: Color

    var body: some View {
        let top = max(values.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 5) {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(lit == nil || lit == index ? AnyShapeStyle(color.gradient) : AnyShapeStyle(color.opacity(0.28)))
                        .frame(height: max(2, 42 * max(value, 0) / top))
                        .frame(maxHeight: 42, alignment: .bottom)
                    Text(labels.indices.contains(index) ? labels[index] : "")
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary).lineLimit(1).fixedSize()
                }
                .frame(maxWidth: 30)
                .help(labels.indices.contains(index) ? "\(labels[index]): \(Money.format(value, cents: false))" : "")
            }
        }
    }
}

/// A small ring of where spending went, with its three biggest slices named beside it.
struct MiniRing: View {
    let slices: [(category: Category, total: Double)]

    var body: some View {
        let sum = max(slices.reduce(0) { $0 + $1.total }, 1)
        HStack(spacing: 14) {
            Canvas { context, size in
                let radius = min(size.width, size.height) / 2 - 4
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                var start = -90.0
                for slice in slices where slice.total / sum > 0.004 {
                    let sweep = slice.total / sum * 360
                    var path = Path()
                    // The gap between slices shrinks with the slice: an end before its start would draw the long way round.
                    let gap = min(1, sweep / 4)
                    path.addArc(center: center, radius: radius, startAngle: .degrees(start + gap), endAngle: .degrees(start + sweep - gap), clockwise: false)
                    context.stroke(path, with: .color(slice.category.color), style: StrokeStyle(lineWidth: 8, lineCap: .butt))
                    start += sweep
                }
            }
            .frame(width: 58, height: 58)
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(slices.prefix(3).enumerated()), id: \.offset) { _, slice in
                    HStack(spacing: 6) {
                        Circle().fill(slice.category.color).frame(width: 7, height: 7)
                        Text(slice.category.displayName).font(.caption).lineLimit(1)
                        Spacer(minLength: 4)
                        Text((slice.total / sum).formatted(.percent.precision(.fractionLength(0))))
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
    }
}
