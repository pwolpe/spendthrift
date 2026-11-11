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

    func items(for entry: UUID) -> [OrderItem] {
        (matches[entry.uuidString]?.items ?? []).compactMap { items.indices.contains($0) ? items[$0] : nil }
    }

    /// Adds an export. Anyone in the household can add theirs: an order belongs to one
    /// export, so its orders replace any earlier copy of the same orders.
    mutating func merge(_ new: [OrderItem]) {
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

    /// The order files of an export, if this folder is one (or holds one's order folder).
    /// The rest of an export (delivery photos, cart history) is never looked at.
    static func files(in folder: URL) -> [URL]? {
        let fm = FileManager.default
        for base in [folder, folder.appendingPathComponent("Your Amazon Orders", isDirectory: true)] {
            let retail = base.appendingPathComponent(retailFile)
            guard fm.fileExists(atPath: retail.path), isOrderFile(retail) else { continue }
            let digital = base.appendingPathComponent(digitalFile)
            return fm.fileExists(atPath: digital.path) ? [retail, digital] : [retail]
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

    static func read(_ files: [URL]) -> [OrderItem] {
        files.flatMap { url -> [OrderItem] in
            guard let data = try? Data(contentsOf: url), let text = CSVTable.decodeText(data) else { return [] }
            var rows = CSV.parse(text)
            guard rows.count > 1 else { return [] }
            let header = rows.removeFirst()
            let column = Dictionary(header.enumerated().map { ($1.trimmingCharacters(in: .whitespaces), $0) }, uniquingKeysWith: { a, _ in a })
            func cell(_ row: [String], _ name: String) -> String {
                guard let i = column[name], i < row.count else { return "" }
                let value = row[i].trimmingCharacters(in: .whitespaces)
                return value == "Not Available" || value == "Not Applicable" ? "" : value
            }
            return url.lastPathComponent == digitalFile ? digital(rows, cell) : retail(rows, cell)
        }
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
