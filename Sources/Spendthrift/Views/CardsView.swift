import SwiftUI
import Charts
import PDFKit

extension BudgetStore {
    /// An account that is a credit card: named for a card issuer, and not a checking or savings account.
    static func isCard(_ account: Account) -> Bool {
        let lower = account.name.lowercased()
        return account.apart == nil && !lower.contains("checking") && !lower.contains("savings") && issuer(in: account.name) != nil
    }

    /// Cheap enough for the sidebar: reads the accounts, not the charges.
    var hasCards: Bool { accounts.contains(where: Self.isCard) }

    /// What the statements say about each card. Worked out once and kept until the library changes.
    func cardFacts() -> [CardEngine.Card] {
        cached("card-facts") {
            guard let asOf = transactions.last?.date else { return [] }
            return CardEngine.cards(accounts.filter(Self.isCard).map { (id: $0.id, name: $0.name) }, in: transactions, asOf: asOf)
        }
    }

    /// The card as it is in the catalogue, when the app or the person has said which it is.
    func cardProduct(_ id: UUID) -> CardCatalog.Product? {
        CardCatalog.product(titled: accounts.first { $0.id == id }?.product)
    }

    /// What to call a card: "Chase Sapphire Reserve ••4090" once it is known, else the account's own name.
    func cardTitle(_ id: UUID) -> String {
        guard let account = accounts.first(where: { $0.id == id }) else { return "Card" }
        guard let product = account.product, !product.isEmpty else { return account.name }
        let digits = account.name.components(separatedBy: "••").dropFirst().first.map { " ••" + $0 } ?? ""
        return product + digits
    }

    /// The person says which card this is (nil: none of the ones on offer).
    func setCardProduct(_ title: String?, for id: UUID) {
        guard let index = library.accounts.firstIndex(where: { $0.id == id }) else { return }
        library.accounts[index].product = title ?? ""
        library.accounts[index].productByHand = true
        readsChecked += 1
        savedOnly()
    }

    /// Works out which card each card account is, from its own statements: the name they print, the
    /// yearly fees charged, the names of its credits. Read once per account, again only when new
    /// statements arrive, and never over a choice the person made. Nothing leaves the Mac.
    func learnCardProducts() async {
        let sources = library.sources ?? []
        var asked: [(index: Int, issuer: String, files: [URL], fees: [Double], words: String, count: Int)] = []
        for (index, account) in library.accounts.enumerated() where Self.isCard(account) && account.productByHand != true {
            let mine = sources.filter { $0.accountID == account.id }
            guard !mine.isEmpty, account.productLooked != mine.count, account.product?.isEmpty != false || account.productLooked == nil,
                  let issuer = Self.issuer(in: account.name) else { continue }
            let pdfs = mine.filter(\.isPDF).sorted { ($0.lastDate ?? "") > ($1.lastDate ?? "") }.prefix(2).map { paths.statementFile($0) }
            var fees: [Double] = [], words: Set<String> = []
            for entry in library.entries where entry.accountID == account.id {
                if entry.amount > 0, CardEngine.annualFee(entry.description).isFee { fees.append(entry.amount) }
                if entry.amount < 0, let credit = CardEngine.benefitName(entry.description) { words.insert(credit) }
            }
            asked.append((index, issuer, Array(pdfs), fees, words.joined(separator: " "), mine.count))
        }
        guard !asked.isEmpty else { return }
        let jobs = asked.map { (files: $0.files, issuer: $0.issuer, fees: $0.fees, words: $0.words) }
        let found: [(title: String?, read: Bool)] = await Task.detached(priority: .utility) {
            jobs.map { job in
                // The first two pages of the newest statements are where a card names itself.
                let text = job.files.compactMap { PDFDocument(url: $0) }.filter { !$0.isLocked }
                    .flatMap { doc in (0..<min(2, doc.pageCount)).compactMap { doc.page(at: $0)?.string } }.joined(separator: "\n")
                return (CardCatalog.find(issuer: job.issuer, statementText: text, fees: job.fees, lineWords: job.words)?.title, !text.isEmpty || job.files.isEmpty)
            }
        }.value
        for (ask, answer) in zip(asked, found) where library.accounts.indices.contains(ask.index) && library.accounts[ask.index].productByHand != true {
            library.accounts[ask.index].product = answer.title ?? ""
            // A statement that could not be opened is not a look: try again next time.
            if answer.title != nil || answer.read { library.accounts[ask.index].productLooked = ask.count }
        }
        readsChecked += 1
        savedOnly()
    }

