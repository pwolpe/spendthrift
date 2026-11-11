import Foundation

/// One line of an online order: a thing bought, and what it came to with tax.
/// A card statement only says "Amazon $41.35"; these say what the $41.35 was.
struct OrderItem: Codable, Hashable {
    enum Shop: String, Codable { case store, groceries, digital }

    var orderID: String
    var shop: Shop
    /// The day it shipped (yyyy-MM-dd), which is when the card is charged.
    var date: String
    /// Items that left together were charged together: the ship time, to the minute.
    var shipment: String
    var name: String
    /// The shop's own shelf for it ("Kitchen", "Hardcover"), when it says.
    var department: String?
    var cents: Int
    var quantity: Int
    /// What the shop lists for the whole shipment. For groceries this is closer to the
    /// charge than the items are (weighed items, bag fees).
    var listedCents: Int?
    /// Whose account it was ordered on (a first name), when the export says.
    var who: String?

    /// Where it's filed before the model has read it: only as fine as the shop's own shelves allow.
    var roughCategory: Category {
        switch shop {
        case .groceries: return .groceries
        case .digital: return .entertainment
        case .store:
            let d = (department ?? "").lowercased()
            if d.contains("grocery") { return .groceries }
            if d.contains("health") || d.contains("beauty") { return .health }
            if ["kitchen", "home", "tools", "lawn", "furniture"].contains(where: d.contains) { return .home }
            if ["cover", "paperback", "book", "music", "video", "toy"].contains(where: d.contains) { return .entertainment }
            return .shopping
        }
    }

    /// The shelf it came off, in plain words, for adding orders up by kind.
    var shelf: String {
        switch shop {
        case .groceries: "Groceries"
        case .digital: "Books & Digital"
        case .store: department == "Grocery" ? "Groceries" : (department ?? "Everything Else")
        }
    }
}

/// Which order items a card charge paid for, and how sure that is.
struct OrderMatch: Codable, Hashable {
    enum Kind: String, Codable {
        /// The items add up to the charge, to the cent.
        case exact
        /// The charge is a little under the items: points or a gift balance covered the rest.
        case lessCredit
        /// Groceries: the charge is near the listed total (weights, bags and tips move it).
        case approximate
    }
    var items: [Int]
    var kind: Kind
}

/// Everything read from order-history exports, and how it lines up with the card charges.
/// Kept in its own file so the library stays small and quick to load.
struct OrderBook: Codable {
    var items: [OrderItem] = []
    /// Charge (a `LedgerEntry` id) → the items it paid for. Rebuilt whenever items or charges change.
    var matches: [String: OrderMatch] = [:]
    /// What the model made of each product listing, by the listing's full text.
    var sorted: [String: ItemSort]?
    /// Money that came back, by order.
    var refunds: [String: Int]?

    /// A listing read by the model: what the thing is in plain words, and where it belongs in the budget.
    struct ItemSort: Codable, Hashable {
        var name: String
        var category: String
    }

    func items(for entry: UUID) -> [OrderItem] {
        (matches[entry.uuidString]?.items ?? []).compactMap { items.indices.contains($0) ? items[$0] : nil }
    }

    /// Adds an export. Anyone in the household can add theirs: an order belongs to one
    /// export, so its orders replace any earlier copy of the same orders.
    mutating func merge(_ new: [OrderItem], refunds back: [String: Int] = [:]) {
        refunds = (refunds ?? [:]).merging(back) { _, latest in latest }
        let incoming = Set(new.map(\.orderID))
        items.removeAll { incoming.contains($0.orderID) }
        items += new
        items.sort { ($0.date, $0.orderID, $0.shipment, $0.name, $0.cents) < ($1.date, $1.orderID, $1.shipment, $1.name, $1.cents) }
        matches = [:]
    }

