import Foundation
import PDFKit
import AppKit
import Observation

// MARK: - Reading the pictures of paid checks

/// A statement says "Check #109 $175,000" and nothing more; the picture of the check, printed on a
/// later page, says who it was written to and what for. The model reads those pictures.
/// What is sent is the picture of that one page. Asked for back: number, amount, payee, memo,
/// and never the account, routing or Social Security numbers written on a check.
enum CheckReader {
    struct Check: Sendable {
        var number: String
        var amount: Double
        var payee: String
        var memo: String
        var category: Category?
        var confident: Bool
    }

    /// The pages of a statement that show check pictures (their captions are text: "Check # 109 Date … Amount …").
    static func picturePages(of document: PDFDocument) -> [PDFPage] {
        (0..<min(document.pageCount, 60)).compactMap { document.page(at: $0) }.filter { page in
            guard let text = page.string else { return false }
            return text.range(of: #"(?i)check images|check ?# ?\d+ +date +\d|#0{3,}\d+ +\$[\d,]+\.\d\d"#, options: .regularExpression) != nil
        }.prefix(4).map { $0 }
    }

    @MainActor static func picture(of page: PDFPage) -> Data? {
        let bounds = page.bounds(for: .mediaBox)
        let scale = 1_700 / max(bounds.width, 1)
        let image = page.thumbnail(of: NSSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        return IconRenderer.png(image)
    }

    static func read(_ picture: Data) async -> [Check]? {
        guard let key = CloudKey.load() else { return nil }
        let question = """
        This page of a bank statement shows pictures of paid checks, each with a printed caption giving its number and \
        amount. For every check you can read, reply with:
        - number: the check number from the caption, digits only, without leading zeros
        - amount: the amount from the caption, as a number
        - payee: who it is made out to ("Pay to the order of"), written out properly ("United States Treasury", not "US Treas")
        - memo: what the memo or "For" line says, in a few words; "" if blank or unreadable
        - category: exactly one of: \(Category.pickable.map(\.rawValue).joined(separator: "; "))
        - confident: true if the payee is clearly readable and the category follows from the payee or memo; false if you are guessing

        A check to the US Treasury, the IRS or a state tax department is "Income Taxes". A check to an investment fund, \
        a REIT or a brokerage is "Investing & Capital Calls". Rent, a contractor, a housing association or condo, furniture and repairs \
        are Home. A check to a person with nothing to say what it was for is Other, with confident false.
        Never copy an account number, routing number or Social Security number into any field.
        Reply with JSON only: {"checks": [{"number": "", "amount": 0, "payee": "", "memo": "", "category": "", "confident": true}]}
        """
        let model = DecisionSorter.handles(CloudAI.model) ? CloudAI.defaultModel : CloudAI.model
        let body: [String: Any] = [
            "model": model,
            "max_tokens": 3_000,
            "usage": ["include": true],
            "messages": [["role": "user", "content": [
                ["type": "text", "text": question],
                ["type": "image_url", "image_url": ["url": "data:image/png;base64," + picture.base64EncodedString()]],
            ]]],
        ]
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!, timeoutInterval: 90)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Spendthrift", forHTTPHeaderField: "X-Title")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              CloudSpend.note(job: "Reading checks", model: model, usage: object["usage"] as? [String: Any]) == (),
              let message = (object["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
              let text = message["content"] as? String, let list = CloudAI.object(from: text)?["checks"] as? [[String: Any]] else { return nil }
        return list.compactMap { item in
            let number = ((item["number"] as? String) ?? (item["number"] as? Int).map(String.init) ?? "").filter(\.isNumber)
            let trimmed = String(number.drop(while: { $0 == "0" }))
            guard !trimmed.isEmpty, let amount = (item["amount"] as? Double) ?? (item["amount"] as? String).flatMap(MoneyParsing.parse),
                  let payee = (item["payee"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), payee.filter(\.isLetter).count >= 2 else { return nil }
            // Belt and braces: nothing shaped like a Social Security or account number is kept.
            let memo = ((item["memo"] as? String) ?? "").replacingOccurrences(of: #"\b\d{3}-?\d{2}-?\d{4}\b|\b\d{8,}\b"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let category = (item["category"] as? String).flatMap { wanted in Category.pickable.first { $0.rawValue.caseInsensitiveCompare(wanted) == .orderedSame } }
            return Check(number: trimmed, amount: abs(amount), payee: String(payee.prefix(60)), memo: String(memo.prefix(80)),
                         category: category, confident: (item["confident"] as? Bool) ?? false)
        }
    }
}