    func showCard(_ id: UUID) {
        navigate { if route.last != .card(id) { route.append(.card(id)) } }
    }
}

// MARK: The card itself

/// A card drawn as a card: the issuer's name, the last four digits, a chip. Its colour comes from
/// what the statements call it (a "Platinum" credit makes it silver, "Gold" gold); otherwise from
/// its name, so each card keeps its own look. Pointed at, it tilts and catches the light.
struct CardFace: View {
    let card: CardEngine.Card
    var width: CGFloat = 250
    @State private var pointed = false
    private var store: BudgetStore { .shared }

    private var issuer: String { card.name.components(separatedBy: "••").first?.trimmingCharacters(in: .whitespaces) ?? card.name }
    private var digits: String { card.name.components(separatedBy: "••").dropFirst().first.map { String($0.prefix(4)) } ?? "" }

    var body: some View {
        let _ = store.readsChecked
        let product = store.cardProduct(card.id)
        let look = product?.look ?? CardCatalog.look(forUnknown: card.name, issuer: BudgetStore.issuer(in: card.name))
        let ink: Color = look.darkInk ? Color(red: 0.16, green: 0.17, blue: 0.2) : .white
        let height = width / 1.586, shape = RoundedRectangle(cornerRadius: width * 0.055, style: .continuous)
        // A framed card (the charge-card look) carries its issuer across the top, centred; the others, their own name top left.
        let framed = look.pattern == .frame
        ZStack(alignment: .topLeading) {
            shape.fill(LinearGradient(colors: [look.top, look.bottom], startPoint: .topLeading, endPoint: .bottomTrailing))
            CardPattern(look: look).clipShape(shape)
            // The light that slides across when the card is tilted.
            shape.fill(LinearGradient(colors: [.white.opacity(0), .white.opacity(0.35), .white.opacity(0)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .mask { Rectangle().frame(width: width * 0.35).rotationEffect(.degrees(20)).offset(x: pointed ? width * 0.75 : -width * 0.75) }
                .clipShape(shape)
            VStack(alignment: .leading, spacing: 0) {
                if framed {
                    Text(issuer.uppercased()).font(.system(size: width * 0.05, weight: .semibold)).tracking(width * 0.012)
                        .lineLimit(1).minimumScaleFactor(0.6).frame(maxWidth: .infinity)
                } else {
                    HStack(alignment: .top) {
                        Text(product.map { $0.face.isEmpty ? "" : $0.face } ?? issuer)
                            .font(.system(size: width * (product == nil ? 0.068 : 0.05), weight: product == nil ? .bold : .semibold, design: product == nil ? .rounded : .default))
                            .tracking(product == nil ? 0 : width * 0.01).lineLimit(1).minimumScaleFactor(0.6)
                        Spacer(minLength: 4)
                        Image(systemName: "wave.3.right").font(.system(size: width * 0.06, weight: .semibold)).opacity(0.7)
                    }
                }
                Spacer(minLength: 0)
                // The chip.
                RoundedRectangle(cornerRadius: width * 0.016, style: .continuous)
                    .fill(LinearGradient(colors: [Color(red: 0.95, green: 0.84, blue: 0.52), Color(red: 0.78, green: 0.62, blue: 0.28)], startPoint: .top, endPoint: .bottom))
                    .frame(width: width * 0.13, height: width * 0.1)
                    .overlay { VStack(spacing: width * 0.022) { ForEach(0..<3, id: \.self) { _ in Rectangle().fill(.black.opacity(0.18)).frame(height: 0.7) } }.padding(.horizontal, 3) }
                Spacer(minLength: 0)
                HStack(alignment: .lastTextBaseline) {
                    Text(digits.isEmpty ? "••••" : "••••  \(digits)")
                        .font(.system(size: width * 0.064, weight: .medium, design: .monospaced)).tracking(0.5).lineLimit(1).minimumScaleFactor(0.6)
                        .shadow(color: .black.opacity(look.darkInk ? 0 : 0.35), radius: 0.5, y: 0.5)
                    Spacer(minLength: 4)
                    // The issuer in the corner once the card's own name has taken the top; the card's name there on a framed one.
                    if let product {
                        Text(framed ? product.face : issuer.uppercased()).font(.system(size: width * 0.04, weight: .bold)).tracking(width * 0.006)
                            .lineLimit(1).minimumScaleFactor(0.5).opacity(0.85)
                    }
                }
            }
            .foregroundStyle(ink)
            .padding(width * (framed ? 0.095 : 0.07))
        }
        .frame(width: width, height: height)
        .overlay { shape.strokeBorder(.white.opacity(0.25), lineWidth: 0.75) }
        .shadow(color: .black.opacity(pointed ? 0.32 : 0.2), radius: pointed ? 16 : 8, y: pointed ? 10 : 4)
        .rotation3DEffect(.degrees(pointed ? 9 : 0), axis: (x: 0.6, y: -1, z: 0), perspective: 0.6)
        .scaleEffect(pointed ? 1.03 : 1)
        .onHover { inside in withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { pointed = inside } }
        .accessibilityHidden(true)
    }
}

/// The verdict on a card's last twelve months, as a rubber stamp.
private struct VerdictStamp: View {
    let card: CardEngine.Card
    var size: CGFloat = 11

    var body: some View {
        switch card.verdict {
        case .noFee: Stamp(text: "NO FEE", color: .secondary, size: size)
        case .paysItsWay: Stamp(text: "PAYS ITS WAY", color: Theme.good, size: size)
        case .costs(let net): Stamp(text: "COSTS \(Money.format(net, cents: false))", color: Theme.caution, size: size)
        }
    }
}

private struct Figure: View {
    let title: String
    let amount: Double
    var color: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(Money.format(amount, cents: false)).font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit().foregroundStyle(color)
        }
    }
}

// MARK: All the cards

/// Every card laid out like cards on a table: what each costs to hold, what it has paid back, what
/// it carries, and the one thing most worth knowing about it. All of it read from the statements.
struct CardsView: View {
    private var store: BudgetStore { .shared }
    var scrolls = true

