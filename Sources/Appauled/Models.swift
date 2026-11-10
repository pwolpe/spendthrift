import SwiftUI

// MARK: - Categories

/// A spending category: one of the built-in ones, or one Tony made himself.
/// `rawValue` is the name, and it's what gets saved.
struct Category: Hashable, Identifiable, Codable {
    let rawValue: String
    init(_ name: String) { rawValue = name }

    init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    static let groceries = Category("Groceries")
    static let dining = Category("Dining")
    static let shopping = Category("Shopping")
    static let transportation = Category("Car & Transportation")
    static let bills = Category("Bills & Utilities")
    static let subscriptions = Category("Subscriptions")
    static let health = Category("Health & Fitness")
    static let home = Category("Home")
    static let travel = Category("Travel")
    static let entertainment = Category("Entertainment")
    static let personal = Category("Personal Care")
    static let gifts = Category("Gifts & Giving")
    static let fees = Category("Fees & Interest")
    static let other = Category("Other")
    static let transfer = Category("Payments & Transfers")
    static let income = Category("Income")
    static let unsorted = Category("Unknown")
    // Kept apart from everyday life:
    static let investmentIncome = Category("Investment Income")
    static let investing = Category("Investing & Capital Calls")
    static let investmentLoan = Category("Investment Loan")
    static let taxes = Category("Income Taxes")
    /// A payment to a credit card whose statements haven't been added: the only record of that spending.
    static let uncoveredCards = Category("Cards Not Added Yet")

    private static let builtInLook: [(Category, symbol: String, color: Color)] = [
        (.groceries, "cart.fill", .green), (.dining, "fork.knife", .orange), (.shopping, "bag.fill", .pink),
        (.transportation, "car.fill", .blue), (.bills, "bolt.fill", .yellow), (.subscriptions, "play.rectangle.fill", .purple),
        (.health, "heart.fill", .red), (.home, "house.fill", .brown), (.travel, "airplane", .cyan),
        (.entertainment, "ticket.fill", .indigo), (.personal, "scissors", .mint),
        (.gifts, "gift.fill", Color(red: 0.95, green: 0.35, blue: 0.45)),
        (.fees, "building.columns.fill", Color(red: 0.45, green: 0.5, blue: 0.6)), (.other, "square.grid.2x2.fill", .teal),
        (.transfer, "arrow.left.arrow.right", .gray), (.income, "dollarsign", Color(red: 0.2, green: 0.7, blue: 0.4)),
        (.unsorted, "questionmark", Color(nsColor: .tertiaryLabelColor)),
        (.investmentIncome, "chart.line.uptrend.xyaxis", Color(red: 0.16, green: 0.55, blue: 0.47)),
        (.investing, "building.columns.circle.fill", Color(red: 0.25, green: 0.38, blue: 0.62)),
        (.investmentLoan, "percent", Color(red: 0.45, green: 0.36, blue: 0.62)),
        (.taxes, "doc.text.fill", Color(red: 0.55, green: 0.45, blue: 0.35)),
        (.uncoveredCards, "creditcard.trianglebadge.exclamationmark", Color(red: 0.85, green: 0.5, blue: 0.2)),
    ]
    private static let look: [Category: (symbol: String, color: Color)] =
        Dictionary(uniqueKeysWithValues: builtInLook.map { ($0.0, ($0.symbol, $0.color)) })

    static let investmentCases: [Category] = [.investmentIncome, .investing, .investmentLoan]
    static let builtInSpending: [Category] = builtInLook.map(\.0).filter {
        $0.lane == .everyday && $0 != .income && $0 != .unsorted && $0 != .uncoveredCards
    }

    /// Which part of Tony's money a category belongs to. Only `everyday` shows up in spending totals.
    enum Lane: String { case everyday, investments, taxes, transfers }
    var lane: Lane {
        if self == .transfer { return .transfers }
        if self == .taxes { return .taxes }
        if Self.investmentCases.contains(self) { return .investments }
        return .everyday
    }

    var id: String { rawValue }
    var displayName: String { self == .unsorted ? "Not Sorted Yet" : rawValue }
    var isBuiltIn: Bool { Self.look[self] != nil }
    var isSpending: Bool { lane == .everyday && self != .income }

