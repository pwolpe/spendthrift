import Foundation
import PDFKit
import AppKit
import Observation

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

extension CloudSorter {
    /// The same places sorted twice, independently and at the same moment. Where the two readings
    /// agree, the answer stands. Where they differ, the model plainly isn't sure, so the place is
    /// marked as a guess and goes to Double-Check instead of one answer being picked silently.
    /// (Sorting the same statements on two days used to give different totals; this is why.)
    static func sortTwice(_ items: [CloudItem], examples: [MerchantRule]) async -> [String: CloudVerdict]? {
        async let first = sort(items, examples: examples)
        async let second = sort(items, examples: examples)
        guard let a = await first else { return await second }
        guard let b = await second else { return a }
        var out = a
        for (key, verdict) in a {
            guard let other = b[key] else { continue }
            if other.category != verdict.category {
                // Prefer the reading that was itself unsure of nothing; either way, flag it.
                let kept = verdict.confident || !other.confident ? verdict : other
                out[key] = CloudVerdict(name: kept.name, category: kept.category, confident: false, domain: kept.domain ?? other.domain)
            }
        }
        for (key, verdict) in b where out[key] == nil { out[key] = verdict }
        return out
    }
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
            try? await CloudAI.complete(job: "Finding logos", system: system, user: listing, json: true, maxTokens: 60 * names.count + 3_000, timeout: 80)
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
        - Wine shops, liquor stores, wineries and vineyards, distilleries, whiskey and spirits sellers, wine clubs and \
        wine auctions (bottles bought to keep or take home, in person or online) are "Wine & Spirits", never Groceries \
        or Shopping. A drink at a bar, a restaurant or a music venue is still Dining, whatever its name.
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
            if !item.notes.isEmpty { entry["notes"] = item.notes.map(Redactor.scrub) }
            return entry
        }
        guard let body = try? JSONSerialization.data(withJSONObject: ["items": payload]),
              let user = String(data: body, encoding: .utf8) else { return nil }
        let system = instructions(examples: examples)
        let reply = await Timeout.run(120) {
            try? await CloudAI.complete(job: "Sorting payees", system: system, user: user, json: true, maxTokens: 250 * items.count + 4_000)
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
/// Claude Haiku 5.5 agreed on 88%. Kept for experiments: `defaults write com.pwolpe.spendthrift
/// cloudModel cloudflare/clef`. Jobs that need writing still use the default model.
enum DecisionSorter {
    static func handles(_ model: String) -> Bool { model.hasPrefix("cloudflare/clef") }

    private static let meanings: [Category: String] = [
        .groceries: "Supermarkets, food markets, butchers, bakeries selling food to take home",
        .wine: "Wine shops, liquor stores, wineries, distilleries, wine clubs and wine auctions: bottles bought to keep or take home (not drinks at a bar)",
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

    /// "Which category?" as a question a decision model can answer: every category the person can pick, with what it covers.
    static func categoryQuestion() -> Decisions.Question {
        var options: [String: String] = [:]
        for category in Category.pickable {
            options[category.rawValue] = meanings[category] ?? "A category this person created for themselves; use it whenever the transaction fits its name"
        }
        return .choice("Pick the budget category for this bank or credit card transaction. A refund belongs in the category of what was bought. "
                       + "\"TST*\" and \"SQ *\" are payment processors used by restaurants and small shops.", options: options)
    }

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
                if ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] != nil, attempt == 0 {
                    print("DEBUG DECISION status \(status) \(String(data: data.prefix(300), encoding: .utf8) ?? "")")
                }
                return nil
            }
            return (category, (answer["confidence"] as? Double) ?? 0)
        }
        return nil
    }
}