    var body: some View {
        let cards = store.cardFacts()
        let _ = store.readsChecked
        MaybeScroll(scrolls: scrolls) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cards").font(.system(size: 30, weight: .bold, design: .serif))
                    Text("What each card costs to hold, what it has paid you back, and what it carries. Read from your statements and nothing else.")
                        .font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if cards.isEmpty {
                    EmptyState(title: "No cards yet", message: "Add a credit card's statements and it will have a page here.", art: "nothing")
                } else {
                    table(cards)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 330), spacing: 18, alignment: .top)], alignment: .leading, spacing: 18) {
                        ForEach(cards) { card in tile(card) }
                    }
                    Text("Points, lounges and anything else that never appears on a statement are not counted here. A credit is known only once it has landed on a statement.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Cards")
    }

    /// The last twelve months across every card, in a line.
    @ViewBuilder private func table(_ cards: [CardEngine.Card]) -> some View {
        let fees = cards.reduce(0) { $0 + $1.feesPaid }, back = cards.reduce(0) { $0 + $1.creditsBack }
        let waiting = cards.flatMap { card in card.findings.filter { $0.kind == .waiting || $0.kind == .wrongCard }.map { (card, $0) } }
        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 34) {
                    Figure(title: "Fees, last 12 months", amount: fees)
                    Figure(title: "Credits back", amount: back, color: Theme.good)
                    Figure(title: back >= fees ? "Ahead by" : "Short by", amount: abs(back - fees), color: back >= fees ? Theme.good : Theme.caution)
                    Figure(title: "Put on cards", amount: cards.reduce(0) { $0 + $1.spent })
                    Spacer(minLength: 0)
                }
                if !waiting.isEmpty {
                    Divider()
                    Text("WORTH A LOOK NOW").font(Theme.mono(10.5, .bold)).tracking(1.2).foregroundStyle(.secondary)
                    ForEach(Array(waiting.prefix(4)), id: \.1.id) { card, finding in
                        FindingRow(finding: finding, card: card, namesCard: true)
                    }
                }
            }
        }
    }

    private func tile(_ card: CardEngine.Card) -> some View {
        Button { store.showCard(card.id) } label: {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    CardFace(card: card, width: 190)
                    Spacer(minLength: 8)
                    VerdictStamp(card: card).padding(.top, 6)
                }
                Text(store.cardTitle(card.id)).font(.headline).lineLimit(1)
                HStack(alignment: .top, spacing: 22) {
                    Figure(title: "Fees", amount: card.feesPaid)
                    Figure(title: "Credits back", amount: card.creditsBack, color: card.creditsBack > 0.5 ? Theme.good : .primary)
                    Figure(title: "Carried", amount: card.spent)
                }
                if let first = card.findings.first {
                    Text(first.text).font(.callout).foregroundStyle(.secondary).lineLimit(3).multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.sheet, in: .rect(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.hairline) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open \(store.cardTitle(card.id))")
    }
}