    /// Tony's own categories sit right after the built-in spending ones.
    static var custom: [Category] { CustomCategories.all.map { Category($0.name) } }
    static var spendingCases: [Category] { builtInSpending + custom }
    /// Categories offered in pickers (everything except "Unknown").
    static var pickable: [Category] { spendingCases + [.transfer, .income] + investmentCases + [.taxes] }
    static var allCases: [Category] { pickable + [.uncoveredCards, .unsorted] }

    var symbol: String { Self.look[self]?.symbol ?? CustomCategories.find(rawValue)?.symbol ?? "tag.fill" }
    var color: Color { Self.look[self]?.color ?? CustomCategories.find(rawValue)?.swiftUIColor ?? .gray }
}

/// A category Tony created: a name, an icon and a color.
struct CustomCategory: Codable, Hashable, Identifiable {
    var id = UUID()
    var name: String
    var symbol: String
    var color: String

    static let palette: [(name: String, color: Color)] = [
        ("red", .red), ("orange", .orange), ("yellow", .yellow), ("green", .green), ("mint", .mint), ("teal", .teal),
        ("cyan", .cyan), ("blue", .blue), ("indigo", .indigo), ("purple", .purple), ("pink", .pink), ("brown", .brown),
    ]
    static let symbols = [
        "tag.fill", "star.fill", "pawprint.fill", "figure.and.child.holdinghands", "graduationcap.fill", "book.fill",
        "briefcase.fill", "hammer.fill", "leaf.fill", "sailboat.fill", "figure.golf", "figure.skiing.downhill",
        "tennis.racket", "dumbbell.fill", "bicycle", "tram.fill", "fuelpump.fill", "wineglass.fill", "cup.and.saucer.fill",
        "birthday.cake.fill", "music.note", "gamecontroller.fill", "camera.fill", "paintbrush.fill", "tshirt.fill",
        "stethoscope", "pills.fill", "cross.case.fill", "banknote.fill", "chart.line.uptrend.xyaxis", "building.2.fill",
        "key.fill", "wrench.and.screwdriver.fill", "phone.fill", "wifi", "desktopcomputer", "shippingbox.fill",
        "beach.umbrella.fill", "tent.fill", "heart.circle.fill", "person.2.fill", "theatermasks.fill",
    ]
    var swiftUIColor: Color { Self.palette.first { $0.name == color }?.color ?? .gray }

    init(id: UUID = UUID(), name: String, symbol: String, color: String) {
        self.id = id; self.name = name; self.symbol = symbol; self.color = color
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        symbol = (try? c.decodeIfPresent(String.self, forKey: .symbol)) ?? "tag.fill"
        color = (try? c.decodeIfPresent(String.self, forKey: .color)) ?? "blue"
    }
}

/// The current list of custom categories, readable from anywhere (colors and icons are looked up
/// while drawing, off the main actor too). `BudgetStore` keeps it in step with the saved library.
enum CustomCategories {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var list: [CustomCategory] = []

    static var all: [CustomCategory] {
        lock.lock(); defer { lock.unlock() }
        return list
    }
    static func set(_ new: [CustomCategory]) {
        lock.lock(); defer { lock.unlock() }
        list = new
    }
    static func find(_ name: String) -> CustomCategory? { all.first { $0.name == name } }
}

// MARK: - What's saved on disk

