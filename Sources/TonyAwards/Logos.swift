import SwiftUI
import AppKit

/// Business logos, fetched once from the business's own website icon and kept on disk.
/// A list of real logos reads at a glance in a way that colored category squares don't.
@MainActor @Observable
final class LogoStore {
    static let shared = LogoStore()

    private(set) var images: [String: NSImage] = [:]
    @ObservationIgnored private var requested: Set<String> = []
    @ObservationIgnored private let folder: URL = {
        let dir = BudgetPaths().root.appendingPathComponent("Logos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// The logo if it's already here; otherwise nil now, and it appears when it arrives.
    func logo(for domain: String) -> NSImage? {
        if let image = images[domain] { return image }
        guard !requested.contains(domain) else { return nil }
        requested.insert(domain)
        let file = folder.appendingPathComponent(domain + ".png")
        let miss = folder.appendingPathComponent(domain + ".none")
        Task.detached(priority: .utility) {
            if let image = NSImage(contentsOf: file) {
                await MainActor.run { self.images[domain] = image }
                return
            }
            // Looked before and found nothing: don't ask again for a month.
            if let date = (try? miss.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               Date.now.timeIntervalSince(date) < 30 * 24 * 3600 { return }
            guard let url = URL(string: "https://www.google.com/s2/favicons?sz=128&domain=\(domain)"),
                  let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let image = NSImage(data: data),
                  let rep = image.representations.first, rep.pixelsWide >= 48 else {
                // (A 16-pixel reply is the service's "no icon" placeholder globe.)
                try? Data().write(to: miss)
                return
            }
            try? data.write(to: file)
            await MainActor.run { self.images[domain] = image }
        }
        return nil
    }
}

/// A place's logo when one is known, otherwise its category's icon.
struct MerchantIcon: View {
    /// Read directly rather than from the environment: this icon is drawn in tables, menus,
    /// exported pages and pictures of screens, and not all of those pass the environment down.
    private var store: BudgetStore { .shared }
    let name: String
    let category: Category
    var size: CGFloat = 32
    @State private var logos = LogoStore.shared

    var body: some View {
        if let domain = store.domain(forPlace: name), let logo = logos.logo(for: domain) {
            Image(nsImage: logo)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .padding(size * 0.12)
                .frame(width: size, height: size)
                .background(Color.white, in: .rect(cornerRadius: size * 0.28, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
                .transition(.opacity)
        } else {
            CategoryIcon(category: category, size: size)
        }
    }
}
