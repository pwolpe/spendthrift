import SwiftUI

/// The app checking itself. `scripts/test.sh` runs this against the made-up statements in
/// `Tests/Fixtures`, and against a copy of a real library when there is one, and fails on any FAIL line.
///
/// Three parts: `logic` needs no data at all; `books` holds for any library, however large or odd
/// (these are the sums the screens show, so a screen can never say two different things);
/// the rest changes things the way a person would and checks what happened.
@MainActor
enum SelfTest {
    private static var passed = 0, failed = 0

    private static func check(_ name: String, _ ok: Bool) {
        if ok { passed += 1 } else { failed += 1 }
        print("SELFTEST \(ok ? "PASS" : "FAIL") \(name)")
    }

    // MARK: Rules that need no data

    /// A charge built by hand: `days` after 2024-01-15.
    private static func charge(_ payee: String, _ amount: Double, day days: Int, category: Category = .subscriptions) -> Transaction {
        let start = DateParsing.isoDay("2024-01-15") ?? .now
        let date = Calendar.current.date(byAdding: .day, value: days, to: start) ?? start
        return Transaction(id: UUID(), date: date, month: Month(date: date), description: payee.uppercased(), amount: amount,
                           merchant: payee, merchantKey: "own:" + payee, category: category, account: "Card", accountID: UUID(),
                           source: .user, needsCheck: false, isOverride: false)
    }

    /// `count` charges a month apart, the first on 2024-01-15, with these amounts (the last is repeated if short).
    private static func monthly(_ payee: String, _ amounts: [Double], count: Int? = nil) -> [Transaction] {
        let start = DateParsing.isoDay("2024-01-15") ?? .now
        return (0..<(count ?? amounts.count)).map { i in
            let date = Calendar.current.date(byAdding: .month, value: i, to: start) ?? start
            var t = charge(payee, amounts[min(i, amounts.count - 1)], day: 0)
            t = Transaction(id: t.id, date: date, month: Month(date: date), description: t.description, amount: t.amount, merchant: payee,
                            merchantKey: t.merchantKey, category: t.category, account: "Card", accountID: t.accountID,
                            source: .user, needsCheck: false, isOverride: false)
            return t
        }
    }

    private static func recurringRules() {
        let end = DateParsing.isoDay("2025-01-20") ?? .now
        let steady = RecurringEngine.find(in: monthly("Steady", [9.99], count: 12), asOf: end)
        check("twelve equal monthly charges are a monthly bill, 12 times the amount a year",
              steady.count == 1 && steady[0].cadence == .monthly && abs(steady[0].yearly - 119.88) < 0.001 && steady[0].isActive && steady[0].chargeIDs.count == 12)
        let wild = monthly("Wild", [12, 80, 25, 140, 9, 60, 33, 110], count: 8)
        check("a payee charged monthly at wildly different amounts is not a bill", RecurringEngine.find(in: wild, asOf: end).isEmpty)
        let yearly = RecurringEngine.find(in: [charge("Annual", 99, day: 0), charge("Annual", 99, day: 365)], asOf: end)
        check("two charges a year apart are a yearly bill", yearly.count == 1 && yearly[0].cadence == .yearly && abs(yearly[0].yearly - 99) < 0.001)
        check("two charges a month apart are not yet a bill", RecurringEngine.find(in: [charge("Fresh", 5, day: 0), charge("Fresh", 5, day: 30)], asOf: end).isEmpty)
        let crept = RecurringEngine.find(in: monthly("Creeper", [10, 10, 11, 12]), asOf: DateParsing.isoDay("2024-04-20") ?? .now)
        check("a price that went from 10 to 12 crept up 2, or 24 a year", crept.count == 1 && abs(crept[0].creep - 2) < 0.001 && abs(crept[0].extraPerYear - 24) < 0.001)
        let gone = RecurringEngine.find(in: monthly("Gone", [15], count: 6), asOf: DateParsing.isoDay("2024-06-15")?.addingTimeInterval(4 * 30 * 86_400) ?? .now)
        check("a bill whose last charge was four gaps ago has ended", gone.count == 1 && !gone[0].isActive && gone[0].next == nil)
        let old = RecurringEngine.find(in: monthly("Old", [15.99], count: 14), asOf: DateParsing.isoDay("2025-03-01") ?? .now)
        check("a long-running active subscription worth $60 or more a year is worth a look",
              old.count == 1 && old[0].isForgotten
              && RecurringEngine.find(in: monthly("Rent", [1500], count: 14).map { var t = $0; t = Transaction(id: t.id, date: t.date, month: t.month, description: t.description, amount: t.amount, merchant: t.merchant, merchantKey: t.merchantKey, category: .home, account: t.account, accountID: t.accountID, source: .user, needsCheck: false, isOverride: false); return t },
                                      asOf: DateParsing.isoDay("2025-03-01") ?? .now).allSatisfy { !$0.isForgotten })
        let steps = InsightEngine.subscriptions(asOf: Month(year: 2024, month: 4), in: monthly("Netflix", [15.49], count: 4))
        check("the older subscriptions list still finds a monthly charge", steps.count == 1 && steps[0].merchant == "Netflix" && abs(steps[0].monthlyAmount - 15.49) < 0.001)
    }

    private static func logic() {
        recurringRules()
        changeAndBudgetRules()
        reviewRules()
        // Who a line belongs to.
        check("a known name needs its whole name", KnownMerchants.match("PARAMOUNT+ 888-274-5343 CA", generic: false)?.name == "Paramount+"
              && KnownMerchants.match("PARAMOUNT HOTEL NEW YORK NY", generic: false) == nil)
        check("money coming in from a holding is investment income, whoever pays it",
              KnownMerchants.match("ACME REIT DIVIDEND PPD", amount: -120, generic: false)?.category == .investmentIncome
              && KnownMerchants.match("FUND XYZ DISTRIBUTION", amount: -900, generic: false)?.category == .investmentIncome
              && KnownMerchants.match("FUND XYZ DISTRIBUTION", amount: 900, generic: false)?.category != .investmentIncome)
        check("a mobile deposit is not a petrol station", KnownMerchants.match("MOBILE DEPOSIT REF 1234", generic: false)?.name != "Mobil")
        check("a spelling ignores what changes charge to charge",
              MerchantResolver.spelling("STARBUCKS STORE 04127  NEW YORK") == MerchantResolver.spelling("STARBUCKS STORE 99310 NEW YORK"))
        check("a spelling the person separated wins",
              MerchantResolver.key(for: "PARAMOUNT+ CA", amount: 5, existingKeys: [String](), spellings: ["PARAMOUNT+ CA": "own:1"]) == "own:1"
              && MerchantResolver.key(for: "PARAMOUNT+ CA", amount: 5, existingKeys: [String]()) == "known:Paramount+")
        check("finding a payee ignores punctuation and case", PlacesView.squeeze("Barry's  Bootcamp") == "barrysbootcamp")

        // The quick way of reading a day must agree with the careful one, every day, clock changes included.
        let careful = DateParsing.formatter("yyyy-MM-dd")
        var day = careful.date(from: "2015-01-01")!, agree = true
        for _ in 0..<(17 * 366) {
            let text = careful.string(from: day)
            if let quick = DateParsing.isoDay(text), quick != careful.date(from: text) { agree = false }
            day = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        }
        check("days are read the same the quick way and the careful way", agree
              && DateParsing.isoDay("2026-02-30") == nil && DateParsing.isoDay("2026-13-01") == nil && DateParsing.isoDay("11/03/2026") == nil
              && DateParsing.isoDay("2024-02-29") != nil && Month(isoDay: "2026-03-09") == Month(year: 2026, month: 3))

        // Tidying payees: what counts as one name, and what the app may do unasked.
        check("tidy: one name written two ways", TidyEngine.namesAgree("Buon Italia", "Buon'Italia") && TidyEngine.namesAgree("Chopt", "Chopt Creative Salad")
              && TidyEngine.namesAgree("The President Hotel", "President Hotel") && TidyEngine.namesAgree("Jake's Saloon", "Jakes Saloon"))
        check("tidy: two places of one chain are two names", !TidyEngine.namesAgree("Aloft Orlando", "Aloft Miami Doral") && !TidyEngine.namesAgree("Westside Market", "Westside Tavern"))
        check("tidy: a name fits the line it is written on, or does not", TidyEngine.nameFits("Kindle Unlimited", spelling: "KINDLE UNLTD -- WA")
              && TidyEngine.nameFits("Westside Market", spelling: "WESTSIDE MARKET NEW YORK NY") && !TidyEngine.nameFits("Mobil", spelling: "AMTRAK WASHINGTON DC"))
        do {
            func spelled(_ payee: String, _ text: String, _ category: Category = .dining, byHand: Bool = false) -> TidyEngine.Spelling {
                TidyEngine.Spelling(payee: payee, text: text, count: 3, typical: 20, category: category, byHand: byHand, sample: text)
            }
            let twin = TidyEngine.Pair(kind: .combine, a: spelled("Jakes Saloon", "JAKES SALOON NEW YORK NY"), b: spelled("Jake's Saloon", "JAKES SALOON - NY"))
            let hotels = TidyEngine.Pair(kind: .combine, a: spelled("Aloft Orlando", "ALOFT ORLANDO FL", .travel), b: spelled("Aloft Miami", "ALOFT MIAMI FL", .travel))
            let mixed = TidyEngine.Pair(kind: .separate, a: spelled("Westside Market", "WESTSIDE MARKET NEW YORK NY", .groceries), b: spelled("Westside Market", "WESTSIDE TAVERN NEW YORK NY", .groceries))
            let wrong = TidyEngine.Pair(kind: .combine, a: spelled("Gym on 23rd", "CHELSEA WINE COUNTRY NEW YORK NY", .health), b: spelled("Chelsea Wine Country", "APLPAY CHELSEA WINE COUNTRY - NY", .wine))
            let plan = TidyEngine.Pair(kind: .combine, a: spelled("Kindle Unlimited", "KINDLE UNLTD -- WA", .subscriptions), b: spelled("Kindle", "KINDLE SVCS -- WA", .shopping))
            check("tidy: sure and agreeing names are combined; unsure is left", TidyEngine.verdict(for: twin, probabilitySame: 0.97) == .combine && TidyEngine.verdict(for: twin, probabilitySame: 0.8) == .leave)
            check("tidy: two hotels of one chain are left alone however sure the model is", TidyEngine.verdict(for: hotels, probabilitySame: 0.99) == .leave)
            check("tidy: a mixed payee is separated only when the model is sure", TidyEngine.verdict(for: mixed, probabilitySame: 0.02) == .separate && TidyEngine.verdict(for: mixed, probabilitySame: 0.3) == .leave)
            check("tidy: charges under a name that does not describe them go where they belong", TidyEngine.verdict(for: wrong, probabilitySame: 0.99) == .rehome)
            check("tidy: a subscription and its maker's other charges are only offered", TidyEngine.verdict(for: plan, probabilitySame: 0.95, recurring: ["Kindle Unlimited"]) == .suggest)
            let found = TidyEngine.pairs(in: ["Westside Market": [mixed.a, mixed.b], "Jakes Saloon": [twin.a], "Jake's Saloon": [twin.b]], alreadyJudged: [])
            check("tidy: pairs worth asking about are found, and never asked about twice", Set(found.map(\.kind)) == [.combine, .separate]
                  && TidyEngine.pairs(in: ["Westside Market": [mixed.a, mixed.b]], alreadyJudged: [mixed.id]).isEmpty)
            check("tidy: a payee named by hand is not second-guessed",
                  TidyEngine.pairs(in: ["Westside Market": [spelled("Westside Market", "WESTSIDE MARKET NEW YORK NY", byHand: true), mixed.b]], alreadyJudged: []).isEmpty)
        }

        // Looking a charge up in the mail: the amount as mail writes it, in the days around it.
        check("mail: an amount is searched with and without its comma", MailSearch.amounts(87383) == ["87,383.00", "87383.00"] && MailSearch.amounts(-12.5) == ["12.50"])
        check("mail: the search covers a week either side", { () -> Bool in
            let q = MailSearch.query(amount: 1234.56, date: DateParsing.isoDay("2026-03-10")!, provider: .gmail)
            return q == "(\"1,234.56\" OR \"1234.56\") after:2026/03/03 before:2026/03/18"
                && MailSearch.url(amount: 1234.56, date: DateParsing.isoDay("2026-03-10")!, provider: .gmail)?.absoluteString.hasPrefix("https://mail.google.com/mail/u/0/#search/") == true
        }())

        // What is said about a payee is true of its charges, and nothing is said about a payee barely seen.
        do {
            let acct = UUID()
            func charge(_ day: String, _ amount: Double, _ payee: String) -> Transaction {
                Transaction(id: UUID(), date: DateParsing.isoDay(day)!, month: Month(isoDay: day)!, description: payee.uppercased(), amount: amount, merchant: payee,
                            merchantKey: payee, category: .dining, account: "Card", accountID: acct, source: .known, needsCheck: false, isOverride: false)
            }
            let now = DateParsing.isoDay("2026-11-01")!
            let cafe = (1...10).map { charge("2026-\(String(format: "%02d", $0))-05", 40, "Cafe") } + (1...10).map { charge("2025-\(String(format: "%02d", $0))-05", 10, "Cafe") }
            let others = ["A", "B", "C", "D"].flatMap { name in (1...3).map { charge("2026-0\($0)-10", 5, name) } }
            let said = PayeeFacts.lines(for: cafe, among: cafe + others, asOf: now)
            check("payee facts: rank, growth and a dearer visit are noticed", said.contains { $0.hasPrefix("Your largest Dining payee") && $0.contains("$400") }
                  && said.contains { $0.contains("up from $100") } && said.contains { $0.contains("$40.00 now") && $0.contains("$10.00") })
            check("payee facts: nothing is said about a payee seen twice", PayeeFacts.lines(for: Array(cafe.prefix(2)), among: cafe, asOf: now).isEmpty)
        }

        // Orders against card charges.
        func item(_ order: String, _ cents: Int, _ date: String, gift: Bool = false) -> OrderItem {
            var item = OrderItem(orderID: order, shop: .store, date: date, shipment: date + "T10:00", name: "Thing from \(order)", cents: cents, quantity: 1)
            item.giftPart = gift ? true : nil
            return item
        }
        let items = [item("A", 1999, "2026-03-01"), item("B", 5000, "2026-03-10"), item("C", 8000, "2026-04-01", gift: true)]
        let exact = OrderMatcher.Charge(id: UUID(), date: "2026-03-02", cents: 1999, shop: .store)
        let pinned = OrderMatcher.Charge(id: UUID(), date: "2026-03-11", cents: 3100, shop: .store)
        let partGift = OrderMatcher.Charge(id: UUID(), date: "2026-04-02", cents: 6500, shop: .store)
        let stranger = OrderMatcher.Charge(id: UUID(), date: "2026-06-15", cents: 777, shop: .store)
        let matches = OrderMatcher.match([exact, pinned, partGift, stranger], to: items, pins: [pinned.id.uuidString: "B"])
        check("an order that adds up to a charge is matched exactly", matches[exact.id.uuidString]?.kind == .exact && matches[exact.id.uuidString]?.items == [0])
        check("the shop's own record outranks the amounts", matches[pinned.id.uuidString]?.kind == .recorded && matches[pinned.id.uuidString]?.items == [1])
        check("a gift balance explains a smaller charge", matches[partGift.id.uuidString]?.kind == .lessCredit && matches[partGift.id.uuidString]?.items == [2])
        check("a charge with no order stays unmatched", matches[stranger.id.uuidString] == nil)

        // Answers may only quote amounts the app computed.
        check("dollar amounts are read out of an answer", ChatAnalyst.dollarAmounts(in: "You spent $1,234.56, then $80.") == ["$1,234.56", "$80"])
        check("months step across a year", Month(year: 2026, month: 1).adding(-1) == Month(year: 2025, month: 12) && Month(year: 2025, month: 12) < Month(year: 2026, month: 1))
        readingFiles()
        knownNames()
        privacy()
        engines()
        orderChecks()
        pdfStatements()
        storage()
    }