/// One line from a statement, exactly as the bank wrote it.
struct LedgerEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var accountID: UUID
    var date: String            // yyyy-MM-dd
    var description: String
    /// Positive = money spent, negative = credit/refund/payment.
    var amount: Double
    /// The bank's own category for this line, when the export has one.
    var bankCategory: String?
    /// Which place this is (see `MerchantResolver`); all lines from one place share a key.
    var merchantKey: String
    /// Set when this one line was given a category different from its place.
    var override: Category?
    /// Anything the person remembers about this charge ("deposit for the Mongolia trip"). Optional; the AI reads it.
    var note: String?

    var dedupeKey: String { "\(date)|\(description.uppercased())|\(String(format: "%.2f", amount))" }

    init(id: UUID = UUID(), accountID: UUID, date: String, description: String, amount: Double,
         bankCategory: String? = nil, merchantKey: String, override: Category? = nil) {
        self.id = id; self.accountID = accountID; self.date = date; self.description = description
        self.amount = amount; self.bankCategory = bankCategory; self.merchantKey = merchantKey; self.override = override
    }

    /// Forgiving: only the essentials are required, so files from other versions of the app still open.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        accountID = try c.decode(UUID.self, forKey: .accountID)
        date = try c.decode(String.self, forKey: .date)
        description = (try? c.decodeIfPresent(String.self, forKey: .description)) ?? "(no description)"
        amount = try c.decode(Double.self, forKey: .amount)
        bankCategory = try? c.decodeIfPresent(String.self, forKey: .bankCategory)
        merchantKey = (try? c.decodeIfPresent(String.self, forKey: .merchantKey))
            ?? MerchantResolver.key(for: description, amount: amount, existingKeys: [String]())
        override = try? c.decodeIfPresent(Category.self, forKey: .override)
        note = try? c.decodeIfPresent(String.self, forKey: .note)
    }
}

/// What the app knows about a place: its tidy name and its category, and who decided.
struct MerchantInfo: Codable, Hashable {
    /// `cloud` = the powerful model was sure; `cloudGuess` = it said it was guessing.
    enum Source: String, Codable { case user, known, bank, generic, ai, cloud, cloudGuess }
    /// Guesses nobody has confirmed: these are what Double-Check lists.
    var isUnconfirmedGuess: Bool { !confirmed && (source == .ai || source == .cloudGuess || category == nil) }
    var name: String
    var category: Category?
    var source: Source
    /// True once Tony has confirmed or changed it. AI guesses start unconfirmed.
    var confirmed = false
    /// An original bank description, shown so Tony can recognize the place.
    var sample: String
    /// The business's website ("starbucks.com"), used to show its logo. Empty = looked for, none known.
    var domain: String?
    /// What the person wants remembered about this place ("only when the in-laws visit"). Optional; the AI reads it.
    var note: String?
    /// True once this place has been looked up on the web, found or not: it is only ever paid for once.
    var lookedUp: Bool?

    init(name: String, category: Category?, source: Source, confirmed: Bool = false, sample: String) {
        self.name = name; self.category = category; self.source = source; self.confirmed = confirmed; self.sample = sample
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Unnamed"
        category = try? c.decodeIfPresent(Category.self, forKey: .category)
        // A source this version doesn't know about is treated as a guess.
        source = (try? c.decodeIfPresent(String.self, forKey: .source)).flatMap(Source.init(rawValue:)) ?? .ai
        confirmed = (try? c.decodeIfPresent(Bool.self, forKey: .confirmed)) ?? false
        sample = (try? c.decodeIfPresent(String.self, forKey: .sample)) ?? name
        domain = try? c.decodeIfPresent(String.self, forKey: .domain)
        note = try? c.decodeIfPresent(String.self, forKey: .note)
        lookedUp = try? c.decodeIfPresent(Bool.self, forKey: .lookedUp)
    }
}

struct Account: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    /// Identifies this account's file "shape" so future statements go to the right place.
    var signature: String
    var lastImport: Date?
    /// Set by "Amounts Look Backwards": this bank's files have purchases and payments swapped.
    var invertAmounts: Bool?
    /// Months some statement of this account says it covers, whether or not anything was bought then.
    var statementMonths: Set<String>?
    /// Earlier card numbers of this same account (a card that was reissued), so their statements still land here.
    var formerSignatures: [String]?

    init(name: String, signature: String) { self.name = name; self.signature = signature }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Account"
        signature = (try? c.decodeIfPresent(String.self, forKey: .signature)) ?? ""
        lastImport = try? c.decodeIfPresent(Date.self, forKey: .lastImport)
        invertAmounts = try? c.decodeIfPresent(Bool.self, forKey: .invertAmounts)
        statementMonths = try? c.decodeIfPresent(Set<String>.self, forKey: .statementMonths)
        formerSignatures = try? c.decodeIfPresent([String].self, forKey: .formerSignatures)
    }
}

// MARK: - Transactions (what the screens show)

