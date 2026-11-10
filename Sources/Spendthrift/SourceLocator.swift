import Foundation
import PDFKit
import Vision
import AppKit

/// Finds, in an original statement, the very line a charge was read from.
///
/// Nothing is remembered at import about where on the page a number sat: the reader works from
/// text, in two orders, sometimes with a model's help. So the finder looks afresh each time, the
/// way a person would: find the amount, then check the date and the merchant are beside it.
enum SourceLocator {
    /// What is being looked for.
    struct Target: Hashable {
        var date: String          // yyyy-MM-dd
        var description: String
        var amount: Double

        init(_ entry: LedgerEntry) { date = entry.date; description = entry.description; amount = entry.amount }
        init(date: String, description: String, amount: Double) { self.date = date; self.description = description; self.amount = amount }

        /// "1,234.56" and "1234.56" (and ".79" for amounts under a dollar), as a pattern that won't match inside a longer number.
        var amountPattern: String {
            let value = abs(amount)
            let plain = String(format: "%.2f", value)
            let whole = plain.dropLast(3), cents = plain.suffix(2)
            var grouped = "", count = 0
            for ch in whole.reversed() {
                if count > 0, count % 3 == 0 { grouped.append(",") }
                grouped.append(ch); count += 1
            }
            var forms = [String(grouped.reversed()) + "." + cents, plain]
            if value < 1 { forms.append("." + cents) }
            let body = Set(forms).map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
            return "(?<![\\d,.])(?:\(body))(?!\\d)"
        }

        /// The words of the description worth looking for beside the amount.
        var words: [String] {
            var seen = Set<String>(), out: [String] = []
            for word in description.uppercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            where word.count >= 3 && seen.insert(word).inserted { out.append(word) }
            return Array(out.prefix(8))
        }

        /// The ways a statement might print this day: "10/04", "10/4", "Oct 4", "Oct 04", "2026-10-04"…
        var dateForms: [String] {
            let parts = date.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return [] }
            let (m, d) = (parts[1], parts[2])
            let names = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
            guard (1...12).contains(m) else { return [] }
            let mm = String(format: "%02d", m), dd = String(format: "%02d", d)
            return ["\(mm)/\(dd)", "\(m)/\(d)", "\(mm)/\(d)", "\(m)/\(dd)", "\(mm)-\(dd)", "\(names[m - 1]) \(d)", "\(names[m - 1]) \(dd)",
                    "\(names[m - 1]). \(d)", "\(d) \(names[m - 1])", date]
        }

