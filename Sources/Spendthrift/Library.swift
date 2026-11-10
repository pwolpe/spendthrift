import Foundation

/// Where everything lives. Tony never needs to see this folder.
struct BudgetPaths {
    let root: URL

    init() {
        if let override = ProcessInfo.processInfo.environment["SPENDTHRIFT_HOME"] {
            root = URL(fileURLWithPath: override, isDirectory: true)   // for testing with sample data
        } else {
            root = Self.realRoot
        }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// The real data folder. The first time it is asked for, data kept under the app's earlier
    /// name is brought along (unless there is already something under the new one).
    static let realRoot: URL = {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = support.appendingPathComponent("Spendthrift", isDirectory: true)
        let earlier = support.appendingPathComponent("Appauled", isDirectory: true)
        if fm.fileExists(atPath: earlier.path), ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter({ !$0.hasPrefix(".") }).isEmpty {
            try? fm.removeItem(at: root)
            try? fm.moveItem(at: earlier, to: root)
        }
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }()

    var libraryFile: URL { root.appendingPathComponent("library.json") }
    var backupFolder: URL { root.appendingPathComponent("Backups", isDirectory: true) }
    /// Every statement exactly as it was added, so a charge can be shown in its original.
    var statementsFolder: URL { root.appendingPathComponent("Statements", isDirectory: true) }
    func statementFile(_ source: SourceFile) -> URL { statementsFolder.appendingPathComponent("\(source.id).\(source.ext)") }

    /// Daily backups, newest first.
    func backups() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: backupFolder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("library-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}

/// Everything the app saves, in one file: accounts, every statement line, and what it has
/// learned about each place. Small enough (a few MB after years) to load and save in one go.
///
/// Reading is deliberately forgiving, so a newer or older version of the app can always open
/// the file: missing fields get defaults, unknown fields are ignored, and one damaged record
/// is skipped rather than losing everything.
struct Library: Codable {
    static let currentVersion = 2
    var version = Library.currentVersion
    var accounts: [Account] = []
    var entries: [LedgerEntry] = []
    var merchants: [String: MerchantInfo] = [:]
    var importedHashes: Set<String> = []
    var dismissedDownloads: Set<String> = []
    var dismissedInsights: Set<String> = []
    var customCategories: [CustomCategory]?
    /// Trips and events the app noticed, and which data they were worked out from.
    var stories: [Story]?
    var storiesBasis: String?
    var dismissedStories: Set<String>?
    /// Charges Tony moved by hand: charge id to the trip it belongs to (a trip's fingerprint), or "" for none.
    /// These win over whatever the model decides, now and every time it looks again.
    var storyChoices: [String: String]?
    /// What the analyst noticed, and the data it was worked out from.
    var discoveries: [Discovery]?
    var discoveriesBasis: String?
    var dismissedDiscoveries: Set<String>?
    /// The same, for earlier calendar years, each worked out the first time that year is looked at.
    var discoveriesByYear: [String: YearFindings]?
    /// One-time adjustments this library has already had ("wine": bottle shops moved to Wine & Spirits).
    var adopted: Set<String>?
    /// The original statement files that were kept (see `BudgetPaths.statementsFolder`).
    var sources: [SourceFile]?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? 1
        accounts = (try? c.decodeIfPresent(Lossy<Account>.self, forKey: .accounts))?.values ?? []
        entries = (try? c.decodeIfPresent(Lossy<LedgerEntry>.self, forKey: .entries))?.values ?? []
        merchants = (try? c.decodeIfPresent(LossyDictionary<MerchantInfo>.self, forKey: .merchants))?.values ?? [:]
        importedHashes = (try? c.decodeIfPresent(Set<String>.self, forKey: .importedHashes)) ?? []
        dismissedDownloads = (try? c.decodeIfPresent(Set<String>.self, forKey: .dismissedDownloads)) ?? []
        dismissedInsights = (try? c.decodeIfPresent(Set<String>.self, forKey: .dismissedInsights)) ?? []
        customCategories = (try? c.decodeIfPresent(Lossy<CustomCategory>.self, forKey: .customCategories))?.values
        stories = (try? c.decodeIfPresent(Lossy<Story>.self, forKey: .stories))?.values
        storiesBasis = try? c.decodeIfPresent(String.self, forKey: .storiesBasis)
        dismissedStories = try? c.decodeIfPresent(Set<String>.self, forKey: .dismissedStories)
        storyChoices = try? c.decodeIfPresent([String: String].self, forKey: .storyChoices)
        discoveries = (try? c.decodeIfPresent(Lossy<Discovery>.self, forKey: .discoveries))?.values
        discoveriesBasis = try? c.decodeIfPresent(String.self, forKey: .discoveriesBasis)
        dismissedDiscoveries = try? c.decodeIfPresent(Set<String>.self, forKey: .dismissedDiscoveries)
        sources = (try? c.decodeIfPresent(Lossy<SourceFile>.self, forKey: .sources))?.values
        discoveriesByYear = try? c.decodeIfPresent([String: YearFindings].self, forKey: .discoveriesByYear)
        adopted = try? c.decodeIfPresent(Set<String>.self, forKey: .adopted)
        // Every line must belong to an account that still exists.
        let known = Set(accounts.map(\.id))
        entries.removeAll { !known.contains($0.accountID) }
    }

    enum LoadResult {
        case fresh                       // no file yet
        case loaded
        /// The main file was damaged; this is the most recent backup. The damaged file was kept aside.
        case restoredFromBackup(Date?)
        /// Damaged and no usable backup. The damaged file was kept aside; starting empty.
        case unreadable
    }

    static func load(paths: BudgetPaths) -> (Library, LoadResult) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.libraryFile.path) else { return (Library(), .fresh) }
        if let library = read(paths.libraryFile) { return (library, .loaded) }
        // Never overwrite a file we couldn't read: set it aside first.
        let stamp = DateParsing.formatter("yyyy-MM-dd-HHmmss").string(from: .now)
        try? fm.moveItem(at: paths.libraryFile, to: paths.root.appendingPathComponent("library-damaged-\(stamp).json"))
        for backup in paths.backups() {
            if let library = read(backup) {
                let date = (try? backup.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return (library, .restoredFromBackup(date))
            }
        }
        return (Library(), .unreadable)
    }

    private static func read(_ url: URL) -> Library? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return try? JSONDecoder().decode(Library.self, from: data)
    }