struct Transaction: Identifiable, Hashable {
    let id: UUID
    let date: Date
    let month: Month
    let description: String
    /// Positive = money spent, negative = credit/refund/payment.
    let amount: Double
    let merchant: String
    let merchantKey: String
    let category: Category
    let account: String
    let accountID: UUID
    let source: MerchantInfo.Source
    /// An AI guess (or no guess) that Tony hasn't looked at yet.
    let needsCheck: Bool
    /// This line has its own category, different from the rest of the place.
    let isOverride: Bool
    /// What the person wrote about this charge, if anything.
    var note: String? = nil

    var isUnknown: Bool { category == .unsorted }
    var isTransfer: Bool { category == .transfer }
    var isIncome: Bool { category == .income }
    var lane: Category.Lane { category.lane }
    /// Everyday spending only: not salary, transfers, taxes or anything on the investment side.
    /// A deposit nobody has labelled yet is left out too: it's far more likely income or a transfer than a refund.
    var countsAsSpending: Bool { category.isSpending && !isUnsortedDeposit }
    var isUnsortedDeposit: Bool { isUnknown && amount < 0 }
    var merchantDisplay: String { merchant }
    var categorySortKey: String { category.displayName }
}

/// A calendar month, e.g. "2026-10".
struct Month: Hashable, Comparable, Identifiable {
    let year: Int
    let month: Int

    init(year: Int, month: Int) { self.year = year; self.month = month }
    init(date: Date) {
        let c = Calendar.current.dateComponents([.year, .month], from: date)
        year = c.year ?? 2000
        month = c.month ?? 1
    }
    init?(key: String) {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        year = parts[0]; month = parts[1]
    }

    var id: String { key }
    var key: String { String(format: "%04d-%02d", year, month) }
    var firstDay: Date { Calendar.current.date(from: DateComponents(year: year, month: month, day: 1)) ?? .now }
    var name: String { firstDay.formatted(.dateTime.month(.wide)) }
    var title: String { firstDay.formatted(.dateTime.month(.wide).year()) }
    var shortName: String { firstDay.formatted(.dateTime.month(.abbreviated)) }

    func adding(_ months: Int) -> Month {
        let d = Calendar.current.date(byAdding: .month, value: months, to: firstDay) ?? firstDay
        return Month(date: d)
    }

    static func < (a: Month, b: Month) -> Bool { (a.year, a.month) < (b.year, b.month) }
}

// MARK: - Import mapping

struct ColumnMapping: Codable, Hashable {
    var dateColumn: Int
    var dateFormat: String
    var descriptionColumn: Int
    /// Single signed amount column. When nil, `debitColumn`/`creditColumn` are used.
    var amountColumn: Int?
    var debitColumn: Int?
    var creditColumn: Int?
    /// For a single amount column: true if purchases show up as negative numbers.
    var purchasesAreNegative: Bool
    /// A column of "Debit"/"Credit" words that gives the direction when amounts are all positive.
    var typeColumn: Int?
}

/// A place Tony already sorted, given to the AI as an example of his habits.
struct MerchantRule: Hashable {
    var name: String
    var category: Category
}

struct Suggestion: Hashable {
    enum Source: Hashable { case knownMerchant, bank, appleIntelligence }
    var name: String
    var category: Category
    var source: Source
}

/// A file the app couldn't work out by itself (rare): needs columns picked or an account chosen.
struct PendingImport: Identifiable {
    let id = UUID()
    let fileURL: URL
    let fileHash: String
    let table: CSVTable
    var mapping: ColumnMapping?
    let candidates: [Account]
    let suggestedName: String
    let signature: String
}

/// One place waiting in Double-Check.
struct ReviewItem: Identifiable, Hashable {
    var id: String { key }
    let key: String
    let info: MerchantInfo
    let count: Int
    let total: Double
}

/// For one card issuer: what the bank account paid it, and how much of that the added statements explain.
struct CardCoverage: Identifiable, Hashable {
    var id: String { issuer }
    let issuer: String
    var paid = 0.0
    var payments = 0
    /// Payments with no card statement covering the weeks before them.
    var uncoveredPaid = 0.0
    var uncoveredPayments = 0
    var statementSpend = 0.0
    var accounts: [String] = []
}

/// Months an account has no statement for, though the months around them (or other accounts) do.
struct MissingStatements: Identifiable, Hashable {
    var id: UUID { accountID }
    let accountID: UUID
    let account: String
    let months: [Month]