    // MARK: Reading what a bank hands over

    private static func csv(_ s: String) -> CSVTable? { try? CSVTable(data: Data(s.utf8)) }
    private static func readDay(_ s: String, _ format: String) -> String? { DateParsing.parse(s, format: format).map { DateParsing.iso.string(from: $0) } }

    private static func readingFiles() {
        check("csv: quotes, a comma inside quotes and CRLF", CSV.parse("a,\"b,c\",d\r\n1,2,3\n") == [["a", "b,c", "d"], ["1", "2", "3"]])
        check("csv: a byte-order mark, doubled quotes", CSV.parse("\u{FEFF}\"say \"\"hi\"\"\",x") == [["say \"hi\"", "x"]])
        check("csv: blank lines are dropped", CSV.parse("a,b\n\n,\nc,d") == [["a", "b"], ["c", "d"]])
        check("csv: the delimiter is sniffed", CSV.detectDelimiter("Datum;Betrag;Text\n01.02.2026;12,50;Shop") == ";" && CSV.detectDelimiter("a\tb\tc\n1\t2\t3") == "\t")

        check("money: parentheses, a trailing minus, a sign before the currency",
              MoneyParsing.parse("(1,234.56)") == -1234.56 && MoneyParsing.parse("12.50-") == -12.5 && MoneyParsing.parse("-$5.00") == -5)
        check("money: a decimal comma and a euro sign", MoneyParsing.parse("1.234,56") == 1234.56 && MoneyParsing.parse("€ 7,50") == 7.5)
        check("money: words and nothing are not an amount", MoneyParsing.parse("abc") == nil && MoneyParsing.parse("") == nil)
        check("money: a number too big for a Double is not an amount", MoneyParsing.parse("1e999") == nil && MoneyParsing.parse("-1e999") == nil)

        let formats: [(String, String)] = [("03/09/2026", "MM/dd/yyyy"), ("3/9/2026", "M/d/yyyy"), ("2026-03-09", "yyyy-MM-dd"), ("03/09/26", "MM/dd/yy"),
                                           ("3/9/26", "M/d/yy"), ("03-09-2026", "MM-dd-yyyy"), ("2026/03/09", "yyyy/MM/dd"), ("09 Mar 2026", "dd MMM yyyy"),
                                           ("Mar 9, 2026", "MMM d, yyyy"), ("Mar 09, 2026", "MMM dd, yyyy"), ("9 Mar 2026", "d MMM yyyy"), ("09/03/2026", "dd/MM/yyyy")]
        check("dates: every listed format reads the same day", formats.allSatisfy { readDay($0.0, $0.1) == "2026-03-09" })
        check("dates: a time after the day is shed", readDay("09/02/2026 12:00:00 AM", "MM/dd/yyyy") == "2026-09-02" && readDay("2026-03-09T10:00:00Z", "yyyy-MM-dd") == "2026-03-09")
        check("dates: impossible days are refused", readDay("13/01/2026", "MM/dd/yyyy") == nil && readDay("2026-02-30", "yyyy-MM-dd") == nil)
        check("dates: the US order wins a tie, evidence overrides it",
              DateParsing.guessFormat(for: ["01/02/2026", "03/04/2026"]) == "MM/dd/yyyy"
              && DateParsing.guessFormat(for: ["13/01/2026", "25/02/2026", "01/03/2026"]) == "dd/MM/yyyy"
              && DateParsing.guessFormat(for: ["01/02/1850"]) == nil)

        let chase = "Transaction Date,Post Date,Description,Category,Type,Amount,Memo\n11/03/2026,11/04/2026,STARBUCKS #1,Food & Drink,Sale,-4.50,\n11/05/2026,11/06/2026,PAYMENT THANK YOU,,Payment,100.00,\n"
        check("columns: a Chase-style file reads, and the payment line fixes the sign",
              csv(chase).flatMap { t in ColumnDetector.detect(t).map { Normalizer.rows(from: t, mapping: $0).rows } }
              == [CanonicalRow(date: "2026-11-03", description: "STARBUCKS #1", amount: 4.5, bankCategory: "Food & Drink"),
                  CanonicalRow(date: "2026-11-05", description: "PAYMENT THANK YOU", amount: -100, bankCategory: nil)])
        check("columns: whole-number amounts are still amounts", csv("Date,Description,Amount\n2026-03-01,Rent,-1500\n2026-03-02,Coffee,-4\n").flatMap(ColumnDetector.detect)?.amountColumn == 2)
        check("columns: a column of whole numbers under another name is not money",
              csv("Date,Description,Check Number\n2026-03-01,Rent,1500\n2026-03-02,Coffee,1501\n").flatMap(ColumnDetector.detect) == nil)

        let mapping = { (amount: Int?, debit: Int?, credit: Int?, type: Int?, negative: Bool) in
            ColumnMapping(dateColumn: 0, dateFormat: "MM/dd/yyyy", descriptionColumn: 1, amountColumn: amount, debitColumn: debit, creditColumn: credit,
                          purchasesAreNegative: negative, typeColumn: type)
        }
        let split = Normalizer.rows(from: CSVTable(header: ["Date", "D", "Debit", "Credit"],
                                                   rows: [["03/01/2026", "COFFEE", "4.50", ""], ["03/02/2026", "PAYROLL", "", "2000.00"], ["bad", "X", "1.00", ""]],
                                                   signature: nil, suggestedName: nil), mapping: mapping(nil, 2, 3, nil, false))
        check("normalize: debit and credit columns, a bad date counted as skipped", split.rows.map(\.amount) == [4.5, -2000] && split.skipped == 1)
        let typed = Normalizer.rows(from: CSVTable(header: ["Date", "D", "Amt", "Type"], rows: [["03/01/2026", "A", "10.00", "Debit"], ["03/02/2026", "B", "5.00", "Credit"]],
                                                   signature: nil, suggestedName: nil), mapping: mapping(2, nil, nil, 3, false))
        check("normalize: a Debit or Credit word gives the direction", typed.rows.map(\.amount) == [10, -5])
        let zero = Normalizer.rows(from: CSVTable(header: nil, rows: [["03/01/2026", "A", "0.00"]], signature: nil, suggestedName: nil), mapping: mapping(2, nil, nil, nil, true))
        check("normalize: no negative zero", zero.rows.first?.amount.sign == .plus)

        // A description with an unquoted comma makes a row of the wrong width: it is left out, and counted.
        let ragged = csv("Date,Description,Amount\n2026-03-01,Coffee,-4.00\n2026-03-02,Lunch, with Sam,-12.00\n2026-03-03,Rent,-1500.00\n")
        let raggedRows = ragged.flatMap { t in ColumnDetector.detect(t).map { Normalizer.rows(from: t, mapping: $0) } }
        check("csv: a row of the wrong width is counted as skipped, not lost silently", ragged?.droppedRows == 1 && raggedRows?.rows.count == 2 && raggedRows?.skipped == 1)

        let ofx = "OFXHEADER:100\n<OFX>\n<FI><ORG>Chase</FI>\n<ACCTID>000123456789\n<STMTTRN><DTPOSTED>20261103120000[-5:EST]<TRNAMT>-4.50<NAME>STARBUCKS &amp; CO<MEMO>NEW YORK</STMTTRN>\n<STMTTRN><DTPOSTED>20261105<TRNAMT>1000.00<NAME>PAYROLL</STMTTRN>\n</OFX>"
        let parsed = try? OFX.parse(Data(ofx.utf8), fallbackName: "x")
        check("ofx: signs flip and entities decode", parsed?.rows == [CanonicalRow(date: "2026-11-03", description: "STARBUCKS & CO", amount: 4.5, bankCategory: nil),
                                                                       CanonicalRow(date: "2026-11-05", description: "PAYROLL", amount: -1000, bankCategory: nil)])
        check("ofx: the account is named from ORG and ACCTID", parsed?.signature == "ofx:chase:6789" && parsed?.suggestedName == "Chase ••6789")
        check("ofx: a file with no transactions is an error", (try? OFX.parse(Data("<OFX></OFX>".utf8), fallbackName: "x")) == nil)

        let file = { (name: String) in URL(fileURLWithPath: "/x/" + name) }
        check("names: card digits and the account name come from a file name",
              StatementReader.cardDigits(in: file("Chase4090_Activity_20261109.csv")) == "4090"
              && StatementReader.accountName(for: file("Chase4090_Activity_20261109.csv")) == "Chase ••4090")
        check("names: a date in the name is not a card", StatementReader.cardDigits(in: file("Coinbase_2026-10-12.csv")) == nil)
        check("names: a year is not a card, unless a word says it is one",
              StatementReader.cardDigits(in: file("transactions_2026.csv")) == nil && StatementReader.cardDigits(in: file("Visa ending 2026.csv")) == "2026"
              && StatementReader.accountName(for: file("transactions_2026.csv")) == "Account")
        check("names: Marcus is not March, March is", StatementReader.accountName(for: file("Marcus_Savings.csv")) == "Marcus Savings"
              && StatementReader.accountName(for: file("Statement_Mar_2026.csv")) == "Account"
              && StatementReader.accountName(for: file("Junction_Decatur.csv")) == "Junction Decatur")

        check("keyword: a processor prefix and a store number come off",
              KeywordExtractor.keyword(for: "TST* BLUE DOOR CAFE #42 SEATTLE WA") == "BLUE DOOR CAFE"
              && KeywordExtractor.displayName(for: "TST* BLUE DOOR CAFE #42 SEATTLE WA") == "Blue Door Cafe"
              && KeywordExtractor.keyword(for: "SQ *JOE'S PIZZA 12345") == "JOE'S PIZZA")
        check("keyword: a wire is named by its recipient",
              KeywordExtractor.wireRecipient("DOMESTIC MANUAL WIRE ACME DESIGN LLC") == "ACME DESIGN LLC"
              && KeywordExtractor.wireRecipient("Consumer Online International Wire Via: X A/C: Hsbc Uk Bank Plc Birmingham REF: 123") == "HSBC UK BANK PLC"
              && KeywordExtractor.wireRecipient("WIRE TRANSFER FEE") == nil)
    }

    // MARK: Who a line belongs to

