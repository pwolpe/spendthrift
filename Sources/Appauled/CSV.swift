import Foundation

// MARK: - Parsing

enum CSV {
    /// RFC 4180-ish parser: quoted fields, escaped quotes, CRLF, BOM.
    static func parse(_ text: String, delimiter: Character = ",") -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = Array(text)
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 1 }
                    else { inQuotes = false }
                } else {
                    field.append(c)
                }
            } else if c == "\"" {
                inQuotes = true
            } else if c == delimiter {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r" || c == "\r\n" {
                if c == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                row.append(field); field = ""
                rows.append(row); row = []
            } else {
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
            .map { $0.map { $0.trimmingCharacters(in: .whitespaces) } }
            .filter { !$0.allSatisfy(\.isEmpty) }
    }

    static func detectDelimiter(_ text: String) -> Character {
        let sample = text.split(whereSeparator: \.isNewline).prefix(10).joined(separator: "\n")
        let candidates: [Character] = [",", ";", "\t", "|"]
        return candidates.max { a, b in sample.filter { $0 == a }.count < sample.filter { $0 == b }.count } ?? ","
    }

    static func escape(_ s: String) -> String {
        if s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) {
            return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return s
    }
}

// MARK: - Table

enum StatementCheck: Equatable {
    case none
    /// Every section matched the statement's own totals.
    case verified
    /// These sections didn't add up.
    case mismatch(String)
    /// Read off a picture (a scan or photo), which is never as certain as real text.
    case scanned
}

struct CSVTable {
    var header: [String]?
    var rows: [[String]]
    var columnCount: Int
    /// Set for PDFs, where every table has the same header (e.g. "pdf:chase:1234").
    var customSignature: String?
    /// A friendly account name we could infer (e.g. "Chase ••1234").
    var suggestedName: String?
    /// For PDFs: whether the rows add up to the totals printed on the statement.
    var check: StatementCheck = .none
    /// The months a statement says it covers ("2026-05", "2026-06"), even if nothing was bought in one of them.
    var months: [String] = []

    init(header: [String]?, rows: [[String]], signature: String?, suggestedName: String?) {
        self.header = header
        self.rows = rows
        self.columnCount = header?.count ?? rows.first?.count ?? 0
        self.customSignature = signature
        self.suggestedName = suggestedName
    }

    enum ReadError: LocalizedError {
        case unreadable, empty
        var errorDescription: String? {
            switch self {
            case .unreadable: "This file couldn't be read as text."
            case .empty: "This file doesn't seem to have any transactions in it."
            }
        }
    }

    init(data: Data) throws {
        guard let text = Self.decodeText(data) else { throw ReadError.unreadable }
        let all = CSV.parse(text, delimiter: CSV.detectDelimiter(text))
        guard !all.isEmpty else { throw ReadError.empty }

        // Banks sometimes put summary lines above the real table. Use the most
        // common width (of rows with 3+ fields) and drop everything above it.
        var widthCounts: [Int: Int] = [:]
        for r in all where r.count >= 3 { widthCounts[r.count, default: 0] += 1 }
        let width = widthCounts.max { $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key) }?.key
            ?? all.map(\.count).max() ?? 0
        guard let start = all.firstIndex(where: { $0.count == width }) else { throw ReadError.empty }
        var body = Array(all[start...]).filter { $0.count == width }
        guard !body.isEmpty else { throw ReadError.empty }

        // Header if the first row has no dates and no money values.
        let first = body[0]
        let looksLikeData = first.contains { DateParsing.guessFormat(for: [$0]) != nil }
            || first.contains { MoneyParsing.parse($0) != nil && $0.contains(where: \.isNumber) && $0.contains(".") }
        if !looksLikeData {
            header = first
            body.removeFirst()
        }
        guard !body.isEmpty else { throw ReadError.empty }
        rows = body
        columnCount = width
    }

    /// Banks export in several encodings; Excel's "Unicode text" is UTF-16.
    static func decodeText(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) }
        // UTF-16 without a byte-order mark: every other byte is zero.
        let head = data.prefix(200)
        if head.count >= 20, head.filter({ $0 == 0 }).count * 3 > head.count {
            return String(data: data, encoding: .utf16LittleEndian) ?? String(data: data, encoding: .utf16BigEndian)
        }
        // Anything binary (a zip, an image, an old .xls) is not a text statement.
        if head.contains(0) { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1)
    }

    /// Identifies the bank/account "shape" so future statements match automatically.
    var signature: String {
        if let customSignature { return customSignature }
        if let header { return header.map { $0.lowercased() }.joined(separator: "|") }
        return "no-header:\(columnCount)"
    }

    func columnName(_ i: Int) -> String {
        if let header, i < header.count, !header[i].isEmpty { return header[i] }
        let sample = rows.first.map { i < $0.count ? $0[i] : "" } ?? ""
        return "Column \(i + 1)" + (sample.isEmpty ? "" : " (\(sample.prefix(18)))")
    }

    func values(_ i: Int) -> [String] { rows.map { i < $0.count ? $0[i] : "" } }
}

// MARK: - Dates & money

