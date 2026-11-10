import Foundation
import PDFKit
import FoundationModels

/// Turns a bank/credit card PDF statement into the same table shape as a CSV.
/// Pattern matching handles most statements; Apple's on-device model is the fallback.
enum PDFStatement {
    enum PDFError: LocalizedError {
        case unreadable, locked, lockedAndSkipped, noTransactions
        var errorDescription: String? {
            switch self {
            case .unreadable: "This PDF couldn't be opened."
            case .locked: "This PDF is locked with a password that didn't open it."
            case .lockedAndSkipped: "This PDF is locked with a password, so it was skipped. Drop it in again when you have the password."
            case .noTransactions: "No transactions were found in this PDF. If your bank offers a CSV download, try that instead."
            }
        }
    }

    /// Rows are produced as: ISO date, description, amount (positive = spent).
    static let mapping = ColumnMapping(dateColumn: 0, dateFormat: "yyyy-MM-dd", descriptionColumn: 1,
                                       amountColumn: 2, debitColumn: nil, creditColumn: nil, purchasesAreNegative: false)

    static func table(from url: URL, password: String? = nil) async throws -> CSVTable {
        guard let doc = PDFDocument(url: url) else { throw PDFError.unreadable }
        if doc.isLocked, !(password.map { doc.unlock(withPassword: $0) } ?? false) { throw PDFError.locked }
        let pdfPages = (0..<min(doc.pageCount, 200)).compactMap { doc.page(at: $0) }
        var pages = pdfPages.compactMap(\.string)
        var text = pages.joined(separator: "\n")
        // A scan has pictures of pages and no text: read the pictures.
        let isScan = text.filter(\.isLetter).count < 40 * max(1, min(pdfPages.count, 3))
        if isScan {
            pages = pdfPages.prefix(40).map(Scans.text(inPage:))
            text = pages.joined(separator: "\n")
            return try await table(fromText: text, pages: pages, positional: nil, url: url)
        }
        return try await table(fromText: text, pages: pages,
                               positional: pdfPages.map(positionalText).joined(separator: "\n"), url: url)
    }

    /// A photo or screenshot of a statement.
    static func table(fromImage url: URL) async throws -> CSVTable {
        guard let text = Scans.text(inImageAt: url) else { throw PDFError.unreadable }
        return try await table(fromText: text, pages: [text], positional: nil, url: url)
    }

