import Foundation
import Observation

/// Optional: a powerful cloud model (through OpenRouter) for the jobs where Apple's small
/// on-device model struggles. Off until a key is entered in Settings. When it's on:
///
///  - places the built-in rules don't know are sorted by the cloud model (merchant text and amounts only);
///  - statements the app can't read are read by it, after name, address and account numbers are blanked;
///  - it understands questions in Ask the Academy and writes the recap and nomination lines.
///
/// Totals are always computed in code. If the cloud can't be reached, everything falls back to
/// the on-device paths, so the app never depends on it.
enum CloudAI {
    static let defaultModel = "anthropic/claude-sonnet-5.5"
    static let models: [(id: String, label: String)] = [
        ("anthropic/claude-haiku-5.5", "Claude Haiku 5.5 · fastest, lowest cost"),
        ("anthropic/claude-sonnet-5.5", "Claude Sonnet 5.5 · recommended"),
        ("anthropic/claude-opus-5.5", "Claude Opus 5.5 · most capable"),
    ]

    static var model: String {
        get { UserDefaults.standard.string(forKey: "cloudModel") ?? defaultModel }
        set { UserDefaults.standard.set(newValue, forKey: "cloudModel") }
    }
    /// Reading whole statements sends more than merchant names, so it has its own switch.
    static var readsStatements: Bool {
        get { UserDefaults.standard.object(forKey: "cloudReadsStatements") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "cloudReadsStatements") }
    }

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["TONY_AWARDS_NO_CLOUD"] == nil && CloudKey.exists
    }
    static var canReadStatements: Bool { isEnabled && readsStatements }

    enum CloudError: LocalizedError {
        case noKey, badKey, outOfCredit, unreachable, server(Int), badReply
        var errorDescription: String? {
            switch self {
            case .noKey: "No key has been entered."
            case .badKey: "OpenRouter didn't accept that key. Check it was copied completely."
            case .outOfCredit: "The OpenRouter account is out of credit or over its limit."
            case .unreachable: "OpenRouter couldn't be reached. Check the internet connection."
            case .server(let code): "OpenRouter had a problem (error \(code)). Try again in a minute."
            case .badReply: "The reply couldn't be understood."
            }
        }
    }

    /// One request. `json: true` asks for (and returns) a JSON object.
    /// - maxTokens: room for the whole reply, including any thinking the model does before it
    ///   writes. Too little and the answer is cut off mid-sentence, so be generous.
    /// - effort: how hard the model should think first ("low", "medium", "high"); nil = its default.
    static func complete(system: String, user: String, json: Bool, maxTokens: Int, temperature: Double = 0,
                         timeout: TimeInterval = 90, effort: String? = nil) async throws -> String {
        guard let key = CloudKey.load() else { throw CloudError.noKey }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("The Tony Awards", forHTTPHeaderField: "X-Title")
        var body: [String: Any] = [
            // A decision model can't write text; jobs that need writing use the default model.
            "model": DecisionSorter.handles(model) ? defaultModel : model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "max_tokens": maxTokens,
            "temperature": temperature,
        ]
        if json { body["response_format"] = ["type": "json_object"] }
        if let effort { body["reasoning"] = ["effort": effort] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var lastError: CloudError = .unreachable
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                switch status {
                case 200:
                    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let choices = object["choices"] as? [[String: Any]],
                          let message = choices.first?["message"] as? [String: Any],
                          let content = message["content"] as? String, !content.isEmpty else { throw CloudError.badReply }
                    // Cut off for length: a partial answer is worse than none (half a JSON object).
                    if (choices.first?["finish_reason"] as? String) == "length" {
                        if ProcessInfo.processInfo.environment["TONY_AWARDS_SNAPSHOT"] != nil { print("DEBUG CLOUD reply cut off at \(maxTokens) tokens") }
                        throw CloudError.badReply
                    }
                    await CloudStatus.shared.note(error: nil)
                    return content
                case 401, 403: lastError = .badKey
                case 402: lastError = .outOfCredit
                case 429, 500...599: lastError = .server(status); continue      // worth one more try
                default: lastError = .server(status)
                }
                break
            } catch let error as CloudError {
                lastError = error; break
            } catch {
                lastError = .unreachable
            }
        }
        await CloudStatus.shared.note(error: lastError)
        throw lastError
    }

    /// Pulls the JSON object out of a reply, tolerating code fences or a stray sentence around it.
    static func object(from reply: String) -> [String: Any]? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let data = String(reply[start...end]).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A tiny request to prove the key works.
    static func test() async -> String? {
        do {
            _ = try await complete(system: "Reply with the single word OK.", user: "Hello", json: false, maxTokens: 5, timeout: 30)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
        }
    }
}

/// What Settings shows about the cloud connection.
@MainActor @Observable
final class CloudStatus {
    static let shared = CloudStatus()
    private(set) var lastError: String?
    private(set) var hasKey = CloudKey.exists
    private(set) var requests = 0

    func note(error: CloudAI.CloudError?) {
        requests += 1
        lastError = error?.errorDescription
    }
    func refreshKey() { hasKey = CloudKey.exists; if !hasKey { lastError = nil } }
}

/// The OpenRouter key lives in a private file in the data folder: never in the app, the library file, or a backup.
enum CloudKey {
    nonisolated(unsafe) private static var cached: String??
    private static let lock = NSLock()

    /// A dot-file in the home folder also works, and wins if present: handy for setting a Mac up
    /// from Terminal without opening Settings.  pbpaste > ~/.tony-awards-key && chmod 600 ~/.tony-awards-key
    private static let dotFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".tony-awards-key")

    /// Why a file and not the keychain: macOS ties keychain access to the exact build of an app
    /// unless it's signed with an Apple Developer ID. Every update would make Tony type his Mac
    /// password into a "wants to use your confidential information" dialog, and the app would
    /// freeze behind it. A file only his user account can read asks for nothing, ever. It always
    /// lives in the real data folder, never a test folder, and is not part of any backup the app makes.
    private static let file: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("Tony Awards", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("ai-key")
    }()

    static var exists: Bool { load() != nil }

    static func load() -> String? {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let read = { (url: URL) -> String? in
            let value = (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        let key = read(dotFile) ?? read(file)
        cached = .some(key)
        return key
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }
        lock.lock(); defer { lock.unlock() }
        do {
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            cached = .some(trimmed)
            return true
        } catch {
            return false
        }
    }

    static func delete() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: dotFile)
        cached = .some(nil)
    }
}

// MARK: - Blanking personal details

