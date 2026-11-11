import Foundation
import FoundationModels

// MARK: - Turning "TST* BLUE DOOR CAFE #42 SEATTLE WA" into a stable keyword

enum KeywordExtractor {
    private static let prefixes = [
        "TST* ", "TST *", "TST*", "SQ *", "SQ* ", "SQ*", "SP * ", "SP *", "SP ", "PAYPAL *", "PP*",
        "APLPAY ", "APL*", "POS ", "POS PURCHASE ", "DEBIT CARD PURCHASE ", "DEBIT PURCHASE ",
        "PURCHASE AUTHORIZED ON ", "PURCHASE ", "CHECKCARD ", "CHECK CARD ", "DBT CRD ", "RECURRING ",
        "ZELLE PAYMENT TO ", "ZELLE PAYMENT FROM ", "ZELLE DEBIT PAYMENT TO: ", "ZELLE CREDIT PAYMENT FROM: ", "ACH DEBIT ", "ACH CREDIT ", "PAYMENT SENT ", "CKO*", "DD *", "IC* ", "LS ", "BT*", "PY *", "GDP*", "SQSP*", "FS *", "TM *",
        "SUMUP *", "SUMUP*", "SUMUP  *", "ZETTLE_*", "ZETTLE *", "IZ *", "IZ*", "CLOVER*", "CLV*", "STRIPE*", "STRIPE *", "SHOPIFY*", "WPY*", "EB *", "FSP*", "BLT*", "TOCK*", "RESY*", "OLO*", "CHOWNOW*", "MINDBODY*", "VAGARO*", "BKG*", "WWW.", "DNH*",
    ]

    static func keyword(for description: String) -> String { keyword(for: description, maxTokens: 3) }

