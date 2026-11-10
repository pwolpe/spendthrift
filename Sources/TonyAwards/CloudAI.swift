import Foundation
import Security
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
    static func complete(system: String, user: String, json: Bool, maxTokens: Int, temperature: Double = 0,
                         timeout: TimeInterval = 90) async throws -> String {
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

/// The OpenRouter key lives in the Mac's keychain: never in the app, its data file, or a backup.
enum CloudKey {
    private static let service = "com.pwolpe.tonyawards.openrouter"
    private static let account = "api-key"
    nonisolated(unsafe) private static var cached: String??
    private static let lock = NSLock()

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static var exists: Bool { load() != nil }

    static func load() -> String? {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let value: String? = SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess
            ? (item as? Data).flatMap { String(data: $0, encoding: .utf8) } : nil
        cached = .some(value)
        return value
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }
        lock.lock(); defer { lock.unlock() }
        SecItemDelete(query as CFDictionary)
        var q = query
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        q[kSecAttrLabel as String] = "The Tony Awards: OpenRouter key"
        let ok = SecItemAdd(q as CFDictionary, nil) == errSecSuccess
        cached = .some(ok ? trimmed : nil)
        return ok
    }

    static func delete() {
        lock.lock(); defer { lock.unlock() }
        SecItemDelete(query as CFDictionary)
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
        // The holder's name sits on the line above their street address. Other text can share that
        // line ("PAUL WOLPE  We accept operator relay calls"), so take only the leading capitalized words.
        var names: Set<String> = []
        // Words that appear in capitals on statements but are never part of a person's name.
        let notNames: Set<String> = ["PAYMENT", "BALANCE", "DUE", "DATE", "STATEMENT", "ACCOUNT", "NEW", "MINIMUM", "TOTAL", "AMOUNT",
                                     "ENCLOSED", "SUMMARY", "CARD", "CARDS", "CASH", "CREDIT", "PAGE", "PERIOD", "BANK", "BOX", "PO",
                                     "MEMBER", "SINCE", "CUSTOMER", "SERVICE", "PLATINUM", "CHECKING", "SAVINGS", "PLEASE", "YOUR", "THE"]
        for i in lines.indices where matches(street, lines[i]) && !matches(poBox, lines[i]) {
            // Usually the line directly above; page layout can slip another row in between. Further up,
            // only accept a line that is nothing but a name, so ordinary capitalized text isn't blanked.
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
}

struct CloudVerdict: Sendable {
    let name: String
    let category: Category
    /// False when the model is guessing (e.g. a payment to a person): those go to Double-Check.
    let confident: Bool
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
        text += "\n\nReply with JSON only: {\"results\": [{\"id\": 1, \"name\": \"…\", \"category\": \"…\", \"confident\": true}]} with one result per item."
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
            return entry
        }
        guard let body = try? JSONSerialization.data(withJSONObject: ["items": payload]),
              let user = String(data: body, encoding: .utf8) else { return nil }
        let system = instructions(examples: examples)
        let reply = await Timeout.run(120) {
            try? await CloudAI.complete(system: system, user: user, json: true, maxTokens: 120 * items.count + 200)
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
            out[item.key] = CloudVerdict(name: name, category: category, confident: (result["confident"] as? Bool) ?? false)
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
                try? await CloudAI.complete(system: system, user: period + chunk, json: true, maxTokens: 16_000, timeout: 170)
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