enum Redactor {
    private static func replace(_ text: String, _ pattern: String, _ with: String, options: NSRegularExpression.Options = []) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return text }
        return re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: with)
    }

    /// For a merchant line: reference numbers, phone numbers and emails add nothing and are removed.
    static func scrub(_ description: String) -> String {
        var s = description
        s = replace(s, #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "", options: .caseInsensitive)
        s = replace(s, #"\(?\b\d{3}\)?[ .-]\d{3}[ .-]\d{4}\b"#, "")
        // Long IDs like 000652456372 or IN1620135574041: words that are mostly digits. (A merchant
        // name with a few digits in it, like "7ELEVEN 34567" or "AMZN MKTP US*2K4AB1", keeps its words.)
        var words: [String] = []
        for piece in s.split(whereSeparator: { $0.isWhitespace }) {
            let word = String(piece)
            let digits = word.filter { $0.isNumber }.count
            if digits >= 6 && digits * 2 >= word.count { continue }
            words.append(word)
        }
        let kept = words.joined(separator: " ")
        // Never send an empty line: if everything looked like an ID, the original is all there is to go on.
        if kept.filter(\.isLetter).count >= 3 { return kept }
        return description.split(whereSeparator: \.isWhitespace).map(String.init).joined(separator: " ")
    }

    /// The account holder's name as printed on a statement: it sits on the line above the street
    /// address. Other text can share that line ("PAUL WOLPE  We accept operator relay calls"), so
    /// only the leading capitalized words are taken.
    static func holderNames(in statement: String) -> Set<String> {
        let lines = statement.components(separatedBy: .newlines)
        guard let street = try? NSRegularExpression(
            pattern: #"^\s*\d{1,6}\s+[A-Za-z0-9 .'-]*\b(ST|STREET|AVE|AVENUE|RD|ROAD|BLVD|BOULEVARD|DR|DRIVE|LN|LANE|WAY|PL|PLACE|CT|COURT|TER|TERRACE|PKWY|HWY|SQ|CIR)\b.*$"#,
            options: .caseInsensitive) else { return [] }
        // Words that appear in capitals on statements but are never part of a person's name.
        let notNames: Set<String> = ["PAYMENT", "BALANCE", "DUE", "DATE", "STATEMENT", "ACCOUNT", "NEW", "MINIMUM", "TOTAL", "AMOUNT",
                                     "ENCLOSED", "SUMMARY", "CARD", "CARDS", "CASH", "CREDIT", "PAGE", "PERIOD", "BANK", "BOX", "PO",
                                     "MEMBER", "SINCE", "CUSTOMER", "SERVICE", "PLATINUM", "CHECKING", "SAVINGS", "PLEASE", "YOUR", "THE"]
        var names: Set<String> = []
        for i in lines.indices {
            let line = lines[i]
            guard street.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil,
                  line.range(of: #"(?i)^\s*P\.?\s?O\.?\s+BOX\b"#, options: .regularExpression) == nil else { continue }
            // Usually the line directly above; page layout can slip another row in between. Further up,
            // only accept a line that is nothing but a name, so ordinary capitalized text isn't taken.
            for above in stride(from: i - 1, through: max(0, i - 3), by: -1) where above >= 0 {
                let all = lines[above].split(separator: " ")
                var words: [Substring] = []
                for word in all {
                    let letters = word.filter(\.isLetter)
                    guard !letters.isEmpty, word.allSatisfy({ $0.isLetter || $0 == "." || $0 == "'" || $0 == "-" }),
                          word == word.uppercased(), !notNames.contains(String(word)), words.count < 4 else { break }
                    words.append(word)
                }
                let wholeLine = words.count == all.count
                if words.count >= 2, words.contains(where: { $0.count >= 3 }), above == i - 1 || wholeLine {
                    names.insert(words.joined(separator: " ")); break
                }
            }
        }
        return names
    }

    /// For a whole statement: the holder's name, street address, city/ZIP, email, phone and
    /// account or card numbers are replaced before the text leaves the Mac.
    static func blank(_ statement: String) -> String {
        var lines = statement.components(separatedBy: .newlines)
        let street = try? NSRegularExpression(
            pattern: #"^\s*\d{1,6}\s+[A-Za-z0-9 .'-]*\b(ST|STREET|AVE|AVENUE|RD|ROAD|BLVD|BOULEVARD|DR|DRIVE|LN|LANE|WAY|PL|PLACE|CT|COURT|TER|TERRACE|PKWY|HWY|SQ|CIR)\b.*$"#,
            options: .caseInsensitive)
        let poBox = try? NSRegularExpression(pattern: #"^\s*P\.?\s?O\.?\s+BOX\b.*$"#, options: .caseInsensitive)
        let cityZip = try? NSRegularExpression(pattern: #"^\s*[A-Za-z .'-]+,?\s+[A-Z]{2}\s+\d{5}(-\d{4})?\s*$"#)
        func matches(_ re: NSRegularExpression?, _ s: String) -> Bool {
            re?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }
        var names = holderNames(in: statement)
        // Statements also print "Account holder: Jane Q. Public"-style labels.
        // The label may be in any case, but the name itself must be capitalized words after a colon
        // (otherwise "cardmember you have…" would turn "have" into a name).
        if let re = try? NSRegularExpression(pattern: #"\b(?i:account holder|customer name|card ?member name|prepared for|passenger name):\s*([A-Z][A-Za-z.'-]+(?: [A-Z][A-Za-z.'-]+){1,3})"#) {
            for m in re.matches(in: statement, range: NSRange(statement.startIndex..., in: statement)) {
                if let r = Range(m.range(at: 1), in: statement) { names.insert(String(statement[r])) }
            }
        }
        for i in lines.indices {
            if matches(street, lines[i]) { lines[i] = "[address]" }
            else if matches(cityZip, lines[i]) { lines[i] = "[city, state, zip]" }
            else if lines[i].range(of: #"^\s*(APT|UNIT|SUITE|STE|#)\s*\w+\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil { lines[i] = "[address]" }
        }
        var text = lines.joined(separator: "\n")
        for name in names.sorted(by: { $0.count > $1.count }) {
            text = text.replacingOccurrences(of: name, with: "[name]", options: .caseInsensitive)
            // "WOLPE /WI-FI" style mentions of the surname alone.
            if let last = name.split(separator: " ").last, last.count >= 4 {
                text = replace(text, "\\b" + NSRegularExpression.escapedPattern(for: String(last)) + "\\b", "[name]", options: .caseInsensitive)
            }
            // "Paul Michael [name]", "PAUL M [name]": the first name with middle names or initials.
            if let first = name.split(separator: " ").first, first.count >= 3 {
                text = replace(text, "\\b" + NSRegularExpression.escapedPattern(for: String(first)) + #"(?:\s+[A-Za-z]+\.?){0,2}\s+\[name\]"#,
                               "[name]", options: .caseInsensitive)
            }
        }
        text = replace(text, #"\[name\]\s*/\s*[A-Za-z]+"#, "[name]")          // airline style "SURNAME/FIRST"
        text = replace(text, #"\b[Xx*•]{2,}\d{4}\b"#, "[number]")          // the bank's own masking, "Xxxx1234"
        text = replace(text, #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "[email]", options: .caseInsensitive)
        // A city, state and ZIP anywhere in a line, and "ending in 1234"-style card or account digits.
        text = replace(text, #"\b[A-Z][A-Za-z.'-]+(?: [A-Z][A-Za-z.'-]+){0,2},? [A-Z]{2} \d{5}(?:-\d{4})?\b"#, "[city, state, zip]")
        text = replace(text, #"(?i)\b(ending(?: in)?|account(?: number| no\.?| #)?|acct\.?|card(?: number| no\.?)?)[:#\s]+[x*•.\d -]*\d{4,5}\b"#, "$1 [number]")
        text = replace(text, #"\b\d{4}[ -]\d{4}[ -]\d{4}[ -]\d{1,4}\b"#, "[number]")
        text = replace(text, #"\b\d{4}[ -]\d{6}[ -]\d{5}\b"#, "[number]")
        text = replace(text, #"\b[A-Za-z]*\d[A-Za-z0-9]{7,}\b"#, "[number]")
        text = replace(text, #"\b\d-\d{5}\b"#, "[number]")                 // Amex "0-44003"
        return text
    }
}

// MARK: - Job 1: sorting places

struct CloudItem {
    let key: String
    let description: String
    let averageAmount: Double
    let count: Int
    let bankCategory: String?
    /// A few of the actual amounts: "the same $5,502.29 every month" says loan, not card payment.
    var amounts: [Double] = []
    /// What the app's own rules guessed, if anything.
    var appGuess: String?
    /// What the person wrote about charges at this place.
    var notes: [String] = []
}

struct CloudVerdict: Sendable {
    let name: String
    let category: Category
    /// False when the model is guessing (e.g. a payment to a person): those go to Double-Check.
    let confident: Bool
    /// The business's website, when it's a business with one ("dunkindonuts.com").
    var domain: String? = nil
}

/// Finds the website of businesses by name, so their logos can be shown.
enum LogoFinder {
    /// name → domain ("" when it isn't a business with a website, or the model doesn't know it).
    static func domains(for names: [String]) async -> [String: String]? {
        guard !names.isEmpty else { return [:] }
        let system = """
        For each numbered business or payee, give the main website domain of that business (for example \
        "starbucks.com", "coned.com", "united.com"), lower case, without "www". Use null when it is a person, a \
        generic description ("Card Payment", "Cash Withdrawal", "Check Deposit"), a small local place whose \
        website you don't actually know, or anything you aren't sure about. Never invent a domain.
        Reply with JSON only: {"sites": [{"id": 1, "domain": "example.com"}]}
        """
        let listing = names.enumerated().map { "\($0 + 1). \($1)" }.joined(separator: "\n")
        let reply = await Timeout.run(90) {
            try? await CloudAI.complete(system: system, user: listing, json: true, maxTokens: 60 * names.count + 3_000, timeout: 80)
        }
        guard let reply, let sites = CloudAI.object(from: reply)?["sites"] as? [[String: Any]] else { return nil }
        var out: [String: String] = Dictionary(uniqueKeysWithValues: names.map { ($0, "") }.reduce(into: [(String, String)]()) { acc, pair in
            if !acc.contains(where: { $0.0 == pair.0 }) { acc.append(pair) }
        })
        for site in sites {
            guard let id = (site["id"] as? Int) ?? (site["id"] as? String).flatMap(Int.init), (1...names.count).contains(id) else { continue }
            out[names[id - 1]] = clean(site["domain"] as? String) ?? ""
        }
        return out
    }

    /// "https://www.Starbucks.com/menu" → "starbucks.com"; nil for anything that isn't a plain domain.
    static func clean(_ raw: String?) -> String? {
        guard var d = raw?.lowercased().trimmingCharacters(in: .whitespaces), !d.isEmpty, d != "null" else { return nil }
        for prefix in ["https://", "http://", "www."] where d.hasPrefix(prefix) { d.removeFirst(prefix.count) }
        d = String(d.split(separator: "/").first ?? "")
        guard d.contains("."), d.count <= 60, d.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        return d
    }
}

enum CloudSorter {
    static func instructions(examples: [MerchantRule]) -> String {
        let custom = Category.custom.map(\.rawValue)
        var text = """
        You sort bank and credit card transactions for a personal budgeting app. For each numbered item, give a tidy \
        name for the business or payee and exactly one category from this list (use the names exactly):

        Everyday spending: \(Category.spendingCases.map(\.rawValue).joined(separator: "; "))
        Income: salary, payroll, and other earnings
        Payments & Transfers: paying a credit card bill, or moving money between the person's own accounts
        Investment Income: distributions, dividends, interest
        Investing & Capital Calls: capital calls, brokerage or crypto purchases and sales, redemptions
        Investment Loan: advances, principal and interest on a loan used for investing
        Income Taxes: payments to or refunds from the IRS or a state tax department

        Rules:
        - "direction" says whether money went out or came in. A refund goes in the category of what was bought.
        - Restaurants, bars, cafes and food delivery are Dining; supermarkets, butchers and food shops are Groceries.
        - Software, apps and online services billed regularly are Subscriptions. Property tax, mortgage, rent, condo \
        fees, furniture and repairs are Home. Insurance, phone, internet and power are Bills & Utilities.
        - Name a credit card bill payment "<Issuer> Card Payment" (for example "Chase Card Payment").
        - Saving is not spending. Money moved into a brokerage, retirement account (IRA, 401k), 529 plan, \
        robo-advisor, crypto exchange, private fund or other investment is "Investing & Capital Calls", never an \
        everyday spending category, even though the money left the bank account. Getting this right matters more \
        than anything else here: the app tells the person whether they spent more than they earned.
        - But living costs are spending, however they are paid: a mortgage, rent, a car loan, a student loan, \
        insurance and property tax are never investing. Only "Investment Loan" is for a loan taken out to invest.
        - "Payments & Transfers" is only for paying one's own credit card or moving money between one's own accounts. \
        Money sent to another person or a business by Zelle, Venmo, PayPal, wire or check is spending: choose the \
        category it most likely is, or Other, and set confident to false so the person can say what it was.
        - "notes", when present, are what the person wrote about these charges in their own words. They know what \
        happened: let a note decide the category and whether you are confident.
        - If "bank_category" is given it is the bank's own guess, and "app_guess" is this app's: useful hints, often too \
        broad. Decide for yourself.
        - "amounts" lists some of the actual amounts. A credit card bill payment changes every month. The same fixed \
        amount paid to a bank or lender every month is a mortgage or loan payment: name it for what it is ("Chase Mortgage \
        or Loan") and file it under Home unless the text says otherwise. Never call it a card payment.
        - Prefixes are payment processors, not the business: "TST*" (Toast) and "SQ *" (Square) are almost always \
        restaurants, cafes or small shops; "SP " is a Shopify store; "PY *"/"PAYPAL *" precede the real seller.
        - Name: how a person would say it ("Dickson's Farmstand Meats", "Con Edison"). No store numbers, cities, \
        states or payment-processor prefixes. Under 40 characters.
        - confident: true whenever you can tell what kind of business or payment it is, even one you have never heard \
        of (a restaurant name, a shop, a utility, a school). Set confident to false only when the purpose truly can't be \
        known from the text: payments to individuals (Zelle, Venmo, Apple Cash), checks, cash withdrawals, unlabelled \
        deposits, or a name that could be several unrelated things. Expect that to be rare.
        """
        if !custom.isEmpty {
            text += "\n- The person made their own categories: \(custom.joined(separator: ", ")). Prefer one of them whenever an item fits it."
        }
        if !examples.isEmpty {
            let lines = examples.suffix(40).map { "\($0.name): \($0.category.rawValue)" }.joined(separator: "\n")
            text += "\n\nPlaces this person already sorted. Follow the same habits:\n\(lines)"
        }
        text += "\n- website: the business's main website domain (\"starbucks.com\"), lower case, when you actually know it; otherwise null. Never invent one."
        text += "\n\nReply with JSON only: {\"results\": [{\"id\": 1, \"name\": \"…\", \"category\": \"…\", \"confident\": true, \"website\": null}]} with one result per item."
        return text
    }

    /// Nil when the cloud couldn't be used (the caller falls back to on-device sorting).
    static func sort(_ items: [CloudItem], examples: [MerchantRule]) async -> [String: CloudVerdict]? {
        guard !items.isEmpty else { return [:] }
        if DecisionSorter.handles(CloudAI.model) { return await DecisionSorter.sort(items, examples: examples) }
        let payload: [[String: Any]] = items.enumerated().map { i, item in
            var entry: [String: Any] = [
                "id": i + 1,
                "text": Redactor.scrub(item.description),
                "direction": item.averageAmount < 0 ? "in" : "out",
                "typical_amount": (abs(item.averageAmount) * 100).rounded() / 100,
                "times": item.count,
            ]
            if let bank = item.bankCategory { entry["bank_category"] = bank }
            if item.amounts.count > 1 { entry["amounts"] = item.amounts.map { ($0 * 100).rounded() / 100 } }
            if let guess = item.appGuess { entry["app_guess"] = guess }
            if !item.notes.isEmpty { entry["notes"] = item.notes }
            return entry
        }
        guard let body = try? JSONSerialization.data(withJSONObject: ["items": payload]),
              let user = String(data: body, encoding: .utf8) else { return nil }
        let system = instructions(examples: examples)
        let reply = await Timeout.run(120) {
            try? await CloudAI.complete(system: system, user: user, json: true, maxTokens: 250 * items.count + 4_000)
        }
        guard let reply, let results = CloudAI.object(from: reply)?["results"] as? [[String: Any]] else { return nil }
        var out: [String: CloudVerdict] = [:]
        for result in results {
            guard let id = (result["id"] as? Int) ?? (result["id"] as? String).flatMap(Int.init), (1...items.count).contains(id),
                  let categoryName = result["category"] as? String,
                  let category = Category.pickable.first(where: { $0.rawValue.caseInsensitiveCompare(categoryName) == .orderedSame })
            else { continue }
            let item = items[id - 1]
            var name = ((result["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty || name.count > 60 { name = KeywordExtractor.displayName(for: item.description) }
            out[item.key] = CloudVerdict(name: name, category: category, confident: (result["confident"] as? Bool) ?? false,
                                         domain: LogoFinder.clean(result["website"] as? String) ?? "")
        }
        return out
    }
}

// MARK: - Job 1, alternative: a "decision" model (Cloudflare Clef) picks the category

/// Decision models don't write text: given a state and a multiple-choice question they return the
/// chosen option with probabilities. That's a natural fit for "which category?", one request per
/// place. They can't tidy a merchant's name, so the app's own cleanup is used for that.
///
/// Not offered in Settings. Measured in Nov 2026 on 563 real places against Claude Sonnet 5.5:
/// Clef (27B) was about twice as fast (25s vs 47s) and far cheaper, but agreed on only 64% of
/// categories, with plain errors (airlines and parking as Subscriptions, restaurants as Shopping).
/// Claude Haiku 5.5 agreed on 88%. Kept for experiments: `defaults write com.pwolpe.tonyawards
/// cloudModel cloudflare/clef`. Jobs that need writing still use the default model.
enum DecisionSorter {
    static func handles(_ model: String) -> Bool { model.hasPrefix("cloudflare/clef") }

    private static let meanings: [Category: String] = [
        .groceries: "Supermarkets, food markets, butchers, bakeries selling food to take home, wine and liquor shops",
        .dining: "Restaurants, bars, cafes, coffee shops, fast food, food delivery, concessions",
        .shopping: "Retail stores and online shopping: clothes, electronics, books, general merchandise, Amazon",
        .transportation: "Gas, parking, tolls, taxis, Uber and Lyft, public transit, car repair and car payments",
        .bills: "Utilities, phone, internet, insurance, and other regular household bills",
        .subscriptions: "Software, apps, streaming, news, memberships and online services billed regularly",
        .health: "Doctors, dentists, pharmacies, hospitals, gyms and fitness studios",
        .home: "Mortgage, rent, condo or HOA fees, property tax, furniture, home improvement and repairs",
        .travel: "Airlines, hotels, rental cars, travel agencies, and spending while abroad on lodging or tours",
        .entertainment: "Movies, concerts, theater, sports events, games, museums, tickets",
        .personal: "Hair, spa, dry cleaning, laundry, cosmetics, personal services",
        .gifts: "Charities, donations, nonprofits, public radio, gifts",
        .fees: "Bank fees, late fees, interest charges, ATM fees",
        .other: "Spending that fits none of the other categories, or whose purpose can't be told (cash, checks, payments to individuals)",
        .transfer: "Paying a credit card bill, or moving money between the person's own accounts",
        .income: "Salary, payroll and other earnings",
        .investmentIncome: "Investment distributions, dividends, interest received",
        .investing: "Capital calls, brokerage or crypto purchases and sales, redemptions",
        .investmentLoan: "Advances, principal or interest on a loan used for investing",
        .taxes: "Payments to or refunds from the IRS or a state tax department",
    ]

    static func sort(_ items: [CloudItem], examples: [MerchantRule]) async -> [String: CloudVerdict]? {
        var criteria: [String: String] = [:]
        for category in Category.pickable {
            criteria[category.rawValue] = meanings[category] ?? "A category this person created for themselves; use it whenever the transaction fits its name"
        }
        var instructions = "Pick the budget category for this bank or credit card transaction. A refund belongs in the category of what was bought. "
            + "\"TST*\" and \"SQ *\" are payment processors used by restaurants and small shops."
        if !examples.isEmpty {
            instructions += " This person has already sorted: " + examples.suffix(15).map { "\($0.name) = \($0.category.rawValue)" }.joined(separator: "; ") + "."
        }
        let question: [String: Any] = ["type": "choice", "instructions": instructions, "criteria": criteria]

        var out: [String: CloudVerdict] = [:]
        var failures = 0
        await withTaskGroup(of: (CloudItem, (Category, Double)?).self) { group in
            var next = 0
            func start() {
                guard next < items.count else { return }
                let item = items[next]; next += 1
                group.addTask { (item, await decide(item, question: question)) }
            }
            for _ in 0..<10 { start() }
            for await (item, answer) in group {
                if let (category, confidence) = answer {
                    out[item.key] = CloudVerdict(name: KeywordExtractor.displayName(for: item.description), category: category,
                                                 confident: confidence >= 0.75)
                } else { failures += 1 }
                start()
            }
        }
        return out.isEmpty && failures > 0 ? nil : out
    }

    private static func decide(_ item: CloudItem, question: [String: Any]) async -> (Category, Double)? {
        guard let key = CloudKey.load() else { return nil }
        var state = "Transaction text: \(Redactor.scrub(item.description)). Money \(item.averageAmount < 0 ? "came in" : "went out"). "
            + "Typical amount $\(String(format: "%.2f", abs(item.averageAmount))). Appears \(item.count) time\(item.count == 1 ? "" : "s")."
        if item.amounts.count > 1 { state += " Recent amounts: " + item.amounts.map { String(format: "%.2f", $0) }.joined(separator: ", ") + "." }
        if let bank = item.bankCategory { state += " The bank's own category: \(bank)." }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/alpha/decisions")!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": CloudAI.model, "state": state, "questions": ["category": question]])
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
            guard let (data, response) = try? await URLSession.shared.data(for: request) else { continue }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429 || status >= 500 { continue }
            guard status == 200, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let answer = (object["answers"] as? [String: Any])?["category"] as? [String: Any],
                  let choice = answer["choice"] as? String,
                  let category = Category.pickable.first(where: { $0.rawValue == choice }) else {
                if ProcessInfo.processInfo.environment["TONY_AWARDS_SNAPSHOT"] != nil, attempt == 0 {
                    print("DEBUG DECISION status \(status) \(String(data: data.prefix(300), encoding: .utf8) ?? "")")
                }
                return nil
            }
            return (category, (answer["confidence"] as? Double) ?? 0)
        }
        return nil
    }
}

// MARK: - Job 2: reading a statement the app couldn't

enum CloudStatementReader {
    struct Reading {
        var rows: [CanonicalRow]
        /// True when the rows add up to the section totals printed on the statement.
        var verified: Bool
    }

    private static let system = """
    You read bank and credit card statements. The text below was taken from a statement (possibly by OCR, so expect \
    small errors; personal details have been replaced with placeholders like [name] and [number]).

    List every individual transaction. Do NOT include balances, summaries, totals, interest-rate tables, rewards, \
    or the captions under pictures of paid checks.

    For each transaction give:
    - date: YYYY-MM-DD. Statements often print only month/day; use the statement period to work out the year.
    - description: the merchant or payee text as printed, on one line, without the date or amount.
    - amount: a positive number.
    - direction: "out" for purchases, fees, withdrawals, checks and payments made from a bank account; "in" for \
    deposits, refunds, credits, and payments received on a credit card.
    - section: the heading the transaction appears under, if any.

    Also list each section total the statement prints (for example "Total Deposits & Credits 1,234.56") as \
    {"section": "...", "amount": 1234.56}.

    Reply with JSON only: {"transactions": [{"date": "", "description": "", "amount": 0, "direction": "out", "section": ""}], \
    "totals": [{"section": "", "amount": 0}]}
    """

    static func read(text: String, closing: Date) async -> Reading? {
        // Send it in pieces of a few pages; statements run to tens of pages, much of it legal text.
        var chunks: [String] = [], current = ""
        for line in Redactor.blank(text).components(separatedBy: .newlines) {
            if current.count + line.count > 24_000, !current.isEmpty { chunks.append(current); current = "" }
            current += line.prefix(2_000) + "\n"
        }
        if current.filter(\.isNumber).count >= 12 { chunks.append(current) }
        guard !chunks.isEmpty, chunks.count <= 12 else { return nil }

        let period = "Statement closing date: \(DateParsing.iso.string(from: closing)).\n\n"
        var rows: [CanonicalRow] = []
        var sums: [String: Double] = [:], totals: [String: Double] = [:]
        for chunk in chunks {
            let reply = await Timeout.run(180) {
                try? await CloudAI.complete(system: system, user: period + chunk, json: true, maxTokens: 40_000, timeout: 170)
            }
            guard let reply, let object = CloudAI.object(from: reply) else { return nil }
            for t in (object["transactions"] as? [[String: Any]]) ?? [] {
                guard let dateText = t["date"] as? String, DateParsing.parse(dateText, format: "yyyy-MM-dd") != nil,
                      let amount = (t["amount"] as? Double) ?? (t["amount"] as? String).flatMap(MoneyParsing.parse), amount != 0,
                      let description = (t["description"] as? String)?.split(whereSeparator: \.isWhitespace).joined(separator: " "),
                      description.filter(\.isLetter).count >= 2 else { continue }
                let out = ((t["direction"] as? String) ?? "out").lowercased() != "in"
                rows.append(CanonicalRow(date: String(dateText.prefix(10)), description: description,
                                         amount: ((out ? abs(amount) : -abs(amount)) * 100).rounded() / 100))
                if let section = (t["section"] as? String)?.lowercased(), !section.isEmpty { sums[section, default: 0] += abs(amount) }
            }
            for total in (object["totals"] as? [[String: Any]]) ?? [] {
                guard let section = (total["section"] as? String)?.lowercased(),
                      let amount = (total["amount"] as? Double) ?? (total["amount"] as? String).flatMap(MoneyParsing.parse) else { continue }
                totals[section.replacingOccurrences(of: "total ", with: "")] = abs(amount)
            }
        }
        guard !rows.isEmpty else { return nil }
        // Verified = at least one printed total matched and none disagreed.
        var matched = 0, mismatched = 0
        for (section, printed) in totals {
            guard let sum = sums.first(where: { $0.key.contains(section) || section.contains($0.key) })?.value else { continue }
            if abs(sum - printed) < 0.005 { matched += 1 } else { mismatched += 1 }
        }
        return Reading(rows: PDFStatement.removeInternalAdjustments(rows), verified: matched > 0 && mismatched == 0)
    }
}

// MARK: - Drawing Tony

/// The banner picture, drawn by a cloud image model from Tony's real photo: a cartoon of him living
/// out a daydream about a purchase he really made. The photo goes along every time so it stays him.
enum CloudImage {
    static let defaultModel = "google/gemini-nano-banana-2.1"
    static var model: String {
        get { UserDefaults.standard.string(forKey: "cloudImageModel") ?? defaultModel }
        set { UserDefaults.standard.set(newValue, forKey: "cloudImageModel") }
    }

    /// The best image model on offer today. Image models improve every few months, so rather than
    /// name one here for good, the app reads what's available and has the writing model choose.
    static func bestModel() async -> String {
        guard let url = URL(string: "https://openrouter.ai/api/v1/models"),
              let (data, _) = try? await URLSession.shared.data(from: url),
              let all = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]] else { return model }
        let candidates = all.filter { entry in
            let shape = entry["architecture"] as? [String: Any]
            let id = entry["id"] as? String ?? ""
            return (shape?["output_modalities"] as? [String])?.contains("image") == true
                && (shape?["input_modalities"] as? [String])?.contains("image") == true
                && !id.hasPrefix("openrouter/")
        }
        let ids = candidates.compactMap { $0["id"] as? String }
        guard !ids.isEmpty else { return model }
        let lines = candidates.map { entry -> String in
            let released = Date(timeIntervalSince1970: (entry["created"] as? Double) ?? 0).formatted(.iso8601.year().month().day())
            let about = String(((entry["description"] as? String) ?? "").prefix(220)).replacingOccurrences(of: "\n", with: " ")
            return "\(entry["id"] as? String ?? "") | \(entry["name"] as? String ?? "") | released \(released) | \(about)"
        }
        let system = """
        Choose the one image model that will draw the best picture for this job: given a photo of a real man, \
        draw a rich, funny, cartoon illustration of him in an imagined scene, keeping his face unmistakably his. \
        Prefer the most capable, most recently released model with a strong record of keeping a person's likeness \
        from a reference photo. Avoid "lite", "mini" and "preview" versions, and prefer a model that draws in \
        around ten seconds over a slower one of similar quality. Reply with JSON only: {"model": "<id exactly as listed>"}
        """
        let reply = await Timeout.run(30) {
            try? await CloudAI.complete(system: system, user: lines.joined(separator: "\n"), json: true, maxTokens: 2_000, timeout: 25)
        }
        if let reply, let choice = CloudAI.object(from: reply)?["model"] as? String, ids.contains(choice) {
            model = choice
            return choice
        }
        return ids.contains(model) ? model : defaultModel
    }

    struct Scene: Sendable {
        let scene: String
        let caption: String
    }

    /// One sentence saying what Tony is doing, and the nomination line that goes with it.
    static func scene(merchant: String, category: String, amount: Double, cast: [String] = ["Tony"]) async -> Scene? {
        let system = """
        You design the picture at the top of The Tony Awards, a playful personal budgeting app made for Tony. \
        Each picture is a cartoon of Tony in a Walter Mitty daydream: an ordinary purchase he really made, \
        blown up into a wildly heroic, absurd, joyful fantasy. Seeing it should make him laugh out loud, because \
        it is so specifically about where he really just spent money.

        Given the purchase, reply with JSON only: {"scene": "...", "caption": "..."}

        scene: one or two sentences, starting with "he is", describing the daydream: what Tony is, what he is \
        doing, what he wears and where. Tie it concretely to this exact business: what it sells, its colors, its \
        setting, what people do there. Then exaggerate it into an adventure. Examples: a coffee and donut shop -> \
        "he is a triumphant explorer in a pith helmet, planting a flag on the summit of a mountain of glazed \
        donuts, a river of iced coffee running through an orange and pink valley below"; a rideshare -> "he is a \
        chariot racer in a Roman arena, the chariot a small pink-trimmed city car pulled by four scooters, the \
        crowd going wild"; an electric utility -> "he is a mad scientist in a castle laboratory, throwing a giant \
        switch as lightning lights a single enormous light bulb"; a parking garage -> "he is a stunt driver \
        leaping a convertible between the rooftops of two parking garages, valets holding up scorecards". \
        Any costume must leave his whole face clearly visible. Funny side characters and details are welcome. \
        Do not ask for any words, lettering or logos in the picture.

        caption: one witty awards-show nomination, at most 14 words, starting with "Nominated for Best", about \
        this purchase and this daydream. Light accounting humor is welcome; never negative about spending. \
        Do not mention the amount.
        """
        // A different flavor of daydream each time, so the pictures don't settle into one joke.
        let flavor = ["a blockbuster action movie", "a space adventure", "a medieval legend", "a spy thriller", "a nature documentary",
                      "an Olympic final", "a superhero comic", "a jungle expedition", "a rock concert", "a fairy tale", "a heist movie",
                      "a western", "a monster movie", "an old Hollywood musical", "a polar expedition", "a magic show",
                      "a samurai epic", "a circus", "a pirate adventure", "a deep sea voyage"].randomElement()!
        let who = cast.count > 1
            ? " This picture stars two friends, \(cast.joined(separator: " and ")), together: start the scene with \"they are\" and give each of them something to do. In the caption, say \"a Duo\" or name them both."
            : cast.first == "Tony" ? "" : " This picture stars \(cast[0]) (not Tony): the scene still starts with \"he is\"."
        let user = "Purchase: \(merchant) (\(category)), \(Money.format(amount)). This time, make the daydream \(flavor).\(who) Hats, helmets and masks stay off his head so the whole face shows."
        let reply = await Timeout.run(40) {
            try? await CloudAI.complete(system: system, user: user, json: true, maxTokens: 3_000, temperature: 1.0, timeout: 35)
        }
        guard let reply, let o = CloudAI.object(from: reply), let scene = (o["scene"] as? String), !scene.isEmpty else { return nil }
        var caption = ((o["caption"] as? String) ?? "").replacingOccurrences(of: "*", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\" \n"))
        if !caption.hasPrefix("Nominated") || caption.count > 140 { caption = "Nominated for Best Supporting Role at \(merchant)." }
        return Scene(scene: scene, caption: caption)
    }

    /// Draws the scene as a wide cartoon, with Tony's photo as the model for his face. Nil if it couldn't be drawn.
    /// Every picture is drawn in a different manner, so opening the app is a small surprise each time.
    /// Only manners that can carry a real face: each was tried with the photos, and flatter ones
    /// (pixel art, paper cut, woodblock) lost the likeness.
    static let styles: [(id: String, look: String)] = [
        ("3d", "a modern 3D animated feature film: soft rounded shapes, rich lighting, expressive faces"),
        ("strip", "a classic mid-century newspaper comic strip: a slightly wobbly hand-inked black line, flat muted colors, very little shading, gentle deadpan humor"),
        ("clay", "stop-motion claymation: everything sculpted from modelling clay with visible thumbprints, miniature handmade sets, warm studio lighting"),
        ("anime", "a hand-painted Japanese animated film: lush painted backgrounds, soft clean line work, gentle colors, a sense of wonder"),
        ("popart", "a 1960s pop-art comic book panel: thick black ink outlines, halftone dots, flat primary colors, dramatic action lines"),
        ("poster", "a vintage 1930s travel poster: flat screen-printed color blocks, strong geometric composition, a limited warm palette, subtle paper grain"),
        ("watercolor", "a loose ink-and-watercolor magazine cartoon: quick confident pen lines, soft washes of color, plenty of white paper, dry wit"),
        ("saturday", "a 1960s Saturday-morning television cartoon: flat cel colors, thick clean outlines, stylized angular backgrounds, big goofy energy"),
    ]

    /// Draws the scene with the real photos as the reference for each face. Likeness comes first:
    /// the head is a faithful, detailed caricature portrait, and only the rest takes on the style.
    static func draw(scene: String, cast: [(name: String, photo: Data)], model: String, style: String) async -> Data? {
        guard let key = CloudKey.load(), !cast.isEmpty else { return nil }
        let intro = cast.count == 1
            ? "The attached photo is \(cast[0].name), a real person. Make a picture starring him."
            : "The first attached photo is \(cast[0].name) and the second is \(cast[1].name), two real people who are friends. Make a picture starring both of them together, each clearly himself."
        let star = cast.count == 1 ? "\(cast[0].name) is the star" : "\(cast[0].name) and \(cast[1].name) are the stars, side by side"
        let prompt = """
        \(intro)
        Likeness comes first. Treat each photo as the reference for that man's head and reproduce it faithfully: \
        the exact face shape and proportions, hairline and hair, eyebrows, eyes, nose, mouth and smile, any beard or \
        stubble exactly as it is, and glasses if and only if he wears them in his photo, in the same frame shape. Do \
        not simplify, beautify, slim, age or generalize the face into a generic cartoon character. A colleague \
        glancing at the picture must know instantly who it is. Render the head as a detailed caricature portrait: \
        slightly larger than life, the face fully recognizable, three-quarter or front view, well lit, nothing covering it.
        Everything else (the body, costume, props, other characters and the setting) is drawn in this style: \(style). \
        The head is finished in the same medium so it belongs in the picture, but it keeps the full detail and true \
        likeness of the photo.
        The scene, a Walter Mitty daydream: \(scene)
        Very wide cinematic landscape picture (21:9). \(star): in the foreground, shown from about the waist up or \
        closer so the face is large, full of joy and swagger. Keep the bottom edge of the picture free of anything \
        important. Playful, full of funny details. No words, letters, numbers, logos, captions or watermarks anywhere.
        """
        var content: [[String: Any]] = [["type": "text", "text": prompt]]
        for member in cast {
            content.append(["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + member.photo.base64EncodedString()]])
        }
        let body: [String: Any] = [
            "model": model,
            "modalities": ["image", "text"],
            "image_config": ["aspect_ratio": "21:9"],
            "messages": [["role": "user", "content": content]],
        ]
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!, timeoutInterval: 150)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("The Tony Awards", forHTTPHeaderField: "X-Title")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = (object["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
              let images = message["images"] as? [[String: Any]],
              let url = (images.first?["image_url"] as? [String: Any])?["url"] as? String,
              let comma = url.firstIndex(of: ","),
              let picture = Data(base64Encoded: String(url[url.index(after: comma)...])) else { return nil }
        return picture
    }
}

// MARK: - Noticing trips and events

/// Nothing in a statement says "trip". But a flight, then a week of charges in another country,
/// then a flight home, is a story anyone would recognize. The model finds those runs; the app
/// adds up what they cost.
enum StoryFinder {
    struct Line: Sendable {
        let id: UUID
        let date: String
        let text: String
        let amount: Double
        let category: String
    }

    private static let system = """
    You are looking at a person's card and bank spending, one transaction per line:
    number | date | merchant text (often ends with a city and state or country) | amount | category

    Work out where home is (where most everyday purchases happen). Then find:

    1. TRIPS: travel away from home. A trip is a run of days with spending in another city, state or country, \
    plus the flights, trains, hotels, rental cars and tours that belong to it even when they were paid weeks earlier. \
    One trip per journey; if several places were visited on one journey, it is one trip.
    2. EVENTS: a cluster of unusual, related spending that is clearly one occasion or project, such as a wedding, a big party, \
    a move, a renovation, or a medical episode. Be conservative: ordinary life is not an event.

    Do not include everyday spending at home, commuting, regular subscriptions, or single purchases. \
    Only include a transaction when you are reasonably sure it belongs. A weekend away with two or three charges still counts as a trip.

    For each one give:
    - kind: "trip" or "event"
    - name: short and natural, like "Mongolia", "Las Vegas weekend", "Ireland and Northern Ireland", "Kitchen renovation"
    - place: the main place (city, region or country), or null for an event with no particular place
    - start and end: YYYY-MM-DD, the days actually away (or the span of the event), not the booking dates
    - summary: one warm, specific sentence about what the spending shows. Do not mention any amounts.
    - lines: the numbers of every transaction that belongs to it

    Reply with JSON only: {"home": "...", "stories": [{"kind": "trip", "name": "", "place": "", "start": "", "end": "", "summary": "", "lines": [1, 2]}]}
    """

    /// Nil when the cloud couldn't be used. Each transaction lands in at most one story.
    static func find(_ lines: [Line]) async -> [Story]? {
        guard CloudAI.isEnabled, lines.count >= 20 else { return [] }
        // Everything in one request when it fits (a holiday trip shouldn't be cut in two at New Year);
        // only a very long history is split, a calendar year at a time.
        var stories: [Story] = []
        var used: Set<UUID> = []
        let groups: [(key: String, value: [Line])] = lines.count <= 3_500
            ? [("all", lines)]
            : Dictionary(grouping: lines, by: { String($0.date.prefix(4)) }).sorted(by: { $0.key < $1.key })
        for (_, year) in groups {
            let numbered = year.sorted { $0.date < $1.date }
            let listing = numbered.enumerated().map { i, l in
                "\(i + 1) | \(l.date) | \(String(Redactor.scrub(l.text).prefix(60))) | \(String(format: "%.2f", l.amount)) | \(l.category)"
            }.joined(separator: "\n")
            let reply = await Timeout.run(600) {
                try? await CloudAI.complete(system: system, user: listing, json: true, maxTokens: 64_000, timeout: 590, effort: "medium")
            }
            if ProcessInfo.processInfo.environment["TONY_AWARDS_SNAPSHOT"] != nil {
                print("DEBUG STORIES sent \(numbered.count) lines (\(listing.count) chars); reply \(reply?.count ?? -1) chars; ends: \(String((reply ?? "").suffix(80)).replacingOccurrences(of: "\n", with: " "))")
            }
            guard let reply, let found = CloudAI.object(from: reply)?["stories"] as? [[String: Any]] else { return nil }
            for item in found {
                guard let name = (item["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty,
                      let numbers = item["lines"] as? [Any] else { continue }
                let ids = numbers.compactMap { ($0 as? Int) ?? ($0 as? String).flatMap(Int.init) }
                    .filter { (1...numbered.count).contains($0) }
                    .map { numbered[$0 - 1].id }
                    .filter { used.insert($0).inserted }
                guard ids.count >= 2 else { continue }
                let dates = numbered.filter { ids.contains($0.id) }.map(\.date).sorted()
                let valid = { (s: Any?) -> String? in
                    guard let s = s as? String, DateParsing.parse(s, format: "yyyy-MM-dd") != nil else { return nil }
                    return String(s.prefix(10))
                }
                stories.append(Story(kind: (item["kind"] as? String) == "event" ? .event : .trip,
                                     name: String(name.prefix(60)),
                                     place: (item["place"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                                     start: valid(item["start"]) ?? dates.first ?? "", end: valid(item["end"]) ?? dates.last ?? "",
                                     summary: ((item["summary"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                                     entryIDs: ids))
            }
        }
        return stories.sorted { $0.start > $1.start }
    }
}

// MARK: - Job 3: a spreadsheet whose columns the app couldn't work out

enum CloudColumnMapper {
    static func mapping(for table: CSVTable) async -> ColumnMapping? {
        let header = (0..<table.columnCount).map { "\($0): \(table.header?[safe: $0] ?? "(no header)")" }.joined(separator: " | ")
        let sample = table.rows.prefix(12).map { row in row.map { Redactor.scrub(String($0.prefix(60))) }.joined(separator: " | ") }.joined(separator: "\n")
        let system = """
        A bank export has these columns (numbered from 0) and sample rows. Work out which columns matter. Reply with JSON only:
        {"date": <column>, "date_format": "<a DateFormatter pattern such as MM/dd/yyyy or yyyy-MM-dd>", "description": <column>,
         "amount": <column or null>, "debit": <column or null>, "credit": <column or null>, "purchases_are_negative": <true or false>}
        Use "amount" when one column holds signed amounts, otherwise "debit" (money out) and "credit" (money in).
        purchases_are_negative: true if money spent appears as negative numbers in the amount column.
        """
        let reply = await Timeout.run(60) {
            try? await CloudAI.complete(system: system, user: "Columns: \(header)\n\nRows:\n\(sample)", json: true, maxTokens: 300, timeout: 50)
        }
        guard let reply, let o = CloudAI.object(from: reply) else { return nil }
        func column(_ key: String) -> Int? {
            guard let i = o[key] as? Int, (0..<table.columnCount).contains(i) else { return nil }
            return i
        }
        guard let date = column("date"), let description = column("description"),
              let format = (o["date_format"] as? String) ?? DateParsing.guessFormat(for: table.values(date)) else { return nil }
        let amount = column("amount"), debit = column("debit"), credit = column("credit")
        guard amount != nil || (debit != nil && credit != nil) else { return nil }
        return ColumnMapping(dateColumn: date, dateFormat: format, descriptionColumn: description, amountColumn: amount,
                             debitColumn: amount == nil ? debit : nil, creditColumn: amount == nil ? credit : nil,
                             purchasesAreNegative: (o["purchases_are_negative"] as? Bool) ?? true)
    }
}

// MARK: - Job 4 and 5: questions and short lines of writing

enum CloudWriter {
    /// A short piece of text (the monthly recap, today's nomination). Nil if the cloud isn't on or fails.
    static func line(system: String, facts: String, maxTokens: Int, temperature: Double) async -> String? {
        guard CloudAI.isEnabled else { return nil }
        return await Timeout.run(40) {
            try? await CloudAI.complete(system: system, user: facts, json: false, maxTokens: maxTokens, temperature: temperature, timeout: 35)
        }?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Understands a question about spending. The numbers are still computed in code from the result.
    static func query(_ question: String, first: Month, last: Month) async -> SpendingQuery? {
        guard CloudAI.isEnabled else { return nil }
        let now = Month(date: .now)
        let system = """
        Turn a question about personal spending into a query. Reply with JSON only:
        {"metric": "...", "category": "...", "place": "...", "from": "YYYY-MM", "to": "YYYY-MM"}
        metric: total (how much), list (show or what did I buy), top_places, top_categories, count (how many times), \
        monthly_average, subscriptions (recurring charges).
        category: one of \(Category.pickable.map(\.rawValue).joined(separator: "; ")), or "any".
        place: the store or payee named in the question as the person wrote it, or "any". When a place is named, use "any" for category.
        Today is \(Date.now.formatted(.dateTime.year().month(.wide).day())). Data covers \(first.key) to \(last.key); \
        with no time mentioned use that whole range. "Last month" is \(now.adding(-1).key). "This year" is \(now.year)-01 to \(last.key).
        """
        let reply = await Timeout.run(30) {
            try? await CloudAI.complete(system: system, user: question, json: true, maxTokens: 150, timeout: 25)
        }
        guard let reply, let o = CloudAI.object(from: reply),
              let metric = (o["metric"] as? String).flatMap({ SpendingQuery.Metric(rawValue: $0.lowercased()) }) else { return nil }
        let categoryName = (o["category"] as? String) ?? "any"
        let category = Category.pickable.first { $0.rawValue.caseInsensitiveCompare(categoryName) == .orderedSame }
        let placeText = ((o["place"] as? String) ?? "any").trimmingCharacters(in: .whitespaces)
        let place = placeText.isEmpty || placeText.lowercased() == "any" ? nil : placeText
        var from = (o["from"] as? String).flatMap(Month.init(key:)) ?? first
        var to = (o["to"] as? String).flatMap(Month.init(key:)) ?? last
        if from > to { swap(&from, &to) }
        from = max(from, first); to = min(to, last)
        if from > to { from = first; to = last }
        return SpendingQuery(metric: metric, category: place == nil ? category : nil, place: place, from: from, to: to)
    }
}
