import SwiftUI
import AppKit
import ImagePlayground
import FoundationModels

/// The banner across the top of the Overview: a cartoon of Tony living out a daydream about
/// something he really bought. There is never a wait. What shows on opening is already on disk:
/// the picture prepared during the last visit, or one of the starters that ship with the app.
/// Meanwhile, out of sight, the next one is drawn from his real photo for the next time he opens it.
@MainActor @Observable
final class DailyTony {
    static let shared = DailyTony()

    private(set) var image: NSImage?
    private(set) var caption: String = ""
    private(set) var isGenerating = false
    private(set) var isAIImage = false

    let headshot: NSImage? = DailyTony.photo.flatMap(NSImage.init(data:))

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
        let dir = BudgetPaths().root.appendingPathComponent("Daily Tony", isDirectory: true)
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
    }

    /// What the picture is about ("Dunkin' · Nov 7"), shown under it. Nil for a starter.
    private(set) var source: String?
    private(set) var current: Picture?
    @ObservationIgnored private var preparedThisLaunch = false

    private init() { showOnOpen() }

    private static let starterFolder: URL? = {
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("Starters"), FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Starters")
        return FileManager.default.fileExists(atPath: dev.path) ? dev : nil
    }()

    private struct Starter: Codable { var id: String; var caption: String }
    private static let starters: [Picture] = {
        guard let folder = starterFolder, let data = try? Data(contentsOf: folder.appendingPathComponent("starters.json")),
              let list = try? JSONDecoder().decode([Starter].self, from: data) else { return [] }
        return list.map { Picture(file: "starter:\($0.id).jpg", caption: $0.caption, seen: true) }
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
        }
        let apply = { self.image = loaded; self.caption = picture.caption; self.source = label; self.current = picture; self.isAIImage = true }
        if animated { withAnimation(.easeInOut(duration: 0.5)) { apply() } } else { apply() }
        return true
    }

    /// On opening: the picture made last time if it hasn't been seen, otherwise a random one.
    private func showOnOpen() {
        var saved = gallery
        if let index = saved.lastIndex(where: { !$0.seen }), show(saved[index], animated: false) {
            for i in saved.indices { saved[i].seen = true }
            gallery = saved
            return
        }
        showRandom(animated: false)
    }

    /// Any other picture, at once: the starters and everything drawn so far.
    func showRandom(animated: Bool = true) {
        let pool = (Self.starters + gallery.filter(\.seen)).filter { $0.file != current?.file }.shuffled()
        for picture in pool where show(picture, animated: animated) { return }
    }

    /// Tony's real photo, sent along with every drawing so the cartoon always looks like him.
    private static let photo: Data? = {
        if let url = Bundle.main.url(forResource: "tony", withExtension: "jpg"), let data = try? Data(contentsOf: url) { return data }
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/tony.jpg")
        return try? Data(contentsOf: dev)
    }()

    /// Once per launch, out of sight: choose the best image model there is today, pick a real recent
    /// purchase, and draw the picture that will be waiting the next time the app opens.
    func prepareNext(highlights: [Highlight]) async {
        lastHighlights = highlights
        guard CloudAI.isEnabled, !preparedThisLaunch, !isGenerating, !highlights.isEmpty, let photo = Self.photo else { return }
        preparedThisLaunch = true
        isGenerating = true
        defer { isGenerating = false }

        var saved = gallery
        let lately = Set(saved.suffix(8).compactMap(\.merchant))
        let recent = Array(highlights.prefix(15))
        let pick = recent.filter { !lately.contains($0.merchant) }.randomElement() ?? recent.randomElement()!
        async let chosen = CloudImage.bestModel()
        async let planned = CloudImage.scene(merchant: pick.merchant, category: pick.category.displayName, amount: pick.amount)
        let model = await chosen
        guard let scene = await planned else { preparedThisLaunch = false; return }
        // A style none of the last several pictures used.
        let usedLately = Set(saved.suffix(7).compactMap(\.style))
        let style = CloudImage.styles.filter { !usedLately.contains($0.id) }.randomElement() ?? CloudImage.styles.randomElement()!
        var drawn = await CloudImage.draw(scene: scene.scene, photo: photo, model: model, style: style.look), used = model
        if drawn == nil, model != CloudImage.defaultModel {
            drawn = await CloudImage.draw(scene: scene.scene, photo: photo, model: CloudImage.defaultModel, style: style.look); used = CloudImage.defaultModel
        }
        guard let drawn, NSImage(data: drawn) != nil else { preparedThisLaunch = false; return }

        let file = "tony-\(Int(Date.now.timeIntervalSince1970)).png"
        try? drawn.write(to: folder.appendingPathComponent(file))
        saved.append(Picture(file: file, caption: scene.caption, merchant: pick.merchant,
                             date: pick.date.map { DateParsing.iso.string(from: $0) }, seen: false, model: used, style: style.id))
        // Keep the last thirty; older ones go, with their files.
        while saved.count > 30 { try? FileManager.default.removeItem(at: folder.appendingPathComponent(saved.removeFirst().file)) }
        gallery = saved
        if ProcessInfo.processInfo.environment["TONY_AWARDS_SNAPSHOT"] != nil {
            print("DEBUG PICTURE next: \(pick.merchant) [\(used), \(style.id)] \(scene.caption)\n  scene: \(scene.scene)")
        }
    }
}

// MARK: - The banner on the Overview

struct DailyTonyCard: View {
    private var store: BudgetStore { .shared }
    @State private var daily = DailyTony.shared

    var body: some View {
        Color.black
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
            .overlay {
                // Darkens the bottom third so the words read over any picture.
                VStack(spacing: 0) {
                    Color.clear
                    LinearGradient(colors: [.black.opacity(0), .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                }
            }
            .overlay(alignment: .bottom) {
                HStack(alignment: .bottom, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("Today's Nominee · \(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))", systemImage: "star.circle.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(Color(red: 1, green: 0.84, blue: 0.4))
                            .textCase(.uppercase)
                        Text(daily.caption.isEmpty ? "Hi, Tony." : daily.caption)
                            .font(.system(size: 28, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .fixedSize(horizontal: false, vertical: true)
                            .contentTransition(.opacity)
                        if let source = daily.source {
                            // The real purchase behind the picture: this is what makes it land.
                            Label(source, systemImage: "receipt")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.white.opacity(0.85))
                                .contentTransition(.opacity)
                        }
                    }
                    Spacer(minLength: 0)
                    Button {
                        daily.showRandom()
                    } label: {
                        Label("Another One", systemImage: "wand.and.sparkles")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.large)
                }
                .padding(24)
            }
            .clipShape(.rect(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.12), radius: 14, y: 5)
            // Once the statements are in, quietly get the next picture ready.
            .task(id: "\(store.hasLoadedTransactions)-\(store.isImporting)-\(store.recentHighlights().first?.merchant ?? "")") {
                guard store.hasLoadedTransactions, !store.isImporting else { return }
                await daily.prepareNext(highlights: store.recentHighlights())
            }
    }
}