enum DateParsing {
    static let formats = ["MM/dd/yyyy", "M/d/yyyy", "yyyy-MM-dd", "MM/dd/yy", "M/d/yy", "MM-dd-yyyy",
                          "yyyy/MM/dd", "dd MMM yyyy", "MMM d, yyyy", "MMM dd, yyyy", "d MMM yyyy", "dd/MM/yyyy"]

    private static var formatters: [String: DateFormatter] = [:]
    private static let lock = NSLock()

    static func formatter(_ format: String) -> DateFormatter {
        lock.lock(); defer { lock.unlock() }
        if let f = formatters[format] { return f }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = format
        f.isLenient = false
        formatters[format] = f
        return f
    }

    static func clean(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespaces)
        if v.count > 10, v.first?.isNumber == true, v.contains("T") { v = String(v.prefix(10)) }
        return v
    }

    static func parse(_ s: String, format: String) -> Date? {
        let v = clean(s)
        if let d = formatter(format).date(from: v) { return d }
        // Strip trailing time like "09/02/2026 12:00:00 AM".
        if !format.contains(" "), let space = v.firstIndex(of: " ") {
            return formatter(format).date(from: String(v[..<space]))
        }
        return nil
    }

    /// Picks the format that parses (nearly) all values; nil if none fit.
    static func guessFormat(for values: [String]) -> String? {
        let nonEmpty = values.filter { !$0.isEmpty }.prefix(200)
        guard !nonEmpty.isEmpty else { return nil }
        var best: (String, Int)?
        for f in formats {
            let ok = nonEmpty.filter { s in
                guard let d = parse(s, format: f) else { return false }
                let y = Calendar.current.component(.year, from: d)
                return (1990...2100).contains(y)
            }.count
            if ok * 10 >= nonEmpty.count * 9, ok > (best?.1 ?? 0) { best = (f, ok) }
        }
        return best?.0
    }

    static let iso: DateFormatter = formatter("yyyy-MM-dd")
}

enum MoneyParsing {
    static func parse(_ raw: String) -> Double? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        var negative = false
        if s.hasPrefix("(") && s.hasSuffix(")") { negative = true; s = String(s.dropFirst().dropLast()) }
        if s.hasSuffix("-") { negative = true; s.removeLast() }
        for junk in ["$", "€", "£", "USD", ",", " ", "\u{00A0}"] { s = s.replacingOccurrences(of: junk, with: "") }
        if s.hasPrefix("+") { s.removeFirst() }
        guard s.contains(where: \.isNumber), let v = Double(s) else { return nil }
        return negative ? -v : v
    }
}

// MARK: - Column detection

enum ColumnDetector {
    static func detect(_ table: CSVTable) -> ColumnMapping? {
        let n = table.columnCount
        let names = (0..<n).map { (table.header?[safe: $0] ?? "").lowercased() }

        // Dates
        var dateColumns: [(Int, String)] = []
        for i in 0..<n {
            if let f = DateParsing.guessFormat(for: table.values(i)) { dateColumns.append((i, f)) }
        }
        guard !dateColumns.isEmpty else { return nil }
        let preferredDate = dateColumns.first { names[$0.0].contains("trans") }
            ?? dateColumns.first { names[$0.0] == "date" }
            ?? dateColumns.first { !names[$0.0].contains("post") }
            ?? dateColumns[0]

        // Money
        let dateIdx = Set(dateColumns.map(\.0))
        let moneyColumns = (0..<n).filter { i in
            guard !dateIdx.contains(i), !names[i].contains("balance") else { return false }
            let vals = table.values(i).filter { !$0.isEmpty }
            guard !vals.isEmpty else {
                // Entirely empty columns can still be debit/credit columns on short files.
                return isDebit(names[i]) || isCredit(names[i])
            }
            let ok = vals.filter { MoneyParsing.parse($0) != nil }.count
            return ok * 10 >= vals.count * 9 && vals.contains { $0.contains(".") || $0.contains("$") }
        }
        var amount: Int? = moneyColumns.first { names[$0].contains("amount") }
        let debit = moneyColumns.first { isDebit(names[$0]) }
        let credit = moneyColumns.first { isCredit(names[$0]) }
        if amount == nil, debit == nil || credit == nil { amount = moneyColumns.first }
        guard amount != nil || (debit != nil && credit != nil) else { return nil }

        // Description
        let used = Set([preferredDate.0, amount, debit, credit].compactMap { $0 })
        let textCandidates = (0..<n).filter { !used.contains($0) && !dateIdx.contains($0) }
        let keywordOrder = ["description", "payee", "merchant", "name", "details", "transaction", "memo"]
        var description: Int?
        for key in keywordOrder {
            if let i = textCandidates.first(where: { names[$0].contains(key) && !names[$0].contains("type") && !names[$0].contains("category") }) {
                description = i; break
            }
        }
        if description == nil {
            description = textCandidates.max { a, b in
                score(table.values(a)) < score(table.values(b))
            }
        }
        guard let description else { return nil }

        var negatives = 0, positives = 0
        // Lines that are certainly money coming in tell us which sign means "in", whatever the majority is.
        var incomeNegative = 0, incomePositive = 0
        let incomeWords = ["PAYROLL", "DIRECT DEP", "DIR DEP", "PAYMENT THANK YOU", "PAYMENT - THANK", "PAYMENT RECEIVED",
                           "AUTOPAY PAYMENT", "INTEREST PAID", "INTEREST PAYMENT", "MOBILE DEPOSIT", "REFUND"]
        if let amount {
            let descriptions = table.values(description)
            for (i, v) in table.values(amount).enumerated() {
                guard let d = MoneyParsing.parse(v), d != 0 else { continue }
                if d < 0 { negatives += 1 } else { positives += 1 }
                let text = descriptions[i].uppercased()
                if incomeWords.contains(where: text.contains) { if d < 0 { incomeNegative += 1 } else { incomePositive += 1 } }
            }
        }
        var purchasesAreNegative = negatives > positives
        if incomePositive != incomeNegative, incomePositive + incomeNegative >= 1 { purchasesAreNegative = incomePositive > incomeNegative }

        // Some banks give every amount as a positive number plus a column saying "Debit" or "Credit".
        var typeColumn: Int?
        if amount != nil, negatives == 0, positives > 0 {
            typeColumn = textCandidates.first { i in
                guard i != description else { return false }
                let values = table.values(i).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
                guard values.count * 10 >= table.rows.count * 9 else { return false }
                return values.allSatisfy { Normalizer.direction(ofType: $0) != nil } && values.contains { Normalizer.direction(ofType: $0) == 1 }
            }
        }

        return ColumnMapping(
            dateColumn: preferredDate.0,
            dateFormat: preferredDate.1,
            descriptionColumn: description,
            amountColumn: amount,
            debitColumn: amount == nil ? debit : nil,
            creditColumn: amount == nil ? credit : nil,
            purchasesAreNegative: typeColumn == nil ? purchasesAreNegative : false,
            typeColumn: typeColumn
        )
    }