/// One thing worth knowing, with the charges behind it a click away.
private struct FindingRow: View {
    let finding: CardEngine.Finding
    let card: CardEngine.Card
    var namesCard = false
    private var store: BudgetStore { .shared }

    private var symbol: (name: String, color: Color) {
        switch finding.kind {
        case .waiting: ("hourglass", Theme.caution)
        case .missed: ("circle.dashed", Theme.caution)
        case .wrongCard: ("arrow.left.arrow.right", Theme.caution)
        case .quiet: ("moon.zzz.fill", .secondary)
        case .feeDue: ("calendar.badge.clock", Theme.accent)
        case .feeRose: ("arrow.up.right", Theme.spent)
        case .interest: ("percent", Theme.spent)
        case .net: ("equal.circle", Theme.accent)
        case .share: ("chart.pie.fill", Theme.accent)
        }
    }

    var body: some View {
        Button {
            if namesCard { store.showCard(card.id) }
            else if !finding.charges.isEmpty { store.showCharges(TransactionFilter(ids: finding.charges, title: finding.chargesTitle)) }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: symbol.name).foregroundStyle(symbol.color).frame(width: 22)
                (Text(namesCard ? "\(store.cardTitle(card.id)).  " : "").fontWeight(.semibold) + Text(finding.text))
                    .font(.callout).multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                if namesCard || !finding.charges.isEmpty { Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(namesCard ? "Open \(card.name)" : finding.charges.isEmpty ? "" : "See the charges behind this")
    }
}

// MARK: One card

struct CardPage: View {
    let id: UUID
    private var store: BudgetStore { .shared }
    var scrolls = true

