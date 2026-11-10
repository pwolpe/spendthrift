import Foundation

/// A statement file, read and ready to add.
struct ParsedStatement {
    var rows: [CanonicalRow]
    /// Identifies the account this file belongs to (file shape plus card digits when known).
    var signature: String
    var suggestedName: String
    var check: StatementCheck = .none
    /// Months the statement covers by its own printed dates, when it prints them.
    var months: [String] = []
}

/// Reads whatever a bank lets you download: CSV/TSV exports, PDF statements, and
/// Quicken/Money files (OFX, QFX, QBO).
enum StatementReader {
    static let extensions: Set<String> = Set(["csv", "txt", "tsv", "pdf", "ofx", "qfx", "qbo", "xlsx"]).union(Scans.imageExtensions)

    enum Outcome {
        case ready(ParsedStatement)
        /// Couldn't work out the columns: ask (rare).
        case needsMapping(CSVTable, signature: String, suggestedName: String)
    }

    enum ReadError: LocalizedError {
        case noTransactions, notAStatement
        var errorDescription: String? {
            switch self {
            case .noTransactions: "No transactions were found in this file."
            case .notAStatement: "This doesn't look like a statement: there's no list of dated transactions in it."
            }
        }
    }

    /// What to tell Tony about a file type the app doesn't read.
    static func adviceForUnsupported(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "xls", "numbers", "xlsm":
            return "This is a spreadsheet the app can't open directly. On your bank's website, choose CSV or PDF when you download."
        case "zip":
            return "This zip couldn't be opened. Double-click it in Finder to unzip it, then drop in what's inside."
        case "doc", "docx", "pages", "rtf", "html", "htm":
            return "This is a document, not a statement download. Look for “Download” or “Export” on your bank's website and choose CSV or PDF."
        case "":
            return "This isn't a statement file. Look for “Download” or “Export” on your bank's website."
        default:
            return "The app doesn't read .\(url.pathExtension.lowercased()) files. Look for “Download” or “Export” on your bank's website and choose CSV or PDF."
        }
    }

    static func read(_ url: URL, data: Data, password: String? = nil) async throws -> Outcome {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "pdf", _ where Scans.imageExtensions.contains(ext):
            let table = ext == "pdf" ? try await PDFStatement.table(from: url, password: password)
                                     : try await PDFStatement.table(fromImage: url)
            let rows = Normalizer.rows(from: table, mapping: PDFStatement.mapping).rows
            guard !rows.isEmpty else { throw ReadError.noTransactions }
            return .ready(ParsedStatement(rows: rows, signature: table.signature,
                                          suggestedName: table.suggestedName ?? accountName(for: url), check: table.check, months: table.months))
        case "ofx", "qfx", "qbo":
            return .ready(try OFX.parse(data, fallbackName: accountName(for: url)))
        default:
            // Some banks hand out OFX with a .txt or .csv name.
            if let head = String(data: data.prefix(400), encoding: .utf8), head.contains("OFXHEADER") || head.contains("<OFX>") {
                return .ready(try OFX.parse(data, fallbackName: accountName(for: url)))
            }
            let table = ext == "xlsx" ? try Spreadsheet.table(from: url) : try CSVTable(data: data)
            let digits = cardDigits(in: url)
            let signature = table.signature + (digits.map { "|#\($0)" } ?? "")
            let name = accountName(for: url)
            if let mapping = ColumnDetector.detect(table) {
                let rows = Normalizer.rows(from: table, mapping: mapping).rows
                if !rows.isEmpty { return .ready(ParsedStatement(rows: rows, signature: signature, suggestedName: name)) }
            }
            // Only offer "pick the columns" for something that is actually a table with dates in it.
            let hasDates = (0..<table.columnCount).contains { DateParsing.guessFormat(for: table.values($0)) != nil }
            guard hasDates, table.columnCount >= 2 else { throw ReadError.notAStatement }
            // Before asking Tony to pick columns, let the powerful model work them out.
            if CloudAI.isEnabled, let mapping = await CloudColumnMapper.mapping(for: table) {
                let rows = Normalizer.rows(from: table, mapping: mapping).rows
                if !rows.isEmpty { return .ready(ParsedStatement(rows: rows, signature: signature, suggestedName: name)) }
            }
            return .needsMapping(table, signature: signature, suggestedName: name)
        }
    }

    /// "Chase4090_Activity_20261109.csv" → "4090". Banks often put the card's last digits in the name.
    static func cardDigits(in url: URL) -> String? {
        var stem = url.deletingPathExtension().lastPathComponent
        // A date in the name ("…_2026-10-12_Coinbase") is not a card number.
        stem = stem.replacingOccurrences(of: #"(?<![0-9])(19|20)[0-9]{2}[-_.][0-9]{2}[-_.][0-9]{2}(?![0-9])"#, with: " ", options: .regularExpression)
        if let r = stem.range(of: #"(?<![0-9])[0-9]{4}(?![0-9])"#, options: .regularExpression) { return String(stem[r]) }
        // A whole account number in the name: its last four digits.
        if let r = stem.range(of: #"(?<![0-9])[0-9]{12,19}(?![0-9])"#, options: .regularExpression) { return String(stem[r].suffix(4)) }
        return nil
    }

    /// "Chase4090_Activity_20261109.csv" → "Chase ••4090".
    static func accountName(for url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        let noise: Set<String> = ["activity", "transactions", "transaction", "statement", "statements", "export", "download",
                                  "stmt", "csv", "since", "to", "and", "history", "account", "report", "data"]
        let months = Set((1...12).map { Month(year: 2000, month: $0).shortName.lowercased() })
        let words = stem.split { !$0.isLetter }.map(String.init)
            .filter { $0.count > 1 && !noise.contains($0.lowercased()) && !months.contains(String($0.lowercased().prefix(3))) }
        let banks = ["bofa": "Bank of America", "boa": "Bank of America", "usaa": "USAA", "amex": "American Express", "wf": "Wells Fargo",
                     "citi": "Citi", "pnc": "PNC", "td": "TD Bank", "hsbc": "HSBC", "bmo": "BMO", "jpm": "J.P. Morgan", "cap": "Capital"]
        var name = words.prefix(2).map { banks[$0.lowercased()] ?? ($0.prefix(1).uppercased() + $0.dropFirst().lowercased()) }.joined(separator: " ")
        if name.isEmpty { name = "Account" }
        if let digits = cardDigits(in: url) { name += " ••\(digits)" }
        return name
    }
}

// MARK: - OFX / QFX / QBO (Quicken, Microsoft Money, QuickBooks downloads)

/// OFX comes in two flavours (old SGML without closing tags, and XML). Both put each value
/// right after its tag, so reading "<TAG>value" up to the next "<" handles either.
enum OFX {
    static func parse(_ data: Data, fallbackName: String) throws -> ParsedStatement {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw CSVTable.ReadError.unreadable
        }
        var rows: [CanonicalRow] = []
        for block in text.components(separatedBy: "<STMTTRN>").dropFirst() {
            let body = block.components(separatedBy: "</STMTTRN>")[0]
            guard let rawDate = value("DTPOSTED", in: body) ?? value("DTUSER", in: body), rawDate.count >= 8,
                  let date = DateParsing.parse(String(rawDate.prefix(8)), format: "yyyyMMdd"),
                  let amount = value("TRNAMT", in: body).flatMap(MoneyParsing.parse) else { continue }
            let name = value("NAME", in: body) ?? ""
            let memo = value("MEMO", in: body) ?? ""
            var description = name.isEmpty ? memo : name
            // Banks split long names across NAME and MEMO.
            if !name.isEmpty, !memo.isEmpty, !memo.uppercased().contains(name.uppercased()), name.count >= 30 { description = name + memo }
            description = decode(description).split(whereSeparator: \.isWhitespace).joined(separator: " ")
            // In OFX, money leaving the account is negative.
            rows.append(CanonicalRow(date: DateParsing.iso.string(from: date),
                                     description: description.isEmpty ? "(no description)" : description,
                                     amount: (-amount * 100).rounded() / 100, bankCategory: nil))
        }
        guard !rows.isEmpty else { throw StatementReader.ReadError.noTransactions }

        let org = value("ORG", in: text).map(decode)
        let digits = value("ACCTID", in: text).map { String($0.filter(\.isNumber).suffix(4)) }.flatMap { $0.isEmpty ? nil : $0 }
        let issuer = org.flatMap { PDFStatement.detectIssuer($0) } ?? org
        var name = [issuer, digits.map { "••\($0)" }].compactMap { $0 }.joined(separator: " ")
        if name.isEmpty { name = fallbackName }
        return ParsedStatement(rows: rows, signature: "ofx:\((org ?? "").lowercased()):\(digits ?? "")", suggestedName: name)
    }

    private static func value(_ tag: String, in text: String) -> String? {
        guard let start = text.range(of: "<\(tag)>", options: .caseInsensitive) else { return nil }
        let rest = text[start.upperBound...]
        let end = rest.firstIndex(where: { $0 == "<" || $0.isNewline }) ?? rest.endIndex
        let v = rest[..<end].trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    private static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
    }
}