    private static func isDebit(_ n: String) -> Bool { n.contains("debit") || n.contains("withdraw") || n == "money out" }
    private static func isCredit(_ n: String) -> Bool { n.contains("credit") || n.contains("deposit") || n == "money in" }

    /// Text columns with many distinct, longer values are probably descriptions.
    private static func score(_ values: [String]) -> Double {
        let nonEmpty = values.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return 0 }
        let numeric = nonEmpty.filter { MoneyParsing.parse($0) != nil }.count
        if numeric * 2 > nonEmpty.count { return 0 }
        let avgLen = Double(nonEmpty.reduce(0) { $0 + $1.count }) / Double(nonEmpty.count)
        return Double(Set(nonEmpty).count) * avgLen
    }
}

// MARK: - Normalising into the app's canonical format

struct CanonicalRow: Hashable {
    var date: String          // yyyy-MM-dd
    var description: String
    var amount: Double        // positive = spent
    /// The bank's own category, when the file has one.
    var bankCategory: String?
}

enum Normalizer {
    /// "Debit"/"Credit"-style words: +1 = money out, -1 = money in, nil = not such a word.
    static func direction(ofType word: String) -> Int? {
        switch word {
        case "debit", "dr", "withdrawal", "sale", "purchase", "charge", "fee", "payment out", "out", "d": 1
        case "credit", "cr", "deposit", "return", "refund", "payment in", "in", "c": -1
        default: nil
        }
    }

    static func rows(from table: CSVTable, mapping m: ColumnMapping) -> (rows: [CanonicalRow], skipped: Int) {
        var out: [CanonicalRow] = []
        var skipped = 0
        let categoryColumn = BankCategory.column(in: table, mapping: m)
        for r in table.rows {
            guard let rawDate = r[safe: m.dateColumn],
                  let date = DateParsing.parse(rawDate, format: m.dateFormat) else { skipped += 1; continue }
            let desc = (r[safe: m.descriptionColumn] ?? "")
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            var spent: Double
            if let a = m.amountColumn {
                guard let v = r[safe: a].flatMap(MoneyParsing.parse) else { skipped += 1; continue }
                if let t = m.typeColumn, let direction = r[safe: t].flatMap({ direction(ofType: $0.trimmingCharacters(in: .whitespaces).lowercased()) }) {
                    spent = abs(v) * Double(direction)
                } else {
                    spent = m.purchasesAreNegative ? -v : v
                }
            } else {
                let debit = r[safe: m.debitColumn ?? -1].flatMap(MoneyParsing.parse) ?? 0
                let credit = r[safe: m.creditColumn ?? -1].flatMap(MoneyParsing.parse) ?? 0
                if debit == 0 && credit == 0 { skipped += 1; continue }
                spent = abs(debit) - abs(credit)
            }
            if spent == 0 { spent = 0 } // normalise -0
            let bank = categoryColumn.flatMap { r[safe: $0] }?.trimmingCharacters(in: .whitespaces)
            out.append(CanonicalRow(date: DateParsing.iso.string(from: date),
                                    description: desc.isEmpty ? "(no description)" : desc,
                                    amount: (spent * 100).rounded() / 100,
                                    bankCategory: bank?.isEmpty == false ? bank : nil))
        }
        return (out, skipped)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