    var body: some View {
        MaybeScroll(scrolls: scrolls) {
            if let card = store.cardFacts().first(where: { $0.id == id }) {
                VStack(alignment: .leading, spacing: 20) {
                    head(card)
                    if !card.findings.isEmpty { knowing(card) }
                    if !card.benefits.isEmpty { credits(card) }
                    costs(card)
                    carries(card)
                    Text("Read from this card's statements and nothing else. Points, lounges and anything that never appears on a statement are not counted; a credit is known only once it has landed here.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(28)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity)
            } else {
                EmptyState(title: "This card has no charges", message: "Its statements may have been removed.", art: "nothing").padding(28)
            }
        }
        .navigationTitle("Cards")
    }

    private func head(_ card: CardEngine.Card) -> some View {
        HStack(alignment: .center, spacing: 26) {
            CardFace(card: card, width: 280)
            VStack(alignment: .leading, spacing: 10) {
                let _ = store.readsChecked
                Text(store.cardTitle(card.id)).font(.system(size: 28, weight: .bold, design: .serif))
                    .lineLimit(2).minimumScaleFactor(0.7)
                HStack(spacing: 10) {
                    Text(whichCardNote(card)).font(.callout).foregroundStyle(.secondary)
                    Menu("Not this card?") {
                        ForEach(CardCatalog.products.filter { $0.issuer == BudgetStore.issuer(in: card.name) }) { product in
                            Button(product.title) { store.setCardProduct(product.title, for: card.id) }
                        }
                        Divider()
                        Button("None of these") { store.setCardProduct(nil, for: card.id) }
                    }
                    .menuStyle(.borderlessButton).fixedSize().font(.callout)
                    .help("Choose which card this is; the app will not change it again")
                }
                Text("On file from \(card.first.formatted(.dateTime.month(.wide).year())) to \(card.last.formatted(.dateTime.month(.wide).year()))")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 26) {
                    Figure(title: "Fees, last 12 months", amount: card.feesPaid)
                    Figure(title: "Credits back", amount: card.creditsBack, color: card.creditsBack > 0.5 ? Theme.good : .primary)
                    Figure(title: "Carried", amount: card.spent)
                }
                .padding(.top, 4)
                AfterFirstFrame { VerdictStamp(card: card, size: 13) }.frame(height: 40, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
    }

    /// How the app came to call the card what it does.
    private func whichCardNote(_ card: CardEngine.Card) -> String {
        guard let account = store.accounts.first(where: { $0.id == card.id }) else { return "" }
        if account.productByHand == true { return account.product?.isEmpty == false ? "You said which card this is." : "" }
        if account.product?.isEmpty == false { return "Named from its own statements." }
        return "Its statements do not say which card this is."
    }

    private func knowing(_ card: CardEngine.Card) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Worth knowing")
                ForEach(Array(card.findings.enumerated()), id: \.element.id) { index, finding in
                    if index > 0 { Divider() }
                    FindingRow(finding: finding, card: card)
                }
            }
        }
    }

    // MARK: Credits

    /// Each credit the card has paid, as a row of marks: one per month, quarter or year, filled
    /// when it came, hollow when it did not, ringed for the stretch still running.
    private func credits(_ card: CardEngine.Card) -> some View {
        let live = card.benefits.filter { !$0.ended }, past = card.benefits.filter(\.ended)
        return Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "Credits it has paid you", subtitle: "Each mark is a month, a quarter or a year: filled when the credit came, hollow when it did not.")
                ForEach(Array(live.enumerated()), id: \.element.id) { index, benefit in
                    if index > 0 { Divider() }
                    BenefitRow(benefit: benefit)
                }
                if !past.isEmpty {
                    if !live.isEmpty { Divider() }
                    Text("EARLIER").font(Theme.mono(10.5, .bold)).tracking(1.2).foregroundStyle(.secondary)
                    ForEach(past) { benefit in
                        ReceiptLine(value: Money.format(benefit.total), help: "See these credits",
                                    action: { store.showCharges(TransactionFilter(ids: Set(benefit.creditIDs), title: benefit.name)) }) {
                            Text("\(benefit.name), \(benefit.first.formatted(.dateTime.year()))\(Calendar.current.component(.year, from: benefit.first) == Calendar.current.component(.year, from: benefit.last) ? "" : " to \(benefit.last.formatted(.dateTime.year()))")")
                                .font(.callout)
                        }
                    }
                }
            }
        }
    }

    // MARK: Costs

    private func costs(_ card: CardEngine.Card) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "What it costs to hold",
                              subtitle: card.fees.isEmpty ? "No yearly fee has ever appeared on its statements."
                                  : card.nextFee.map { "The next yearly fee should come round about \($0.date.formatted(.dateTime.month(.wide).day().year()))." })
                ForEach(card.fees.reversed().prefix(8)) { fee in
                    // Two fees on one day: the smaller is a second fee beside the card's own (the statement does not say what for).
                    let second = fee.who == nil && card.fees.contains { $0.id != fee.id && $0.amount > fee.amount && Calendar.current.isDate($0.date, inSameDayAs: fee.date) }
                    ReceiptLine(value: Money.format(fee.amount), help: "See this charge",
                                action: { store.showCharges(TransactionFilter(ids: [fee.id], title: "Yearly fee on \(card.name)")) }) {
                        Text("\(fee.date.formatted(.dateTime.month(.abbreviated).day().year())) · \(fee.who.map { "yearly fee for \($0)'s card" } ?? (second ? "a second yearly fee" : "yearly fee"))").font(.callout)
                    }
                }
                if card.interest > 0.5 {
                    ReceiptLine(value: Money.format(card.interest), valueColor: Theme.spent, help: "See these charges",
                                action: { store.showCharges(TransactionFilter(ids: card.interestIDs, title: "Interest and other charges on \(card.name)")) }) {
                        Text("Interest and other charges, last 12 months").font(.callout)
                    }
                }
            }
        }
    }

    // MARK: What it carries

    private func carries(_ card: CardEngine.Card) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(title: "What it carries",
                              subtitle: "\(Money.format(card.spent, cents: false)) across \(card.charges.formatted()) \(card.charges == 1 ? "purchase" : "purchases") in the last 12 months")
                if card.years.count > 1 {
                    Chart(card.years) { year in
                        BarMark(x: .value("Year", String(year.year)), y: .value("Bought", year.spent), width: .ratio(0.6))
                            .foregroundStyle(Theme.inkFill.gradient).cornerRadius(3)
                    }
                    .chartYAxis { AxisMarks(position: .leading) { value in
                        AxisGridLine().foregroundStyle(Theme.hairline)
                        AxisValueLabel { if let v = value.as(Double.self) { Text(Money.format(v, cents: false)) } }
                    } }
                    .frame(height: 130)
                }
                if !card.categories.isEmpty {
                    // What it is used for, as one bar.
                    let shown = card.categories.prefix(5)
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            ForEach(Array(shown), id: \.category) { line in
                                Rectangle().fill(line.category.color.gradient).frame(width: max(2, geo.size.width * line.total / max(card.spent, 1)))
                                    .help("\(line.category.displayName): \(Money.format(line.total, cents: false))")
                            }
                            Rectangle().fill(Color.primary.opacity(0.08))
                        }
                        .clipShape(.capsule)
                    }
                    .frame(height: 10)
                    HStack(spacing: 14) {
                        ForEach(Array(shown), id: \.category) { line in
                            HStack(spacing: 5) {
                                Circle().fill(line.category.color).frame(width: 7, height: 7)
                                Text("\(line.category.displayName) \(Int((line.total / max(card.spent, 1) * 100).rounded()))%").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if !card.payees.isEmpty {
                    Divider()
                    ForEach(Array(card.payees.prefix(6).enumerated()), id: \.element.name) { index, payee in
                        PayeeLine(name: payee.name, category: payee.category, detail: payee.count == 1 ? "1 purchase" : "\(payee.count) purchases",
                                  amount: payee.total, rank: index + 1) { store.showPlace(payee.name) }
                    }
                    Button("Everything bought on this card, last 12 months") {
                        store.showCharges(TransactionFilter(ids: card.purchaseIDs, title: "Bought on \(card.name), last 12 months"))
                    }
                    .buttonStyle(.borderless).font(.callout)
                }
            }
        }
    }
}