    /// Who a wire went to. A bank prints every wire the same way ("Consumer Online International Wire
    /// Via: … A/C: Hsbc Uk Bank Plc Birmingham …"), so without this every wire would be one payee.
    /// Returns the recipient named after "A/C:", upper case, a few words: enough to tell recipients apart.
    static func wireRecipient(_ description: String) -> String? {
        let upper = description.uppercased()
        // Another bank's way: "DOMESTIC MANUAL WIRE DESIGNLUSH INC.", "INT'L WIRED FUNDS OUT BRIDGE TO BHUTAN".
        if upper.range(of: "A/C:") == nil,
           let lead = upper.range(of: #"^(?:DOMESTIC|INCOMING|OUTGOING|INT.?L|INTERNATIONAL)\b[A-Z ]*?\bWIRED?\b(?: FUNDS)?(?:[ -]+(?:DEBIT|CREDIT|OUT|IN))?\s+"#, options: .regularExpression) {
            let words = upper[lead.upperBound...].split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                .filter { !$0.allSatisfy(\.isNumber) }
            let name = words.prefix(4).joined(separator: " ")
            return name.count >= 3 ? name : nil
        }
        guard upper.range(of: #"\bWIRE\b"#, options: .regularExpression) != nil, let start = upper.range(of: "A/C:") else { return nil }
        var rest = String(upper[start.upperBound...])
        // The recipient ends where the next labelled field begins.
        if let end = rest.range(of: #"\s(REF|ORG|IMAD|TRN|BNF|OBI|SSN|ID)\s?[:/]"#, options: .regularExpression) { rest = String(rest[..<end.lowerBound]) }
        let words = rest.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { !$0.allSatisfy(\.isNumber) }
        let name = words.prefix(4).joined(separator: " ")
        return name.count >= 3 ? name : nil
    }

    /// Removes card-processor prefixes ("TST*", "SQ *", "SP ") from upper-cased text.
    static func stripPrefixes(_ text: String) -> String {
        var s = text
        var changed = true
        while changed {
            changed = false
            for p in prefixes where s.hasPrefix(p) && s.count > p.count + 2 {
                s = String(s.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        return s
    }

    /// A readable name straight from the bank's text, e.g. "TST*WOGIES BAR &amp; GRILL -" → "Wogies Bar & Grill".
    static func displayName(for description: String) -> String {
        var words = keyword(for: description, maxTokens: 5)
            .replacingOccurrences(of: "&AMP;", with: "&")
            .split(separator: " ").map(String.init)
        // "HOTEL/H LAS VEGAS NV": a slash ends the name. ("EVERY.TO/CHARGES" keeps "EVERY.TO".)
        if let i = words.firstIndex(where: { $0.contains("/") }) {
            words = Array(words[..<i]) + [String(words[i].split(separator: "/").first ?? "")]
        }
        // Card statements end with the city and state ("… NEW YORK NY"); drop the state code.
        if words.count > 2, let last = words.last, usStates.contains(last) { words.removeLast() }
        // "EVERY EVERY.TO" → "EVERY"
        words = words.enumerated().filter { i, w in
            i == 0 || w.split(separator: ".").first.map(String.init) != words[i - 1]
        }.map(\.element)
        // Banks cut names off mid-word ("DICKSON'S FARMSTAND M"); drop a dangling letter.
        if words.count > 1, let last = words.last, last.count == 1, last.allSatisfy(\.isLetter) { words.removeLast() }
        while let last = words.last, words.count > 1, last.allSatisfy({ !$0.isLetter && !$0.isNumber }) { words.removeLast() }
        return prettify(words.joined(separator: " "))
    }

    private static let usStates: Set<String> = [
        "AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "DC", "FL", "GA", "HI", "ID", "IL", "IN", "IA", "KS", "KY", "LA",
        "ME", "MD", "MA", "MI", "MN", "MS", "MO", "MT", "NE", "NV", "NH", "NJ", "NM", "NY", "NC", "ND", "OH", "OK", "OR",
        "PA", "RI", "SC", "SD", "TN", "TX", "UT", "VT", "VA", "WA", "WV", "WI", "WY",
    ]

    static func keyword(for description: String, maxTokens: Int) -> String {
        let original = description.uppercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var s = stripPrefixes(original)
        if let star = s.firstIndex(of: "*") {
            let before = s[..<star].trimmingCharacters(in: .whitespaces)
            let after = s[s.index(after: star)...].trimmingCharacters(in: .whitespaces)
            s = before.filter(\.isLetter).count >= 3 ? before : after
        }
        var kept: [String] = []
        for token in s.split(separator: " ").map(String.init) {
            let digits = token.filter(\.isNumber).count
            if token.contains("#") || digits >= 3 || (digits > 0 && digits * 2 >= token.count) { break }
            kept.append(token)
            if kept.count == maxTokens { break }
        }
        var result = kept.joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -,.:/"))
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: " -,.:/?'"))
        if result.filter(\.isLetter).count < 3 { result = String(original.prefix(30)) }
        // A rule only works if the keyword appears literally in the description.
        if !original.contains(result) { result = String(original.prefix(30)) }
        return result.replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "\\", with: "")
    }

    static func prettify(_ keyword: String) -> String {
        let vowels = Set("aeiou")
        return keyword.lowercased().split(separator: " ").map { word -> String in
            let w = String(word).trimmingCharacters(in: CharacterSet(charactersIn: "?"))
            if w.hasSuffix(".com") { return w.prefix(1).uppercased() + w.dropFirst() }
            // Initials like NYC, CVS, BJS stay in capitals.
            if w.count <= 4, w.allSatisfy(\.isLetter), !w.contains(where: vowels.contains) { return w.uppercased() }
            if w.count <= 3, ["llc", "inc", "co"].contains(w) == false, w.allSatisfy(\.isLetter), keyword.count <= 4 {
                return w.uppercased()
            }
            // Buon'italia → Buon'Italia, but Dickson's stays Dickson's.
            let parts = w.split(separator: "'", omittingEmptySubsequences: false).map(String.init)
            return parts.enumerated().map { i, p in
                i == 0 || p.count > 1 ? p.prefix(1).uppercased() + p.dropFirst() : p
            }.joined(separator: "'")
        }.joined(separator: " ")
    }
}

// MARK: - Built-in list of well-known merchants (instant and works offline)

enum KnownMerchants {
    /// Order matters: first match wins (e.g. "UBER EATS" before "UBER").
    static let list: [(pattern: String, name: String, category: Category)] = [
        // Payments, transfers, income
        ("PAYMENT THANK YOU", "Card Payment", .transfer), ("PAYMENT - THANK", "Card Payment", .transfer),
        ("AUTOPAY", "Card Payment", .transfer), ("AUTOMATIC PAYMENT", "Card Payment", .transfer),
        ("ONLINE PAYMENT", "Card Payment", .transfer), ("MOBILE PAYMENT", "Card Payment", .transfer),
        ("CREDIT CARD PAYMENT", "Card Payment", .transfer), ("EPAY", "Card Payment", .transfer),
        ("VENMO", "Venmo", .transfer), ("TRANSFER", "Transfer", .transfer),
        ("PAYROLL", "Paycheck", .income), ("DIRECT DEP", "Paycheck", .income), ("DIR DEP", "Paycheck", .income),
        ("SALARY", "Paycheck", .income), ("INTEREST PAID", "Bank Interest", .investmentIncome), ("DIVIDEND", "Dividend", .investmentIncome),
        ("IRS TREAS", "Tax Refund", .income), ("TAX REFUND", "Tax Refund", .income), ("SOC SEC", "Social Security", .income),
        // Fees
        ("INTEREST CHARGE", "Interest Charge", .fees), ("LATE FEE", "Late Fee", .fees), ("ANNUAL FEE", "Annual Fee", .fees),
        ("FOREIGN TRANSACTION", "Foreign Transaction Fee", .fees), ("SERVICE FEE", "Service Fee", .fees),
        ("OVERDRAFT", "Overdraft Fee", .fees), ("ATM FEE", "ATM Fee", .fees),
        // Dining (before Uber/Amazon)
        ("UBER EATS", "Uber Eats", .dining), ("UBER *EATS", "Uber Eats", .dining), ("UBEREATS", "Uber Eats", .dining),
        ("DOORDASH", "DoorDash", .dining), ("GRUBHUB", "Grubhub", .dining), ("STARBUCKS", "Starbucks", .dining),
        ("DUNKIN", "Dunkin'", .dining), ("MCDONALD", "McDonald's", .dining), ("CHIPOTLE", "Chipotle", .dining),
        ("PANERA", "Panera", .dining), ("CHICK-FIL-A", "Chick-fil-A", .dining), ("TACO BELL", "Taco Bell", .dining),
        ("WENDY", "Wendy's", .dining), ("BURGER KING", "Burger King", .dining), ("DOMINO", "Domino's", .dining),
        ("PIZZA HUT", "Pizza Hut", .dining), ("SWEETGREEN", "Sweetgreen", .dining), ("PEETS", "Peet's Coffee", .dining),
        ("SUBWAY", "Subway", .dining), ("SHAKE SHACK", "Shake Shack", .dining), ("PANDA EXPRESS", "Panda Express", .dining),
        ("TST*", "Restaurant", .dining),
        // Subscriptions (before Amazon/Apple)
        ("NETFLIX", "Netflix", .subscriptions), ("SPOTIFY", "Spotify", .subscriptions), ("HULU", "Hulu", .subscriptions),
        ("DISNEY PLUS", "Disney+", .subscriptions), ("DISNEYPLUS", "Disney+", .subscriptions),
        ("HBO MAX", "Max", .subscriptions), ("APPLE.COM/BILL", "Apple", .subscriptions),
        ("PRIME VIDEO", "Prime Video", .subscriptions), ("AMAZON PRIME", "Amazon Prime", .subscriptions),
        ("AUDIBLE", "Audible", .subscriptions), ("YOUTUBE", "YouTube", .subscriptions),
        ("PARAMOUNT", "Paramount+", .subscriptions), ("PEACOCK", "Peacock", .subscriptions),
        ("SIRIUSXM", "SiriusXM", .subscriptions), ("NYTIMES", "New York Times", .subscriptions), ("NEW YORK TIMES", "New York Times", .subscriptions),
        ("PATREON", "Patreon", .subscriptions), ("DROPBOX", "Dropbox", .subscriptions),
        ("ADOBE", "Adobe", .subscriptions), ("MICROSOFT", "Microsoft", .subscriptions),
        ("ANTHROPIC", "Claude", .subscriptions), ("CLAUDE.AI", "Claude", .subscriptions), ("OPENAI", "OpenAI", .subscriptions),
        ("GOOGLE *", "Google", .subscriptions),
        // Wine & spirits
        ("TOTAL WINE", "Total Wine", .wine), ("BEVMO", "BevMo", .wine), ("WINE.COM", "Wine.com", .wine), ("VIVINO", "Vivino", .wine),
        ("DRIZLY", "Drizly", .wine), ("ASTOR WINES", "Astor Wines & Spirits", .wine), ("KLWINES", "K&L Wine Merchants", .wine),
        ("BINNY", "Binny's", .wine), ("SPEC'S", "Spec's", .wine), ("RESERVEBAR", "ReserveBar", .wine), ("FLAVIAR", "Flaviar", .wine),
        ("SEELBACHS", "Seelbachs", .wine), ("WINE & SPIRITS", "Wine & Spirits Shop", .wine), ("WINE AND SPIRITS", "Wine & Spirits Shop", .wine),
        ("WINES & SPIRITS", "Wine & Spirits Shop", .wine), ("WINE & LIQUOR", "Wine & Liquor Shop", .wine), ("WINE AND LIQUOR", "Wine & Liquor Shop", .wine),
        ("LIQUOR STORE", "Liquor Store", .wine), ("LIQUORS", "Liquor Store", .wine),
        // Groceries
        ("WHOLEFDS", "Whole Foods", .groceries), ("WHOLE FOODS", "Whole Foods", .groceries),
        ("TRADER JOE", "Trader Joe's", .groceries), ("SAFEWAY", "Safeway", .groceries), ("KROGER", "Kroger", .groceries),
        ("PUBLIX", "Publix", .groceries), ("ALDI", "Aldi", .groceries), ("WEGMANS", "Wegmans", .groceries),
        ("COSTCO", "Costco", .groceries), ("SPROUTS", "Sprouts", .groceries), ("FOOD LION", "Food Lion", .groceries),
        ("STOP & SHOP", "Stop & Shop", .groceries), ("ALBERTSONS", "Albertsons", .groceries), ("RALPHS", "Ralphs", .groceries),
        ("MEIJER", "Meijer", .groceries), ("INSTACART", "Instacart", .groceries), ("HARRIS TEETER", "Harris Teeter", .groceries),
        ("WINCO", "WinCo", .groceries), ("FRED MEYER", "Fred Meyer", .groceries), ("SHOPRITE", "ShopRite", .groceries),
        ("VONS", "Vons", .groceries), ("H-E-B", "H-E-B", .groceries), ("GIANT", "Giant", .groceries),
        // Health
        ("CVS", "CVS", .health), ("WALGREENS", "Walgreens", .health), ("RITE AID", "Rite Aid", .health),
        ("PHARMACY", "Pharmacy", .health), ("DENTAL", "Dentist", .health), (" DDS", "Dentist", .health), (" DMD", "Dentist", .health), ("ORTHODONT", "Dentist", .health),
        (" MD ", "Medical", .health), ("PEDIATRIC", "Medical", .health), ("DERMATOLOG", "Medical", .health), ("URGENT CARE", "Medical", .health),
        ("OPTOMETR", "Medical", .health), ("PHYSICAL THERAPY", "Medical", .health), ("MEDICAL", "Medical", .health),
        ("HOSPITAL", "Hospital", .health), ("CLINIC", "Clinic", .health), ("FITNESS", "Gym", .health),
        ("EQUINOX", "Equinox", .health), ("SOULCYCLE", "SoulCycle", .health), ("PELOTON", "Peloton", .health), ("PLANET FITNESS", "Planet Fitness", .health),
        // Home
        ("HOME DEPOT", "Home Depot", .home), ("LOWES", "Lowe's", .home), ("LOWE'S", "Lowe's", .home),
        ("IKEA", "IKEA", .home), ("WAYFAIR", "Wayfair", .home), ("ACE HARDWARE", "Ace Hardware", .home),
        ("POTTERYBARN", "Pottery Barn", .home), ("POTTERY BARN", "Pottery Barn", .home), ("WILLIAMS-SONOMA", "Williams Sonoma", .home),
        ("WILLIAMS SONOMA", "Williams Sonoma", .home), ("WEST ELM", "West Elm", .home), ("CRATE & BARREL", "Crate & Barrel", .home),
        ("CRATE&BARREL", "Crate & Barrel", .home), ("RESTORATION HARDWARE", "RH", .home), ("BED BATH", "Bed Bath & Beyond", .home),
        // Shopping
        ("AMAZON", "Amazon", .shopping), ("AMZN", "Amazon", .shopping), ("TARGET", "Target", .shopping),
        ("WALMART", "Walmart", .shopping), ("WAL-MART", "Walmart", .shopping), ("BEST BUY", "Best Buy", .shopping),
        ("APPLE STORE", "Apple Store", .shopping), ("EBAY", "eBay", .shopping), ("ETSY", "Etsy", .shopping),
        ("TJ MAXX", "TJ Maxx", .shopping), ("TJMAXX", "TJ Maxx", .shopping), ("MARSHALLS", "Marshalls", .shopping),
        ("NORDSTROM", "Nordstrom", .shopping), ("MACY", "Macy's", .shopping), ("KOHL", "Kohl's", .shopping),
        // Transportation
        ("UBER", "Uber", .transportation), ("LYFT", "Lyft", .transportation), ("SHELL", "Shell", .transportation),
        ("CHEVRON", "Chevron", .transportation), ("EXXON", "Exxon", .transportation), ("MOBIL", "Mobil", .transportation),
        ("ARCO", "ARCO", .transportation), ("SUNOCO", "Sunoco", .transportation), ("CITGO", "Citgo", .transportation),
        ("VALERO", "Valero", .transportation), ("SPEEDWAY", "Speedway", .transportation), ("CIRCLE K", "Circle K", .transportation),
        ("WAWA", "Wawa", .transportation), ("PARKING", "Parking", .transportation), ("TAXI", "Taxi", .transportation), ("CURB ", "Curb", .transportation), ("PARKMOBILE", "ParkMobile", .transportation),
        ("EZPASS", "E-ZPass", .transportation), ("E-ZPASS", "E-ZPass", .transportation), ("FASTRAK", "FasTrak", .transportation),
        ("JIFFY LUBE", "Jiffy Lube", .transportation),
        ("MTA*", "MTA", .transportation), ("NYCT", "MTA", .transportation), ("OMNY", "MTA", .transportation), ("NJ TRANSIT", "NJ Transit", .transportation),
        ("METRO-NORTH", "Metro-North", .transportation), ("LIRR", "LIRR", .transportation), ("AMTRAK", "Amtrak", .travel),
        // Bills
        ("COMCAST", "Comcast", .bills), ("XFINITY", "Xfinity", .bills), ("VERIZON", "Verizon", .bills),
        ("AT&T", "AT&T", .bills), ("T-MOBILE", "T-Mobile", .bills), ("SPECTRUM", "Spectrum", .bills),
        ("PG&E", "PG&E", .bills), ("CON ED", "Con Edison", .bills), ("DUKE ENERGY", "Duke Energy", .bills),
        ("GEICO", "GEICO", .bills), ("STATE FARM", "State Farm", .bills), ("PROGRESSIVE", "Progressive", .bills),
        ("ALLSTATE", "Allstate", .bills), ("INSURANCE", "Insurance", .bills),
        // Travel
        ("DELTA AIR", "Delta", .travel), ("UNITED AIRLINES", "United", .travel), ("AMERICAN AIR", "American Airlines", .travel),
        ("SOUTHWEST", "Southwest", .travel), ("JETBLUE", "JetBlue", .travel), ("ALASKA AIR", "Alaska Airlines", .travel),
        ("MARRIOTT", "Marriott", .travel), ("HILTON", "Hilton", .travel), ("HYATT", "Hyatt", .travel),
        ("AIRBNB", "Airbnb", .travel), ("EXPEDIA", "Expedia", .travel), ("BOOKING.COM", "Booking.com", .travel),
        ("HOTEL", "Hotel", .travel), ("HERTZ", "Hertz", .travel), ("AVIS", "Avis", .travel),
        // Entertainment
        ("TICKETMASTER", "Ticketmaster", .entertainment), ("STUBHUB", "StubHub", .entertainment),
        ("AMC ", "AMC Theatres", .entertainment), ("REGAL", "Regal", .entertainment), ("STEAM", "Steam", .entertainment),
        ("PLAYSTATION", "PlayStation", .entertainment), ("XBOX", "Xbox", .entertainment), ("NINTENDO", "Nintendo", .entertainment),
        ("CINEMA", "Movies", .entertainment), ("THEATER", "Theater", .entertainment), ("THEATRE", "Theater", .entertainment),
        // Personal care
        ("SALON", "Salon", .personal), ("BARBER", "Barber", .personal), ("ULTA", "Ulta", .personal),
        ("SEPHORA", "Sephora", .personal), ("GREAT CLIPS", "Great Clips", .personal),
        // Giving
        ("DONATION", "Donation", .gifts), ("CHARITY", "Charity", .gifts), ("GOFUNDME", "GoFundMe", .gifts),
        ("RED CROSS", "Red Cross", .gifts), ("CHURCH", "Church", .gifts),
        // Generic words, checked last
        ("PIZZA", "Restaurant", .dining), ("CAFE", "Restaurant", .dining), ("COFFEE", "Restaurant", .dining),
        ("RESTAURANT", "Restaurant", .dining), ("GRILL", "Restaurant", .dining), ("BAKERY", "Restaurant", .dining),
        ("DINER", "Restaurant", .dining), ("SUSHI", "Restaurant", .dining), ("TAVERN", "Restaurant", .dining),
        ("BISTRO", "Restaurant", .dining), ("TRATTORIA", "Restaurant", .dining), ("DELI ", "Restaurant", .dining),
    ]

    /// Patterns that describe a kind of place ("HOSPITAL", "CAFE") rather than a specific business.
    /// The bank's own category is more reliable than these (e.g. "NYU HOSPITAL CAFE" is lunch, not a doctor).
    private static let genericNames: Set<String> = [
        "Restaurant", "Hotel", "Pharmacy", "Medical", "Clinic", "Hospital", "Gym", "Parking", "Insurance",
        "Taxi", "Movies", "Theater", "Salon", "Barber", "Donation", "Charity", "Church", "Dentist", "Transfer",
    ]

    /// Money moving on the investment side, taxes, card payments and housing: recognized from the bank's
    /// own wording. Some depend on direction: "Blackstone Fund" coming in is a distribution, going out
    /// a capital call. `flow`: -1 = only money in, +1 = only money out, 0 = either.
    static let flows: [(pattern: String, name: String, category: Category, flow: Int)] = [
        // Investments
        ("DIST SBS", "Blackstone Distributions", .investmentIncome, 0),
        ("BLACKSTONE FUND", "Blackstone Fund Distributions", .investmentIncome, -1),
        ("BLACKSTONE FUND", "Blackstone Capital Calls", .investing, 1),
        ("WEBCAPCALL", "Blackstone Capital Calls", .investing, 0), ("CAPITAL CALL", "Capital Call", .investing, 0),
        ("ADVANCE ON LOAN", "Investment Loan Advance", .investmentLoan, 0),
        ("PRINCIPAL PAYMENT ON LOAN", "Investment Loan Principal", .investmentLoan, 0),
        ("INTEREST PAYMENT ON LOAN", "Investment Loan Interest", .investmentLoan, 0),
        ("COINBASE CARD", "Coinbase Card Payment", .transfer, 0), ("COINBASE", "Coinbase", .investing, 0),
        ("FID BKG SVC", "Fidelity", .investing, 0), ("FIDELITY BROKERAGE", "Fidelity", .investing, 0),
        ("VANGUARD", "Vanguard", .investing, 0), ("SCHWAB BROKERAGE", "Schwab", .investing, 0),
        ("ROBINHOOD", "Robinhood", .investing, 0), ("REIT FUNDING", "REIT Redemption", .investing, 0),
        ("E*TRADE", "E*TRADE", .investing, 0), ("ETRADE", "E*TRADE", .investing, 0), ("MERRILL", "Merrill", .investing, 0),
        ("MORGAN STANLEY", "Morgan Stanley", .investing, 0), ("TD AMERITRADE", "TD Ameritrade", .investing, 0),
        ("WEALTHFRONT", "Wealthfront", .investing, 0), ("BETTERMENT", "Betterment", .investing, 0),
        ("INTERACTIVE BROK", "Interactive Brokers", .investing, 0), ("TREASURYDIRECT", "TreasuryDirect", .investing, 0),
        ("SCHWAB", "Schwab", .investing, 0), ("MONEYLINK", "Schwab", .investing, 0), ("KRAKEN", "Kraken", .investing, 0),
        ("DISTRIBUTION", "Distribution", .investmentIncome, -1), ("CAPITAL GAIN", "Capital Gains", .investmentIncome, -1),
        ("REALTY INCOME", "Realty Income Dividend", .investmentIncome, 0),
        ("ORION PROPERTIES", "Orion Properties Dividend", .investmentIncome, 0),
        ("INTEREST PAYMENT", "Bank Interest", .investmentIncome, -1),
        // Taxes
        ("USATAXPYMT", "IRS", .taxes, 0), ("IRS USATAX", "IRS", .taxes, 0), ("NYS DTF", "New York State Tax", .taxes, 0),
        ("FRANCHISE TAX", "State Tax", .taxes, 0), ("TAX PAYMNT", "State Tax", .taxes, 0),
        ("IRS TREAS", "IRS", .taxes, 0), ("TAX REFUND", "Tax Refund", .taxes, -1), ("TAX REF", "Tax Refund", .taxes, -1),
        ("DEPT OF REVENUE", "State Tax", .taxes, 0), ("DEPARTMENT OF REVENUE", "State Tax", .taxes, 0),
        ("STATE TAX", "State Tax", .taxes, 0), ("EST TAX", "Estimated Tax", .taxes, 1), ("IRS ", "IRS", .taxes, 1),
        ("NYCPROPTAX", "NYC Property Tax", .home, 0), ("PROPERTY TAX", "Property Tax", .home, 0), ("PROPTAX", "Property Tax", .home, 0),
        // Paying off credit cards (named by issuer so each can be matched to its statements)
        ("CHASE CREDIT CRD", "Chase Card Payment", .transfer, 0), ("AMEX EPAYMENT", "American Express Card Payment", .transfer, 0),
        ("AMERICAN EXPRESS ACH", "American Express Card Payment", .transfer, 0),
        ("CITI AUTOPAY", "Citi Card Payment", .transfer, 0), ("CITI CARD ONLINE", "Citi Card Payment", .transfer, 0),
        ("CAPITAL ONE CRCARDPMT", "Capital One Card Payment", .transfer, 0), ("CAPITAL ONE MOBILE PMT", "Capital One Card Payment", .transfer, 0),
        ("DISCOVER E-PAYMENT", "Discover Card Payment", .transfer, 0), ("APPLECARD GSBANK", "Apple Card Payment", .transfer, 0),
        ("BARCLAYCARD", "Barclays Card Payment", .transfer, 0),
        ("BANK OF AMERICA CREDIT CARD", "Bank of America Card Payment", .transfer, 0), ("BK OF AMER VISA", "Bank of America Card Payment", .transfer, 0),
        ("WELLS FARGO CARD", "Wells Fargo Card Payment", .transfer, 0), ("WF CREDIT CARD", "Wells Fargo Card Payment", .transfer, 0),
        ("SYNCHRONY", "Synchrony Card Payment", .transfer, 1), ("CARDMEMBER SERV", "U.S. Bank Card Payment", .transfer, 1),
        ("DISCOVER CARD", "Discover Card Payment", .transfer, 1), ("DISCOVER DC PYMNTS", "Discover Card Payment", .transfer, 1),
        ("CRCARDPMT", "Card Payment", .transfer, 0),
        // Housing and household, paid straight from the bank
        ("CHASE ACH", "Loan Payment", .home, 1), ("ALLAREAREALTY", "All Area Realty (Common Charges)", .home, 0),
        ("MORTGAGE", "Mortgage", .home, 1), ("MTG PYMT", "Mortgage", .home, 1), ("MTG PMT", "Mortgage", .home, 1),
        ("HOME LOAN", "Mortgage", .home, 1), ("LOANCARE", "Mortgage", .home, 1), ("MR COOPER", "Mortgage", .home, 1),
        ("MASSMUTUAL", "MassMutual Life Insurance", .bills, 0), ("THE CINCINNATI I", "Cincinnati Insurance", .bills, 0),
        // Cash and cheques
        ("ATM SURCHARGE REFUND", "ATM Fee Refund", .fees, 0), ("ATM WITHDRAW", "Cash Withdrawal", .other, 0),
        ("NON-CHASE ATM", "Cash Withdrawal", .other, 0), ("CHECK #", "Checks Written", .other, 0),
        ("APPLE CASH", "Apple Cash to People", .other, 1),
        ("EXT TRNSFR", "Transfer", .transfer, 0), ("ONLINE TRANSFER", "Transfer", .transfer, 0),
    ]

    /// Rules that are only a likely guess (a payment to a bank could be a mortgage, a car loan…).
    /// These are filed as guesses, so they show up in Double-Check instead of being trusted silently.
    static let tentativeNames: Set<String> = ["Loan Payment"]

    /// `generic: false` returns only specific businesses (Starbucks, Con Edison…); `true` only generic words.
    /// - amount: positive = money out. Needed for the direction-dependent rules above.
    static func match(_ description: String, amount: Double? = nil, generic: Bool) -> Suggestion? {
        let d = description.uppercased()
        if !generic, let hit = flows.first(where: { rule in
            d.contains(rule.pattern) && (rule.flow == 0 || amount == nil || (rule.flow > 0) == ((amount ?? 0) > 0))
        }) {
            return Suggestion(name: hit.name, category: hit.category, source: .knownMerchant)
        }
        guard let hit = list.first(where: { d.contains($0.pattern) }),
              genericNames.contains(hit.name) == generic else { return nil }
        let name = generic ? KeywordExtractor.displayName(for: description) : hit.name
        return Suggestion(name: name, category: hit.category, source: .knownMerchant)
    }
}

// MARK: - The bank's own category (Chase, Capital One, Amex and others include one in their CSVs)

enum BankCategory {
    /// Finds a "Category" column in a statement, if the bank provides one.
    static func column(in table: CSVTable, mapping: ColumnMapping) -> Int? {
        guard let header = table.header else { return nil }
        let used = Set([mapping.dateColumn, mapping.descriptionColumn, mapping.amountColumn, mapping.debitColumn, mapping.creditColumn].compactMap { $0 })
        return header.indices.first { i in
            !used.contains(i) && header[i].lowercased().contains("category")
        }
    }

    /// Bank category names (Chase, Amex "Group-Subgroup", Capital One, Discover…) → ours.
    static func map(_ bank: String) -> Category? {
        let b = bank.lowercased()
        let table: [(String, Category)] = [
            ("grocer", .groceries), ("supermarket", .groceries),
            ("food & drink", .dining), ("dining", .dining), ("restaurant", .dining), ("bar & cafe", .dining),
            ("gas", .transportation), ("fuel", .transportation), ("automotive", .transportation),
            ("transportation", .transportation), ("parking", .transportation), ("taxi", .transportation),
            ("airline", .travel), ("lodging", .travel), ("travel", .travel), ("hotel", .travel), ("car rental", .travel),
            ("health", .health), ("medical", .health), ("pharmac", .health), ("fitness", .health),
            ("bills", .bills), ("utilit", .bills), ("insurance", .bills), ("communication", .bills), ("phone", .bills),
            ("entertainment", .entertainment), ("recreation", .entertainment),
            ("personal", .personal), ("gift", .gifts), ("donation", .gifts), ("charit", .gifts),
            ("home", .home), ("fees", .fees), ("interest", .fees),
            ("merchandise", .shopping), ("shopping", .shopping), ("department", .shopping), ("retail", .shopping),
            ("education", .other), ("professional", .other), ("business service", .other), ("government", .other),
        ]
        return table.first { b.contains($0.0) }?.1
    }
}

// MARK: - Never wait forever on the model

/// Runs an on-device model call with a time limit. The model occasionally stalls (while it is
/// still downloading, or under memory pressure); the app must carry on without it.
enum Timeout {
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if claimed { return false }; claimed = true; return true }
    }

