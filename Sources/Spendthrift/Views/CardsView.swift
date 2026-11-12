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
        if let warm = cardFactsWarm, warm.revision == revision { return warm.cards }
        return cached("card-facts") {
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
            // Look when it has never been looked at, when it could not be told and more statements have
            // come since, or when the name on file is one the catalogue no longer has.
            let known = account.product.map { !$0.isEmpty && CardCatalog.product(titled: $0) != nil } ?? false
            let stale = account.product?.isEmpty == false && !known
            guard !mine.isEmpty, !known, account.product == nil || stale || account.productLooked != mine.count,
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

    /// What to call an account wherever it is named: a card by its own name, anything else as it is.
    func accountLabel(_ id: UUID) -> String {
        guard let account = accounts.first(where: { $0.id == id }) else { return "Account" }
        return Self.isCard(account) ? cardTitle(id) : account.name
    }

    /// The page for an account: a card's own page, or every charge on anything else.
    func showAccount(_ id: UUID) {
        if let account = accounts.first(where: { $0.id == id }), Self.isCard(account), cardFacts().contains(where: { $0.id == id }) { showCard(id) }
        else { showCharges(TransactionFilter(accountID: id)) }
    }

    /// The statements of one account, newest first.
    func statements(of account: UUID) -> [SourceFile] {
        sourceFiles.filter { $0.accountID == account }.sorted { ($0.lastDate ?? "") > ($1.lastDate ?? "") }
    }

    /// Works the card facts out on another thread, so the Overview can mention a card without the
    /// main thread paying for it. The Cards pages then find them ready.
    func warmCardFacts() async {
        guard cardFactsWarm?.revision != revision, let asOf = transactions.last?.date else { return }
        let at = revision, all = transactions, cards = accounts.filter(Self.isCard).map { (id: $0.id, name: $0.name) }
        let made = await Task.detached(priority: .utility) { CardEngine.cards(cards, in: all, asOf: asOf) }.value
        guard at == revision else { return }
        cardFactsWarm = (at, made)
        readsChecked += 1
    }

    // MARK: A credit arriving

    private static let seenCreditsKey = "cardCreditsSeen"
    /// Not in a test or snapshot run: those are not the person looking.
    private static var remembersCredits: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["SPENDTHRIFT_HOME"] == nil && env["SPENDTHRIFT_SNAPSHOT"] == nil && env["SPENDTHRIFT_TIMING"] == nil
    }

    /// A card credit that has landed since the person last looked at that card: which card, which
    /// credit, and the line itself. The first time the app meets a library, everything already there
    /// counts as seen: news is only what arrives afterwards.
    func creditArrivals() -> [(card: CardEngine.Card, benefit: CardEngine.Benefit, credit: Transaction)] {
        guard let warm = cardFactsWarm, warm.revision == revision, let asOf = transactions.last?.date else { return [] }
        let every = warm.cards.flatMap { card in card.benefits.flatMap { benefit in benefit.creditIDs.map { (card, benefit, $0) } } }
        if ProcessInfo.processInfo.environment["SPENDTHRIFT_FRESH_CREDIT"] != nil {
            // For looking at the page: treat the latest credit as just arrived.
            let lines = Dictionary(transactions(withIDs: every.map(\.2)).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return every.compactMap { card, benefit, id in lines[id].map { (card, benefit, $0) } }.max { $0.2.date < $1.2.date }.map { [$0] } ?? []
        }
        guard let known = UserDefaults.standard.stringArray(forKey: Self.seenCreditsKey) else {
            if Self.remembersCredits { UserDefaults.standard.set(every.map { $0.2.uuidString }, forKey: Self.seenCreditsKey) }
            return []
        }
        let seen = Set(known), cutoff = asOf.addingTimeInterval(-60 * 86_400)
        let fresh = every.filter { !seen.contains($0.2.uuidString) }
        let lines = Dictionary(transactions(withIDs: fresh.map(\.2)).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Old lines that were never marked (a statement added late) are history, not news.
        let old = fresh.filter { (lines[$0.2]?.date ?? .distantPast) <= cutoff }.map { $0.2.uuidString }
        if !old.isEmpty, Self.remembersCredits { UserDefaults.standard.set(Array(seen.union(old)), forKey: Self.seenCreditsKey) }
        return fresh.compactMap { card, benefit, id in lines[id].flatMap { $0.date > cutoff ? (card, benefit, $0) : nil } }.sorted { $0.2.date > $1.2.date }
    }

    /// The person has seen these credits on the card's page.
    func markCreditsSeen(_ ids: [UUID]) {
        guard !ids.isEmpty, Self.remembersCredits else { return }
        let seen = Set(UserDefaults.standard.stringArray(forKey: Self.seenCreditsKey) ?? []).union(ids.map(\.uuidString))
        UserDefaults.standard.set(Array(seen), forKey: Self.seenCreditsKey)
        readsChecked += 1
    }

    /// The one card thing most worth a look right now, for the Overview: a credit not yet come with
    /// the stretch running out, a purchase that went on the wrong card, a fee about to come round.
    /// Nil until the facts have been worked out in the background: it never makes the main thread do it.
    func cardNudge() -> (card: CardEngine.Card, finding: CardEngine.Finding)? {
        guard let warm = cardFactsWarm, warm.revision == revision else { return nil }
        return warm.cards.flatMap { card in card.findings.filter { [.waiting, .wrongCard, .feeDue].contains($0.kind) }.map { (card: card, finding: $0) } }
            .max { ($0.finding.weight, $1.card.name) < ($1.finding.weight, $0.card.name) }
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
    /// The card's account, and the account's own name ("Chase ••1234").
    let id: UUID
    let name: String
    var width: CGFloat = 250
    @State private var pointed = false
    private var store: BudgetStore { .shared }

    private var issuer: String { name.components(separatedBy: "••").first?.trimmingCharacters(in: .whitespaces) ?? name }
    private var digits: String { name.components(separatedBy: "••").dropFirst().first.map { String($0.prefix(4)) } ?? "" }

    var body: some View {
        let _ = store.readsChecked
        let product = store.cardProduct(id)
        let look = product?.look ?? CardCatalog.look(forUnknown: name, issuer: BudgetStore.issuer(in: name))
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
                        // A name written small ("coinbase") is a wordmark: set larger and tight. Capitals are set small and spaced.
                        let wordmark = product.map { $0.face == $0.face.lowercased() } ?? true
                        Text(product.map { $0.face.isEmpty ? "" : $0.face } ?? issuer)
                            .font(.system(size: width * (wordmark ? 0.068 : 0.05), weight: wordmark ? .bold : .semibold, design: product == nil ? .rounded : .default))
                            .tracking(wordmark ? 0 : width * 0.01).lineLimit(1).minimumScaleFactor(0.6)
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
                    if let product, framed || product.face.lowercased() != issuer.lowercased() {
                        Text(framed ? product.face : issuer.uppercased()).font(.system(size: width * 0.04, weight: .bold)).tracking(width * 0.006)
                            .lineLimit(1).minimumScaleFactor(0.5).opacity(0.85)
                    }
                }
            }
            .foregroundStyle(ink)
            // Dark type on metal is stamped in: a line of light under each letter.
            .shadow(color: .white.opacity(look.darkInk ? 0.55 : 0), radius: 0, y: 0.7)
            .padding(width * (framed ? 0.105 : 0.07))
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
                    CardFace(id: card.id, name: card.name, width: 190)
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
                    papers(card)
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
        // The Cards page may be opened before the Overview has worked the facts out in the background.
        .task { await store.warmCardFacts() }
        // A credit that has just come gets its moment here, and is then no longer news.
        .task(id: store.readsChecked) {
            let fresh = store.creditArrivals().filter { $0.card.id == id }.map(\.credit.id)
            guard !fresh.isEmpty else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            store.markCreditsSeen(fresh)
        }
    }

    private func head(_ card: CardEngine.Card) -> some View {
        HStack(alignment: .center, spacing: 26) {
            CardFace(id: card.id, name: card.name, width: 280)
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
                let fresh = Set(store.creditArrivals().filter { $0.card.id == card.id }.map(\.credit.id))
                ForEach(Array(live.enumerated()), id: \.element.id) { index, benefit in
                    if index > 0 { Divider() }
                    BenefitRow(benefit: benefit, fresh: fresh)
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

    // MARK: Its statements

    /// The paper behind all of this: the last year of statements as a row of sheets, each one a
    /// click from the original, with a gap where a month is missing.
    @ViewBuilder private func papers(_ card: CardEngine.Card) -> some View {
        StatementStrip(account: card.id, fallbackEnd: card.last)
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
    /// Credits that landed since the person last looked: their marks arrive with a flourish.
    var fresh: Set<UUID> = []
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
                    Pip(fraction: benefit.usual > 0 ? min(1, use.received / benefit.usual) : 0, current: use.isCurrent,
                        justLanded: use.credits.contains(where: fresh.contains))
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
            HStack(spacing: 4) {
                Text(benefit.uses.first(where: { $0.id == pointed }).map(about) ?? (benefit.uses.count > 1 ? "\(span)." : " "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if pointed == nil, let shop = benefit.shops.first {
                    LinkText(text: "For \(shop)", font: .caption, help: "Open \(shop): every charge, on every card") { store.showPlace(shop) }
                }
            }
        }
    }
}

/// One stretch of a credit: a coin that is full, part full or empty, and ringed while it is still
/// running. One whose credit has just landed drops in, rings like a coin on a counter, and throws a few sparks.
private struct Pip: View {
    let fraction: Double
    let current: Bool
    var justLanded = false
    @State private var breathing = false
    @State private var landed = false

    var body: some View {
        let shownFraction = justLanded && !landed ? 0 : fraction
        ZStack {
            Circle().fill(Color.primary.opacity(0.07))
            if shownFraction > 0.02 {
                Circle().fill(Theme.good.gradient)
                    .mask(alignment: .bottom) { Rectangle().frame(height: 18 * max(0.18, shownFraction)) }
                    .transition(.scale(scale: 0.2).combined(with: .opacity))
            }
            Circle().strokeBorder(shownFraction >= 0.98 ? Theme.good : Color.primary.opacity(0.22), lineWidth: 1.2)
            if current, fraction < 0.98 {
                Circle().strokeBorder(Theme.caution, style: StrokeStyle(lineWidth: 1.6, dash: [3, 2.5]))
                    .scaleEffect(breathing ? 1.32 : 1.18).opacity(breathing ? 0.5 : 1)
                    .onAppear { withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { breathing = true } }
            }
            if justLanded {
                // The ring it sends out, and the sparks.
                Circle().strokeBorder(Theme.good, lineWidth: 1.5).scaleEffect(landed ? 2.6 : 1).opacity(landed ? 0 : 0.9)
                ForEach(0..<6, id: \.self) { i in
                    Image(systemName: "sparkle").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.goldDeep)
                        .offset(x: landed ? cos(Double(i) * .pi / 3) * 17 : 0, y: landed ? sin(Double(i) * .pi / 3) * 17 : 0)
                        .opacity(landed ? 0 : 1)
                }
            }
        }
        .frame(width: 18, height: 18)
        .scaleEffect(justLanded && landed ? 1 : justLanded ? 1.6 : 1)
        .contentShape(Circle())
        .onAppear {
            guard justLanded else { return }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.45).delay(0.6)) { landed = true }
        }
    }
}

/// The paper behind an account: its last year of statements as a row of sheets, each a click from
/// the original, with a gap where a month is missing.
struct StatementStrip: View {
    let account: UUID
    /// The last day with a line on this account, for when a statement does not say its own dates.
    var fallbackEnd: Date = .now
    private var store: BudgetStore { .shared }

    var body: some View {
        let all = store.statements(of: account)
        if let newest = all.first {
            let latest = Month(isoDay: newest.lastDate ?? "") ?? Month(date: fallbackEnd)
            let months = (0..<12).reversed().map { latest.adding(-$0) }
            let missing = Set(store.missingStatements.first { $0.accountID == account }?.months ?? [])
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        SectionHeader(title: "Where this comes from", subtitle: "\(all.count) \(all.count == 1 ? "statement" : "statements"), exactly as the bank sent them")
                        Spacer()
                        Button("All Its Statements") { store.browse(newest) }.buttonStyle(.borderless).font(.callout)
                            .help("Browse every statement of this account")
                    }
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(months) { month in
                            let sheet = all.first { ($0.lastDate.flatMap { Month(isoDay: $0) }) == month } ?? all.first { $0.monthsCovered.contains(month) }
                            Sheet(month: month, source: sheet, missing: sheet == nil && missing.contains(month))
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}

/// One month's statement as a small sheet of paper with a folded corner. Click it for the original.
private struct Sheet: View {
    let month: Month
    let source: SourceFile?
    let missing: Bool
    @State private var pointed = false
    private var store: BudgetStore { .shared }
    /// The printed lines on the sheet: a heading and four rows.
    private static let rules: [CGFloat] = [16, 22, 28, 18, 24]
    /// "Nov", and the year with it each January.
    private var label: String { String(month.name.prefix(3)) + (month.month == 1 ? " ’" + String(month.year % 100) : "") }

    var body: some View {
        let page = UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 3, bottomTrailingRadius: 3, topTrailingRadius: 10, style: .continuous)
        Button { if let source { store.browse(source) } else if missing { store.go(to: .accounts) } } label: {
            VStack(spacing: 5) {
                ZStack {
                    if source != nil {
                        page.fill(Color(red: 0.99, green: 0.98, blue: 0.95))
                        // A few printed lines.
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(Self.rules.enumerated()), id: \.offset) { i, wide in
                                Capsule().fill(Color.black.opacity(i == 0 ? 0.3 : 0.13)).frame(width: wide, height: 2)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(.leading, 7).padding(.top, 11)
                        if source?.check == "verified" {
                            Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.good)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(4)
                        }
                        page.strokeBorder(Color.black.opacity(0.12))
                    } else {
                        page.strokeBorder(missing ? Theme.caution : Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        if missing { Image(systemName: "questionmark").font(.caption.weight(.bold)).foregroundStyle(Theme.caution) }
                    }
                }
                .frame(width: 44, height: 56)
                .shadow(color: .black.opacity(source != nil ? (pointed ? 0.25 : 0.12) : 0), radius: pointed ? 6 : 2, y: pointed ? 4 : 1)
                .offset(y: pointed && source != nil ? -4 : 0)
                .rotationEffect(.degrees(pointed && source != nil ? -2 : 0))
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(source == nil && !missing)
        .onHover { inside in withAnimation(.spring(response: 0.25, dampingFraction: 0.6)) { pointed = inside } }
        .help(source.map { "Open the \($0.monthTitle) statement" + ($0.check == "verified" ? ": its lines add up to the totals it prints" : "") }
              ?? (missing ? "The \(month.title) statement seems to be missing. Open Setup to see what to add." : "No statement ending in \(month.title)"))
        .accessibilityLabel(source.map { "\($0.monthTitle) statement" } ?? "No \(month.title) statement")
    }
}

/// One line on the Overview when a card has something that will not wait: a credit not yet come as
/// its stretch runs out, a fee about to come round.
struct CardNotice: View {
    private var store: BudgetStore { .shared }

    var body: some View {
        let _ = store.readsChecked
        // A stack, so the working-out below has something to hang on while there is nothing to show.
        VStack(spacing: 0) { notice }
            .task(id: store.revision) {
                try? await Task.sleep(for: .seconds(1.2))
                guard !Task.isCancelled else { return }
                await store.warmCardFacts()
            }
    }

    @ViewBuilder private var notice: some View {
        if let arrival = store.creditArrivals().first {
            // Good news first: a credit that was being waited for has come.
            Button { store.go(to: .cards) { store.route = [.card(arrival.card.id)] } } label: {
                HStack(spacing: 12) {
                    CardFace(id: arrival.card.id, name: arrival.card.name, width: 54).allowsHitTesting(false)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("The \(Money.format(-arrival.credit.amount, cents: false)) came").font(.callout.weight(.semibold))
                        Text("\(arrival.benefit.name) landed on \(store.cardTitle(arrival.card.id)) on \(arrival.credit.date.formatted(.dateTime.month(.abbreviated).day())).")
                            .font(.callout).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Image(systemName: "sparkles").foregroundStyle(Theme.good)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Theme.good.opacity(0.1), in: .rect(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("See it on the card's page")
            .transition(.opacity)
        } else if let nudge = store.cardNudge() {
            Button { store.go(to: .cards) { store.route = [.card(nudge.card.id)] } } label: {
                HStack(spacing: 12) {
                    CardFace(id: nudge.card.id, name: nudge.card.name, width: 54).allowsHitTesting(false)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(store.cardTitle(nudge.card.id)).font(.callout.weight(.semibold))
                        Text(nudge.finding.text).font(.callout).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Theme.caution.opacity(0.08), in: .rect(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open this card")
            .transition(.opacity)
        }
    }
}