/// One credit: its name, its rhythm, and a mark for each stretch.
private struct BenefitRow: View {
    let benefit: CardEngine.Benefit
    private var store: BudgetStore { .shared }
    @State private var pointed: String?

    /// "Jul 2025 to Dec 2026", or "2022 to 2026" for a yearly one.
    private var span: String {
        guard let first = benefit.uses.first, let last = benefit.uses.last else { return "" }
        let end = Calendar.current.date(byAdding: .day, value: -1, to: last.end) ?? last.end
        let style: Date.FormatStyle = benefit.cadence == .yearly ? .dateTime.year() : .dateTime.month(.abbreviated).year()
        return "\(first.start.formatted(style)) to \(end.formatted(style))"
    }

    private func about(_ use: CardEngine.Use) -> String {
        let money = { (v: Double) in Money.format(v, cents: false) }
        var text = use.received > 0.5 ? "\(use.label): \(money(use.received)) came" : "\(use.label): nothing came"
        if use.isCurrent { text += " so far" }
        if benefit.cadence != .yearly, !use.elsewhere.isEmpty, use.received < benefit.usual - 1, let shop = benefit.shops.first {
            text += ". \(money(use.elsewhere.reduce(0) { $0 + $1.amount })) went to \(shop) on another card"
        } else if benefit.cadence != .yearly, !use.here.isEmpty, use.received < 0.5, let shop = benefit.shops.first {
            text += ", though \(money(use.here.reduce(0) { $0 + $1.amount })) went to \(shop) on this card"
        }
        return text + "."
    }