    var summary: String {
        let names = months.prefix(4).map(\.name)
        let list = names.count <= 2 ? names.joined(separator: " and ")
            : names.dropLast().joined(separator: ", ") + " and " + (months.count > 4 ? "\(months.count - 3) more" : names.last!)
        return "\(account): nothing for \(list)"
    }
}

/// A file from the last import that couldn't be added, with a plain-English reason.
struct ImportIssue: Identifiable, Hashable {
    let id = UUID()
    let file: String
    let reason: String
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let symbol: String
    var offersUndo = false
}

enum SidebarItem: Hashable {
    case overview, cashflow, stories, transactions, report, ask, review, categories, accounts
}

/// "New Category…" was chosen somewhere; `then` receives the category once it's made.
struct CategoryEditorRequest: Identifiable {
    let id = UUID()
    var editing: CustomCategory?
    var then: (Category) -> Void = { _ in }
}

struct TransactionFilter: Equatable {
    var category: Category?
    var month: Month?
    var accountID: UUID?
    var merchantKey: String?
    /// A place by its tidy name, however many ways it is spelled on statements.
    var merchant: String?
    var needsCheck = false
    /// Only the charges that belong to one trip or event.
    var storyID: UUID?
    /// A hand-picked set of charges (something the analyst noticed), and what to call it.
    var ids: Set<UUID>?
    var title: String?
}

/// Something the model noticed reading every charge: a subscription paid twice, a habit that adds
/// up, a fee nobody would choose to pay. The model picks the charges; the app adds them up.
struct Discovery: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var detail: String
    var kind: String
    var entryIDs: [UUID]

    init(title: String, detail: String, kind: String, entryIDs: [UUID]) {
        self.title = title; self.detail = detail; self.kind = kind; self.entryIDs = entryIDs
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        title = try c.decode(String.self, forKey: .title)
        detail = (try? c.decodeIfPresent(String.self, forKey: .detail)) ?? ""
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "other"
        entryIDs = (try? c.decodeIfPresent([UUID].self, forKey: .entryIDs)) ?? []
    }

    var symbol: String {
        switch kind {
        case "subscription": "repeat.circle.fill"
        case "duplicate": "equal.circle.fill"
        case "increase": "arrow.up.circle.fill"
        case "fees": "building.columns.circle.fill"
        case "habit": "flame.circle.fill"
        case "mistake": "exclamationmark.circle.fill"
        case "tax": "doc.text.fill"
        default: "sparkle"
        }
    }
}

/// A trip or an event the app noticed in the spending: a run of charges that belong together.
/// Which charges belong is the model's call; every number shown is added up in code.
struct Story: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case trip, event }
    var id = UUID()
    var kind: Kind
    var name: String
    var place: String?
    var start: String          // yyyy-MM-dd
    var end: String
    var summary: String
    var entryIDs: [UUID]

    /// Stable across re-detection, so a story Tony dismissed stays dismissed.
    var fingerprint: String { "\(kind.rawValue)|\(name.lowercased())|\(start.prefix(7))" }

    init(kind: Kind, name: String, place: String?, start: String, end: String, summary: String, entryIDs: [UUID]) {
        self.kind = kind; self.name = name; self.place = place; self.start = start; self.end = end
        self.summary = summary; self.entryIDs = entryIDs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)).flatMap(Kind.init(rawValue:)) ?? .trip
        name = try c.decode(String.self, forKey: .name)
        place = try? c.decodeIfPresent(String.self, forKey: .place)
        start = try c.decode(String.self, forKey: .start)
        end = (try? c.decodeIfPresent(String.self, forKey: .end)) ?? start
        summary = (try? c.decodeIfPresent(String.self, forKey: .summary)) ?? ""
        entryIDs = (try? c.decodeIfPresent([UUID].self, forKey: .entryIDs)) ?? []
    }
}

// MARK: - Formatting

enum Money {
    static let currencyCode = Locale.current.currency?.identifier ?? "USD"

    static func format(_ value: Double, cents: Bool = true) -> String {
        value.formatted(.currency(code: currencyCode).precision(.fractionLength(cents ? 2 : 0)))
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