        /// How well a line (and the lines around it) fits: mostly the merchant's words, then the day.
        func score(row: String, near: String) -> Double {
            let rowU = row.uppercased(), nearU = near.uppercased()
            let words = words
            func share(_ text: String) -> Double {
                words.isEmpty ? 0 : Double(words.filter(text.contains).count) / Double(words.count)
            }
            let rowL = row.lowercased(), nearL = near.lowercased()
            let hasDate = { (text: String) in dateForms.contains(where: text.contains) }
            return 10 * max(share(rowU), 0.7 * share(rowU + " " + nearU)) + (hasDate(rowL) ? 4 : hasDate(nearL) ? 2 : 0)
        }
    }

    /// Scores at or above this are "this is the line"; below it, "the closest thing to it".
    static let sure = 6.0

    // MARK: PDF

    struct PDFHit {
        var pageIndex: Int
        var amount: PDFSelection
        /// The whole printed line the amount sits on.
        var row: PDFSelection?
        var score: Double
        var isSure: Bool { score >= SourceLocator.sure }
    }

    static func locate(_ target: Target, in doc: PDFDocument) -> PDFHit? {
        guard let amountRE = try? NSRegularExpression(pattern: target.amountPattern) else { return nil }
        var best: PDFHit?
        for index in 0..<min(doc.pageCount, 200) {
            guard let page = doc.page(at: index), let text = page.string, !text.isEmpty else { continue }
            let matches = amountRE.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            guard !matches.isEmpty else { continue }
            let lines = fragments(of: page)
            for match in matches {
                guard let selection = page.selection(for: match.range) else { continue }
                let box = selection.bounds(for: page)
                guard box.width > 0 else { continue }
                // The printed line the amount is on, then the lines just above (a charge's name can sit a
                // line or two over its amount) and one below.
                let row = lines.filter { abs($0.y - box.midY) <= 4 }.sorted { $0.x < $1.x }.map(\.text).joined(separator: " ")
                let near = lines.filter { ($0.y - box.midY > 4 && $0.y - box.midY < 64) || (box.midY - $0.y > 4 && box.midY - $0.y < 16) }
                    .map(\.text).joined(separator: " ")
                let score = target.score(row: row, near: near)
                if best == nil || score > best!.score {
                    let media = page.bounds(for: .mediaBox)
                    let band = CGRect(x: media.minX, y: box.minY - 1, width: media.width, height: box.height + 2)
                    best = PDFHit(pageIndex: index, amount: selection, row: page.selection(for: band), score: score)
                }
            }
        }
        return best
    }

    private static func fragments(of page: PDFPage) -> [(y: CGFloat, x: CGFloat, text: String)] {
        guard let all = page.selection(for: page.bounds(for: .mediaBox)) else { return [] }
        return all.selectionsByLine().compactMap { line in
            let text = (line.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            let bounds = line.bounds(for: page)
            return (bounds.midY, bounds.minX, text)
        }
    }

    // MARK: Pictures and scans

    /// Where the amount is in a picture of a statement, as a share of its width and height (origin bottom-left).
    struct PictureHit {
        var box: CGRect
        var score: Double
        var isSure: Bool { score >= SourceLocator.sure }
    }

    nonisolated static func locate(_ target: Target, in image: CGImage) -> PictureHit? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil,
              let amountRE = try? NSRegularExpression(pattern: target.amountPattern) else { return nil }
        let seen = (request.results ?? []).compactMap { o in o.topCandidates(1).first.map { (o.boundingBox, $0) } }
        var best: PictureHit?
        for (box, candidate) in seen {
            let text = candidate.string
            guard let match = amountRE.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range, in: text) else { continue }
            let exact = (try? candidate.boundingBox(for: range))?.boundingBox ?? box
            let row = seen.filter { abs($0.0.midY - box.midY) <= max(box.height, $0.0.height) * 0.6 }.map(\.1.string).joined(separator: " ")
            let near = seen.filter { $0.0.midY > box.midY && $0.0.midY - box.midY < box.height * 4 }.map(\.1.string).joined(separator: " ")
            let score = target.score(row: row, near: near)
            if best == nil || score > best!.score { best = PictureHit(box: exact, score: score) }
        }
        return best
    }

    // MARK: Tables (CSV, Excel, Quicken)

    struct Sheet {
        var header: [String]
        var rows: [[String]]
        /// Shown under the title when the table isn't the file word for word.
        var note: String?
    }

    struct RowHit: Hashable {
        var row: Int
        var column: Int?
        var score: Double
        var isSure: Bool { score >= 7 }
    }

    /// The file as a table: a CSV or spreadsheet as it is, a Quicken file as its list of transactions.
    static func sheet(at url: URL, ext: String) -> Sheet? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let head = String(data: data.prefix(400), encoding: .utf8) ?? ""
        if ["ofx", "qfx", "qbo"].contains(ext) || head.contains("OFXHEADER") || head.contains("<OFX>") { return quicken(data) }
        guard let table = ext == "xlsx" ? try? Spreadsheet.table(from: url) : try? CSVTable(data: data) else { return nil }
        let width = max(table.columnCount, table.rows.map(\.count).max() ?? 0)
        let header = (0..<width).map { i in table.header.flatMap { i < $0.count && !$0[i].isEmpty ? $0[i] : nil } ?? "Column \(i + 1)" }
        return Sheet(header: header, rows: table.rows)
    }

    private static func quicken(_ data: Data) -> Sheet? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        func value(_ tag: String, in body: String) -> String {
            guard let start = body.range(of: "<\(tag)>", options: .caseInsensitive) else { return "" }
            let rest = body[start.upperBound...]
            let end = rest.firstIndex(where: { $0 == "<" || $0.isNewline }) ?? rest.endIndex
            return rest[..<end].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "&amp;", with: "&")
        }
        let rows = text.components(separatedBy: "<STMTTRN>").dropFirst().map { block -> [String] in
            let body = block.components(separatedBy: "</STMTTRN>")[0]
            let posted = value("DTPOSTED", in: body).prefix(8)
            let day = posted.count == 8 ? "\(posted.prefix(4))-\(posted.dropFirst(4).prefix(2))-\(posted.suffix(2))" : String(posted)
            return [day, value("NAME", in: body), value("MEMO", in: body), value("TRNAMT", in: body)]
        }
        return Sheet(header: ["Posted", "Name", "Memo", "Amount"], rows: Array(rows),
                     note: "A Quicken file is written for programs, not people. This is its list of transactions.")
    }

    static func locate(_ target: Target, in sheet: Sheet) -> RowHit? {
        let squeeze = { (s: String) in s.uppercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        let wanted = squeeze(target.description)
        let loose = { (s: String) in String(s.uppercased().filter { $0.isLetter || $0.isNumber }) }
        let wantedLoose = loose(target.description)
        let value = abs(target.amount)
        let formats = ["MM/dd/yyyy", "M/d/yyyy", "yyyy-MM-dd", "MM/dd/yy", "M/d/yy", "yyyyMMdd", "MM-dd-yyyy", "dd/MM/yyyy", "MMM d, yyyy", "d MMM yyyy"]
        var dayCache: [String: Bool] = [:]
        func isTheDay(_ cell: String) -> Bool {
            if let known = dayCache[cell] { return known }
            let trimmed = String(cell.trimmingCharacters(in: .whitespaces).prefix(10))
            let match = cell.hasPrefix(target.date) || formats.contains { f in
                DateParsing.parse(trimmed, format: f).map { DateParsing.iso.string(from: $0) == target.date } ?? false
            }
            dayCache[cell] = match
            return match
        }
        var best: RowHit?
        for (index, row) in sheet.rows.enumerated() {
            var score = 0.0, column: Int?
            for (c, cell) in row.enumerated() where !cell.isEmpty {
                if column == nil, cell.contains(where: \.isNumber), !cell.contains("/"), cell.count <= 16,
                   let money = MoneyParsing.parse(cell), abs(abs(money) - value) < 0.005 { column = c }
            }
            guard column != nil else { continue }
            score += 4
            let cells = row.map(squeeze)
            if cells.contains(wanted) { score += 6 }
            else if !wantedLoose.isEmpty, row.contains(where: { let l = loose($0); return l.count >= 6 && (l.contains(wantedLoose) || wantedLoose.contains(l)) }) { score += 4 }
            if row.contains(where: { $0.count >= 6 && $0.count <= 24 && isTheDay($0) }) { score += 3 }
            if best == nil || score > best!.score { best = RowHit(row: index, column: column, score: score) }
            if score >= 13 { break }
        }
        return best
    }
}
