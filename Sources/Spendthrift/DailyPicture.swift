import SwiftUI
import AppKit
import ImagePlayground
import FoundationModels

/// The banner across the top of the Overview: a cartoon of Tony, Paul or both living out a daydream
/// about something really bought, one of them holding the receipt with the real place and total. There is never a wait. What shows on opening is already on disk:
/// the picture prepared during the last visit, or one of the starters that ship with the app.
/// Meanwhile, out of sight, the next one is drawn from his real photo for the next time he opens it.
@MainActor @Observable
final class DailyPicture {
    static let shared = DailyPicture()

    private(set) var image: NSImage?
    private(set) var caption: String = ""
    private(set) var isGenerating = false
    private(set) var isAIImage = false

    let headshot: NSImage? = DailyPicture.photo.flatMap(NSImage.init(data:))

    /// Cartoon Tony: baked in at build time, or made on first launch.
    private(set) var cartoon: NSImage? = Bundle.main.url(forResource: "tony-cartoon", withExtension: "png").flatMap(NSImage.init(contentsOf:))
    /// The portrait used wherever Tony's face appears small: drawn from his photo in the same
    /// style as the app's default pictures, so the sidebar, the icon and the banner are one person.
    private let portrait: NSImage? = {
        if let url = Bundle.main.url(forResource: "tony-avatar", withExtension: "png") { return NSImage(contentsOf: url) }
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/tony-avatar.png")
        return NSImage(contentsOf: dev)
    }()
    var avatar: NSImage? { portrait ?? croppedAvatar(cartoon ?? headshot) }
    /// Paul's portrait, drawn the same way, for the places that show the two of them.
    let paulAvatar: NSImage? = {
        if let url = Bundle.main.url(forResource: "paul-avatar", withExtension: "png") { return NSImage(contentsOf: url) }
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/paul-avatar.png")
        return NSImage(contentsOf: dev)
    }()

    @ObservationIgnored private var avatarCache: (source: ObjectIdentifier, image: NSImage)?
    private func croppedAvatar(_ source: NSImage?) -> NSImage? {
        guard let source else { return nil }
        if let avatarCache, avatarCache.source == ObjectIdentifier(source) { return avatarCache.image }
        guard let cg = FaceCrop.portrait(source, zoom: 1.8) else { return source }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        avatarCache = (ObjectIdentifier(source), image)
        return image
    }

    private var cartoonFile: URL { folder.appendingPathComponent("cartoon-tony.png") }
    private var triedCartoon = false

    /// If the build couldn't bake in a cartoon, make one here and update the Dock icon.
    func ensureCartoon() async {
        guard !triedCartoon else { return }
        triedCartoon = true
        if cartoon == nil, let cached = NSImage(contentsOf: cartoonFile) {
            cartoon = cached
        } else if cartoon == nil, let photo = headshot, let made = await CartoonMaker.cartoon(from: photo) {
            cartoon = made
            try? IconRenderer.png(made)?.write(to: cartoonFile)
        } else {
            return // bundled cartoon already in the icon
        }
        if Bundle.main.url(forResource: "tony-cartoon", withExtension: "png") == nil, let cartoon {
            NSApp.applicationIconImage = IconRenderer.icon(face: cartoon, isCartoon: true)
        }
    }