    /// Returns nil if `work` hasn't finished after `seconds`. (The stalled call is abandoned, not awaited.)
    static func run<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async -> T?) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let gate = Gate()
            Task {
                let value = await work()
                if gate.claim() { continuation.resume(returning: value) }
            }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                if gate.claim() { continuation.resume(returning: nil) }
            }
        }
    }
}

// MARK: - Apple Intelligence (free, on-device, private)

struct SuggestionInput {
    let keyword: String
    let description: String
    let averageAmount: Double
}

enum CategorySuggester {
    static var isAvailable: Bool { SystemLanguageModel.default.isAvailable }

    /// Why Apple Intelligence can't help right now, in words Tony can act on. Nil when it's working.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Apple Intelligence is turned off. Turn it on in System Settings → Apple Intelligence & Siri and I'll sort new payees for you."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still getting ready on this Mac (it downloads in the background). I'll sort the rest as soon as it's done."
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn't support Apple Intelligence, so payees I don't recognize need a category from you."
        case .unavailable:
            return "Apple Intelligence isn't available right now, so payees I don't recognize need a category from you."
        }
    }

    private static let instructions = """
    You help someone sort their credit card and bank transactions into budget categories.
    Give one guess for every numbered transaction.
    Restaurants, cafes, cafeterias, bars, delis and coffee shops are Dining. Supermarkets, markets, butchers and food shops are Groceries.
    Software, apps, websites and online services billed every month are Subscriptions. Dry cleaners and laundry are Personal Care.
    Radio stations, public media and nonprofits are Gifts & Giving. Newsstands and convenience stores are Shopping.
    Distributions, dividends and interest are Investment Income. Capital calls and brokerage or crypto purchases are Investing & Capital Calls.
    Payments to the IRS or a state tax department are Income Taxes. Paying a credit card bill or moving money between own accounts is Payments & Transfers.
    A refund or credit belongs in the category of what was bought.
    For the name, use the business name as written in the transaction, tidied up. Never guess a different business.
    Do not use apostrophes or quotation marks in names (write Joes Pizza, not Joe's Pizza).
    """

    /// Words that suggest money moving between accounts rather than a purchase.
    private static let moneyMovementWords = [
        "PAYMENT", "TRANSFER", "XFER", "ZELLE", "VENMO", "PAYPAL", "CASH APP", "DEPOSIT", "ACH", "WIRE",
        "ATM", "WITHDRAW", "CHECK", "PAYROLL", "DIR DEP", "DIRECT DEP", "INTEREST", "DIVIDEND", "SALARY",
        "DIST ", "DISTRIBUTION", "CAPITAL", "LOAN", "TAX", "BROKERAGE", "REDEMPTION", "REMOTE ONLINE", "CASHOUT",
    ]

    static func mightBeMoneyMovement(_ description: String) -> Bool {
        let d = description.uppercased()
        return moneyMovementWords.contains { d.contains($0) }
    }

    /// - examples: places Tony already categorized, so the model follows his habits.
    static func suggest(_ items: [SuggestionInput], examples: [MerchantRule] = []) async -> [String: Suggestion] {
        guard isAvailable, !items.isEmpty else { return [:] }
        // Purchases can't be "Payments & Transfers" or "Income": the small on-device model reaches for
        // those when unsure, so only offer them when the bank's text mentions a payment or transfer.
        let (movement, purchases) = (items.filter { mightBeMoneyMovement($0.description) },
                                     items.filter { !mightBeMoneyMovement($0.description) })
        var out: [String: Suggestion] = [:]
        let limit = 30.0 + 12.0 * Double(items.count)
        if !purchases.isEmpty {
            out.merge(await Timeout.run(limit) { await ask(purchases, examples: examples, purchasesOnly: true) } ?? [:]) { a, _ in a }
        }
        if !movement.isEmpty {
            out.merge(await Timeout.run(limit) { await ask(movement, examples: examples, purchasesOnly: false) } ?? [:]) { a, _ in a }
        }
        // If a batch fails or skips some, try the stragglers one at a time.
        if items.count > 1 {
            for item in items where out[item.keyword] == nil {
                out.merge(await suggest([item], examples: examples)) { a, _ in a }
            }
        }
        return out
    }

    private static func ask(_ items: [SuggestionInput], examples: [MerchantRule], purchasesOnly: Bool) async -> [String: Suggestion] {
        guard let schema = AISchemas.merchantGuesses(count: items.count, purchasesOnly: purchasesOnly) else { return [:] }
        let list = items.enumerated().map { i, item in
            let kind = item.averageAmount < 0 ? "refund or credit" : "spent"
            return "\(i + 1). \(item.description) (\(kind) \(Money.format(abs(item.averageAmount))))"
        }.joined(separator: "\n")
        var prompt = list
        // Tony's own categories: the model won't reach for them unless told they exist.
        let own = Category.custom.map(\.rawValue)
        let ownNote = own.isEmpty ? "" : "This person made their own categories: \(own.joined(separator: ", ")). "
            + "Prefer one of them whenever a transaction fits it (for example anything for pets goes in a Pets category).\n\n"
        if examples.isEmpty, !own.isEmpty { prompt = ownNote + "Transactions to sort:\n" + list }
        if !examples.isEmpty {
            let lines = examples.suffix(20).map { "\($0.name): \($0.category.rawValue)" }.joined(separator: "\n")
            prompt = ownNote + "Places this person already sorted (follow the same habits):\n\(lines)\n\nTransactions to sort:\n\(list)"
        }
        var out: [String: Suggestion] = [:]
        do {
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt, schema: schema,
                                                     options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 80 * items.count + 50))
            for guess in try response.content.value([GeneratedContent].self, forProperty: "guesses") {
                guard let number = try? guess.value(Int.self, forProperty: "number"), (1...items.count).contains(number),
                      let categoryName = try? guess.value(String.self, forProperty: "category"),
                      let category = matchCategory(categoryName) else { continue }
                let item = items[number - 1]
                let name = ((try? guess.value(String.self, forProperty: "name")) ?? "").trimmingCharacters(in: .whitespaces)
                out[item.keyword] = Suggestion(name: honestName(name, for: item.description),
                                               category: category, source: .appleIntelligence)
            }
        } catch {
            if ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] != nil { print("DEBUG AI suggest error: \(error)") }
        }
        return out
    }

    /// Uses the model's tidier name only if it's really the same business: every letter of it must
    /// appear, in order, in the bank's text. This stops "HUMM" becoming "Hummus" or "DICKSON'S" "Dixon's".
    static func honestName(_ name: String, for description: String) -> String {
        let fallback = KeywordExtractor.displayName(for: description)
        // The model sometimes keeps the processor prefix ("SP Rancho Gordo").
        let stripped = KeywordExtractor.stripPrefixes(name.uppercased())
        let name = stripped.count < name.count ? String(name.suffix(stripped.count)) : name
        let letters = { (s: String) in s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let n = letters(name), d = letters(description.replacingOccurrences(of: "&amp;", with: "&"))
        guard n.count >= 3, d.contains(n) else { return fallback }
        // "GDP Essen" or "Westside Market- 77": the model kept junk around the plain name, so use that.
        let f = letters(fallback)
        if n.count > f.count, n.contains(f) { return fallback }
        return String(name.prefix(40))
    }

    private static func matchCategory(_ s: String) -> Category? {
        let lower = s.lowercased()
        return Category.pickable.first { $0.rawValue.lowercased() == lower }
            ?? Category.pickable.first { lower.contains($0.rawValue.lowercased()) }
            ?? Category.pickable.first { $0.rawValue.lowercased().contains(lower) && lower.count >= 4 }
    }
}