    /// Saves atomically, keeping one backup per day for two weeks.
    func save(paths: BudgetPaths) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        let fm = FileManager.default
        let today = paths.backupFolder.appendingPathComponent("library-\(DateParsing.iso.string(from: .now)).json")
        if fm.fileExists(atPath: paths.libraryFile.path), !fm.fileExists(atPath: today.path) {
            try? fm.createDirectory(at: paths.backupFolder, withIntermediateDirectories: true)
            try? fm.copyItem(at: paths.libraryFile, to: today)
            for old in paths.backups().dropFirst(14) { try? fm.removeItem(at: old) }
        }
        try? data.write(to: paths.libraryFile, options: .atomic)
    }
}

/// An array that skips elements it can't read instead of failing altogether.
struct Lossy<T: Decodable>: Decodable {
    var values: [T] = []
    private struct Skip: Decodable { init(from decoder: Decoder) throws {} }
    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        while !c.isAtEnd {
            if let v = try? c.decode(T.self) { values.append(v) } else { _ = try? c.decode(Skip.self) }
        }
    }
}

struct LossyDictionary<T: Decodable>: Decodable {
    var values: [String: T] = [:]
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Key.self)
        for key in c.allKeys {
            if let v = try? c.decode(T.self, forKey: key) { values[key.stringValue] = v }
        }
    }
}

// MARK: - Which place is this?

/// Turns a bank's text into a stable "place" and, when it can, an instant category.
/// Order of trust: well-known businesses, then the bank's own category, then generic words.
/// Anything left over goes to Apple Intelligence (see `BudgetStore.sortRemaining`).
enum MerchantResolver {
    /// - existingKeys: places already known, so "DICKSON'S FARMSTAND M" joins "DICKSON'S FARMSTAND".
    static func key(for description: String, amount: Double, existingKeys: some Collection<String>) -> String {
        if let known = KnownMerchants.match(description, amount: amount, generic: false) { return "known:" + known.name }
        // A wire is whoever it was sent to, not the words every wire begins with.
        if let recipient = KeywordExtractor.wireRecipient(description) { return "WIRE " + recipient }
        let keyword = KeywordExtractor.keyword(for: description)
        let shorter = existingKeys.filter { $0.count >= 6 && $0 != keyword && !$0.hasPrefix("known:") && keyword.hasPrefix($0) }
        return shorter.min { $0.count < $1.count } ?? keyword
    }

    /// A category we can give immediately, without AI. Nil means "ask the AI".
    static func instant(description: String, amount: Double, bankCategory: String?) -> MerchantInfo {
        if let known = KnownMerchants.match(description, amount: amount, generic: false) {
            let tentative = KnownMerchants.tentativeNames.contains(known.name)
            return MerchantInfo(name: known.name, category: known.category, source: tentative ? .ai : .known, confirmed: false, sample: description)
        }
        if let recipient = KeywordExtractor.wireRecipient(description) {
            return MerchantInfo(name: "Wire to " + recipient.capitalized, category: nil, source: .ai, sample: description)
        }
        let name = KeywordExtractor.displayName(for: description)
        // Once Tony has his own categories, a generic word ("CLINIC" on a vet's name) is no longer
        // good enough: let the AI weigh it against his categories.
        let generic = Category.custom.isEmpty ? KnownMerchants.match(description, generic: true) : nil
        if let bank = bankCategory.flatMap(BankCategory.map) {
            // Parking or a taxi the bank files under Travel is still getting around town.
            let siblings: Set<Category> = [.travel, .transportation]
            if let generic, generic.category == bank || (siblings.contains(generic.category) && siblings.contains(bank)) {
                return MerchantInfo(name: name, category: generic.category, source: .generic, sample: description)
            }
            // A card payment is never "Shopping", whatever the bank's column says: let the AI decide.
            if !(CategorySuggester.mightBeMoneyMovement(description) && amount < 0) {
                return MerchantInfo(name: name, category: bank, source: .bank, sample: description)
            }
        }
        if let generic {
            return MerchantInfo(name: name, category: generic.category, source: .generic, sample: description)
        }
        return MerchantInfo(name: name, category: nil, source: .ai, sample: description)
    }
}
