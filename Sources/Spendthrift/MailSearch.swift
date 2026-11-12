import Foundation
import AppKit

/// The answer to "what was this charge?" is usually sitting in the person's mail: a receipt, a
/// confirmation, an invoice. This builds the search that finds it (the amount, in the days around
/// the charge) and opens it in their own mail, in their own browser. Nothing is read by the app.
enum MailSearch {
    enum Provider: String, CaseIterable, Identifiable {
        case gmail = "Gmail", outlook = "Outlook", yahoo = "Yahoo Mail"
        var id: String { rawValue }
    }

    static var provider: Provider {
        get { UserDefaults.standard.string(forKey: "mailProvider").flatMap(Provider.init(rawValue:)) ?? .gmail }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "mailProvider") }
    }

    /// The amount as mail usually writes it, with and without the thousands comma.
    static func amounts(_ amount: Double) -> [String] {
        let plain = String(format: "%.2f", abs(amount))
        // Commas every three digits, by hand: the same on every Mac, whatever its region.
        let parts = plain.split(separator: ".")
        var digits = Array(parts[0]), grouped = ""
        while digits.count > 3 { grouped = "," + String(digits.suffix(3)) + grouped; digits.removeLast(3) }
        grouped = String(digits) + grouped + "." + parts[1]
        return grouped == plain ? [plain] : [grouped, plain]
    }

    /// A week either side of the charge: receipts arrive when something is ordered, cards are charged when it ships.
    static func query(amount: Double, date: Date, provider: Provider = provider) -> String {
        let terms = amounts(amount).map { "\"\($0)\"" }.joined(separator: " OR ")
        let day = { (offset: Int) -> String in
            let d = Calendar.current.date(byAdding: .day, value: offset, to: date) ?? date
            return DateParsing.formatter(provider == .gmail ? "yyyy/MM/dd" : "yyyy-MM-dd").string(from: d)
        }
        switch provider {
        case .gmail: return "(\(terms)) after:\(day(-7)) before:\(day(8))"
        case .outlook: return "(\(terms)) received:\(day(-7))..\(day(8))"
        case .yahoo: return terms
        }
    }

    /// What the search does, for each provider, in words (Yahoo cannot be asked for a range of days).
    static func explanation(amount: Double, date: Date, provider: Provider = provider) -> String {
        let day = date.formatted(.dateTime.month(.abbreviated).day().year())
        switch provider {
        case .gmail, .outlook: return "Opens \(provider.rawValue) in your browser, searching for \(Money.format(abs(amount))) in the week either side of \(day). Then say here what it was."
        case .yahoo: return "Opens \(provider.rawValue) in your browser, searching for \(Money.format(abs(amount))). It cannot be limited to dates, so look near \(day). Then say here what it was."
        }
    }

    static func url(amount: Double, date: Date, provider: Provider = provider) -> URL? {
        let q = query(amount: amount, date: date, provider: provider)
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=#/?:")
        guard let encoded = q.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        switch provider {
        case .gmail: return URL(string: "https://mail.google.com/mail/u/0/#search/\(encoded)")
        case .outlook: return URL(string: "https://outlook.live.com/mail/0/?q=\(encoded)")
        case .yahoo: return URL(string: "https://mail.yahoo.com/d/search/keyword=\(encoded)")
        }
    }

    @MainActor static func open(amount: Double, date: Date) {
        if let url = url(amount: amount, date: date) { NSWorkspace.shared.open(url) }
    }
}