    private static func knownNames() {
        check("known: names, direction-dependent rules and card payments",
              KnownMerchants.match("STARBUCKS #1234 NEW YORK NY", generic: false)?.name == "Starbucks"
              && KnownMerchants.match("TOTAL WINE & MORE #123", generic: false)?.category == .wine
              && KnownMerchants.match("ACME DISTRIBUTION", amount: -900, generic: false)?.category == .investmentIncome
              && KnownMerchants.match("ACME DISTRIBUTION", amount: 900, generic: false) == nil
              && KnownMerchants.match("CHASE CREDIT CRD AUTOPAY 1234", amount: 500, generic: false)?.name == "Chase Card Payment")
        check("known: the bank's own category, and places joining places",
              BankCategory.map("Food & Drink") == .dining && BankCategory.map("Gas/Automotive") == .transportation
              && BankCategory.map("Bills & Utilities") == .bills && BankCategory.map("Zzz") == nil
              && MerchantResolver.key(for: "DICKSON'S FARMSTAND M", amount: 10, existingKeys: ["DICKSON'S FARMSTAND"]) == "DICKSON'S FARMSTAND")
        check("known: T-Mobile is not Mobil", KnownMerchants.match("T-MOBILE*BILL 800-937-8997", generic: false)?.name == "T-Mobile"
              && KnownMerchants.match("MOBIL 12345 NEWARK NJ", generic: false)?.name == "Mobil")
        check("known: a brand must be a word of its own",
              KnownMerchants.match("MARCO'S PIZZA 123", generic: false) == nil && KnownMerchants.match("ARCO #123", generic: false)?.name == "ARCO"
              && KnownMerchants.match("CONSULTANT GROUP", generic: false) == nil && KnownMerchants.match("DAVIS HARDWARE", generic: false) == nil
              && KnownMerchants.match("AVIS RENT A CAR 123", generic: false)?.name == "Avis")
        check("known: STAIRS are not the IRS, the IRS is", KnownMerchants.match("ACME STAIRS & RAILS", amount: 50, generic: false) == nil
              && KnownMerchants.match("IRS TREAS 310 TAX REF", amount: -50, generic: false)?.category == .taxes
              && KnownMerchants.match("ACH PYMT IRS PAYMENT", amount: 50, generic: false)?.name == "IRS")
        check("known: a lookalike is not an investment firm", KnownMerchants.match("MERRILL'S BAKERY", amount: 5, generic: false) == nil
              && KnownMerchants.match("VANGUARDIA CAFE", amount: 5, generic: false) == nil && KnownMerchants.match("MERRILL LYNCH", amount: 5, generic: false)?.name == "Merrill")
        // What banks print, still found: processor marks, store numbers, names run into more letters.
        let real: [(String, String)] = [
            ("STARBUCKS #1234", "Starbucks"), ("WHOLEFDS MKT 10234", "Whole Foods"), ("AMZN MKTP US*2K4AB1", "Amazon"), ("AMAZON.COM*1A2B3", "Amazon"),
            ("APPLE.COM/BILL", "Apple"), ("PARAMOUNT+ CA", "Paramount+"), ("MCDONALDS F1234", "McDonald's"), ("MCDONALD'S 12345", "McDonald's"),
            ("EXXONMOBIL 4412", "Exxon"), ("UBER *EATS HELP.UBER.COM", "Uber Eats"), ("UBEREATS", "Uber Eats"), ("UBER *TRIP", "Uber"),
            ("TRADER JOES #123", "Trader Joe's"), ("BINNY'S BEVERAGE", "Binny's"), ("TRADER JOE'S #123", "Trader Joe's"), ("DUNKIN #123", "Dunkin'"), ("DUNKIN' DONUTS", "Dunkin'"),
            ("AMERICAN AIRLINES 0012", "American Airlines"), ("DELTA AIR LINES 0062", "Delta"), ("CON EDISON PAYMENT", "Con Edison"), ("STOP & SHOP 123", "Stop & Shop"),
            ("AT&T*BILL PAYMENT", "AT&T"), ("CVS/PHARMACY #123", "CVS"), ("GOOGLE *YOUTUBEPREMIUM", "YouTube"), ("GOOGLE *SERVICES", "Google"),
            ("NETFLIX.COM", "Netflix"), ("PAYPAL *NETFLIX", "Netflix"), ("HOME DEPOT #1234", "Home Depot"), ("LOWE'S #0123", "Lowe's"), ("WAL-MART SUPERCENTER", "Walmart"),
            ("COSTCO WHSE #0123", "Costco"), ("SHELL OIL 57444", "Shell"), ("CHICK-FIL-A #01234", "Chick-fil-A"), ("DOORDASH*CHIPOTLE", "DoorDash"),
            ("E-ZPASS NY 1234", "E-ZPass"), ("MTA*NYCT PAYGO", "MTA"), ("SPOTIFY USA", "Spotify"), ("TOTAL WINE & MORE", "Total Wine"), ("WINE & SPIRITS OF NYC", "Wine & Spirits Shop"),
        ]
        let missed = real.filter { KnownMerchants.match($0.0, amount: 10, generic: false)?.name != $0.1 }.map(\.0)
        check("known: every kind of line a bank prints is still found" + (missed.isEmpty ? "" : " (missed: \(missed.joined(separator: "; ")))"), missed.isEmpty)
        check("known: a place of a kind is still found by its word", KnownMerchants.match("NYU HOSPITAL CAFE", generic: true) != nil
              && KnownMerchants.match("MAMMA'S PIZZERIA", generic: true) == nil && KnownMerchants.match("JOES PIZZA", generic: true)?.category == .dining
              && KnownMerchants.match("CITY PHARMACY", generic: true)?.category == .health && KnownMerchants.match("PHARMACYST CAFE", generic: true) != nil)
        check("issuers: a whole word, so a bank that merely starts like one is not it",
              BudgetStore.issuer(in: "Chase Sapphire ••1234") == "Chase" && BudgetStore.issuer(in: "Amex Gold") == "American Express"
              && BudgetStore.issuer(in: "Citi Double Cash") == "Citi" && BudgetStore.issuer(in: "Citizens Bank ••1234") == nil
              && BudgetStore.issuer(in: "Purchase Plus") == nil && BudgetStore.issuer(in: "Monzo") == nil && BudgetStore.issuer(in: "US Bank Checking") == "U.S. Bank")
        check("issuers: signatures and names give the last digits",
              BudgetStore.digits(ofSignature: "pdf:chase:4090") == "4090" && BudgetStore.digits(ofSignature: "date|desc|amount|#4090") == "4090"
              && BudgetStore.digits(inName: "Chase ••4090") == "4090")
        let table = PhraseTable([("AVIS", "a"), ("IRS ", "b"), (" DDS", "c"), ("MCDONALD", "d"), ("TST*", "e")], openEnded: ["MCDONALD"])
        check("whole words: a name matches only where no letter or digit touches it",
              table.firstMatch(in: "AVIS 12") == "a" && table.firstMatch(in: "DAVIS") == nil && table.firstMatch(in: "AVISO") == nil && table.firstMatch(in: "STAIRS X") == nil
              && table.firstMatch(in: "PAY IRS NOW") == "b" && table.firstMatch(in: "DR JONES DDS") == "c" && table.firstMatch(in: "ADDS") == nil
              && table.firstMatch(in: "MCDONALDS") == "d" && table.firstMatch(in: "AMCDONALD") == nil && table.firstMatch(in: "TST*CAFE") == "e")
        check("whole words: the earliest name in the list wins", PhraseTable([("MOBIL", "x"), ("T-MOBILE", "y")]).firstMatch(in: "T-MOBILE") == "y"
              && PhraseTable([("UBER EATS", "x"), ("UBER", "y")]).firstMatch(in: "UBER EATS") == "x")
    }

    // MARK: What leaves the Mac

    private static func privacy() {
        check("scrub: phones, emails and long ids leave a merchant line", Redactor.scrub("AMZN MKTP US*2K4AB1 800-555-1212") == "AMZN MKTP US*2K4AB1"
              && Redactor.scrub("CHECKCARD 000652456372 JOE'S PIZZA") == "CHECKCARD JOE'S PIZZA" && Redactor.scrub("ZELLE TO jane.doe@example.com") == "ZELLE TO")
        check("scrub: an SSN leaves, and a line that is all ids survives", Redactor.scrub("SSN 123-45-6789") == "SSN" && Redactor.scrub("0006524563 12") == "0006524563 12")
        check("account names sent to a model have no digits", Redactor.accountLabel("Chase ••4090") == "Chase" && Redactor.accountLabel("Checking 000123456789") == "Checking"
              && Redactor.accountLabel("Amex Gold") == "Amex Gold")
        check("blank: name, address, city line, card and account digits are replaced",
              Redactor.blank("JANE Q PUBLIC\n123 MAIN STREET\nNEW YORK, NY 10001\nCard 4111 1111 1111 1111 Account ending in 4321")
              == "[name]\n[address]\n[city, state, zip]\nCard [number] Account ending in [number]")
        check("blank: the holder is the capitalized words before the rest of the line", Redactor.holderNames(in: "ANA LOPEZ  We accept relay calls\n12 OAK ST") == ["ANA LOPEZ"])
        check("blank: a name in Title Case is still a name", !Redactor.blank("Jane Q Public\n123 Main Street\nNew York, NY 10001").contains("Jane")
              && !Redactor.blank("Jane Q Public\n123 Main Street\nNew York, NY 10001").contains("Public"))
        check("blank: a heading above an address is not taken for a name", Redactor.blank("Customer Service\n123 Main Street").hasPrefix("Customer Service")
              && Redactor.blank("Payment Address\n123 Main Street").hasPrefix("Payment Address"))
        let identity = Redactor.blank("SSN: 123-45-6789 EIN 12-3456789 call 212-555-0199 or (212) 555-0100")
        check("blank: SSNs, EINs and phone numbers do not leave the Mac", !identity.contains("6789") && !identity.contains("3456789") && !identity.contains("0199") && !identity.contains("0100"))
        check("blank: an amount or a date is not a phone number", Redactor.blank("10/14 BEST BUY 1,249.99\nTotal 2026-11-03 100.00") == "10/14 BEST BUY 1,249.99\nTotal 2026-11-03 100.00")

        // Statements taken out of a zip are not left in the temporary folder.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SpendthriftZip-selftest-\(UUID().uuidString)", isDirectory: true)
        let inside = folder.appendingPathComponent("a.csv")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data("x".utf8).write(to: inside)
        let waiting = PendingImport(fileURL: inside, fileHash: "h", table: CSVTable(header: nil, rows: [], signature: nil, suggestedName: nil), mapping: nil, candidates: [], suggestedName: "n", signature: "s")
        BudgetStore.removeUnpacked([folder], keepingThoseUsedBy: [waiting])
        let keptForPicker = FileManager.default.fileExists(atPath: inside.path)
        check("a zip's folder is found from a file inside it", BudgetStore.unpackedFolder(containing: inside)?.lastPathComponent == folder.lastPathComponent)
        BudgetStore.removeUnpacked([folder])
        check("unpacked zip folders are removed, unless a file in one waits for its columns", keptForPicker && !FileManager.default.fileExists(atPath: folder.path))
    }


    // MARK: Rules from the review of the newest code

    private static func reviewRules() {
        func spelled(_ payee: String, _ text: String, _ category: Category = .dining, byHand: Bool = false) -> TidyEngine.Spelling {
            TidyEngine.Spelling(payee: payee, text: text, count: 3, typical: 20, category: category, byHand: byHand, sample: text)
        }
        // Tidy: what the person named, renamed, filed or confirmed is never moved, split or folded unasked.
        let dads = spelled("Dad's Dinners", "WESTSIDE TAVERN NEW YORK NY", .dining, byHand: true), tavern = spelled("Westside Tavern", "WESTSIDE TAVERN - NY")
        check("tidy: charges are not moved out of a payee the person named, only offered",
              TidyEngine.verdict(for: .init(kind: .combine, a: dads, b: tavern), probabilitySame: 0.99) == .suggest
              && TidyEngine.verdict(for: .init(kind: .combine, a: dads.marked(byHand: false), b: tavern), probabilitySame: 0.99) == .rehome)
        let main = spelled("Westside Market", "WESTSIDE MARKET NEW YORK NY", .groceries, byHand: true), odd = spelled("Westside Market", "WESTSIDE TAVERN NEW YORK NY", .groceries)
        check("tidy: a payee the person named is not taken apart, and two they made are not folded together",
              TidyEngine.verdict(for: .init(kind: .separate, a: main, b: odd), probabilitySame: 0.01) == .leave
              && TidyEngine.verdict(for: .init(kind: .separate, a: main.marked(byHand: false), b: odd), probabilitySame: 0.01) == .separate
              && TidyEngine.verdict(for: .init(kind: .combine, a: spelled("Jakes Saloon", "JAKES SALOON NY", byHand: true), b: spelled("Jake's Saloon", "JAKES SALOON - NY", byHand: true)), probabilitySame: 0.99) == .leave)
        // One id for a pair of spellings whatever the kind; answers saved under the old, kind-prefixed ids still count.
        let twinA = spelled("Jakes Saloon", "JAKES SALOON NEW YORK NY"), twinB = spelled("Jake's Saloon", "JAKES SALOON - NY")
        let asCombine = TidyEngine.Pair(kind: .combine, a: twinA, b: twinB), asSeparate = TidyEngine.Pair(kind: .separate, a: twinB, b: twinA)
        check("tidy: a pair has one id whatever the kind, so it is asked about once", asCombine.id == asSeparate.id && asCombine.id != "combine|" + asCombine.id)
        check("tidy: an answer saved under the old kind-prefixed id still covers the pair",
              TidyEngine.pairs(in: ["Jakes Saloon": [twinA], "Jake's Saloon": [twinB]], alreadyJudged: [asCombine.legacyIDs[0]]).isEmpty
              && TidyEngine.pairs(in: ["Jakes Saloon": [twinA], "Jake's Saloon": [twinB]], alreadyJudged: [asCombine.legacyIDs[1]]).isEmpty
              && !TidyEngine.pairs(in: ["Jakes Saloon": [twinA], "Jake's Saloon": [twinB]], alreadyJudged: []).isEmpty)
        check("tidy: a pair the model did not answer is asked once more, then left alone",
              !TidyBook(judged: ["a": -2]).settled.contains("a") && TidyBook(judged: ["a": -3, "b": -1, "c": 0.5]).settled == ["a", "b", "c"])
        check("tidy: of several records of one name, the person's, then the busiest, then the smallest key speaks",
              TidyEngine.bestKey(among: [("b", false, 9), ("a", true, 2), ("c", false, 9)]) == "a"
              && TidyEngine.bestKey(among: [("c", false, 9), ("b", false, 9), ("d", false, 3)]) == "b"
              && TidyEngine.bestKey(among: [("x", false, 1), ("y", false, 7)]) == "y" && TidyEngine.bestKey(among: []) == nil)

        // Needs and wants.
        check("needs and wants: a record made later takes the person's word first, then the busiest record's",
              TrimEngine.inherited([("k1", 0, 1), ("k2", 0.9, 50)]) == 0 && TrimEngine.inherited([("k1", 0.7, 1), ("k2", 0.2, 5)]) == 0.2 && TrimEngine.inherited([]) == nil)
        let bar = tx("2026-11-02", 60, "Bar", .dining), barToo = tx("2026-11-03", 40, "Bar", .dining), rent = tx("2026-11-01", 1000, "Landlord", .home)
        let chosenCharge: (Transaction) -> Bool = { $0.id == bar.id }
        let byPayee = TrimEngine.ranked([bar, barToo, rent], byPayee: true, chosenOnly: false, optional: chosenCharge)
        let chosenOnly = TrimEngine.ranked([bar, barToo, rent], byPayee: true, chosenOnly: true, optional: chosenCharge)
        check("trim: a line carries what was chosen in it, and the figure is the sum of those amounts",
              byPayee.lines.first { $0.name == "Bar" }.map { abs($0.chosen - 60) < 0.01 && abs($0.total - 100) < 0.01 } == true && abs(byPayee.chosen - 60) < 0.01
              && abs(chosenOnly.chosen - 60) < 0.01 && abs(chosenOnly.total - 1100) < 0.01)
        check("trim: the chosen-only list holds lines that are mostly chosen, ranked by what was chosen",
              chosenOnly.lines.map(\.name) == ["Bar"] && TrimEngine.ranked([bar, barToo, rent], byPayee: false, chosenOnly: true, optional: chosenCharge).lines.map(\.name) == ["Dining"])
        check("needs and wants: the model is told a scrubbed payee name",
              !BudgetStore.optionalState(name: "Jo Smith jo@example.com 212-555-0101", sample: "ZELLE TO JO", category: .gifts, typical: 20, count: 3).contains("@")
              && !BudgetStore.optionalState(name: "Jo Smith jo@example.com 212-555-0101", sample: "ZELLE TO JO", category: .gifts, typical: 20, count: 3).contains("555"))

        // Ways to save keep one id however the figures move.
        let start = DateParsing.isoDay("2024-06-01") ?? .now
        let fees = (0..<3).map { charge("Big Bank", 60, day: 10 + $0 * 20, category: .fees) }
        let first = SavingsEngine.ideas(in: fees, recurring: [], asOf: start, optional: { _ in false })
        let more = SavingsEngine.ideas(in: fees + [charge("Big Bank", 35, day: 90, category: .fees)], recurring: [], asOf: start, optional: { _ in false })
        check("ways to save: an idea keeps its id when the amount changes", first.map(\.id) == ["fees"] && more.map(\.id) == ["fees"])
        check("ways to save: an idea waved away under an old id stays away",
              SavingsEngine.isDismissed("fees", in: ["fees|180"]) && SavingsEngine.isDismissed("habit|Cafe", in: ["habit|Cafe|13"])
              && !SavingsEngine.isDismissed("habit|Cafe", in: ["habit|Cafe X|13"]) && !SavingsEngine.isDismissed("fees", in: ["creep|X"]))

        // One rule for a month in progress, for What Changed, Budget and Insights.
        let day = { (s: String) in DateParsing.isoDay(s) ?? .now }
        check("a month in progress: one rule, the last days count as done, an earlier month never is",
              nov.isInProgress(newestCharge: day("2026-11-26")) && !nov.isInProgress(newestCharge: day("2026-11-27"))
              && !Month(year: 2026, month: 10).isInProgress(newestCharge: day("2026-11-05")) && !nov.isInProgress(newestCharge: day("2026-12-02")))
        // What was said about a year is about the same months of both years, and says so when the newest month is not finished.
        func monthsOf(_ keys: [String], amount: Double) -> [Transaction] { keys.map { tx("\($0)-05", amount, "Market", .groceries) } }
        let y25 = (1...12).map { String(format: "2025-%02d", $0) }, y26 = (1...10).map { String(format: "2026-%02d", $0) }
        let young = ChangeEngine.explainYear(endingAt: Month(year: 2026, month: 12), label: "2026", in: monthsOf(y25, amount: 100) + monthsOf(y26, amount: 200), stories: [])
        check("changes: a young year is compared with the same months of the year before, and its newest month is called so far",
              young.map { $0.months == 10 && $0.soFar == "October" && abs($0.total - 2000) < 0.01 && abs($0.usual - 1000) < 0.01
                  && $0.headline.contains("counting October so far") && $0.headline.contains("the same 10 months a year earlier") } == true)
        check("changes: too few months in the year, or none a year earlier, explain nothing",
              ChangeEngine.explainYear(endingAt: Month(year: 2026, month: 12), label: "2026", in: monthsOf(Array(y26.prefix(9)), amount: 200) + monthsOf(y25, amount: 100), stories: []) == nil
              && ChangeEngine.explainYear(endingAt: Month(year: 2026, month: 12), label: "2026", in: monthsOf(y26, amount: 200), stories: []) == nil)

        // Kept sentences go stale when any fact changes.
        check("reads: a kept sentence is tied to every fact it was written from",
              BudgetStore.basis(of: ["a $1", "b $2"]) == BudgetStore.basis(of: ["a $1", "b $2"]) && BudgetStore.basis(of: ["a $1", "b $2"]) != BudgetStore.basis(of: ["a $1", "b $3"]))
        check("mail: the help says what each provider really does",
              MailSearch.explanation(amount: 12, date: day("2026-03-10"), provider: .gmail).contains("week either side")
              && !MailSearch.explanation(amount: 12, date: day("2026-03-10"), provider: .yahoo).contains("week either side")
              && MailSearch.explanation(amount: 12, date: day("2026-03-10"), provider: .yahoo).contains("cannot be limited to dates"))
    }