    private let folder: URL = {
        let dir = BudgetPaths().root.appendingPathComponent("Pictures", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private var todayKey: String { DateParsing.iso.string(from: .now) }
    private var imageFile: URL { folder.appendingPathComponent("\(todayKey).png") }
    private var captionFile: URL { folder.appendingPathComponent("\(todayKey).txt") }
    private var lastHighlights: [Highlight] = []

    /// Coming back to the app is another chance to prepare the next picture, if this launch hasn't yet.
    func retryIfNeeded() {
        guard !preparedThisLaunch, !isGenerating, !lastHighlights.isEmpty else { return }
        let highlights = lastHighlights
        Task { await prepareNext(highlights: highlights) }
    }

    /// The caricature as a PNG no larger than 1024 pixels, to send along as the reference for a drawing.
    static func referencePNG(_ image: NSImage) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, 1024 / CGFloat(max(cg.width, cg.height)))
        let width = Int(CGFloat(cg.width) * scale), height = Int(CGFloat(cg.height) * scale)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .png, properties: [:])
    }

    // MARK: What to feature

    /// A recent purchase worth celebrating.
    struct Highlight: Hashable {
        let merchant: String
        let category: Category
        let amount: Double
        var date: Date?
    }

    // MARK: The pictures

    /// One picture: a starter that ships with the app, or one drawn here about a real purchase.
    struct Picture: Codable, Hashable {
        var file: String
        var caption: String
        var merchant: String?
        /// The day of the purchase, as yyyy-MM-dd.
        var date: String?
        var seen = false
        var model: String?
        var style: String?
        /// Who is in it: "tony", "paul" or "both".
        var who: String?
        /// What the purchase cost: the real number is what makes the picture land.
        var amount: Double?
        /// True when someone in the picture holds the receipt. Pictures drawn before that was the rule
        /// stay on disk but are no longer shown.
        var receipt: Bool?
    }

    /// What the picture is about ("Dunkin' · Nov 7"), shown under it. Nil for a starter.
    private(set) var source: String?
    private(set) var current: Picture?
    @ObservationIgnored private var preparedThisLaunch = false
    /// For tests: who the next picture stars, and permission to draw another in the same launch.
    @ObservationIgnored var forcedCast: String?
    func allowAnother() { preparedThisLaunch = false }

    private init() { showOnOpen() }

    private static let starterFolder: URL? = {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Starters"), FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Starters")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }()

    private struct Starter: Codable { var id: String; var caption: String; var who: String? }
    private static let starters: [Picture] = {
        guard let folder = starterFolder, let data = try? Data(contentsOf: folder.appendingPathComponent("starters.json")),
              let list = try? JSONDecoder().decode([Starter].self, from: data) else { return [] }
        return list.map { Picture(file: "starter:\($0.id).jpg", caption: $0.caption, seen: true, who: $0.who) }
    }()

    private var galleryFile: URL { folder.appendingPathComponent("gallery.json") }
    private var gallery: [Picture] {
        get { (try? Data(contentsOf: galleryFile)).flatMap { try? JSONDecoder().decode([Picture].self, from: $0) } ?? [] }
        set { if let data = try? JSONEncoder().encode(newValue) { try? data.write(to: galleryFile, options: .atomic) } }
    }

    private func url(for picture: Picture) -> URL? {
        if picture.file.hasPrefix("starter:") { return Self.starterFolder?.appendingPathComponent(String(picture.file.dropFirst(8))) }
        return folder.appendingPathComponent(picture.file)
    }

    private func show(_ picture: Picture, animated: Bool) -> Bool {
        guard let url = url(for: picture), let loaded = NSImage(contentsOf: url) else { return false }
        var label: String?
        if let merchant = picture.merchant {
            let day = picture.date.flatMap { DateParsing.parse($0, format: "yyyy-MM-dd") }
            label = day.map { "\(merchant) · \($0.formatted(.dateTime.month(.abbreviated).day()))" } ?? merchant
            if let amount = picture.amount { label = (label ?? merchant) + " · " + Money.format(amount) }
        }
        let apply = { self.image = loaded; self.caption = picture.caption; self.source = label; self.current = picture; self.isAIImage = true }
        if animated { withAnimation(.easeInOut(duration: 0.5)) { apply() } } else { apply() }
        return true
    }

    /// On opening: the picture made last time if it hasn't been seen, otherwise a random one.
    private func showOnOpen() {
        var saved = gallery
        if let index = saved.lastIndex(where: { !$0.seen && $0.receipt == true }), show(saved[index], animated: false) {
            for i in saved.indices { saved[i].seen = true }
            gallery = saved
            return
        }
        showRandom(animated: false)
    }

    /// Any other picture, at once: the starters and everything drawn so far.
    func showRandom(animated: Bool = true) {
        let pool = (Self.starters + gallery.filter { $0.seen && $0.receipt == true }).filter { $0.file != current?.file }.shuffled()
        for picture in pool where show(picture, animated: animated) { return }
    }

    /// The real photos, sent along with every drawing so the picture is undeniably the person.
    private static func bundled(_ name: String) -> Data? {
        if let url = Bundle.main.url(forResource: name, withExtension: "jpg"), let data = try? Data(contentsOf: url) { return data }
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/\(name).jpg")
        return try? Data(contentsOf: dev)
    }
    private static let photo: Data? = bundled("tony")
    private static let paulPhoto: Data? = bundled("paul")

    /// Once per launch, out of sight: choose the best image model there is today, pick a real recent
    /// purchase, and draw the picture that will be waiting the next time the app opens.
    func prepareNext(highlights: [Highlight]) async {
        lastHighlights = highlights
        guard CloudAI.isEnabled, !preparedThisLaunch, !isGenerating, !highlights.isEmpty, let photo = Self.photo else { return }
        // Who stars this time: Tony, Paul, or the two of them, a third of the time each. Whoever has
        // appeared least in the recent pictures goes next, and never the same as last time.
        var cast: [(name: String, photo: Data)] = [("Tony", photo)]
        var who = "tony"
        if let paul = Self.paulPhoto {
            let lately = gallery.suffix(9).compactMap(\.who)
            let last: String = lately.last ?? ""
            let all: [String] = ["tony", "paul", "both"]
            let options: [String] = all.filter { $0 != last }
            let times = { (o: String) -> Int in lately.filter { $0 == o }.count }
            let fewest = options.map(times).min() ?? 0
            let fair: String = options.filter { times($0) == fewest }.randomElement() ?? "tony"
            if let forcedCast { who = forcedCast } else { who = fair }
            cast = who == "tony" ? [("Tony", photo)] : who == "paul" ? [("Paul", paul)] : [("Tony", photo), ("Paul", paul)]
        }
        preparedThisLaunch = true
        isGenerating = true
        defer { isGenerating = false }

        var saved = gallery
        let lately = Set(saved.suffix(8).compactMap(\.merchant))
        let recent = Array(highlights.prefix(15))
        let pick = recent.filter { !lately.contains($0.merchant) }.randomElement() ?? recent.randomElement()!
        async let chosen = CloudImage.bestModel()
        let names = cast.map(\.name)
        async let planned = CloudImage.scene(merchant: pick.merchant, category: pick.category.displayName, amount: pick.amount, cast: names)
        let model = await chosen
        guard let scene = await planned else {
            if ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] != nil { print("DEBUG PICTURE no scene came back for \(pick.merchant)") }
            preparedThisLaunch = false; return
        }
        // A style none of the last several pictures used.
        let usedLately = Set(saved.suffix(7).compactMap(\.style))
        let style = CloudImage.styles.filter { !usedLately.contains($0.id) }.randomElement() ?? CloudImage.styles.randomElement()!
        // The receipt in his hand is the point of the picture: the real place, what it sells, the real total.
        let receipt = CloudImage.Receipt(merchant: pick.merchant, what: scene.what, total: Money.format(pick.amount))
        var drawn: Data?, used = model, bestMarks = Int.min
        // Drawn up to three times, keeping the best: a picture whose receipt can't be read, reads
        // wrong or isn't in anyone's hand is tried again.
        for attempt in 0..<3 {
            let with = attempt == 2 && model != CloudImage.defaultModel ? CloudImage.defaultModel : model
            guard let candidate = await CloudImage.draw(scene: scene.scene, cast: cast, model: with, style: style.look, receipt: receipt),
                  NSImage(data: candidate) != nil else { continue }
            let marks = await CloudImage.receiptReads(candidate, receipt: receipt)
            if ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] != nil { print("DEBUG PICTURE attempt \(attempt + 1) receipt marks: \(marks.map(String.init) ?? "unknown") of 4") }
            if (marks ?? 4) > bestMarks { drawn = candidate; used = with; bestMarks = marks ?? 4 }
            if bestMarks >= 4 { break }
        }
        guard let drawn else {
            if ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] != nil { print("DEBUG PICTURE nothing was drawn (model \(model))") }
            preparedThisLaunch = false; return
        }

        let file = "tony-\(Int(Date.now.timeIntervalSince1970)).png"
        try? drawn.write(to: folder.appendingPathComponent(file))
        saved.append(Picture(file: file, caption: scene.caption, merchant: pick.merchant,
                             date: pick.date.map { DateParsing.iso.string(from: $0) }, seen: false, model: used, style: style.id, who: who, amount: pick.amount, receipt: true))
        // Keep the last thirty; older ones go, with their files.
        while saved.count > 30 { try? FileManager.default.removeItem(at: folder.appendingPathComponent(saved.removeFirst().file)) }
        gallery = saved
        if ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] != nil {
            print("DEBUG PICTURE next: \(pick.merchant) [\(used), \(style.id), \(who)] \(scene.caption)\n  scene: \(scene.scene)")
        }
    }
}