    static func load(_ url: URL) -> OrderBook {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(OrderBook.self, from: $0) } ?? OrderBook()
    }

    func save(to url: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Reading an export

/// Reads the order history a shop hands over on request (Amazon's "Request Your Data → Your Orders").
enum OrderExport {
    static let retailFile = "Order History.csv"
    static let digitalFile = "Digital Content Orders.csv"
    static let refundFile = "Refund Details.csv"

    /// The order files of an export, if this folder is one (or holds one's order folder).
    /// The rest of an export (delivery photos, cart history) is never looked at.
    static func files(in folder: URL) -> [URL]? {
        let fm = FileManager.default
        for base in [folder, folder.appendingPathComponent("Your Amazon Orders", isDirectory: true)] {
            let retail = base.appendingPathComponent(retailFile)
            guard fm.fileExists(atPath: retail.path), isOrderFile(retail) else { continue }
            let others = [base.appendingPathComponent(digitalFile),
                          base.deletingLastPathComponent().appendingPathComponent("Your Returns & Refunds/\(refundFile)"),
                          base.appendingPathComponent("Your Returns & Refunds/\(refundFile)")]
            return [retail] + others.filter { fm.fileExists(atPath: $0.path) }
        }
        return nil
    }

    /// True for an order file dropped by itself.
    static func isOrderFile(_ url: URL) -> Bool {
        guard [retailFile, digitalFile].contains(url.lastPathComponent),
              let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = String(decoding: (try? handle.read(upToCount: 4096)) ?? Data(), as: UTF8.self)
        return head.contains("Order ID") && head.contains("Product Name")
    }

    /// Everything in one export: its items, with the first name on the account, and its refunds by order.
    static func read(_ files: [URL]) -> (items: [OrderItem], refunds: [String: Int]) {
        // Several people's exports can arrive together; each folder is one person's.
        var items: [(folder: String, item: OrderItem)] = [], refunds: [String: Int] = [:], names: [String: [String: Int]] = [:]
        for url in files {
            let folder = url.deletingLastPathComponent().path
            guard let data = try? Data(contentsOf: url), let text = CSVTable.decodeText(data) else { continue }
            var rows = CSV.parse(text)
            guard rows.count > 1 else { continue }
            let header = rows.removeFirst()
            let column = Dictionary(header.enumerated().map { ($1.trimmingCharacters(in: .whitespaces), $0) }, uniquingKeysWith: { a, _ in a })
            func cell(_ row: [String], _ name: String) -> String {
                guard let i = column[name], i < row.count else { return "" }
                let value = row[i].trimmingCharacters(in: .whitespaces)
                return value == "Not Available" || value == "Not Applicable" ? "" : value
            }
            switch url.lastPathComponent {
            case digitalFile: items += digital(rows, cell).map { (folder, $0) }
            case refundFile:
                for row in rows where !cell(row, "Order ID").isEmpty { refunds[cell(row, "Order ID"), default: 0] += cents(cell(row, "Refund Amount")) }
            default:
                items += retail(rows, cell).map { (folder, $0) }
                // The billing address starts with the account holder's name: the only place the export says whose it is.
                for row in rows {
                    if let first = cell(row, "Billing Address").split(separator: " ").first, first.allSatisfy(\.isLetter) { names[folder, default: [:]][String(first), default: 0] += 1 }
                }
            }
        }
        let who = names.mapValues { counts in counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key }
        return (items.map { var item = $0.item; item.who = who[$0.folder] ?? nil; return item }, refunds)
    }

    /// Amounts come as "12.99", sometimes quoted as "'-1.5'".
    private static func cents(_ text: String) -> Int {
        let cleaned = text.filter { $0.isNumber || $0 == "." || $0 == "-" }
        return Int(((Double(cleaned) ?? 0) * 100).rounded())
    }

    private static func retail(_ rows: [[String]], _ cell: ([String], String) -> String) -> [OrderItem] {
        rows.compactMap { row in
            let id = cell(row, "Order ID"), name = cell(row, "Product Name")
            guard !id.isEmpty, !name.isEmpty, cell(row, "Order Status") != "Cancelled" else { return nil }
            let shipped = cell(row, "Ship Date"), ordered = cell(row, "Order Date")
            let when = shipped.first?.isNumber == true ? shipped : ordered
            guard when.count >= 10 else { return nil }
            let site = cell(row, "Website").lowercased()
            let groceries = ["wholefoods", "fresh", "primenow", "amazon go"].contains { site.contains($0) }
            let listed = cents(cell(row, "Shipment Item Subtotal")) + cents(cell(row, "Shipment Item Subtotal Tax"))
            let department = cell(row, "Department")
            return OrderItem(orderID: id, shop: groceries ? .groceries : .store, date: String(when.prefix(10)),
                             shipment: String(when.prefix(16)), name: name, department: department.isEmpty ? nil : department,
                             cents: cents(cell(row, "Total Amount")), quantity: max(1, Int(cell(row, "Original Quantity")) ?? 1),
                             listedCents: listed > 0 ? listed : nil)
        }
    }

    /// Digital orders list the price and the tax of one title on separate rows.
    private static func digital(_ rows: [[String]], _ cell: ([String], String) -> String) -> [OrderItem] {
        var order: [String] = [], found: [String: OrderItem] = [:]
        for row in rows {
            let id = cell(row, "Order ID"), when = cell(row, "Order Date")
            guard !id.isEmpty, when.count >= 10 else { continue }
            let key = id + "|" + cell(row, "ASIN")
            let amount = cents(cell(row, "Transaction Amount"))
            if found[key] != nil {
                found[key]!.cents += amount
                if found[key]!.name.isEmpty { found[key]!.name = cell(row, "Product Name") }
            } else {
                order.append(key)
                found[key] = OrderItem(orderID: id, shop: .digital, date: String(when.prefix(10)), shipment: String(when.prefix(16)),
                                       name: cell(row, "Product Name"), department: nil, cents: amount, quantity: 1, listedCents: nil)
            }
        }
        return order.compactMap { found[$0] }.map { item in
            var item = item
            if item.name.isEmpty { item.name = "Digital purchase" }
            return item
        }
    }
}

// MARK: - Matching charges to orders

/// Lines card charges up with what was ordered. A charge is one shipment, so the amount and
/// the ship date together almost always single it out. Pure: same inputs, same answer.
enum OrderMatcher {
    struct Charge {
        var id: UUID
        var date: String
        var cents: Int
        var shop: OrderItem.Shop
    }

    /// Which shop a statement line is from, by how these shops sign their charges. Nil for anything else.
    static func shop(of description: String) -> OrderItem.Shop? {
        let d = description.lowercased()
        if d.contains("whole foods") || d.contains("wholefds") || d.contains("amazon fresh") || d.contains("amazon go") { return .groceries }
        if ["kindle", "audible", "prime video", "amazon prime", "amazon digital", "amzn digital", "amazon music"].contains(where: d.contains) { return .digital }
        if d.contains("amazon") || d.contains("amzn") { return .store }
        return nil
    }

    /// Days since a fixed day, for yyyy-MM-dd (so two dates can be subtracted).
    static func dayNumber(_ date: String) -> Int {
        let parts = date.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return 0 }
        var y = parts[0]; let m = parts[1], d = parts[2]
        if m <= 2 { y -= 1 }
        let era = (y >= 0 ? y : y - 399) / 400, yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        return era * 146_097 + yoe * 365 + yoe / 4 - yoe / 100 + doy
    }

    static func match(_ charges: [Charge], to items: [OrderItem]) -> [String: OrderMatch] {
        let days = items.map { dayNumber($0.date) }
        var free = Set(items.indices.filter { items[$0].cents >= 0 })
        var result: [String: OrderMatch] = [:]
        let charges = charges.filter { $0.cents > 0 }.sorted { ($0.date, $0.cents, $0.id.uuidString) < ($1.date, $1.cents, $1.id.uuidString) }

        // Items by day, so a charge only looks at the days around it.
        var onDay: [Int: [Int]] = [:]
        for i in items.indices { onDay[days[i], default: []].append(i) }

        /// Unclaimed items of the charge's shop, shipped from `before` days before the charge to `after` days after it,
        /// grouped (by shipment, or by order).
        func groups(_ charge: Charge, before: Int, after: Int, by key: (OrderItem) -> String) -> [[Int]] {
            let day = dayNumber(charge.date)
            var order: [String] = [], found: [String: [Int]] = [:]
            for d in (day - before)...(day + after) {
                for i in onDay[d] ?? [] where free.contains(i) && items[i].shop == charge.shop {
                    let k = key(items[i])
                    if found[k] == nil { order.append(k) }
                    found[k, default: []].append(i)
                }
            }
            return order.compactMap { found[$0] }
        }
        func take(_ charge: Charge, _ group: [Int], _ kind: OrderMatch.Kind) {
            result[charge.id.uuidString] = OrderMatch(items: group, kind: kind)
            free.subtract(group)
        }
        func total(_ group: [Int]) -> Int { group.reduce(0) { $0 + items[$1].cents } }
        func gap(_ charge: Charge, _ group: [Int]) -> Int { abs(dayNumber(charge.date) - days[group[0]]) }

        // 1. To the cent: one shipment, then everything an order shipped that day, then a whole order.
        let groupings: [(OrderItem) -> String] = [
            { $0.orderID + "|" + $0.shipment },
            { $0.orderID + "|" + $0.date },
            { $0.orderID },
        ]
        for grouping in groupings {
            for charge in charges where result[charge.id.uuidString] == nil {
                let fits = groups(charge, before: 8, after: 3, by: grouping).filter { total($0) == charge.cents }
                if let best = fits.min(by: { gap(charge, $0) < gap(charge, $1) }) { take(charge, best, .exact) }
            }
        }

        // 2. Groceries: weighed items, bag fees and tips move the charge off the items, so go by
        //    the order's listed total and accept the nearest one within a quarter (or $3).
        for charge in charges where charge.shop == .groceries && result[charge.id.uuidString] == nil {
            let near = groups(charge, before: 3, after: 2, by: { $0.orderID }).compactMap { group -> (off: Int, group: [Int])? in
                let listed = items[group[0]].listedCents ?? total(group)
                let off = abs(charge.cents - listed)
                return off <= max(300, listed / 4) ? (off, group) : nil
            }
            if let best = near.min(by: { $0.off < $1.off }) { take(charge, best.group, .approximate) }
        }

        // 3. A charge a little under a shipment: points or a gift balance paid the difference, and
        //    the export doesn't say so. Closest pairs first, so a near miss can't take a better fit's shipment.
        while true {
            var best: (share: Double, gap: Int, charge: Charge, group: [Int])?
            for charge in charges where charge.shop == .store && result[charge.id.uuidString] == nil {
                for group in groups(charge, before: 4, after: 2, by: { $0.orderID + "|" + $0.date }) {
                    let sum = total(group), short = sum - charge.cents
                    guard short > 0, short <= max(200, sum * 12 / 100) else { continue }
                    let candidate = (Double(short) / Double(sum), gap(charge, group), charge, group)
                    if best == nil || (candidate.0, candidate.1) < (best!.share, best!.gap) { best = candidate }
                }
            }
            guard let best else { break }
            take(best.charge, best.group, .lessCredit)
        }
        return result
    }
}

