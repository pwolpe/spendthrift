import Foundation
import PDFKit
import Vision
import AppKit

/// Reads text off pictures: scanned statements (PDFs with no text inside) and photos or
/// screenshots of a statement. Everything runs on this Mac with Apple's Vision framework.
enum Scans {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "tif", "tiff", "bmp", "gif"]

    /// Recognized text, rebuilt into rows: words at the same height are one line, read left to right.
    static func text(in original: CGImage) -> String {
        let image = flattened(original)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false     // merchant names and amounts aren't prose
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return "" }
        var fragments: [(y: CGFloat, x: CGFloat, h: CGFloat, text: String)] = []
        for observation in request.results ?? [] {
            guard let best = observation.topCandidates(1).first else { continue }
            let box = observation.boundingBox       // 0…1, origin bottom-left
            fragments.append((box.midY, box.minX, box.height, best.string))
        }
        fragments.sort { $0.y > $1.y }
        var rows: [[(x: CGFloat, text: String)]] = []
        var lastY = CGFloat.infinity, lastH: CGFloat = 0.01
        for f in fragments {
            if abs(f.y - lastY) > max(lastH, f.h) * 0.6 { rows.append([]); lastY = f.y; lastH = f.h }
            rows[rows.count - 1].append((f.x, f.text))
        }
        let text = rows.map { $0.sorted { $0.x < $1.x }.map(\.text).joined(separator: " ") }.joined(separator: "\n")
        // Recognition sometimes splits "12.50" into "12" and ".50", or reads the decimal point as a comma.
        return text
            .replacingOccurrences(of: #"(\d) \.(\d\d)\b"#, with: "$1.$2", options: .regularExpression)
            .replacingOccurrences(of: #"(\d),(\d\d)(?!\d)"#, with: "$1.$2", options: .regularExpression)
    }

    /// Screenshots can have a see-through background, which reads as black on black. Put the picture on white.
    private static func flattened(_ image: CGImage) -> CGImage {
        guard image.alphaInfo != .none, image.alphaInfo != .noneSkipFirst, image.alphaInfo != .noneSkipLast,
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        return ctx.makeImage() ?? image
    }

    static func text(inPage page: PDFPage) -> String {
        let bounds = page.bounds(for: .mediaBox)
        let scale = min(3, 2400 / max(bounds.width, bounds.height))
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let image = page.thumbnail(of: size, for: .mediaBox)
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return "" }
        return text(in: cg)
    }

    static func text(inImageAt url: URL) -> String? {
        guard let image = NSImage(contentsOf: url), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return text(in: cg)
    }
}

/// Excel workbooks (.xlsx): a zip of XML files. Reads the first sheet into the same table shape as a CSV.
enum Spreadsheet {
    enum SheetError: LocalizedError {
        case unreadable
        var errorDescription: String? { "This Excel file couldn't be read. Try downloading CSV or PDF from your bank instead." }
    }

    static func table(from url: URL) throws -> CSVTable {
        guard let sheetXML = unzip(url, entry: "xl/worksheets/sheet1.xml") else { throw SheetError.unreadable }
        let strings = unzip(url, entry: "xl/sharedStrings.xml").map(SharedStrings.parse) ?? []
        var rows = Sheet.parse(sheetXML, strings: strings)
        guard !rows.isEmpty else { throw CSVTable.ReadError.empty }
        // Excel stores dates as day counts (46300 = a day in 2026). Convert columns that are all such numbers.
        let width = rows.map(\.count).max() ?? 0
        for column in 0..<width {
            let values = rows.dropFirst().compactMap { $0.count > column && !$0[column].isEmpty ? $0[column] : nil }
            guard values.count >= 1, values.allSatisfy({ v in Double(v).map { $0 >= 32874 && $0 <= 73050 } ?? false }) else { continue }
            let header = rows[0].count > column ? rows[0][column].lowercased() : ""
            guard header.contains("date") || header.contains("posted") || values.allSatisfy({ !$0.contains(".") }) else { continue }
            guard !header.contains("amount"), !header.contains("balance"), !header.contains("number"), !header.contains("check") else { continue }
            for r in rows.indices.dropFirst() where rows[r].count > column {
                if let serial = Double(rows[r][column]) {
                    let date = Date(timeIntervalSince1970: (serial - 25569) * 86_400)
                    var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
                    let c = utc.dateComponents([.year, .month, .day], from: date)
                    rows[r][column] = String(format: "%04d-%02d-%02d", c.year ?? 2000, c.month ?? 1, c.day ?? 1)
                }
            }
        }
        let csv = rows.map { $0.map(CSV.escape).joined(separator: ",") }.joined(separator: "\n")
        return try CSVTable(data: Data(csv.utf8))
    }

    private static func unzip(_ url: URL, entry: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, entry]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 && !data.isEmpty ? data : nil
    }

    private final class SharedStrings: NSObject, XMLParserDelegate {
        var strings: [String] = [], current = "", inText = false
        static func parse(_ data: Data) -> [String] {
            let d = SharedStrings(); let p = XMLParser(data: data); p.delegate = d; p.parse(); return d.strings
        }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            if name == "si" { current = "" } else if name == "t" { inText = true }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if inText { current += string } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "t" { inText = false } else if name == "si" { strings.append(current) }
        }
    }

    private final class Sheet: NSObject, XMLParserDelegate {
        var rows: [[String]] = [], row: [String] = [], strings: [String] = []
        var column = 0, type = "", value = "", inValue = false
        static func parse(_ data: Data, strings: [String]) -> [[String]] {
            let d = Sheet(); d.strings = strings; let p = XMLParser(data: data); p.delegate = d; p.parse()
            return d.rows.filter { $0.contains { !$0.isEmpty } }
        }
        /// "C7" → 2
        private func index(ofCell ref: String) -> Int {
            var n = 0
            for ch in ref.uppercased().unicodeScalars where ch.value >= 65 && ch.value <= 90 { n = n * 26 + Int(ch.value - 64) }
            return max(0, n - 1)
        }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
            switch name {
            case "row": row = []
            case "c": column = attributes["r"].map(index(ofCell:)) ?? row.count; type = attributes["t"] ?? ""; value = ""
            case "v", "t": inValue = true
            default: break
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if inValue { value += string } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "v", "t": inValue = false
            case "c":
                let text = type == "s" ? (Int(value).flatMap { $0 < strings.count ? strings[$0] : nil } ?? "") : value
                while row.count < column { row.append("") }
                if row.count == column { row.append(text) } else { row[column] = text }
            case "row": rows.append(row)
            default: break
            }
        }
    }
}