// MARK: - The banner on the Overview

struct BannerCard: View {
    private var store: BudgetStore { .shared }
    @State private var daily = DailyPicture.shared

    var body: some View {
        // The picture hangs clean, like a print; its caption sits beneath it like a gallery label.
        // (Words laid over a picture depend on the picture; words on paper never fail to read.)
        VStack(alignment: .leading, spacing: 14) {
            Color.black.opacity(0.06)
                .aspectRatio(21.0 / 9.0, contentMode: .fit)
                .overlay {
                    if let image = daily.image ?? daily.cartoon {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .id(ObjectIdentifier(image))
                            .transition(.opacity)
                    }
                }
                .clipShape(.rect(cornerRadius: 18, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline) }
                .shadow(color: .black.opacity(0.10), radius: 16, y: 6)

            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Today's Nominee · \(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))".uppercased())
                        .font(.caption.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(Theme.goldDeep)
                    Text(daily.caption.isEmpty ? "Today's daydream" : daily.caption)
                        .font(.system(size: 24, weight: .bold, design: .serif))
                        .fixedSize(horizontal: false, vertical: true)
                    if let source = daily.source {
                        // The real purchase behind the picture: this is what makes it land.
                        Label(source, systemImage: "receipt")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                Button {
                    daily.showRandom()
                } label: {
                    Label("Another One", systemImage: "wand.and.sparkles")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.horizontal, 6)
        }
        // Once the statements are in, quietly get the next picture ready.
        .task(id: "\(store.hasLoadedTransactions)-\(store.isImporting)-\(store.recentHighlights().first?.merchant ?? "")") {
            guard store.hasLoadedTransactions, !store.isImporting else { return }
            await daily.prepareNext(highlights: store.recentHighlights())
        }
    }
}