// MARK: - Reading what each item is

/// Product listings are written to be found, not understood ("Cardia 7: Purified Provinal Omega 7
/// Fatty Acids - Compare to Omega 3-6-9 and See…"). The model reads each one and says what it is
/// and where it belongs in the budget. Only the listing text is sent: no prices, dates or names.
enum ItemSorter {
    static func instructions() -> String {
        """
        You tidy a household's online shopping history for a personal budgeting app. Each numbered item is a product \
        listing exactly as the shop wrote it. For each, give:

        - name: what the thing is, the way a person would say it, under 45 characters. Keep the brand when it is the \
        point ("Sonos Move 2 speaker", "Aesop hand wash", "Counter Culture coffee beans"), drop sizes, counts, colours \
        and sales talk. For a book, film or album, the title.
        - category: exactly one from this list (use the names exactly): \(Category.spendingCases.map(\.rawValue).joined(separator: "; "))

        Rules:
        - Food, drink and pantry goods to have at home are Groceries. Wine, liquor and spirits are "Wine & Spirits".
        - Vitamins, supplements, medicine, first aid and fitness gear are "Health & Fitness". Soap, skincare, haircare, \
        cosmetics, shaving and dental care are "Personal Care".
        - Cookware, kitchen tools, furniture, bedding, storage, cleaning supplies, light bulbs, tools, hardware and \
        garden things are Home.
        - Books, ebooks, audiobooks, music, films, games and toys are Entertainment.
        - A membership or a plan billed again and again (Prime, Kindle Unlimited, Audible) is Subscriptions.
        - Clothes, shoes, bags, electronics, chargers, office supplies and anything bought for no particular room of \
        the house are Shopping. Luggage and travel gear are Travel. Things for the car are "Car & Transportation".
        - If the person made a category of their own that fits (for example one for children or pets), prefer it.
        - Use Other only when the listing really doesn't say what the thing is.

        Reply with JSON only: {"results": [{"id": 1, "name": "…", "category": "…"}]} with one result per item.
        """
    }