    var body: some View {
        let money = { (v: Double) in Money.format(v, cents: false) }
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Button { store.showCharges(TransactionFilter(ids: Set(benefit.creditIDs), title: benefit.name)) } label: {
                    Text(benefit.name).font(.body.weight(.semibold)).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("See every one of these credits")
                Text(benefit.printed != nil ? "\(money(benefit.usual)) a year, the statement says" : "usually \(money(benefit.usual)) \(benefit.cadence.each)")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(Money.format(benefit.total)).font(Theme.mono(13, .semibold))
                Text("so far").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 7) {
                ForEach(benefit.uses) { use in
                    Pip(fraction: benefit.usual > 0 ? min(1, use.received / benefit.usual) : 0, current: use.isCurrent)
                        .onHover { inside in pointed = inside ? use.id : (pointed == use.id ? nil : pointed) }
                        .onTapGesture {
                            let ids = Set(use.credits + (use.elsewhere + use.here).map(\.id))
                            if !ids.isEmpty { store.showCharges(TransactionFilter(ids: ids, title: "\(benefit.name), \(use.label)")) }
                        }
                        .help(about(use))
                        .accessibilityLabel(about(use))
                }
                Spacer(minLength: 0)
            }
            Text(benefit.uses.first(where: { $0.id == pointed }).map(about)
                 ?? ((benefit.uses.count > 1 ? "\(span). " : "") + (benefit.shops.first.map { "For \($0)." } ?? "")))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// One stretch of a credit: a coin that is full, part full or empty, and ringed while it is still running.
private struct Pip: View {
    let fraction: Double
    let current: Bool
    @State private var breathing = false

    var body: some View {
        ZStack {
            Circle().fill(Color.primary.opacity(0.07))
            if fraction > 0.02 {
                Circle().fill(Theme.good.gradient)
                    .mask(alignment: .bottom) { Rectangle().frame(height: 18 * max(0.18, fraction)) }
            }
            Circle().strokeBorder(fraction >= 0.98 ? Theme.good : Color.primary.opacity(0.22), lineWidth: 1.2)
            if current, fraction < 0.98 {
                Circle().strokeBorder(Theme.caution, style: StrokeStyle(lineWidth: 1.6, dash: [3, 2.5]))
                    .scaleEffect(breathing ? 1.32 : 1.18).opacity(breathing ? 0.5 : 1)
                    .onAppear { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { breathing = true } }
            }
        }
        .frame(width: 18, height: 18)
        .contentShape(Circle())
    }
}