    // MARK: Findings

    private static let acct = UUID()
    private static let nov = Month(year: 2026, month: 11)
    private static func tx(_ d: String, _ amount: Double, _ merchant: String, _ category: Category) -> Transaction {
        Transaction(id: UUID(), date: DateParsing.isoDay(d)!, month: Month(isoDay: d)!, description: merchant.uppercased(), amount: amount, merchant: merchant,
                    merchantKey: merchant, category: category, account: "Card", accountID: acct, source: .user, needsCheck: false, isOverride: false)
    }

    private static func engines() {
        let netflix = [tx("2026-09-05", 15.49, "Netflix", .subscriptions), tx("2026-10-05", 15.49, "Netflix", .subscriptions), tx("2026-11-05", 15.49, "Netflix", .subscriptions)]
        check("subscriptions: monthly, steady and still running", InsightEngine.subscriptions(asOf: nov, in: netflix).map(\.merchant) == ["Netflix"])
        let twice = [tx("2026-10-01", 4, "Cafe", .dining), tx("2026-10-02", 4, "Cafe", .dining), tx("2026-11-01", 4, "Cafe", .dining)]
        check("subscriptions: not twice a month", InsightEngine.subscriptions(asOf: nov, in: twice).isEmpty)
        let swing = [tx("2026-09-01", 20, "Gym", .health), tx("2026-10-01", 30, "Gym", .health), tx("2026-11-01", 20, "Gym", .health)]
        check("subscriptions: not a swing of more than 20 percent", InsightEngine.subscriptions(asOf: nov, in: swing).isEmpty)
        // Charges are kept oldest first, as the store keeps them.
        let quiet = [tx("2026-08-05", 9, "Old", .subscriptions), tx("2026-09-05", 9, "Old", .subscriptions), tx("2026-11-01", 4, "Other", .dining)]
        check("subscriptions: not one that has gone quiet", InsightEngine.subscriptions(asOf: nov, in: quiet).isEmpty)

        let found = InsightEngine.insights(for: nov, in: [tx("2026-09-05", 15, "Netflix", .subscriptions), tx("2026-10-05", 15, "Netflix", .subscriptions), tx("2026-11-05", 17, "Netflix", .subscriptions),
                                                          tx("2026-11-10", 12, "Cafe", .dining), tx("2026-11-11", 12, "Cafe", .dining), tx("2026-11-12", 800, "Gadget Shop", .shopping)])
        check("insights: a price rise", found.contains { $0.kind == .priceIncrease && $0.title == "Netflix went up" })
        check("insights: a double charge", found.contains { $0.kind == .duplicate && $0.title == "Possible double charge at Cafe" })
        check("insights: an unusually large purchase", found.contains { $0.kind == .unusual && $0.title == "Bigger than usual: Gadget Shop" })
        check("awards: the biggest categories lead", AwardEngine.awards(for: nov, in: [tx("2026-11-02", 100, "Market", .groceries), tx("2026-11-03", 30, "Bar", .dining),
                                                                                       tx("2026-11-04", 30, "Bar", .dining)]).prefix(2).map(\.winner) == ["Groceries", "Dining"])
        check("insights ignore transfers and unsorted deposits", InsightEngine.insights(for: nov, in: [tx("2026-11-02", 5000, "Brokerage", .transfer), tx("2026-11-03", -900, "Mystery", .unsorted)]).isEmpty)
    }

    // MARK: What changed, and budgets

    private static func changeAndBudgetRules() {
        let near = { (a: Double, b: Double) in abs(a - b) < 0.005 }
        // Three ordinary months, then a November with a trip in it.
        func ordinary(_ months: [String], groceries: Double = 400, dining: Double = 200) -> [Transaction] {
            months.flatMap { m in [tx("\(m)-03", groceries, "Market", .groceries), tx("\(m)-10", dining, "Bistro", .dining)] }
        }
        let hotel = tx("2026-11-15", 500, "Hotel Lisboa", .travel), airline = tx("2026-11-20", 300, "Airline", .travel)
        let lisbon = Story(kind: .trip, name: "Lisbon", place: "Lisbon", start: "2026-11-15", end: "2026-11-20", summary: "", entryIDs: [hotel.id, airline.id])
        let trip = ordinary(["2026-08", "2026-09", "2026-10"]) + [tx("2026-11-10", 510, "Bistro", .dining), hotel, airline, tx("2026-11-28", 400, "Market", .groceries)]
        let withTrip = ChangeEngine.explain(month: nov, in: trip, stories: [lisbon], recurring: [])
        check("changes: usual is the middle of the last three months, the delta is the difference", withTrip.map { near($0.usual, 600) && near($0.total, 1710) && near($0.delta, 1110) } == true)
        check("changes: the drivers add up to the difference to the cent", withTrip.map { near($0.drivers.reduce(0) { $0 + $1.amount }, $0.delta) } == true)
        check("changes: a trip is named first and its charges are not also counted under Travel",
              withTrip?.drivers.first?.kind == .story && withTrip?.drivers.contains { $0.title == "Travel" } == false
              && withTrip.map { near($0.drivers.first { $0.kind == .story }?.amount ?? 0, 800) } == true)
        check("changes: what is left over is named by category", withTrip?.drivers.contains { $0.kind == .categoryUp && $0.title == "Dining" && near($0.amount, 310) } == true)
        check("changes: every driver has a sentence written in code", withTrip?.drivers.allSatisfy { !$0.sentence.isEmpty && $0.sentence == $0.fallback } == true
              && withTrip?.drivers.first?.sentence == "Lisbon added $800")
        let usualMonth = ChangeEngine.explain(month: nov, in: ordinary(["2026-08", "2026-09", "2026-10"]) + [tx("2026-11-03", 400, "Market", .groceries), tx("2026-11-28", 200, "Bistro", .dining)], stories: [], recurring: [])
        check("changes: a month equal to its usual is about usual, with no drivers", usualMonth?.isAboutUsual == true && usualMonth?.drivers.isEmpty == true && usualMonth?.headline.contains("about what you usually spend") == true)
        let skewed = [tx("2026-08-05", 100, "Market", .groceries), tx("2026-09-05", 200, "Market", .groceries), tx("2026-10-05", 900, "Market", .groceries), tx("2026-11-28", 500, "Market", .groceries)]
        check("changes: usual is the median, not the mean", ChangeEngine.explain(month: nov, in: skewed, stories: [], recurring: []).map { near($0.usual, 200) && near($0.delta, 300) } == true)
        let two = [tx("2026-09-05", 100, "Market", .groceries), tx("2026-10-05", 300, "Market", .groceries), tx("2026-11-28", 500, "Market", .groceries)]
        check("changes: with only two earlier months the mean is used", ChangeEngine.explain(month: nov, in: two, stories: [], recurring: []).map { near($0.usual, 200) } == true)
        check("changes: one earlier month is too little history", ChangeEngine.explain(month: nov, in: Array(two.dropFirst()), stories: [], recurring: []) == nil)
        check("changes: a month still being read is not explained", ChangeEngine.explain(month: nov, in: Array(two.dropLast()) + [tx("2026-11-09", 500, "Market", .groceries)], stories: [], recurring: []) == nil)
        let big = ordinary(["2026-08", "2026-09", "2026-10"]) + [tx("2026-11-03", 400, "Market", .groceries), tx("2026-11-10", 200, "Bistro", .dining), tx("2026-11-12", 900, "Gadget Shop", .shopping), tx("2026-11-28", 30, "Market", .groceries)]
        let one = ChangeEngine.explain(month: nov, in: big, stories: [], recurring: [])
        check("changes: one big charge is a driver of its own and the sum still holds", one?.drivers.first?.kind == .oneOff && one.map { near($0.drivers.reduce(0) { $0 + $1.amount }, $0.delta) } == true)
        let tv = monthly("Streamly", [10, 10, 10, 10, 12], count: 5).map { t in Transaction(id: t.id, date: t.date, month: t.month, description: t.description, amount: t.amount, merchant: t.merchant, merchantKey: t.merchantKey, category: .subscriptions, account: "Card", accountID: t.accountID, source: .user, needsCheck: false, isOverride: false) }
        let rises = RecurringEngine.find(in: tv, asOf: DateParsing.isoDay("2024-05-20") ?? .now)
        let may = Month(year: 2024, month: 5)
        let base = tv + [charge("Cafe", 700, day: 120, category: .dining), charge("Cafe", 700, day: 121, category: .dining), charge("Late", 1, day: 135, category: .dining)]
        let rise = ChangeEngine.explain(month: may, in: base, stories: [], recurring: rises)
        check("changes: a price rise is named by the amount it went up", rise?.drivers.contains { $0.kind == .priceRise && near($0.amount, 2) && $0.sentence == "Streamly went up $2.00" } == true
              || rise?.drivers.contains { $0.kind == .priceRise } == false && rise.map { near($0.drivers.reduce(0) { $0 + $1.amount }, $0.delta) } == true)

        // Budgets.
        func months(_ keys: [String], dining: Double) -> [Transaction] { keys.map { tx("\($0)-05", dining, "Bistro", .dining) } }
        let six = ["2026-05", "2026-06", "2026-07", "2026-08", "2026-09", "2026-10"]
        let history = months(six, dining: 300) + six.map { tx("\($0)-06", 10, "Cafe", .personal) } + [tx("2026-09-07", 90, "Spa", .health), tx("2026-10-07", 90, "Spa", .health)]
        let targets = BudgetEngine.targets(before: nov, in: history, stories: [])
        check("budgets: six identical months give that amount as the target", near(targets[.dining] ?? 0, 300))
        check("budgets: a category with fewer than three months, or a target under $25, is skipped", targets[.health] == nil && targets[.personal] == nil)
        check("budgets: a target is rounded to the nearest $10", near(BudgetEngine.targets(before: nov, in: months(six, dining: 304), stories: [])[.dining] ?? 0, 300)
              && near(BudgetEngine.targets(before: nov, in: months(six, dining: 306), stories: [])[.dining] ?? 0, 310))
        let mid = DateParsing.isoDay("2026-11-15") ?? .now
        let midMonth = history + [tx("2026-11-12", 150, "Bistro", .dining)]
        let half = BudgetEngine.summary(for: nov, in: midMonth, stories: [], overrides: [:], asOf: mid)
        check("budgets: halfway through the month, half the target spent is on pace", half.isInProgress && half.lines.first?.pace == .onPace && half.onPace == 1 && half.over == 0)
        check("budgets: the projection appears only after day 10", near(half.lines.first?.projected ?? 0, 300)
              && BudgetEngine.summary(for: nov, in: history + [tx("2026-11-04", 150, "Bistro", .dining)], stories: [], overrides: [:], asOf: DateParsing.isoDay("2026-11-08") ?? .now).lines.first?.projected == nil)
        let fast = BudgetEngine.summary(for: nov, in: history + [tx("2026-11-12", 280, "Bistro", .dining)], stories: [], overrides: [:], asOf: mid)
        check("budgets: spending far ahead of the month is over", fast.lines.first?.pace == .over && fast.over == 1)
        let done = BudgetEngine.summary(for: Month(year: 2026, month: 10), in: history, stories: [], overrides: [:], asOf: mid)
        check("budgets: a finished month is judged against the whole target", !done.isInProgress && done.lines.isEmpty == false && done.lines.first?.pace == .onPace)
        let own = BudgetEngine.summary(for: nov, in: midMonth, stories: [], overrides: ["Dining": 500], asOf: mid)
        check("budgets: an override wins, and removing it restores the computed target",
              own.lines.first.map { near($0.target, 500) && $0.isOverride && near($0.computed ?? 0, 300) } == true
              && near(half.lines.first?.target ?? 0, 300) && half.lines.first?.isOverride == false)
        let tripCharges = ["2026-05", "2026-06", "2026-07", "2026-08"].map { tx("\($0)-20", 1000, "Hotel", .dining) }
        let tripStory = Story(kind: .trip, name: "Trips", place: nil, start: "2026-05-20", end: "2026-08-20", summary: "", entryIDs: tripCharges.map(\.id))
        check("budgets: a trip does not move a target, and without the trip it would",
              near(BudgetEngine.targets(before: nov, in: history + tripCharges, stories: [tripStory])[.dining] ?? 0, 300)
              && (BudgetEngine.targets(before: nov, in: history + tripCharges, stories: [])[.dining] ?? 0) > 1000)
        check("budgets: the card's total is the sum of its rows", near(half.target, half.lines.reduce(0) { $0 + $1.target }) && near(half.spent, half.lines.reduce(0) { $0 + $1.spent }))
        // The first days of a month: an ordinary purchase is not "over" unless it is over the whole target.
        let dayOne = DateParsing.isoDay("2026-11-01") ?? .now, dayTwo = DateParsing.isoDay("2026-11-02") ?? .now
        check("budgets: on day one a normal purchase is not over, but one above the whole target is",
              BudgetEngine.summary(for: nov, in: history + [tx("2026-11-01", 60, "Bistro", .dining)], stories: [], overrides: [:], asOf: dayOne).lines.first?.pace == .onPace
              && BudgetEngine.summary(for: nov, in: history + [tx("2026-11-02", 350, "Bistro", .dining)], stories: [], overrides: [:], asOf: dayTwo).lines.first?.pace == .over)
        // Budget and What Changed agree on when a month is still going.
        let late = ordinary(["2026-08", "2026-09", "2026-10"]) + [tx("2026-11-03", 400, "Market", .groceries), tx("2026-11-26", 20, "Bistro", .dining)]
        check("a month still going is the same month for What Changed and Budget",
              ChangeEngine.explain(month: nov, in: late, stories: [], recurring: []) == nil
              && BudgetEngine.summary(for: nov, in: history, stories: [], overrides: [:], asOf: DateParsing.isoDay("2026-11-26") ?? .now).isInProgress
              && ChangeEngine.explain(month: nov, in: late.dropLast() + [tx("2026-11-28", 20, "Bistro", .dining)], stories: [], recurring: []) != nil
              && !BudgetEngine.summary(for: nov, in: history, stories: [], overrides: [:], asOf: DateParsing.isoDay("2026-11-28") ?? .now).isInProgress)
    }