    /// Nil when the model couldn't be reached; listings it skipped are simply absent.
    static func sort(_ listings: [String]) async -> [String: OrderBook.ItemSort]? {
        guard !listings.isEmpty else { return [:] }
        let payload = listings.enumerated().map { ["id": $0 + 1, "listing": String($1.prefix(220))] as [String: Any] }
        guard let body = try? JSONSerialization.data(withJSONObject: ["items": payload]), let user = String(data: body, encoding: .utf8) else { return nil }
        let system = instructions()
        let reply = await Timeout.run(120) {
            try? await CloudAI.complete(system: system, user: user, json: true, maxTokens: 60 * listings.count + 2_000)
        }
        guard let reply, let results = CloudAI.object(from: reply)?["results"] as? [[String: Any]] else { return nil }
        var out: [String: OrderBook.ItemSort] = [:]
        for result in results {
            guard let id = (result["id"] as? Int) ?? (result["id"] as? String).flatMap(Int.init), (1...listings.count).contains(id),
                  let wanted = result["category"] as? String,
                  let category = Category.spendingCases.first(where: { $0.rawValue.caseInsensitiveCompare(wanted) == .orderedSame }) else { continue }
            var name = ((result["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty || name.count > 70 { name = String(listings[id - 1].prefix(60)) }
            out[listings[id - 1]] = .init(name: name, category: category.rawValue)
        }
        return out
    }
}
