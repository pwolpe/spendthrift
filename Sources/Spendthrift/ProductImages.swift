import SwiftUI
import AppKit

/// Small pictures of the things that were ordered, fetched from the shop by product number and
/// kept on disk. The order history has no pictures in it; the shop serves a small one for most
/// products at a fixed address. Only the product number is sent. A product with no picture is
/// remembered as such, and shows the icon for its kind of thing instead.
@MainActor @Observable
final class ProductImages {
    static let shared = ProductImages()

    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private var missing: Set<String> = []
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private var waiting: [String] = []
    @ObservationIgnored private var running = 0
    @ObservationIgnored private let folder = BudgetPaths().root.appendingPathComponent("Products", isDirectory: true)
    @ObservationIgnored private var missingFile: URL { folder.appendingPathComponent("none.json") }
    /// Off in test runs, so a snapshot never waits on the network.
    @ObservationIgnored private let online = ProcessInfo.processInfo.environment["SPENDTHRIFT_NO_CLOUD"] == nil

    private init() {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        missing = Set((try? Data(contentsOf: missingFile)).flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [])
    }

    /// The picture, if it is already here. Asking starts the fetch when it isn't.
    func image(for asin: String?) -> NSImage? {
        guard let asin, asin.count == 10 else { return nil }
        if let image = images[asin] { return image }
        if missing.contains(asin) || loading.contains(asin) { return nil }
        loading.insert(asin)
        let file = folder.appendingPathComponent("\(asin).jpg")
        if let data = try? Data(contentsOf: file), let image = NSImage(data: data) {
            images[asin] = image
            loading.remove(asin)
            return image
        }
        guard online else { loading.remove(asin); return nil }
        waiting.append(asin)
        pump()
        return nil
    }

    /// A few at a time: a long list scrolling past shouldn't open hundreds of connections.
    private func pump() {
        while running < 6, let asin = waiting.popLast() {
            running += 1
            Task {
                let data = await Self.fetch(asin)
                running -= 1
                loading.remove(asin)
                if let data, let image = NSImage(data: data) {
                    try? data.write(to: folder.appendingPathComponent("\(asin).jpg"))
                    images[asin] = image
                } else if data == nil {
                    // Not there (the shop answers with a one-pixel blank): don't ask again.
                    missing.insert(asin)
                    if let list = try? JSONEncoder().encode(Array(missing)) { try? list.write(to: missingFile, options: .atomic) }
                }
                pump()
            }
        }
    }

    /// The picture's bytes; nil when the shop has none for this product. (A failed connection also
    /// comes back nil here, but is not recorded as missing: see the size check.)
    nonisolated private static func fetch(_ asin: String) async -> Data? {
        guard let url = URL(string: "https://m.media-amazon.com/images/P/\(asin).01._SCLZZZZZZZ_SX160_.jpg") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, data.count > 500 else { return nil }
        return data
    }
}

/// A product's picture, or the icon for its kind of thing while there is none.
struct ProductThumb: View {
    let asin: String?
    let kind: String
    var size: CGFloat = 36
    @State private var pictures = ProductImages.shared

    static func symbol(for kind: String) -> String {
        switch kind {
        case "Baby & Kids": "figure.and.child.holdinghands"
        case "Clothing & Shoes": "tshirt.fill"
        case "Electronics & Gadgets": "headphones"
        case "Computers & Accessories": "desktopcomputer"
        case "Phones & Chargers": "cable.connector"
        case "Kitchen & Cooking": "frying.pan.fill"
        case "Coffee & Tea": "cup.and.saucer.fill"
        case "Pantry & Snacks": "basket.fill"
        case "Fresh Food": "carrot.fill"
        case "Drinks": "waterbottle.fill"
        case "Wine, Beer & Spirits": "wineglass.fill"
        case "Cleaning & Laundry": "bubbles.and.sparkles.fill"
        case "Tools & Home Improvement": "hammer.fill"
        case "Furniture & Decor": "sofa.fill"
        case "Bedding & Bath": "bed.double.fill"
        case "Storage & Organization": "archivebox.fill"
        case "Lighting & Electrical": "lightbulb.fill"
        case "Garden & Outdoor": "leaf.fill"
        case "Vitamins & Supplements": "pills.fill"
        case "Medicine & First Aid": "cross.case.fill"
        case "Skincare & Grooming": "comb.fill"
        case "Dental Care": "mouth.fill"
        case "Fitness & Sports": "dumbbell.fill"
        case "Books": "book.closed.fill"
        case "Kindle & Digital Media": "ipad"
        case "Movies, Music & Games": "gamecontroller.fill"
        case "Toys & Hobbies": "teddybear.fill"
        case "Office & Stationery": "pencil.and.ruler.fill"
        case "Travel & Luggage": "suitcase.rolling.fill"
        case "Pet Supplies": "pawprint.fill"
        case "Gifts & Party": "gift.fill"
        case "Car & Bike": "car.fill"
        case "Memberships & Fees": "person.crop.rectangle.fill"
        default: "shippingbox.fill"
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
        Group {
            if let image = pictures.image(for: asin) {
                // Product shots come on white: keep the white, so they look the same in light and dark.
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                    .padding(size * 0.08)
                    .frame(width: size, height: size)
                    .background(Color.white)
            } else {
                Image(systemName: Self.symbol(for: kind))
                    .font(.system(size: size * 0.44, weight: .medium))
                    .foregroundStyle(OrdersView.color(of: kind))
                    .frame(width: size, height: size)
                    .background(OrdersView.color(of: kind).opacity(0.14))
                    .background(Theme.sheet)      // solid underneath, so a pile of them doesn't show through
            }
        }
        .clipShape(shape)
        .overlay { shape.strokeBorder(Theme.hairline) }
    }
}