    private static func orderChecks() {
        func item(_ order: String, _ cents: Int, _ date: String) -> OrderItem {
            OrderItem(orderID: order, shop: .store, date: date, shipment: date + "T10:00", name: "Thing from \(order)", cents: cents, quantity: 1)
        }
        check("shops: Amazon's ways of signing a charge", OrderMatcher.shop(of: "AMAZON MKTPL*AB12 SEATTLE WA") == .store && OrderMatcher.shop(of: "AMZN Mktp US*2K4AB1") == .store
              && OrderMatcher.shop(of: "WHOLEFDS MKT 10234") == .groceries && OrderMatcher.shop(of: "AMAZON PRIME*1A2B3") == .digital && OrderMatcher.shop(of: "KINDLE SVCS") == .digital)
        check("shops: nobody else's charge is Amazon's", OrderMatcher.shop(of: "STARBUCKS #12") == nil && OrderMatcher.shop(of: "SAM'S CLUB #44") == nil)
        check("day numbers count whole days", OrderMatcher.dayNumber("1970-01-01") == 719_468 && OrderMatcher.dayNumber("2024-03-01") - OrderMatcher.dayNumber("2024-02-28") == 2
              && OrderMatcher.dayNumber("garbage") == 0)
        let twin = [item("A", 1999, "2026-03-01"), item("B", 1999, "2026-03-05")]
        let c1 = OrderMatcher.Charge(id: UUID(), date: "2026-03-02", cents: 1999, shop: .store), c2 = OrderMatcher.Charge(id: UUID(), date: "2026-03-06", cents: 1999, shop: .store)
        let m = OrderMatcher.match([c2, c1], to: twin)
        check("orders: equal charges take their own orders, nearest first", m[c1.id.uuidString]?.items == [0] && m[c2.id.uuidString]?.items == [1])
        let refund = OrderMatcher.Charge(id: UUID(), date: "2026-03-02", cents: -1999, shop: .store), other = OrderMatcher.Charge(id: UUID(), date: "2026-03-02", cents: 1999, shop: .groceries)
        do {
            var change = TidyChange(kind: .combine, day: "2026-03-01", from: "A", other: "B", charges: 2, pairID: "a|b")
            let fresh = change.isOnShow(today: "2026-03-20"), faded = !change.isOnShow(today: "2026-04-05")
            change.kept = true
            check("tidy: a change waits a month to be looked at, then is taken as right; one the person kept leaves at once",
                  fresh && faded && !change.isOnShow(today: "2026-03-02"))
        }
        check("ask: suggested questions are read from a list, and one with a figure or no question mark is dropped",
              BudgetStore.askIdeas(in: "Here you go:\n[\"Why did dining jump in March?\", \"Did I really spend $400 on coffee?\", \"Tell me about rent\", \"why did dining jump in march?\", \"What is my longest-running subscription?\"]")
                == ["Why did dining jump in March?", "What is my longest-running subscription?"] && BudgetStore.askIdeas(in: "no list here").isEmpty)
        // What the statements say about a credit card.
        do {
            check("cards: a credit line names its benefit; a refund, a fraud reversal and a bank transfer do not",
                  CardEngine.benefitName("Platinum Lululemon Credit LULULEMON FLATIRON") == "Platinum Lululemon Credit"
                  && CardEngine.benefitName("TRAVEL CREDIT $300/YEAR") == "Travel Credit"
                  && CardEngine.benefitName("LULULEMON UNION SQUARE NEW YORK NY") == nil && CardEngine.benefitName("FRAUD CREDIT - CITY WINERY") == nil
                  && CardEngine.benefitName("ZELLE CREDIT PAYMENT FROM: SOMEONE") == nil && CardEngine.benefitName("CREDIT - INTEREST") == nil)
            check("cards: a yearly allowance printed in a credit line is read", CardEngine.printedAllowance("TRAVEL CREDIT $300/YEAR") == 300 && CardEngine.printedAllowance("DOORDASH CREDIT") == nil)
            check("cards: a yearly fee is told from other lines, and names the other cardholder when the line does",
                  CardEngine.annualFee("ANNUAL MEMBERSHIP FEE").isFee && CardEngine.annualFee("ANNUAL MEMBERSHIP FEE").who == nil
                  && CardEngine.annualFee("JANE Q ROE ANNUAL MEMBERSHIP FEE").who == "Jane" && !CardEngine.annualFee("LATE FEE").isFee)
            let card = UUID(), other = UUID()
            func line(_ day: String, _ amount: Double, _ text: String, payee: String, on account: UUID, category: Category = .shopping) -> Transaction {
                let date = DateParsing.isoDay(day)!
                return Transaction(id: UUID(), date: date, month: Month(date: date), description: text, amount: amount, merchant: payee, merchantKey: "own:" + payee,
                                   category: category, account: account == card ? "Bank Card ••1111" : "Other ••2222", accountID: account, source: .user, needsCheck: false, isOverride: false)
            }
            var lines = [line("2025-11-20", 695, "ANNUAL MEMBERSHIP FEE", payee: "Annual Fee", on: card, category: .fees)]
            // A shop credit every quarter but one; that quarter, the shop was paid on the other card.
            for day in ["2025-08-10", "2025-11-12", "2026-05-09", "2026-08-11"] {
                lines.append(line(day, 90, "TOGS FLATIRON", payee: "Togs", on: card))
                lines.append(line(day, -75, "Gold Togs Credit TOGS FLATIRON", payee: "Togs", on: card))
            }
            lines.append(line("2026-02-14", 140, "TOGS UPTOWN", payee: "Togs", on: other))
            lines.append(line("2026-11-05", 30, "CORNER CAFE", payee: "Corner Cafe", on: card, category: .dining))
            let facts = CardEngine.cards([(id: card, name: "Bank Card ••1111")], in: lines.sorted { $0.date < $1.date }, asOf: DateParsing.isoDay("2026-11-10")!)
            let togs = facts.first?.benefits.first
            check("cards: a credit that comes most quarters is quarterly, and a full quarter is what it usually pays",
                  togs?.name == "Gold Togs Credit" && togs?.cadence == .quarterly && togs?.usual == 75 && togs?.shops == ["Togs"])
            check("cards: a quarter the credit did not come is found, with what went to that shop on another card",
                  togs?.missed.map(\.label) == ["Jan to Mar 2026"] && togs?.missed.first?.elsewhere.map(\.amount) == [140]
                  && facts.first?.findings.contains { $0.kind == .wrongCard && $0.text.contains("$140") && $0.text.contains("Togs") } == true)
            check("cards: the quarter now running, with nothing yet, is said once the statements reach well into it",
                  facts.first?.findings.contains { $0.kind == .waiting && $0.text.contains("Dec 31") } == true)
            check("cards: the last twelve months set fees against credits, and the verdict follows",
                  facts.first?.feesPaid == 695 && facts.first?.creditsBack == 225 && facts.first?.verdict == .costs(470)
                  && facts.first?.nextFee?.amount == 695 && facts.first.map { DateParsing.iso.string(from: $0.nextFee!.date) } == "2026-11-20"
                  && facts.first?.findings.contains { $0.kind == .feeDue } == true)
        }
        // What an order history says beyond its totals.
        do {
            func day(_ text: String) -> Date { DateParsing.parse(text, format: "yyyy-MM-dd")! }
            var n = 0
            func got(_ name: String, _ date: String, _ cents: Int, asin: String? = "B000000001", digital: Bool = false) -> OrderHabits.Bought {
                n += 1
                return OrderHabits.Bought(id: n, name: name, kind: "Pantry & Snacks", asin: asin, orderID: "O\(n)", date: day(date), cents: cents, digital: digital)
            }
            let coffee = ["2026-01-05", "2026-02-09", "2026-03-16", "2026-04-20", "2026-05-25"].enumerated().map { got("Coffee beans", $1, $0 == 0 ? 1900 : $0 == 4 ? 2700 : 2200) }
            let old = ["2019-01-05", "2019-02-09", "2019-03-16"].map { got("Printer ink", $0, 3000, asin: "B000000002") }
            let books = ["2026-03-01", "2026-04-01", "2026-05-01"].map { got("Kindle+", $0, 999, asin: nil, digital: true) }
            let habits = OrderHabits.habits(coffee + old + books, through: day("2026-06-01"))
            check("orders: a thing bought at a steady rhythm is on the restock clock, with its next date",
                  habits.map(\.name) == ["Coffee beans"] && habits.first?.everyDays == 35 && habits.first?.due == day("2026-06-29") && habits.first?.times == 5)
            check("orders: a year of a habit is what it has cost lately at its rhythm", habits.first?.yearlyCents == Int((Double((1900 + 2200 * 3 + 2700) / 5) * 365 / 35).rounded()))
            check("orders: the same product's first and latest price are set side by side", habits.first?.price?.was == 1900 && habits.first?.price?.now == 2700)
            check("orders: a habit given up long ago and a download are not on the clock", !habits.contains { $0.name == "Printer ink" || $0.name == "Kindle+" })
            check("orders: a rhythm is said in days, weeks or months", OrderHabits.rhythm(10) == "every 10 days" && OrderHabits.rhythm(35) == "about every 5 weeks" && OrderHabits.rhythm(92) == "about every 3 months")
            let camera = got("Camera", "2012-07-14", 70600, asin: "B000000003"), lamp = got("Lamp", "2020-07-12", 90000, asin: "B000000004")
            let memory = OrderHabits.onThisDay([camera, lamp] + coffee, today: day("2026-07-14"))
            check("orders: on this day finds the thing bought on the very day before a dearer one that week", memory?.thing.name == "Camera" && memory?.yearsAgo == 14 && memory?.exact == true)
            check("orders: on this day reaches a few days either side, and never into this year",
                  OrderHabits.onThisDay([camera, lamp] + coffee, today: day("2026-07-11"))?.thing.name == "Lamp" && OrderHabits.onThisDay(coffee, today: day("2026-03-16")) == nil)
            check("orders: on this day prefers a notable thing that week to a trifle on the day",
                  OrderHabits.onThisDay([got("Dusters", "2024-07-14", 1600, asin: "B000000005"), lamp], today: day("2026-07-14"))?.thing.name == "Lamp")
            check("orders: years ago is said in words", OrderHabits.yearsAgo(14) == "Fourteen years ago" && OrderHabits.yearsAgo(1) == "A year ago")
            let shelf = OrderHabits.shelf([camera, lamp] + coffee + books, upTo: 10)
            check("orders: the shelf holds each product once, dearest first, and nothing without a picture to find", shelf.map(\.name) == ["Lamp", "Camera", "Coffee beans"])
        }
        check("orders: refunds and other shops never match", OrderMatcher.match([refund, other], to: [item("A", 1999, "2026-03-01")]).isEmpty)
        var g = item("G", 4000, "2026-03-01"); g.shop = .groceries; g.listedCents = 4400
        let gid = UUID()
        check("orders: groceries match by the listed total", OrderMatcher.match([OrderMatcher.Charge(id: gid, date: "2026-03-02", cents: 4500, shop: .groceries)], to: [g])[gid.uuidString]?.kind == .approximate)
    }

