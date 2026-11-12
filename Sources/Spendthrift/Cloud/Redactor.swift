import Foundation
import PDFKit
import AppKit
import Observation

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

    /// The account holder's name as printed on a statement: it sits on the line above the street
    /// address. Other text can share that line ("JANE DOE  We accept operator relay calls"), so
    /// only the leading capitalized words are taken.
    static func holderNames(in statement: String) -> Set<String> {
        let lines = statement.components(separatedBy: .newlines)
        guard let street = try? NSRegularExpression(
            pattern: #"^\s*\d{1,6}\s+[A-Za-z0-9 .'-]*\b(ST|STREET|AVE|AVENUE|RD|ROAD|BLVD|BOULEVARD|DR|DRIVE|LN|LANE|WAY|PL|PLACE|CT|COURT|TER|TERRACE|PKWY|HWY|SQ|CIR)\b.*$"#,
            options: .caseInsensitive) else { return [] }
        // Words that appear in capitals on statements but are never part of a person's name.
        let notNames: Set<String> = ["PAYMENT", "BALANCE", "DUE", "DATE", "STATEMENT", "ACCOUNT", "NEW", "MINIMUM", "TOTAL", "AMOUNT",
                                     "ENCLOSED", "SUMMARY", "CARD", "CARDS", "CASH", "CREDIT", "PAGE", "PERIOD", "BANK", "BOX", "PO",
                                     "MEMBER", "SINCE", "CUSTOMER", "SERVICE", "PLATINUM", "CHECKING", "SAVINGS", "PLEASE", "YOUR", "THE"]
        var names: Set<String> = []
        for i in lines.indices {
            let line = lines[i]
            guard street.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil,
                  line.range(of: #"(?i)^\s*P\.?\s?O\.?\s+BOX\b"#, options: .regularExpression) == nil else { continue }
            // Usually the line directly above; page layout can slip another row in between. Further up,
            // only accept a line that is nothing but a name, so ordinary capitalized text isn't taken.
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
        return names
    }

    /// For a whole statement: the holder's name, street address, city/ZIP, email, phone and
    /// account or card numbers are replaced before the text leaves the Mac.
    static func blank(_ statement: String) -> String {
        var lines = statement.components(separatedBy: .newlines)
        let street = try? NSRegularExpression(
            pattern: #"^\s*\d{1,6}\s+[A-Za-z0-9 .'-]*\b(ST|STREET|AVE|AVENUE|RD|ROAD|BLVD|BOULEVARD|DR|DRIVE|LN|LANE|WAY|PL|PLACE|CT|COURT|TER|TERRACE|PKWY|HWY|SQ|CIR)\b.*$"#,
            options: .caseInsensitive)
        let cityZip = try? NSRegularExpression(pattern: #"^\s*[A-Za-z .'-]+,?\s+[A-Z]{2}\s+\d{5}(-\d{4})?\s*$"#)
        func matches(_ re: NSRegularExpression?, _ s: String) -> Bool {
            re?.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        }
        var names = holderNames(in: statement)
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
            // "DOE /WI-FI" style mentions of the surname alone.
            if let last = name.split(separator: " ").last, last.count >= 4 {
                text = replace(text, "\\b" + NSRegularExpression.escapedPattern(for: String(last)) + "\\b", "[name]", options: .caseInsensitive)
            }
            // "Jane Marie [name]", "JANE M [name]": the first name with middle names or initials.
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
