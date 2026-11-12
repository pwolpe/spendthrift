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
        check("library: a new stored field must be added to the decoder (22 today)", Mirror(reflecting: Library()).children.count == 22)

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
        let repeating = store.recurring()
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
        check("the small bars add up to the big figures", near(run.reduce(0) { $0 + $1.income }, year.totalIncome) && near(run.reduce(0) { $0 + $1.invested }, year.investmentOut))
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
        if let latest = store.months.last {
            check("everything worth knowing leads somewhere", store.insights(for: latest).allSatisfy { $0.target != nil })
        }
    }

    // MARK: Doing what a person would do

    static func run(files: [URL]) async {
        let store = BudgetStore.shared
        logic()
        books(store)
        // Tidying acts, records what it did, and puts it back exactly on Undo.
        do {
            let byName = TidyEngine.spellings(of: store.transactions, byHand: [])
            if let (payee, list) = byName.first(where: { $0.value.count > 1 }), let main = list.first, let odd = list.last {
                let before = store.transactions.filter { $0.merchant == payee }.map(\.id)
                let done = await store.applyTidy([(TidyEngine.Pair(kind: .separate, a: main, b: odd), 0.01)])
                let after = store.transactions.filter { $0.merchant == payee }.count
                check("tidy: a sure split moves only the odd spelling, and says so", done.count == 1 && done[0].charges == odd.count && after == before.count - odd.count
                      && store.tidyChanges.count == 1 && store.newTidyChanges.count == 1)
                if let change = store.tidyChanges.first { store.undo(change) }
                let restored = store.transactions.filter { $0.merchant == payee }.map(\.id)
                if restored != before { print("SELFTEST NOTE tidy undo: \(payee) had \(before.count), has \(restored.count); same set \(Set(restored) == Set(before)); changes left \(store.tidyChanges.count); odd \(odd.text) x\(odd.count), main \(main.text)") }
                check("tidy: undo puts every charge back and is remembered", Set(restored) == Set(before)
                      && store.tidyChanges.isEmpty && store.library.tidy?.judged.values.contains(-1) == true)
            } else { print("SELFTEST SKIP tidy split (no payee here is written two ways)") }
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