    // MARK: PDF statements

    private static func pdfStatements() {
        let closing = DateParsing.isoDay("2026-11-03")!
        let text = "Purchases\n10/14 BEST BUY 00012 1,249.99\n10/15 TRADER JOE'S #123 45.20\nPayments and Credits\n10/20 PAYMENT THANK YOU 500.00"
        let p = PDFStatement.parseLines(text, closing: closing)
        check("pdf: lines under headings, credits turn negative", p.rows.map(\.amount) == [1249.99, 45.2, -500] && p.rows.map(\.date) == ["2026-10-14", "2026-10-15", "2026-10-20"]
              && p.rows[0].description == "BEST BUY 00012")
        check("pdf: a December charge on a January statement is last year", PDFStatement.parseLines("12/28 SHELL OIL 40.00", closing: DateParsing.isoDay("2026-01-05")!).rows.first?.date == "2025-12-28")
        check("pdf: a merchant named Total is a merchant and an ampersand stays",
              PDFStatement.parseLines("10/14 TOTAL WINE & MORE 88.00", closing: closing).rows.map(\.description) == ["TOTAL WINE & MORE"]
              && PDFStatement.parseLines("10/14 BALANCE BAR COMPANY 12.00\n10/15 MINIMUM WAGE CAFE 9.00\n10/16 PREVIOUS LIFE BOOKS 8.00", closing: closing).rows.count == 3)
        check("pdf: summary lines that begin with those words are still left out",
              PDFStatement.parseLines("10/14 TOTAL FEES CHARGED 0.00\n10/14 PREVIOUS BALANCE 1,200.00\n10/14 MINIMUM PAYMENT DUE 35.00\n10/14 BALANCE FORWARD 90.00", closing: closing).rows.isEmpty)
        check("pdf: a bare ampersand in a name is kept", PDFStatement.parseLines("10/14 STOP & SHOP 123 41.00", closing: closing).rows.map(\.description) == ["STOP & SHOP 123"])

        let d = { (x: Date?) in x.map { DateParsing.iso.string(from: $0) } }
        check("pdf: the billing period", PDFStatement.statementPeriod("Statement Period: Oct 4 – Nov 3, 2026").map { [d($0.start), d($0.end)] } == ["2026-10-04", "2026-11-03"]
              && PDFStatement.statementPeriod("09/26/26 - 10/25/26").map { d($0.end) } == "2026-10-25" && PDFStatement.statementPeriod("Jan 1 – Jun 30, 2026") == nil
              && PDFStatement.statementMonths("Statement Period: Oct 4 – Nov 3, 2026") == ["2026-10", "2026-11"])
        check("pdf: the closing date and the last digits", d(PDFStatement.detectClosingDate("Opening/Closing Date 10/04/26 - 11/03/26")) == "2026-11-03"
              && PDFStatement.detectLast4("Account ending in 4090") == "4090" && PDFStatement.detectLast4("Primary Account: 000012345678901") == "8901")
        // No printed closing date: the period, then the file name, then nothing (and the reading is marked).
        check("pdf: a statement with no closing date is dated from its period or its file name, never from today",
              d(PDFStatement.closingDate(text: "Billing cycle Oct 4 - Nov 3, 2026", fileName: "x.pdf")) == "2026-11-03"
              && d(PDFStatement.closingDate(text: "10/14 SHELL 4.00", fileName: "20260125-statements-1234-.pdf")) == "2026-01-25"
              && d(PDFStatement.closingDate(text: "10/14 SHELL 4.00", fileName: "Statement_2025-10.pdf")) == "2025-10-31"
              && d(PDFStatement.closingDate(text: "10/14 SHELL 4.00", fileName: "Card 2025.pdf")) == "2025-12-31"
              && PDFStatement.closingDate(text: "10/14 SHELL 4.00", fileName: "statement.pdf") == nil
              && PDFStatement.closingDate(text: "10/14 SHELL 4.00", fileName: "Chase4090.pdf") == nil)

        let rows = [CanonicalRow(date: "2026-10-05", description: "A", amount: 100), CanonicalRow(date: "2026-10-05", description: "PAYMENT", amount: -40)]
        check("pdf: printed totals vouch for a reading", PDFStatement.matchesAccountSummary("Purchases $100.00\nPayments and Credits $40.00", rows: rows)
              && !PDFStatement.matchesAccountSummary("Purchases $100.00\nPayments and Credits $41.00", rows: rows))
        check("pdf: a quiet month is vouched for", PDFStatement.emptyStatement("Statement Period: Oct 4 – Nov 3, 2026 Beginning balance $100.00 Ending balance $100.00") == .verified)
        check("pdf: purchases paid with points are removed",
              PDFStatement.removePointsPaid([CanonicalRow(date: "2026-10-05", description: "AMAZON.COM", amount: 25)], text: "Shop with Points Activity\n10/05 AMAZON.COM 25.00 2,500").isEmpty)
    }

    // MARK: What is kept on disk

    private static func storage() {
        let a = UUID().uuidString, stray = UUID().uuidString
        let json = "{\"accounts\":[{\"id\":\"\(a)\",\"name\":\"A\",\"signature\":\"s\"},{\"id\":\"\(a)\",\"name\":\"Twin\",\"signature\":\"t\"}],\"entries\":["
            + "{\"accountID\":\"\(a)\",\"date\":\"2026-01-02\",\"description\":\"STARBUCKS #1\",\"amount\":5},{\"bogus\":1},"
            + "{\"accountID\":\"\(stray)\",\"date\":\"2026-01-03\",\"description\":\"ORPHAN\",\"amount\":7}]}"
        let lib = try? JSONDecoder().decode(Library.self, from: Data(json.utf8))
        check("library: a damaged line is skipped and a missing key is rebuilt", lib?.entries.first?.merchantKey == "known:Starbucks" && lib?.version == 1)
        check("library: a line whose account is missing is kept, under Recovered, not deleted",
              lib?.entries.count == 2 && lib?.accounts.first(where: { $0.name == Library.recoveredName }).map { recovered in lib?.entries.last?.accountID == recovered.id } == true)
        check("library: two accounts with one id become one", lib?.accounts.filter { $0.id.uuidString == a }.count == 1 && lib?.accounts.count == 2)
        let doubled = lib.map { Dictionary($0.accounts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }) }
        check("library: looking accounts up by id cannot fail", doubled?.count == lib?.accounts.count)
        check("library: a new stored field must be added to the decoder (25 today)", Mirror(reflecting: Library()).children.count == 25)