    private static func table(fromText text: String, pages: [String], positional positionalText: String?, url: URL) async throws -> CSVTable {

        let knownIssuer = detectIssuer(text)
        // Chase names its files "20260125-statements-4090-.pdf" after the account as it is today, even
        // when an older statement inside still prints a replaced card's number. Trust the file name there.
        let fromFileName = url.lastPathComponent.range(of: #"statements-\d{4}-"#, options: .regularExpression)
            .map { String(url.lastPathComponent[$0].filter(\.isNumber)) }
        let last4 = fromFileName ?? detectLast4(text) ?? StatementReader.cardDigits(in: url)
        let closing = detectClosingDate(text) ?? .now

        // PDFs store text in whatever order the bank's software wrote it. Usually that's reading
        // order; sometimes (Chase checking) amounts come out detached from their descriptions.
        // So read it both ways (as stored, and rebuilt row by row from positions on the page)
        // and keep whichever agrees with the statement's own printed totals.
        let stored = parseLines(text, closing: closing)
        var best = stored
        if let positionalText {
            let positional = parseLines(positionalText, closing: closing)
            if positional.score > stored.score || (positional.score == stored.score && positional.rows.count > stored.rows.count) {
                best = positional
            }
        }
        var rows = best.rows
        var cloudCheck: StatementCheck?
        // Card statements print an account summary ("Purchases +$346.81, Payments/Credits -$1,818.04")
        // rather than section totals: that's just as good a check.
        // (The summary may only read correctly in one of the two text orders, so try both.)
        let summaryMatches = { (candidate: [CanonicalRow]) in
            matchesAccountSummary(text, rows: candidate) || (positionalText.map { matchesAccountSummary($0, rows: candidate) } ?? false)
        }
        if best.matched == 0, best.mismatched.isEmpty, summaryMatches(rows) { best.matched = 1 }
        // Unless our own reading already adds up to the statement's printed totals, let the powerful
        // model read it too (when Tony's Mac has a key). It copes with layouts and scans the patterns
        // don't, and two independent readings that agree are as good as a printed total.
        let selfVerified = best.matched > 0 && best.mismatched.isEmpty
        if !selfVerified, CloudAI.canReadStatements,
           let cloud = await CloudStatementReader.read(text: positionalText ?? text, closing: closing) {
            let total = { (list: [CanonicalRow]) in (list.reduce(0) { $0 + $1.amount } * 100).rounded() / 100 }
            let agree = cloud.rows.count == rows.count && total(cloud.rows) == total(rows)
            if cloud.verified || agree || summaryMatches(cloud.rows) {
                if !agree { rows = cloud.rows }
                cloudCheck = .verified
            } else if rows.isEmpty || !best.mismatched.isEmpty || positionalText == nil || cloud.rows.count >= rows.count {
                // Ours was empty, wrong, read off a picture, or less complete: take the model's.
                rows = cloud.rows
                cloudCheck = positionalText == nil ? .scanned : StatementCheck.none
            }
        }
        // Without the cloud, and only when pattern matching found nothing, try the on-device model.
        if rows.isEmpty, CategorySuggester.isAvailable {
            // Slow (several seconds a page), so only read pages that look like they list transactions.
            let candidates = pages.filter(looksLikeTransactions)
            rows = await Timeout.run(60 + 45 * Double(candidates.count)) { await aiExtract(pages: candidates, closing: closing) } ?? []
        }
        guard !rows.isEmpty else { throw PDFError.noTransactions }

        let head = String(text.prefix(1500))
        // A card statement mentions "savings" and "checking" in passing (rewards, payment instructions),
        // so only call it a bank account when it doesn't look like a card.
        let isCard = text.range(of: #"(?i)minimum payment due|credit (?:access )?line|credit limit|card ?member|pay over time"#, options: .regularExpression) != nil
        let kind: String? = isCard ? nil
            : text.range(of: #"(?i)checking account summary|checking summary"#, options: .regularExpression) != nil
            || head.range(of: #"(?i)\bchecking\b"#, options: .regularExpression) != nil ? "Checking"
            : text.range(of: #"(?i)savings account summary|savings summary"#, options: .regularExpression) != nil
            || head.range(of: #"(?i)\bsavings account\b"#, options: .regularExpression) != nil ? "Savings" : nil
        // A bank we've never heard of usually prints its name near the top.
        let issuer = knownIssuer ?? head.components(separatedBy: .newlines).prefix(8).map { $0.trimmingCharacters(in: .whitespaces) }.first { line in
            line.count <= 40 && line.range(of: #"(?i)\b(bank|credit union|financial|trust|savings & loan)\b"#, options: .regularExpression) != nil
                && line.rangeOfCharacter(from: .decimalDigits) == nil
        }
        let signature = "pdf:\(issuer?.lowercased() ?? "statement"):\(last4 ?? "")"
        let name = [issuer, kind, last4.map { "••\($0)" }].compactMap { $0 }.joined(separator: " ")
        var table = CSVTable(header: ["Date", "Description", "Amount"],
                             rows: rows.map { [$0.date, $0.description, String(format: "%.2f", $0.amount)] },
                             signature: signature,
                             suggestedName: name.isEmpty ? nil : name)
        if let cloudCheck {
            table.check = cloudCheck
        } else if !best.mismatched.isEmpty {
            table.check = .mismatch(best.mismatched.joined(separator: ", "))
        } else if best.matched > 0 {
            table.check = .verified
        } else if positionalText == nil {
            table.check = .scanned
        }
        return table
    }

    /// Do the rows add up to the card's printed account summary? Money out must equal purchases plus
    /// cash advances, balance transfers, fees and interest; money in must equal payments and credits.
    static func matchesAccountSummary(_ text: String, rows: [CanonicalRow]) -> Bool {
        // Every amount printed after a label, anywhere on a line. A statement can print several
        // summaries (Amex: Pay In Full, Pay Over Time, Account Total); any one that fits will do.
        func amounts(_ label: String) -> [Double] {
            // (Capital One prints "Transactions + $42.45": a sign, a space, then the amount.)
            let pattern = "(?i)(?:^|\\s)(?:" + label + ")\\s+[-+]?\\s?\\$?([\\d,]+\\.\\d{2})\\b"
            guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
            return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
                Range(m.range(at: 1), in: text).flatMap { MoneyParsing.parse(String(text[$0])) }
            }
        }
        let spent = rows.filter { $0.amount > 0 }.reduce(0) { $0 + $1.amount }
        let received = rows.filter { $0.amount < 0 }.reduce(0) { $0 - $1.amount }
        guard spent > 0 || received > 0 else { return false }
        let extras = (amounts("Cash Advances").first ?? 0) + (amounts("Balance Transfers").first ?? 0)
            + (amounts("Fees(?: Charged)?").first ?? 0) + (amounts("Interest(?: Charged)?").first ?? 0)
        let purchases = amounts("Purchases") + amounts("New Charges") + amounts("Total New Charges") + amounts("Transactions")
        var credits = amounts("Payments?,? ?(?:and |& |/ ?)?(?:Other )?Credits") + amounts("Total Payments and Credits")
        if let payments = amounts("Payments").first { credits.append(payments + (amounts("Credits").first ?? 0)) }
        let outMatches = purchases.contains { abs($0 + extras - spent) < 0.005 || abs($0 - spent) < 0.005 }
        let inMatches = credits.contains { abs($0 - received) < 0.005 }
        return outMatches && inMatches
    }

    /// Rebuilds the visual rows of a page: text fragments at the same height are one row, read left to right.
    static func positionalText(_ page: PDFPage) -> String {
        guard let all = page.selection(for: page.bounds(for: .mediaBox)) else { return page.string ?? "" }
        var fragments: [(y: CGFloat, x: CGFloat, text: String)] = []
        for line in all.selectionsByLine() {
            let bounds = line.bounds(for: page)
            let text = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { fragments.append((bounds.midY, bounds.minX, text)) }
        }
        fragments.sort { $0.y > $1.y }
        var rows: [[(x: CGFloat, text: String)]] = []
        var lastY = CGFloat.infinity
        for f in fragments {
            if abs(f.y - lastY) > 3.5 { rows.append([]); lastY = f.y }
            rows[rows.count - 1].append((f.x, f.text))
        }
        return rows.map { $0.sorted { $0.x < $1.x }.map(\.text).joined(separator: " ") }.joined(separator: "\n")
    }

    // MARK: Metadata

    /// Quick check of the first page for statement wording (for PDFs named only by date).
    nonisolated static func looksLikeStatement(_ url: URL) -> Bool {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size < 8_000_000, let doc = PDFDocument(url: url), !doc.isLocked,
              let first = doc.page(at: 0)?.string?.lowercased() else { return false }
        let phrases = ["closing date", "statement period", "new balance", "account ending", "statement closing",
                       "beginning balance", "ending balance", "payment due date", "minimum payment"]
        return phrases.filter(first.contains).count >= 2
    }

    private static let issuers = ["American Express", "Chase", "Citi", "Capital One", "Bank of America", "Wells Fargo",
                                  "Discover", "U.S. Bank", "Barclays", "Synchrony", "PNC", "TD Bank", "Fidelity",
                                  "Charles Schwab", "Ally", "USAA", "Navy Federal", "Apple Card", "Goldman Sachs"]

    static func detectIssuer(_ text: String) -> String? {
        let head = String(text.prefix(6000))
        // Web addresses are the most reliable clue ("americanexpress.com" on an Amex Platinum statement).
        let domains = [("americanexpress.com", "American Express"), ("chase.com", "Chase"), ("citi.com", "Citi"),
                       ("capitalone.com", "Capital One"), ("bankofamerica.com", "Bank of America"),
                       ("wellsfargo.com", "Wells Fargo"), ("discover.com", "Discover"), ("usbank.com", "U.S. Bank")]
        let lower = head.lowercased()
        var best: (String, String.Index)?
        for (domain, name) in domains {
            if let r = lower.range(of: domain), best == nil || r.lowerBound < best!.1 { best = (name, r.lowerBound) }
        }
        for name in issuers {
            let pattern = "(?i)\\b" + NSRegularExpression.escapedPattern(for: name) + "\\b"
            if let r = head.range(of: pattern, options: .regularExpression), best == nil || r.lowerBound < best!.1 {
                best = (name, r.lowerBound)
            }
        }
        return best?.0
    }

    static func detectLast4(_ text: String) -> String? {
        let pattern = #"(?i)(?:ending in|account ending|acct ending|account number|account #|card number)[^0-9]{0,40}?(?:[x*•\d]{1,}[\s-]){0,3}(\d{4,5})\b"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else {
            // "Primary Account: 000012345678901" (Chase checking)
            if let r = text.range(of: #"(?i)primary account[:\s]+\d{6,}"#, options: .regularExpression) {
                return String(text[r].filter(\.isNumber).suffix(4))
            }
            return nil
        }
        return String(text[r].suffix(4))
    }

    /// The latest full date printed on the statement, used to fill in missing years.
    static func detectClosingDate(_ text: String) -> Date? {
        // "Billing Period: 10/08/26-11/06/26" (Citi) or "Opening/Closing Date 10/04/26 - 11/03/26" (Chase): the end date.
        if let r = text.range(of: #"(?i)(billing period|statement period|opening/closing date)[:\s]+\d{1,2}/\d{1,2}/\d{2,4}\s*[-–]\s*(\d{1,2}/\d{1,2}/\d{2,4})"#,
                              options: .regularExpression) {
            let end = String(text[r]).split(whereSeparator: { $0 == "-" || $0 == "–" || $0.isWhitespace }).last.map(String.init) ?? ""
            if let d = slashDate(end), Calendar.current.component(.year, from: d) >= 2000 { return d }
        }
        // "For the Period 1/1/26 to 1/30/26" (Chase checking)
        if let r = text.range(of: #"(?i)for the period\s+\d{1,2}/\d{1,2}/\d{2,4}\s+to\s+(\d{1,2}/\d{1,2}/\d{2,4})"#, options: .regularExpression) {
            let end = String(text[r]).split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
            if let d = slashDate(end), Calendar.current.component(.year, from: d) >= 2000 { return d }
        }
        // Most statements say it outright.
        if let r = text.range(of: #"(?i)(closing date|statement closing date|closing date of billing cycle|statement date)[:\s]+(\d{1,2}/\d{1,2}/\d{2,4})"#,
                              options: .regularExpression) {
            let s = String(text[r]).split(whereSeparator: { $0.isWhitespace || $0 == ":" }).last.map(String.init) ?? ""
            if let d = slashDate(s),
               Calendar.current.component(.year, from: d) >= 2000 { return d }
        }
        var dates: [Date] = []
        let numeric = try! NSRegularExpression(pattern: #"\b(\d{1,2}/\d{1,2}/(?:\d{4}|\d{2}))\b"#)
        let named = try! NSRegularExpression(pattern: #"\b((?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.? \d{1,2}, \d{4})\b"#)
        let ns = NSRange(text.startIndex..., in: text)
        for m in numeric.matches(in: text, range: ns) {
            guard let r = Range(m.range(at: 1), in: text) else { continue }
            let s = String(text[r])
            if let d = slashDate(s) { dates.append(d) }
        }
        for m in named.matches(in: text, range: ns) {
            guard let r = Range(m.range(at: 1), in: text) else { continue }
            let s = String(text[r]).replacingOccurrences(of: ".", with: "")
            for f in ["MMMM d, yyyy", "MMM d, yyyy"] {
                if let d = DateParsing.parse(s, format: f) { dates.append(d); break }
            }
        }
        let limit = Date.now.addingTimeInterval(45 * 24 * 3600)
        return dates.filter { $0 <= limit && Calendar.current.component(.year, from: $0) >= 2000 }.max()
    }

    /// "11/03/26" or "11/03/2026" (a plain "M/d/yyyy" parse would read "26" as the year 26).
    static func slashDate(_ s: String) -> Date? {
        guard let year = s.split(separator: "/").last else { return nil }
        return DateParsing.parse(s, format: year.count == 4 ? "M/d/yyyy" : "M/d/yy")
    }

    // MARK: Pattern matching

    /// "1,234.56", "$12.00", "(45.00)", "12.00CR", and amounts under a dollar written ".79" or "-.79".
    private static let moneyToken = #"^\(?-?\$?-?(?:[\d,]*\d)?\.\d{2}\)?(?:CR|DR)?-?$"#
    private static let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    private static let skipWords = ["total", "balance", "payment due", "minimum", "credit limit", "available credit",
                                    "previous", "new balance", "interest charged", "annual percentage", "page "]

    struct Parsed {
        var rows: [CanonicalRow] = []
        /// Sections whose rows add up to the "Total …" line the statement prints.
        var matched = 0
        var mismatched: [String] = []
        var score: Int { matched * 10 - mismatched.count * 10 }
    }

    /// Handles these layouts:
    ///   one line:    "10/14  BEST BUY 00012          1,249.99"
    ///   several:     "10/18/26 WYNN LAS VEGAS HOTEL/H LAS VEGAS NV" … detail lines … "$2,152.54 ⧫"   (Amex)
    ///   checks:      "178 02/23 180.00"   (under "Checks Paid")
    static func parseLines(_ text: String, closing: Date) -> Parsed {
        var out = Parsed()
        var sectionIsCredit = false
        var sectionTitle = ""
        var sectionSum = 0.0, sectionCount = 0
        let moneyRE = try! NSRegularExpression(pattern: moneyToken)
        let isMoney: (String) -> Bool = { t in
            moneyRE.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
        }
        // A charge whose amount is on a later line.
        var pending: (date: Date, description: String, linesWaited: Int)?
        // The row just added from a bare amount with no "$": the next line may hold the real dollars.
        var foreignCandidate: Int?
        var foreignLinesLeft = 0

        // Statements with several cardholders print the holder's name in front of every merchant.
        let holders = Redactor.holderNames(in: text).map { $0.uppercased() + " " }
        func add(_ date: Date, _ fullDescription: String, _ rawAmount: Double) {
            var description = fullDescription
            if let name = holders.first(where: { description.uppercased().hasPrefix($0) }) {
                description = String(description.dropFirst(name.count)).trimmingCharacters(in: .whitespaces)
            }
            guard description.filter(\.isLetter).count >= 3,
                  !skipWords.contains(where: description.lowercased().hasPrefix) else { return }
            // "February 11, 2026" in a sentence is a date, not a charge dated Feb 11 called "2026 …".
            if description.range(of: #"^(19|20)\d\d\b"#, options: .regularExpression) != nil { return }
            var amount = rawAmount
            sectionSum += abs(rawAmount); sectionCount += 1
            if sectionIsCredit && amount > 0 { amount = -amount }
            out.rows.append(CanonicalRow(date: DateParsing.iso.string(from: date), description: description,
                                         amount: (amount * 100).rounded() / 100))
        }
        // Section headings tell us whether plain positive amounts are money in or out.
        // PDF text often glues a heading onto the first transaction line, so look a few words in.
        func updateSection(_ text: String) {
            let t = text.lowercased()
            let before = sectionIsCredit
            var recognized = true
            // On a bank account, "Payments & Transfers" is money going out (on a card it's money coming in).
            if t.contains("payments & transfers") || t.contains("payments and transfers") || t.contains("atm & debit") || t.contains("debit card") {
                sectionIsCredit = false
            } else if t.hasSuffix(": transactions") {
                // Capital One heads each cardholder's purchases "NAME #1095: Transactions".
                sectionIsCredit = false
            } else if ["payments", "credits", "deposits", "additions", "refunds"].contains(where: t.contains) { sectionIsCredit = true }
            // "PURCHASE" (Chase cards print it in the singular), "CASH ADVANCES", "BALANCE TRANSFERS"…
            else if ["purchase", "withdrawals", "debits", "charges", "checks paid", "fees", "cash advance", "balance transfer", "interest charged"]
                .contains(where: t.contains) { sectionIsCredit = false }
            else { recognized = false }
            if recognized {
                let title = text.replacingOccurrences(of: "(continued)", with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespaces)
                if title.caseInsensitiveCompare(sectionTitle) != .orderedSame || before != sectionIsCredit {
                    sectionTitle = title; sectionSum = 0; sectionCount = 0
                }
            }
        }
        /// "Total Deposits & Credits $124,416.93": does it agree with the rows we just read?
        func reconcile(_ line: String, tokens: [String]) {
            guard sectionCount > 0, !sectionTitle.isEmpty, line.lowercased().hasPrefix("total " + sectionTitle.lowercased()),
                  let last = tokens.last, isMoney(last), let printed = parseMoney(last) else { return }
            if abs(abs(printed) - sectionSum) < 0.005 { out.matched += 1 } else { out.mismatched.append(sectionTitle) }
            sectionSum = 0; sectionCount = 0
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // Drop markers like Amex's "⧫" (Pay Over Time) so the amount is the last word.
            var tokens = line.split(whereSeparator: \.isWhitespace).map(String.init)
                .filter { $0.contains(where: { $0.isLetter || $0.isNumber || "$-().,/*".contains($0) }) }
            let hasMoney = tokens.contains(where: isMoney)

            // A foreign charge lists the foreign amount, then the dollars on the next line
            // ("7,312.50" then "-$443.99"). The dollars are what was charged.
            // The currency's name can sit in between ("7,312.50", "South African", "Rands", "-$443.99").
            if let index = foreignCandidate {
                foreignLinesLeft -= 1
                if tokens.count == 1, isMoney(tokens[0]), tokens[0].contains("$"), let dollars = parseMoney(tokens[0]),
                   index == out.rows.count - 1 {
                    sectionSum += abs(dollars) - abs(out.rows[index].amount)
                    out.rows[index].amount = ((sectionIsCredit && dollars > 0 ? -dollars : dollars) * 100).rounded() / 100
                    foreignCandidate = nil
                    continue
                }
                if foreignLinesLeft <= 0 || hasMoney || leadingDate(tokens, closing: closing) != nil { foreignCandidate = nil }
            }
            // An amount on a line of its own finishes the pending charge.
            if let p = pending {
                if tokens.count == 1, isMoney(tokens[0]), let amount = parseMoney(tokens[0]) {
                    let before = out.rows.count
                    add(p.date, p.description, amount)
                    if out.rows.count > before, !tokens[0].contains("$") { foreignCandidate = out.rows.count - 1; foreignLinesLeft = 4 }
                    pending = nil
                    continue
                }
                // Statement credits name the merchant on the next line ("…Entertainment Credit" / "NEW YORK TIMES").
                if p.linesWaited == 0, p.description.lowercased().contains("credit"), !hasMoney,
                   leadingDate(tokens, closing: closing) == nil, line.filter(\.isLetter).count >= 4 {
                    pending?.description += " " + line
                }
                pending?.linesWaited += 1
                if pending!.linesWaited > 10 { pending = nil }
            }

            if !hasMoney {
                // A date at the very start begins a charge whose amount comes later.
                if let (date, used) = leadingDate(tokens, closing: closing) {
                    var rest = Array(tokens.dropFirst(used))
                    if let (_, used2) = leadingDate(rest, closing: closing) { rest.removeFirst(used2) }
                    let description = rest.joined(separator: " ")
                    // "10/15/26 10/18/26" (hotel arrival/departure) is detail, not a new charge.
                    // ("February 11, 2026 on the statement closing date" is a sentence, not a charge.)
                    if description.filter(\.isLetter).count >= 3,
                       description.range(of: #"^(19|20)\d\d\b"#, options: .regularExpression) == nil { pending = (date, description, 0) }
                } else if pending == nil, line.count < 70 {
                    updateSection(line)
                }
                continue
            }
            if tokens.first?.lowercased() == "total" { reconcile(line, tokens: tokens); continue }
            // Captions under pictures of paid checks ("001234567890 FEB 23 #0000000178 $180.00") repeat the Checks Paid rows.
            // (Ten digits: a store number such as "DUNKIN #365296" is a real purchase.)
            if tokens.contains(where: { $0.hasPrefix("#") && $0.count >= 10 && $0.dropFirst().allSatisfy(\.isNumber) }) { continue }

            guard let start = (0..<min(tokens.count, 7)).first(where: { leadingDate(Array(tokens[$0...]), closing: closing) != nil }) else { continue }
            var checkNumber: String?
            if start > 0 {
                // "178 02/23 180.00" under Checks Paid.
                if start == 1, tokens[0].allSatisfy(\.isNumber), sectionTitle.lowercased().contains("check") {
                    checkNumber = tokens[0]
                } else {
                    updateSection(tokens[..<start].joined(separator: " "))
                }
                tokens.removeFirst(start)
            }
            guard let (date, used) = leadingDate(tokens, closing: closing) else { continue }
            tokens.removeFirst(used)
            // A second (posting) date often follows.
            if let (_, used2) = leadingDate(tokens, closing: closing) { tokens.removeFirst(used2) }

            var trailing: [String] = []
            while let last = tokens.last, isMoney(last), trailing.count < 2 { trailing.insert(tokens.removeLast(), at: 0) }
            // Two amounts at the end are usually "amount, running balance": take the first. But a
            // foreign charge prints the foreign amount and then the dollars ("7,312.50 -$443.99"):
            // when only the second carries a dollar sign, that's the one that was charged.
            var amountToken = trailing.first
            if trailing.count == 2, trailing[1].contains("$"), !trailing[0].contains("$") { amountToken = trailing[1] }
            guard let amountToken, var amount = parseMoney(amountToken) else { continue }
            // Capital One prints a payment as "AUTOPAY PYMT - $42.45": the minus stands apart.
            if tokens.last == "-" { tokens.removeLast(); amount = -abs(amount) }
            pending = nil
            add(date, checkNumber.map { "Check #\($0)" } ?? tokens.joined(separator: " "), amount)
        }
        out.rows = removeInternalAdjustments(out.rows)
        return out
    }

    /// Amex moves balances between "Pay In Full" and "Pay Over Time" with a matching
    /// DEBIT ADJUSTMENT / CREDIT ADJUSTMENT pair. They cancel out and aren't real spending.
    static func removeInternalAdjustments(_ rows: [CanonicalRow]) -> [CanonicalRow] {
        var out = rows
        let isAdjustment = { (r: CanonicalRow) in r.description.uppercased().contains("ADJUSTMENT") }
        var i = 0
        while i < out.count {
            if isAdjustment(out[i]),
               let j = out.indices.first(where: { $0 != i && isAdjustment(out[$0]) && out[$0].date == out[i].date
                                                  && abs(out[$0].amount + out[i].amount) < 0.005 }) {
                out.remove(at: max(i, j)); out.remove(at: min(i, j))
                i = 0
                continue
            }
            i += 1
        }
        return out
    }

    /// At least a few dated lines and some amounts: worth asking the AI to read.
    static func looksLikeTransactions(_ page: String) -> Bool {
        let dates = (try? NSRegularExpression(pattern: #"(?m)^\s*\d{1,2}/\d{1,2}"#))?
            .numberOfMatches(in: page, range: NSRange(page.startIndex..., in: page)) ?? 0
        let money = (try? NSRegularExpression(pattern: #"\d\.\d{2}\b"#))?
            .numberOfMatches(in: page, range: NSRange(page.startIndex..., in: page)) ?? 0
        return dates >= 3 && money >= 3
    }

    private static func parseMoney(_ token: String) -> Double? {
        var t = token
        var credit = false
        if t.hasSuffix("CR") { credit = true; t.removeLast(2) }
        if t.hasSuffix("DR") { t.removeLast(2) }
        guard var v = MoneyParsing.parse(t) else { return nil }
        if credit { v = -abs(v) }
        return v
    }

    /// Accepts "10/14", "10/14/26", "10/14/2026" or "Oct 14". Returns the date and tokens consumed.
    private static func leadingDate(_ tokens: [String], closing: Date) -> (Date, Int)? {
        guard var first = tokens.first else { return nil }
        // "11/03/26*" marks a posting date on Amex statements.
        while first.hasSuffix("*") { first.removeLast() }
        let cal = Calendar.current
        let closingYear = cal.component(.year, from: closing)
        let closingMonth = cal.component(.month, from: closing)

        func withYear(month: Int, day: Int) -> Date? {
            guard (1...12).contains(month), (1...31).contains(day) else { return nil }
            let year = month > closingMonth ? closingYear - 1 : closingYear
            return cal.date(from: DateComponents(year: year, month: month, day: day))
        }

        let parts = first.split(separator: "/")
        if parts.count >= 2, parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            if parts.count == 3 {
                if let d = slashDate(first) { return (d, 1) }
                return nil
            }
            if parts.count == 2, let m = Int(parts[0]), let d = Int(parts[1]), let date = withYear(month: m, day: d) { return (date, 1) }
            return nil
        }
        if tokens.count >= 2, let mi = monthNames.firstIndex(of: String(first.lowercased().prefix(3))),
           first.count <= 5, let day = Int(tokens[1].trimmingCharacters(in: CharacterSet(charactersIn: ","))),
           let date = withYear(month: mi + 1, day: day) {
            return (date, 2)
        }
        return nil
    }

    // MARK: AI fallback

    private static func aiExtract(pages: [String], closing: Date) async -> [CanonicalRow] {
        let year = Calendar.current.component(.year, from: closing)
        var rows: [CanonicalRow] = []
        for page in pages {
            for chunk in chunks(of: page, size: 3000) {
                let session = LanguageModelSession(instructions: """
                You extract transactions from bank and credit card statement text.
                For every transaction, output one line: MM/DD/YYYY | description | amount
                Use a negative amount for payments, refunds, credits and deposits; positive for purchases, fees and withdrawals.
                If a date has no year, the statement ends in \(year).
                Skip totals, balances and summaries. If there are no transactions, output nothing.
                """)
                guard let reply = try? await session.respond(to: chunk, options: GenerationOptions(temperature: 0)) else { continue }
                for line in reply.content.split(whereSeparator: \.isNewline) {
                    let parts = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                    guard parts.count == 3,
                          let date = DateParsing.parse(parts[0], format: "MM/dd/yyyy"),
                          let amount = MoneyParsing.parse(parts[2]),
                          parts[1].filter(\.isLetter).count >= 3 else { continue }
                    // Only keep what really appears in the statement text.
                    guard chunk.localizedCaseInsensitiveContains(String(parts[1].prefix(8))) else { continue }
                    rows.append(CanonicalRow(date: DateParsing.iso.string(from: date), description: parts[1], amount: amount))
                }
            }
        }
        return rows
    }

    private static func chunks(of text: String, size: Int) -> [String] {
        var out: [String] = [], current = ""
        for line in text.components(separatedBy: .newlines) {
            if current.count + line.count > size, !current.isEmpty { out.append(current); current = "" }
            current += line + "\n"
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}