        // Saving says whether it worked.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SpendthriftTest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        check("saving: a library written to a folder reports success", lib?.save(paths: BudgetPaths(root: folder)) == true
              && Library.load(paths: BudgetPaths(root: folder)).0.entries.count == 2)
        check("saving: a library that cannot be written reports failure", lib?.save(paths: BudgetPaths(root: URL(fileURLWithPath: "/dev/null/nowhere"))) == false)

        // The order history.
        check("orders file: an older file without every key still loads", (try? JSONDecoder().decode(OrderBook.self, from: Data("{\"items\":[]}".utf8))) != nil
              && (try? JSONDecoder().decode(OrderBook.self, from: Data("{}".utf8))) != nil)
        let odd = "{\"items\":[{\"orderID\":\"A\",\"shop\":\"newshop\",\"date\":\"2026-01-01\",\"shipment\":\"x\",\"name\":\"n\",\"cents\":1,\"quantity\":1},"
            + "{\"orderID\":\"B\",\"shop\":\"store\",\"date\":\"2026-01-02\",\"name\":\"kept\",\"cents\":250}],"
            + "\"matches\":{\"x\":{\"items\":[0],\"kind\":\"aNewKind\"},\"y\":{\"items\":[1],\"kind\":\"exact\"}},\"refunds\":{\"B\":100}}"
        let book = try? JSONDecoder().decode(OrderBook.self, from: Data(odd.utf8))
        check("orders file: a word this version does not know costs that part, not the file",
              book?.items.map(\.orderID) == ["B"] && book?.items.first?.quantity == 1 && book?.matches.keys.sorted() == ["y"] && book?.refunds == ["B": 100])
        let ordersFile = folder.appendingPathComponent("orders.json")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data("{ this is not json".utf8).write(to: ordersFile)
        let fromBroken = OrderBook.load(ordersFile)
        let aside = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasPrefix("orders-damaged-") }
        check("orders file: one that cannot be read is moved aside, not treated as empty and written over",
              fromBroken.items.isEmpty && !FileManager.default.fileExists(atPath: ordersFile.path) && aside.count == 1)
        check("orders file: no file is an empty book", OrderBook.load(folder.appendingPathComponent("nothing.json")).items.isEmpty)
        // Writes go through one queue: the last one asked for is the one that stays.
        var growing = OrderBook()
        for n in 1...20 {
            growing.items.append(OrderItem(orderID: "O\(n)", shop: .store, date: "2026-01-01", shipment: "x", name: "n", cents: n, quantity: 1))
            growing.save(to: ordersFile)
        }
        OrderBook.flushSaves()
        check("orders file: saves land in the order they were asked for", OrderBook.load(ordersFile).items.count == 20)
    }

    // MARK: Sums that must agree, whatever the library holds

    private static func books(_ store: BudgetStore) {
        let near = { (a: Double, b: Double) in abs(a - b) < 0.01 }
        check("ask: the findings questions are written from are there, and say nothing when nothing has changed",
              store.askIdeaFacts().count >= 3 && store.askIdeaFacts() == store.askIdeaFacts())
        check("orders: with card charges on file, an order with none is explained by its date",
              store.orderChargeList.isEmpty || (store.orderChargeSpan != nil && store.unpaidNote(for: .distantFuture) == "not on a statement yet" && store.unpaidNote(for: .distantPast) == "before your statements begin"))
        for card in store.cardFacts() {
            check("cards: \(card.name.components(separatedBy: "••").first ?? "a card")adds up: each year's credits are its benefits' credits, and every finding has words",
                  abs(card.years.reduce(0) { $0 + $1.credits } - card.benefits.reduce(0) { $0 + $1.total }) < 0.01
                  && card.findings.allSatisfy { !$0.text.isEmpty } && card.share >= 0 && card.share <= 1.0001)
        }
        check("cards: the cards are the accounts named for a card issuer, and their shares of card spending make a whole",
              store.cardFacts().count <= store.accounts.filter(BudgetStore.isCard).count
              && (store.cardFacts().allSatisfy { $0.spent < 0.5 } || abs(store.cardFacts().reduce(0) { $0 + $1.share } - 1) < 0.001))
        let repeating = store.recurring()
        // A past year shows the bills of that time: nothing that began later, nothing judged by today.
        if let first = store.transactions.first?.date, let last = store.transactions.last?.date,
           let middle = Optional(first.addingTimeInterval(last.timeIntervalSince(first) / 2)) {
            let then = store.recurring(asOf: middle)
            check("bills: seen from a past day, nothing that repeats began after it or is judged by later charges",
                  then.allSatisfy { $0.first <= middle && $0.last <= middle && ($0.next == nil || $0.isActive) })
            let was = store.overviewShowsYear, period = store.overviewPeriod
            let years = Set(store.transactions.map { Calendar.current.component(.year, from: $0.date) }).sorted()
            if years.count > 1, let early = years.first {
                store.overviewShowsYear = true; store.overviewPeriod = .year(early)
                let end = store.overviewAsOf
                check("bills: a past year on the Overview is read as of its last day",
                      end.map { Calendar.current.component(.year, from: $0) == early && Calendar.current.component(.month, from: $0) == 12 } == true
                      && store.recurring(asOf: end).allSatisfy { $0.last <= end! })
                store.overviewPeriod = .last12
                check("bills: the last twelve months are the present", store.overviewAsOf == nil)
            }
            store.overviewShowsYear = was; store.overviewPeriod = period
        }
        let billIDs = Set(store.transactions.map(\.id))
        check("every bill and subscription is made of charges that exist", repeating.allSatisfy { $0.chargeIDs.allSatisfy(billIDs.contains) && $0.chargeIDs.count >= 2 })
        check("the Bills & Subscriptions card is the sum of its active rows", near(repeating.filter(\.isActive).reduce(0) { $0 + $1.yearly },
              repeating.filter(\.isActive).reduce(0) { $0 + $1.amount * $1.cadence.perYear }) && repeating.filter { !$0.isActive }.allSatisfy { $0.next == nil })
        guard let period = ReportData.periods(for: store).first else { return }
        let year = CashFlowData(store: store, period: period)
        let months = year.months.map { CashFlowData(store: store, month: $0) }
        check("the verdict is income less what was consumed", near(year.surplus, year.totalIncome - year.spending - year.taxes - year.loanInterest))
        check("a year is the sum of its months", near(months.reduce(0) { $0 + $1.spending }, year.spending)
              && near(months.reduce(0) { $0 + $1.totalIncome }, year.totalIncome) && near(months.reduce(0) { $0 + $1.taxes }, year.taxes))
        check("the Spending card and the spending page agree", near(year.months.reduce(0) { $0 + store.totalSpent(in: $1) }, year.spending))
        check("the category ring adds up to spending", year.months.allSatisfy { m in near(store.categoryTotals(in: m).reduce(0) { $0 + $1.total }, max(store.totalSpent(in: m), store.categoryTotals(in: m).reduce(0) { $0 + $1.total })) })
        let run = CashFlowData.run(of: year.months, in: store)
        check("the small bars add up to the big figures", near(run.reduce(0) { $0 + $1.income }, year.totalIncome) && near(run.reduce(0) { $0 + $1.invested }, year.built))
        // The Investing card's figure and its small bars are one definition: money put to work, loan interest apart.
        check("the Investing card's bars add up to its figure, loan interest left out of both", near(run.reduce(0) { $0 + $1.invested }, year.investmentOut - year.loanInterest)
              && near(year.loanInterest, store.transactions.filter { year.months.contains($0.month) && CashFlowData.isLoanInterest($0) }.reduce(0) { $0 + $1.amount }))
        // "$X of $Y was chosen" is one figure: the same by payee and by category, and the one the Spending card gives.
        let stretch = store.transactions.filter { Set(year.months).contains($0.month) }
        let ranked = [true, false].map { store.trimmed(stretch, stretch: "books", month: nil, byPayee: $0, chosenOnly: true) }
        check("what was chosen is one figure: the sum of chosen amounts, by payee and by category, equal to the Spending card's",
              ranked.allSatisfy { near($0.chosen, year.optionalSpending) && near($0.total, year.spending) }
              && ranked.allSatisfy { r in r.lines.allSatisfy { $0.chosen > 0 && $0.chosen * 2 >= $0.total - 0.005 } })
        check("the Trim card's lines are kept, and equal a fresh ranking", store.trimmed(stretch, stretch: "books", month: nil, byPayee: true, chosenOnly: true).lines
              == TrimEngine.ranked(stretch, byPayee: true, chosenOnly: true, optional: store.isOptional).lines)
        let verdict = FlowHero.verdict(for: year)
        check("the stamp matches the sum", year.totalIncome <= 0.5 ? verdict == .unknown
              : verdict == .even ? abs(year.surplus) < year.totalIncome * 0.01 : (verdict == .within) == (year.surplus > 0))
        check("money kept apart is counted nowhere else", Set(store.transactions.map(\.id)).isDisjoint(with: store.setApart.map(\.id)))
        check("every charge falls in a month the app knows", store.transactions.allSatisfy { store.months.contains($0.month) })
        check("charges are kept oldest first, each in the month of its day", zip(store.transactions, store.transactions.dropFirst()).allSatisfy { $0.date <= $1.date }
              && store.transactions.allSatisfy { $0.month == Month(date: $0.date) })
        if let trip = store.stories.first {
            let ids = Set(trip.entryIDs)
            check("a trip's charges are found by index as by search", store.transactions(in: trip).map(\.id) == store.transactions.filter { ids.contains($0.id) }.map(\.id))
        }
        let ids = Set(store.library.entries.map(\.id.uuidString))
        check("every order match points at real items and a real charge", store.orders.matches.allSatisfy { key, match in
            ids.contains(key) && !match.items.isEmpty && match.items.allSatisfy { store.orders.items.indices.contains($0) }
        })
        // What changed: for every month of the latest year, the drivers add up to the difference.
        let latestYear = Array(store.months.suffix(12))
        let explained = latestYear.compactMap { store.changes(in: $0) }
        check("what changed: for every month of the latest year the drivers add up to the difference to the cent",
              explained.allSatisfy { e in near(e.drivers.reduce(0) { $0 + $1.amount }, e.delta) && (e.isAboutUsual ? e.drivers.isEmpty : !e.drivers.isEmpty && e.drivers.count <= 5) })
        check("what changed: the kept answer equals a fresh one", latestYear.allSatisfy { m in
            store.changes(in: m) == ChangeEngine.explain(month: m, in: store.transactions, stories: store.stories, recurring: store.recurring()) })
        if let year = store.changes(in: .last12) {
            check("what changed: the year's drivers add up to its difference", near(year.drivers.reduce(0) { $0 + $1.amount }, year.delta))
        }
        // The Budget card is its rows; each row is its charges.
        if let latest = store.months.last {
            let card = store.budget(for: latest)
            let inTrip = Set(store.stories.flatMap(\.entryIDs))
            check("the Budget card's totals equal the sum of its rows", near(card.spent, card.lines.reduce(0) { $0 + $1.spent }) && near(card.target, card.lines.reduce(0) { $0 + $1.target })
                  && card.onPace + card.over == card.lines.count)
            check("each Budget row is exactly its category's charges for the month, trips and events left out", card.lines.allSatisfy { line in
                near(line.spent, store.transactions(withIDs: line.chargeIDs).reduce(0) { $0 + $1.amount })
                && near(line.spent, store.spending(in: latest).filter { $0.category == line.category && !inTrip.contains($0.id) }.reduce(0) { $0 + $1.amount }) })
        }
        if let latest = store.months.last {
            check("everything worth knowing leads somewhere", store.insights(for: latest).allSatisfy { $0.target != nil })
        }
    }

    // MARK: Doing what a person would do

    static func run(files: [URL]) async {
        let store = BudgetStore.shared
        logic()
        books(store)
        // Needs and wants, where to trim, ways to save: sums of real charges, never more than was spent.
        if let period = ReportData.periods(for: store).first {
            let flow = CashFlowData(store: store, period: period)
            let months = Set(flow.months)
            let stretch = store.transactions.filter { months.contains($0.month) }
            let byPayee = TrimEngine.lines(stretch, byPayee: true, optional: store.isOptional)
            let byCategory = TrimEngine.lines(stretch, byPayee: false, optional: store.isOptional)
            check("every ranked line is worth something, by payee and by category", (byPayee + byCategory).allSatisfy { $0.total > 0 && (0...1).contains($0.optionalShare) })
            if let change = store.changes(in: period) {
                check("what changed is about the same total the verdict shows", abs(change.total - flow.spending) < 0.01)
            }
            check("what was chosen is part of what was spent", flow.optionalSpending >= -0.01 && flow.optionalSpending <= flow.spending + 0.01)
            check("the ranking is largest first and every line is its charges", zip(byPayee, byPayee.dropFirst()).allSatisfy { $0.total >= $1.total }
                  && byPayee.prefix(20).allSatisfy { line in abs(store.transactions(withIDs: line.chargeIDs).reduce(0) { $0 + $1.amount } - line.total) < 0.01 })
            let ideas = store.savingsIdeas()
            check("ways to save: each is worth something, none twice, largest first", ideas.allSatisfy { $0.yearly > 0 } && Set(ideas.map(\.id)).count == ideas.count
                  && zip(ideas, ideas.dropFirst()).allSatisfy { $0.yearly >= $1.yearly })
            if let idea = ideas.first {
                store.dismiss(idea)
                check("an idea waved away stays away", !store.savingsIdeas().contains { $0.id == idea.id })
            }
        }
        // A change asked for in words finds its payee, says what it would do, does it, and can put it back.
        if let t = store.transactions.first(where: { $0.countsAsSpending && $0.category != .gifts && $0.merchant.count >= 5 }) {
            let action = ChatAction(["type": "file", "payee": t.merchant.lowercased(), "category": "gifts"], store: store)
            check("chat: an instruction finds its payee and its category", action == .file(payee: t.merchant, category: .gifts, was: t.category))
            check("chat: nothing changes until asked", store.charges(at: t.merchant).allSatisfy { $0.category != .gifts || $0.isOverride })
            _ = action?.perform()
            check("chat: the change is made", !store.charges(at: t.merchant).isEmpty && store.charges(at: t.merchant).allSatisfy { $0.category == .gifts })
            _ = action?.undo?()
            check("chat: and can be put back", store.charges(at: t.merchant).allSatisfy { $0.category == t.category })
            check("chat: an unknown payee or category is refused", ChatAction(["type": "file", "payee": "zzqqxx nowhere", "category": "gifts"], store: store) == nil
                  && ChatAction(["type": "file", "payee": t.merchant, "category": "no such thing"], store: store) == nil)
        }

        // More chat: undo changes only the records the action changed; an action says so when its payee is gone.
        if let t = store.transactions.first(where: { $0.countsAsSpending && $0.merchant.count >= 5 }),
           let u = store.transactions.first(where: { $0.countsAsSpending && $0.merchant != t.merchant && $0.merchantKey != t.merchantKey }) {
            let mine = Set(store.charges(at: t.merchant).map(\.merchantKey)), theirs = Set(store.charges(at: u.merchant).map(\.merchantKey))
            let record = { (key: String) in store.library.merchants[key].map { "\($0.name)|\($0.category?.rawValue ?? "-")|\($0.source.rawValue)|\($0.confirmed)" } }
            let before = Dictionary(uniqueKeysWithValues: mine.union(theirs).map { ($0, record($0)) })
            let rename = ChatAction.rename(payee: t.merchant, to: u.merchant)
            _ = rename.perform()
            check("chat: a rename to the name of another payee joins them", mine.allSatisfy { store.library.merchants[$0]?.name == u.merchant })
            _ = rename.undo?()
            check("chat: undoing a rename puts back only the payee that was renamed, as it was",
                  mine.allSatisfy { record($0) == before[$0] } && theirs.allSatisfy { record($0) == before[$0] })
            let file = ChatAction.file(payee: t.merchant, category: t.category == .gifts ? .travel : .gifts, was: t.category)
            _ = file.perform()
            _ = file.undo?()
            check("chat: undoing a filing puts each payee record back as it was", mine.allSatisfy { record($0) == before[$0] })
            let message = ChatAction.rename(payee: "Zzqq Nowhere At All", to: "Something").perform()
            check("chat: an action on a payee that is gone says so and changes nothing", message.contains("can't find") && !message.hasPrefix("Done"))
        }
        // Naming a payee is the person's word, and a later answer from a model does not replace what they said.
        if let t = store.transactions.first(where: { $0.countsAsSpending && $0.merchant.count >= 5 }), let before = store.library.merchants[t.merchantKey], before.category != nil {
            let name = before.name
            store.renamePlace(t.merchantKey, to: name + " Renamed")
            check("a rename is the person's own word: filed by them and confirmed", store.library.merchants[t.merchantKey].map { $0.source == .user && $0.confirmed } == true && store.byHandNames().contains(name + " Renamed"))
            store.renamePlace(t.merchantKey, to: name)
            store.library.merchants[t.merchantKey]?.source = before.source
            store.library.merchants[t.merchantKey]?.confirmed = before.confirmed
            store.library.merchants[t.merchantKey]?.optional = nil
            store.setOptional(false, payee: [t.merchantKey])
            store.applyOptional([t.merchantKey: 0.9])
            check("needs and wants: an answer that arrives later never overwrites the person's word", store.library.merchants[t.merchantKey]?.optional == 0)
            // A record made later for the same payee takes that word before anything is asked.
            let twin = "own:selftest-twin"
            store.library.merchants[twin] = MerchantInfo(name: name, category: before.category, source: .ai, sample: "TWIN")
            _ = store.inheritOptionalByName()
            check("needs and wants: a new record of the same payee inherits what the person said", store.library.merchants[twin]?.optional == 0)
            store.library.merchants[twin] = nil
            store.library.merchants[t.merchantKey]?.optional = before.optional
            store.changed()
        }
        // Saving one sentence is not a rebuild of everything.
        let revision = store.revision
        store.savedOnly()
        check("saving alone rebuilds nothing", store.revision == revision)
        // "Since you last looked" never counts what came in during this sitting.
        if let late = store.arrived(since: .distantPast) {
            let sources = Dictionary(uniqueKeysWithValues: (store.library.sources ?? []).map { ($0.id, $0.added) })
            check("since you last looked: only statements added before this sitting began", late.statements <= (store.library.sources ?? []).count
                  && store.library.entries.filter { late.charges.contains($0.id) }.allSatisfy { $0.sourceID.flatMap { sources[$0] }.map { $0 <= BudgetStore.launchedAt } == true })
        }
        check("since you last looked: a statement added after launch is not news",
              !(store.library.sources ?? []).allSatisfy { $0.added > BudgetStore.launchedAt } || store.arrived(since: .distantPast) == nil)

        // A payee is tied to a trip by its charges in it, not by a monthly bill that happened to fall on a day away.
        for bill in store.recurring().filter({ $0.isActive && $0.cadence == .monthly && $0.count >= 12 }).prefix(3) {
            let charges = store.charges(at: bill.merchant)
            check("a monthly bill is not called part of every trip (\(bill.merchant))", store.stories(touching: charges).count * 2 <= max(1, charges.count))
        }

        // "Since you last looked" counts exactly the charges of statements added after that moment.
        if let newest = (store.library.sources ?? []).map(\.added).max() {
            check("nothing has arrived since the newest statement", store.arrived(since: newest) == nil)
            if let all = store.arrived(since: .distantPast, until: .distantFuture) {
                let fromStatements = Set(store.library.entries.filter { $0.sourceID != nil }.map(\.id))
                check("everything from a statement has arrived since the beginning", Set(all.charges).isSubset(of: fromStatements) && all.statements == (store.library.sources ?? []).count
                      && abs(all.spent - store.transactions(withIDs: all.charges).filter { $0.countsAsSpending && $0.amount > 0 }.reduce(0) { $0 + $1.amount }) < 0.01)
            }
        }

        // What pages keep between redraws must equal what they would work out afresh.
        for f in [TransactionFilter(category: .travel), TransactionFilter(month: store.months.last), TransactionFilter(needsCheck: true)] {
            let fresh = store.transactions.filter { (f.category == nil || $0.category == f.category!) && (f.month == nil || $0.month == f.month!) && (!f.needsCheck || $0.needsCheck) }.map(\.id)
            check("kept rows equal a fresh filter (\(f.cacheKey))", Set(store.filteredTransactions(f, search: "").map(\.id)) == Set(fresh))
        }
        if let t = store.transactions.first {
            check("a payee's kept charges equal a fresh search", Set(store.charges(at: t.merchant).map(\.id)) == Set(store.transactions.filter { $0.merchant == t.merchant }.map(\.id)))
            check("the kept list of payees is every payee", store.allPayeeNames == Set(store.transactions.map(\.merchant)))
            let old = t.merchant, new = old + " Renamed"
            _ = store.charges(at: old); _ = PlaceLinker.names()
            store.renamePlace(t.merchantKey, to: new)
            check("a rename is seen at once by everything kept", !store.charges(at: new).isEmpty && store.allPayeeNames.contains(new))
            store.renamePlace(t.merchantKey, to: old)
        }
        if let a = store.accounts.first {
            let mine = store.transactions.filter { $0.accountID == a.id }
            let s = store.summary(of: a)
            check("an account's kept summary equals fresh sums", s.count == mine.count && abs(s.spent - mine.filter(\.countsAsSpending).reduce(0) { $0 + $1.amount }) < 0.01)
        }
        store.go(to: .orders) { store.orderOnly = nil }
        store.navigate { store.orderOnly = "X" }
        store.back()
        check("Back leaves a single order for the whole list", store.orderOnly == nil)
        store.selection = .overview

        // Tidying acts, records what it did, and puts it back exactly on Undo.
        do {
            let byName = TidyEngine.spellings(of: store.transactions, byHand: [])
            // The same payee every run (a dictionary's order is not), and one whose odd spelling has a name of its own.
            let candidate = byName.sorted { $0.key < $1.key }.first { name, list in
                list.count > 1 && list.last.map { KeywordExtractor.displayName(for: $0.sample).caseInsensitiveCompare(name) != .orderedSame } == true
            }
            if let (payee, list) = candidate, let main = list.first, let odd = list.last {
                let before = store.transactions.filter { $0.merchant == payee }.map(\.id)
                let tidiedBefore = store.tidyChanges.count
                let done = await store.applyTidy([(TidyEngine.Pair(kind: .separate, a: main, b: odd), 0.01)])
                let after = store.transactions.filter { $0.merchant == payee }.count
                check("tidy: a sure split moves only the odd spelling, and says so", done.count == 1 && done[0].charges == odd.count && after == before.count - odd.count
                      && store.tidyChanges.count == tidiedBefore + 1 && store.newTidyChanges.contains { $0.pairID == done[0].pairID })
                if let change = store.library.tidy?.changes.last(where: { $0.pairID == done.first?.pairID }) { store.undo(change) }
                let restored = store.transactions.filter { $0.merchant == payee }.map(\.id)
                if restored != before || store.tidyChanges.count != tidiedBefore { print("SELFTEST NOTE tidy counts \(tidiedBefore) -> \(store.tidyChanges.count), raw \(store.library.tidy?.changes.count ?? -1), done \(done.count), judged-declined \(store.library.tidy?.judged.values.filter { $0 == -1 }.count ?? -1)") }
                if restored != before { print("SELFTEST NOTE tidy undo: \(payee) had \(before.count), has \(restored.count); same set \(Set(restored) == Set(before)); changes left \(store.tidyChanges.count); odd \(odd.text) x\(odd.count), main \(main.text)") }
                check("tidy: undo puts every charge back and is remembered", Set(restored) == Set(before)
                      && store.tidyChanges.count == tidiedBefore && store.library.tidy?.judged.values.contains(-1) == true)
            } else { print("SELFTEST SKIP tidy split (no payee here is written two ways)") }
        }
        // What the person named, filed or confirmed is not touched by tidying; a charge they filed alone stays; undo only moves back what is still where tidying put it.
        do {
            let byName = TidyEngine.spellings(of: store.transactions, byHand: [])
            let candidate = byName.sorted { $0.key < $1.key }.first { name, list in
                list.count > 1 && list.last.map { KeywordExtractor.displayName(for: $0.sample).caseInsensitiveCompare(name) != .orderedSame } == true
            }
            if let (payee, list) = candidate, let main = list.first, let odd = list.last {
                let keys = store.library.merchants.filter { $0.value.name == payee }.map(\.key)
                let pair = TidyEngine.Pair(kind: .separate, a: main, b: odd)
                let onPayee = { store.transactions.filter { $0.merchant == payee }.count }
                let before = onPayee()
                // Confirmed by the person (the pair still says it is not, as it was when the model was asked): left alone.
                let was = keys.map { ($0, store.library.merchants[$0]?.confirmed ?? false) }
                for key in keys { store.library.merchants[key]?.confirmed = true }
                let refused = await store.applyTidy([(pair, 0.01)])
                check("tidy: a payee the person confirmed is not taken apart, whatever the pair said when it was asked", refused.isEmpty && onPayee() == before)
                for (key, confirmed) in was { store.library.merchants[key]?.confirmed = confirmed }
                // A charge the person filed by itself stays on its payee.
                let spellingOf = { (e: LedgerEntry) in MerchantResolver.spelling(e.description).uppercased() }
                if let own = store.library.entries.firstIndex(where: { keys.contains($0.merchantKey) && spellingOf($0) == odd.text }) {
                    let id = store.library.entries[own].id
                    store.library.entries[own].override = .gifts
                    let done = await store.applyTidy([(pair, 0.01)])
                    let kept = store.library.entries.first { $0.id == id }
                    check("tidy: a charge the person filed alone is left where it is, with its own category",
                          kept?.override == .gifts && keys.contains(kept?.merchantKey ?? "") && (done.first?.charges ?? 0) == odd.count - 1)
                    // Moved by hand after tidying: undo leaves it where the person put it.
                    if let change = store.library.tidy?.changes.last(where: { $0.pairID == done.first?.pairID }), let moved = change.moved?.keys.first(where: { $0 != id.uuidString }),
                       let other = store.library.merchants.keys.first(where: { !keys.contains($0) && $0 != change.otherKey }),
                       let i = store.library.entries.firstIndex(where: { $0.id.uuidString == moved }) {
                        store.library.entries[i].merchantKey = other
                        store.undo(change)
                        check("tidy: undo puts back only the charges still where tidying put them", store.library.entries[i].merchantKey == other && onPayee() == before - 1)
                        store.library.entries[i].merchantKey = keys.first ?? other
                    } else if let change = store.library.tidy?.changes.last(where: { $0.pairID == done.first?.pairID }) { store.undo(change) }
                    if let j = store.library.entries.firstIndex(where: { $0.id == id }) { store.library.entries[j].override = nil }
                    store.changed()
                } else { print("SELFTEST SKIP tidy override (no charge written the odd way)") }
                // A pair the model did not answer is remembered, once, then again, and then it is settled.
                let probe = "pair|selftest|selftest2"
                _ = await store.applyTidy([], unanswered: [probe])
                let once = store.library.tidy?.judged[probe]
                _ = await store.applyTidy([], unanswered: [probe])
                let twice = store.library.tidy?.judged[probe]
                check("tidy: a pair left unanswered is asked once more and then let be", once == -2 && twice == -3 && store.library.tidy?.settled.contains(probe) == true)
                store.library.tidy?.judged[probe] = nil
            } else { print("SELFTEST SKIP tidy by hand (no payee here is written two ways)") }
        }
        // One way a payee is written can be made a payee of its own; the rest stay, and the choice is kept.
        let bySpelling = Dictionary(grouping: store.transactions, by: \.merchant)
            .mapValues { Dictionary(grouping: $0) { MerchantResolver.spelling($0.description) } }
        if let (payee, spellings) = bySpelling.first(where: { $0.value.count > 1 }), let (spelling, moving) = spellings.min(by: { $0.value.count < $1.value.count }) {
            let before = store.transactions.filter { $0.merchant == payee }.count
            store.separate(spelling: spelling, from: payee, as: "Somebody Else Entirely", category: .travel)
            let moved = store.transactions.filter { $0.merchant == "Somebody Else Entirely" }
            check("separate one spelling from a payee", moved.count == moving.count && moved.allSatisfy { $0.category == .travel }
                  && store.transactions.filter { $0.merchant == payee }.count == before - moving.count
                  && moved.first.map { MerchantResolver.key(for: $0.description, amount: $0.amount, existingKeys: [String](), spellings: [spelling.uppercased(): $0.merchantKey]) == $0.merchantKey } == true)
        } else { print("SELFTEST SKIP separate one spelling (no payee here is written two ways)") }
        // Back always returns to where a link was followed from, however deep; the sidebar is a fresh start.
        if let payee = store.transactions.first?.merchant, let month = store.months.first {
            store.selection = .overview
            store.overviewMonth = month
            store.stepInto(.spending)
            store.showCharges(TransactionFilter(category: .dining, month: month))
            store.showPlace(payee)
            store.go(to: .transactions)
            let deep = store.selection == .transactions && store.route.isEmpty && store.canGoBack
            store.back()
            let onPayee = store.selection == .overview && store.route.last == .place(payee) && store.overviewDetail == .spending
            store.back(); store.back()
            let onDetail = store.route.isEmpty && store.overviewDetail == .spending && store.overviewMonth == month
            store.back()
            check("back retraces every step", deep && onPayee && onDetail && store.overviewDetail == nil && !store.canGoBack)
            store.showPlace(payee)
            store.selection = .places
            check("the sidebar starts afresh", store.route.isEmpty && !store.canGoBack)
            store.selection = .overview
            store.overviewMonth = nil
        }
        // SPENDTHRIFT_EXPLAIN="Whitfield|my accountant, for tax prep": say what a place was and print what happened.
        if let spec = ProcessInfo.processInfo.environment["SPENDTHRIFT_EXPLAIN"]?.split(separator: "|", maxSplits: 1).map(String.init), spec.count == 2,
           let t = store.transactions.first(where: { $0.merchant.localizedCaseInsensitiveContains(spec[0]) }) {
            let before = "\(t.merchant) | \(t.category.displayName)"
            let ok = await store.explain(t.merchantKey, said: spec[1])
            let after = store.transactions.first { $0.id == t.id }
            print("EXPLAIN \(ok ? "ok" : "failed"): \(before)  →  \(after?.merchant ?? "?") | \(after?.category.displayName ?? "?") | note: \(after?.note ?? "-") | needs check: \(after?.needsCheck ?? true)")
        }
        if store.stories.count >= 2, let moving = store.transactions(in: store.stories[0]).first?.id {
            let from = store.stories[0], to = store.stories[1]
            let before = store.transactions(in: to).count
            store.move([moving], to: to)
            check("move a charge between trips", store.story(containing: moving)?.fingerprint == to.fingerprint
                  && store.stories.first { $0.fingerprint == to.fingerprint }.map { store.transactions(in: $0).count } == before + 1)
            store.move([moving], to: nil)
            check("take a charge out of every trip", store.story(containing: moving) == nil)
            store.move([moving], to: from)
        }
        guard let t = store.transactions.first(where: { $0.countsAsSpending && $0.category != .gifts }) else { check("has data", false); print("SELFTEST SUMMARY \(passed) passed, \(failed) failed"); return }
        let samePlace = store.transactions.filter { $0.merchantKey == t.merchantKey }.count

        store.setCategory(.gifts, for: [t.id], wholePlace: false)
        check("only-this-charge changes one", store.transactions.filter { $0.merchantKey == t.merchantKey && $0.category == .gifts }.count == 1)
        check("override is flagged", store.transactions.first { $0.id == t.id }?.isOverride == true)

        store.setCategory(.travel, for: [t.id], wholePlace: true)
        check("whole-place changes all \(samePlace)", store.transactions.filter { $0.merchantKey == t.merchantKey && $0.category == .travel }.count == samePlace)
        check("whole-place marks as user's choice", store.place(t.merchantKey)?.source == .user && store.place(t.merchantKey)?.confirmed == true)

        store.renamePlace(t.merchantKey, to: "Renamed Place")
        check("rename applies everywhere", store.transactions.filter { $0.merchant == "Renamed Place" }.count == samePlace)

        // Custom categories
        let pets = store.saveCategory(CustomCategory(name: "Pets", symbol: "pawprint.fill", color: "teal"))
        check("create custom category", pets != nil && Category.spendingCases.contains(Category("Pets")) && Category("Pets").symbol == "pawprint.fill")
        check("duplicate name refused", store.saveCategory(CustomCategory(name: "pets", symbol: "tag.fill", color: "red")) == nil
              && store.saveCategory(CustomCategory(name: "Dining", symbol: "tag.fill", color: "red")) == nil)
        if let pets {
            store.setCategory(pets, forPlace: t.merchantKey)
            check("file a place under it", store.transactions.filter { $0.category == pets }.count == samePlace)
            guard var edited = store.customCategories.first(where: { $0.name == "Pets" }) else { return check("the new category is listed", false) }
            let customBefore = Category.custom.count
            edited.name = "Dog"
            store.saveCategory(edited)
            check("rename keeps its charges", store.transactions.filter { $0.category == Category("Dog") }.count == samePlace && !Category.allCases.contains(pets))
            check("AI schema offers it", Category.spendingCases.map(\.rawValue).contains("Dog") && AISchemas.merchantGuesses(count: 1, purchasesOnly: true) != nil)
            if let dog = store.customCategories.first(where: { $0.name == "Dog" }) { store.deleteCategory(dog) }
            check("delete moves charges to Other", store.transactions.filter { $0.merchantKey == t.merchantKey && $0.category == .other }.count == samePlace
                  && Category.custom.count == customBefore - 1)
            store.setCategory(.travel, forPlace: t.merchantKey)
        }

        let before = store.transactions.count, accountsBefore = store.accounts.count
        store.importFiles(files)
        try? await Task.sleep(for: .seconds(3))
        check("re-import adds nothing (\(store.transactions.count) vs \(before))", store.transactions.count == before && store.accounts.count == accountsBefore)
        check("choices survive re-import", store.transactions.filter { $0.merchantKey == t.merchantKey && $0.category == .travel }.count == samePlace)

        if let account = store.accounts.first {
            let spent = store.spent(in: account)
            store.flipAmounts(account.id)
            check("flip swaps signs", abs(store.spent(in: account) + spent) < 0.01 || spent == 0)
            store.flipAmounts(account.id)
            check("flip twice restores", abs(store.spent(in: account) - spent) < 0.01)
            let n = store.transactionCount(for: account)
            store.removeAccount(account.id)
            check("remove account drops its \(n) transactions", store.transactions.count == before - n)
        }
        // Saved library reloads identically.
        // Written now, rather than after the usual short wait, so this checks the file and not the timing.
        store.saveNow()
        let reloaded = Library.load(paths: store.paths).0
        let cents = { (entries: [LedgerEntry]) in entries.reduce(0) { $0 + Int(($1.amount * 100).rounded()) } }
        check("saved to disk (\(reloaded.entries.count) entries)", reloaded.entries.count == store.library.entries.count
              && cents(reloaded.entries) == cents(store.library.entries) && reloaded.merchants.count == store.library.merchants.count)
        // Whatever the library holds in memory comes back from the file: a field left out of the
        // loading code would vanish at the next launch without anyone noticing.
        func shape(_ library: Library) -> [String: Int] {
            guard let data = try? JSONEncoder().encode(library), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return object.mapValues { ($0 as? [Any])?.count ?? ($0 as? [String: Any])?.count ?? 1 }
        }
        let kept = shape(store.library), back = shape(reloaded)
        let lost = kept.filter { back[$0.key] != $0.value }.keys.sorted()
        check("every part of the library survives saving and loading" + (lost.isEmpty ? "" : " (lost: \(lost.joined(separator: ", ")))"), !kept.isEmpty && lost.isEmpty)
        print("SELFTEST SUMMARY \(passed) passed, \(failed) failed")
    }
}
