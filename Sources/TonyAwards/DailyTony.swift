import SwiftUI
import AppKit
import ImagePlayground
import FoundationModels

/// Each day, caricature Tony shows up holding something he recently bought, in a matching scene.
/// Apple's on-device Image Playground draws only the prop and the backdrop; Tony stays exactly as drawn.
@MainActor @Observable
final class DailyTony {
    static let shared = DailyTony()

    private(set) var image: NSImage?
    private(set) var caption: String = ""
    private(set) var isGenerating = false
    private(set) var isAIImage = false

    let headshot: NSImage? = Bundle.main.url(forResource: "tony", withExtension: "jpg").flatMap(NSImage.init(contentsOf:))
        ?? Bundle.module_tonyFallback

    /// Cartoon Tony: baked in at build time, or made on first launch.
    private(set) var cartoon: NSImage? = Bundle.main.url(forResource: "tony-cartoon", withExtension: "png").flatMap(NSImage.init(contentsOf:))
    var avatar: NSImage? { croppedAvatar(cartoon ?? headshot) }

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
    private var loadedKey: String?
    private var lastHighlights: [Highlight] = []

    /// Image Playground refuses to draw while the app is in the background; try again when Tony comes back.
    func retryIfNeeded() {
        guard loadedKey != todayKey || CloudAI.isEnabled, !isGenerating, !lastHighlights.isEmpty else { return }
        let highlights = lastHighlights
        Task { await loadToday(highlights: highlights) }
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

    // MARK: The cloud picture: Tony himself, doing what he just did

    /// What the picture is about ("Dunkin' · Thursday"), shown under it.
    private(set) var source: String?
    /// True while a picture is being made the slow, on-device way (which shows a progress note).
    /// Cloud pictures are made out of sight and simply appear.
    private(set) var showsProgress = false

    private struct Latest: Codable {
        var file: String
        var caption: String
        var source: String
        var merchant: String
        /// The newest purchase when this was drawn: when something newer arrives, draw again.
        var basis: String
        var day: String
    }
    private var latestFile: URL { folder.appendingPathComponent("latest.json") }
    private var latest: Latest? {
        (try? Data(contentsOf: latestFile)).flatMap { try? JSONDecoder().decode(Latest.self, from: $0) }
    }

    private func basis(_ highlights: [Highlight]) -> String {
        guard let newest = highlights.first else { return "" }
        return "\(newest.merchant)|\(newest.date.map { DateParsing.iso.string(from: $0) } ?? "")"
    }

    /// Shows the last picture at once, then (out of sight) draws a new one if there's a new day or a
    /// newer purchase, and swaps it in. Returns false if the cloud couldn't do it.
    private func loadFromCloud(highlights: [Highlight], force: Bool) async -> Bool {
        let saved = latest
        if image == nil || !isAIImage, let saved, let picture = NSImage(contentsOf: folder.appendingPathComponent(saved.file)) {
            image = picture; caption = saved.caption; source = saved.source; isAIImage = true
        }
        guard !highlights.isEmpty else { return saved != nil }
        let current = basis(highlights)
        if !force, let saved, saved.basis == current, saved.day == todayKey { return true }
        guard !isGenerating, let cartoon, let reference = Self.referencePNG(cartoon) else { return saved != nil }
        isGenerating = true
        defer { isGenerating = false }
        cleanUpOldDays()

        // A purchase from the last few days, picked at random, and not the one already showing.
        let recent = Array(highlights.prefix(6))
        let pick = recent.filter { $0.merchant != saved?.merchant }.randomElement() ?? recent[0]
        let when = pick.date.map { date -> String in
            let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: date), to: Calendar.current.startOfDay(for: .now)).day ?? 0
            return days <= 0 ? "today" : days == 1 ? "yesterday" : days < 7 ? "on \(date.formatted(.dateTime.weekday(.wide)))" : "on \(date.formatted(.dateTime.month(.wide).day()))"
        } ?? "recently"
        guard let scene = await CloudImage.scene(merchant: pick.merchant, category: pick.category.displayName, amount: pick.amount, when: when),
              let data = await CloudImage.draw(scene: scene.scene, reference: reference),
              let picture = NSImage(data: data) else { return saved != nil || image != nil && isAIImage }

        let file = "tony-\(Int(Date.now.timeIntervalSince1970)).png"
        try? data.write(to: folder.appendingPathComponent(file))
        let label = "\(pick.merchant) · \(when.replacingOccurrences(of: "on ", with: "").capitalized)"
        let record = Latest(file: file, caption: scene.caption, source: label, merchant: pick.merchant, basis: current, day: todayKey)
        if let encoded = try? JSONEncoder().encode(record) { try? encoded.write(to: latestFile, options: .atomic) }
        withAnimation(.easeInOut(duration: 0.8)) {
            image = picture; caption = scene.caption; source = label; isAIImage = true
        }
        loadedKey = todayKey
        return true
    }

    struct Plan {
        let highlight: Highlight?
        let prop: String
        let backdrop: String
    }

    /// Prop + backdrop for each category, used when Apple Intelligence can't suggest one.
    private static let categoryIdeas: [Category: (prop: String, backdrop: String)] = [
        .dining: ("a big slice of pepperoni pizza", "a cozy Italian restaurant with string lights"),
        .groceries: ("a paper grocery bag overflowing with vegetables and bread", "a sunny farmers market"),
        .shopping: ("a stack of colorful shopping bags", "a bright city shopping street"),
        .transportation: ("a shiny red toy convertible car", "a coastal road at sunset"),
        .travel: ("a vintage suitcase covered in travel stickers", "a tropical beach with palm trees"),
        .subscriptions: ("a big striped bucket of popcorn", "a cozy living room with a big TV"),
        .entertainment: ("two golden theater tickets", "a theater stage with red velvet curtains"),
        .home: ("a red toolbox", "a cozy house porch with flowers"),
        .health: ("a pair of blue dumbbells", "a bright modern gym"),
        .bills: ("a glowing light bulb", "a city skyline at night"),
        .gifts: ("a wrapped gift box with a big bow", "a festive party room with balloons"),
        .personal: ("a fluffy white towel and a spa candle", "a calm spa with plants"),
        .fees: ("a pink piggy bank", "a grand old bank lobby"),
        .other: ("a golden trophy", "a theater stage with red velvet curtains"),
    ]

    private func makePlan(_ highlights: [Highlight], surprise: Bool) async -> Plan {
        let day = Calendar.current.ordinality(of: .day, in: .era, for: .now) ?? 0
        let pick = surprise ? highlights.randomElement() : (highlights.isEmpty ? nil : highlights[day % highlights.count])
        let fallback = Self.categoryIdeas[pick?.category ?? .other] ?? Self.categoryIdeas[.other]!
        guard let pick, SystemLanguageModel.default.isAvailable, let schema = AISchemas.dailyPlan else {
            return Plan(highlight: pick, prop: fallback.prop, backdrop: fallback.backdrop)
        }
        let session = LanguageModelSession(instructions: """
        You plan a fun cartoon picture for a budgeting app. Given a purchase, choose:
        prop: one simple physical object that represents what was bought, that a person could hold up in one hand (e.g. a cup of coffee, a slice of pizza, a television remote, a shopping bag).
        backdrop: an empty place connected to the purchase, with no people (e.g. a cozy coffee shop, an electronics store).
        Keep each to a few plain words. Never mention people, brands or logos.
        """)
        if let reply = try? await session.respond(to: "Purchase: \(pick.merchant) (\(pick.category.displayName))", schema: schema,
                                                  options: GenerationOptions(temperature: 0.7, maximumResponseTokens: 80)),
           let prop = try? reply.content.value(String.self, forProperty: "prop"),
           let backdrop = try? reply.content.value(String.self, forProperty: "backdrop"),
           !prop.isEmpty, !backdrop.isEmpty {
            return Plan(highlight: pick, prop: prop, backdrop: backdrop)
        }
        return Plan(highlight: pick, prop: fallback.prop, backdrop: fallback.backdrop)
    }

    // MARK: Loading

    func loadToday(highlights: [Highlight], force: Bool = false) async {
        // With a cloud key, Tony is drawn doing what he actually just did. No waiting screen.
        if CloudAI.isEnabled {
            lastHighlights = highlights
            if await loadFromCloud(highlights: highlights, force: force) { return }
        }
        guard !isGenerating, force || loadedKey != todayKey else { return }
        showsProgress = true
        defer { showsProgress = false }

        if !force, let cached = NSImage(contentsOf: imageFile) {
            image = cached
            isAIImage = true
            caption = (try? String(contentsOf: captionFile, encoding: .utf8)) ?? greeting
            loadedKey = todayKey
            return
        }

        lastHighlights = highlights
        isGenerating = true
        defer { isGenerating = false }
        cleanUpOldDays()

        // Apple's on-device models work best one at a time: let category suggestions finish first.
        for _ in 0..<120 where BudgetStore.shared.isSuggesting { try? await Task.sleep(for: .milliseconds(500)) }

        let plan = await makePlan(highlights, surprise: force)
        let category = plan.highlight?.category ?? .other
        // Apple's image model only draws things it's good at: an object and an empty scene.
        let backdrop = await generate("\(plan.backdrop), empty, no people, wide view")
        let prop = await generate("\(plan.prop), single object, centered, plain white background")

        guard let caricature = cartoon ?? headshot,
              let composed = Compositor.compose(caricature: caricature, backdrop: backdrop, prop: prop,
                                                propSymbol: category.symbol, tint: NSColor(category.color)) else {
            image = avatar
            isAIImage = false
            return
        }
        image = composed
        isAIImage = backdrop != nil || prop != nil
        // Only lock in today's picture once it features a real purchase.
        let final = isAIImage && plan.highlight != nil
        if final {
            loadedKey = todayKey
            try? IconRenderer.png(composed)?.write(to: imageFile)
        }
        caption = await makeCaption(plan)
        if final { try? caption.write(to: captionFile, atomically: true, encoding: .utf8) }
    }

    private func generate(_ text: String) async -> NSImage? {
        do {
            let creator = try await ImageCreator()
            let style = [ImagePlaygroundStyle.illustration, .animation].first { creator.availableStyles.contains($0) } ?? .illustration
            for try await created in creator.images(for: [.text(text)], style: style, limit: 1) {
                return NSImage(cgImage: created.cgImage, size: NSSize(width: created.cgImage.width, height: created.cgImage.height))
            }
        } catch {
            if ProcessInfo.processInfo.environment["TONY_AWARDS_SNAPSHOT"] != nil { print("DEBUG Daily Tony image error (\(text)): \(error)") }
        }
        return nil
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let part = hour < 12 ? "Good morning" : hour < 17 ? "Good afternoon" : "Good evening"
        return "\(part), Tony. The nominees are being announced…"
    }

    private func makeCaption(_ plan: Plan) async -> String {
        let fallback = plan.highlight.map { "Nominated for Best Supporting Role at \($0.merchant)." } ?? greeting
        if CloudAI.isEnabled {
            var facts = "Today's picture: Tony holding \(plan.prop) in \(plan.backdrop)."
            if let h = plan.highlight { facts += " It celebrates his recent purchase at \(h.merchant) (\(h.category.displayName))." }
            if let line = await CloudWriter.line(system: """
                You write today's nomination for The Tony Awards, a playful budgeting app made for Tony, a CPA.
                Write one witty awards-show nomination about what Tony is holding, at most 14 words. It must start with "Nominated for Best".
                Examples: Nominated for Best Coffee Run in a Leading Role. Nominated for Best Grocery Haul, Produce Division.
                Light accounting puns are welcome. Never be negative about spending. Reply with the nomination only, no quotes.
                """, facts: facts, maxTokens: 60, temperature: 1.0)?.replacingOccurrences(of: "*", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: "\" \n")), line.hasPrefix("Nominated"), line.count < 140 {
                return line
            }
        }
        guard SystemLanguageModel.default.isAvailable else { return fallback }
        let session = LanguageModelSession(instructions: """
        You write today's nomination for The Tony Awards, a playful budgeting app made for Tony, a CPA.
        Write one awards-show nomination about what Tony is holding, at most 14 words. It must start with "Nominated for Best".
        Examples: Nominated for Best Coffee Run in a Leading Role. Nominated for Best Grocery Haul, Produce Division.
        Light accounting puns are welcome. Never be negative about spending. Reply with the nomination only, no quotes.
        """)
        var facts = "Today's picture: Tony holding \(plan.prop) in \(plan.backdrop)."
        if let h = plan.highlight { facts += " It celebrates his recent purchase at \(h.merchant) (\(h.category.displayName))." }
        do {
            let prompt = facts
            guard let answer = await Timeout.run(45, { try? await session.respond(to: prompt, options: GenerationOptions(temperature: 0.9, maximumResponseTokens: 60)).content }) else { throw CancellationError() }
            let reply = (content: answer, ())
            let text = reply.content.replacingOccurrences(of: "*", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"")))
            return text.hasPrefix("Nominated") && text.count < 140 ? text : fallback
        } catch {
            return fallback
        }
    }

    private func cleanUpOldDays() {
        let cutoff = Date.now.addingTimeInterval(-14 * 24 * 3600)
        let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for url in items where !url.lastPathComponent.hasPrefix("cartoon") {
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .now
            if date < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }
}

private extension Bundle {
    /// When running unbundled during development, look next to the package.
    static var module_tonyFallback: NSImage? {
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/tony.jpg")
        return NSImage(contentsOf: dev)
    }
}

// MARK: - The card on the Overview

struct DailyTonyCard: View {
    @Environment(BudgetStore.self) private var store
    @State private var daily = DailyTony.shared

    var body: some View {
        Card(padding: 0) {
            HStack(spacing: 0) {
                ZStack {
                    if let image = daily.image ?? daily.cartoon ?? daily.avatar {
                        // A new picture simply fades in over the old one: no spinner, no waiting.
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .blur(radius: daily.showsProgress ? 12 : 0)
                            .saturation(daily.showsProgress ? 0.3 : 1)
                            .id(ObjectIdentifier(image))
                            .transition(.opacity)
                    }
                    if daily.showsProgress {
                        VStack(spacing: 8) {
                            ProgressView().controlSize(.large)
                            Text("Drawing today's Tony…").font(.callout.weight(.medium))
                        }
                        .padding(14)
                        .glassEffect(.regular, in: .rect(cornerRadius: 14))
                    }
                }
                .frame(width: 230, height: 230)
                .clipped()
                .animation(.easeInOut(duration: 0.6), value: daily.showsProgress)

                VStack(alignment: .leading, spacing: 10) {
                    Label("Today's Nominee · \(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()))", systemImage: "star.circle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(Color(red: 0.75, green: 0.55, blue: 0.12))
                        .textCase(.uppercase)
                    Text(daily.caption.isEmpty ? "Hi, Tony." : daily.caption)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                    Spacer(minLength: 0)
                    HStack(spacing: 12) {
                        if let source = daily.source {
                            // The real purchase behind the picture: this is what makes it land.
                            Label(source, systemImage: "receipt")
                                .font(.callout.weight(.medium))
                                .foregroundStyle(.secondary)
                                .contentTransition(.opacity)
                        } else if daily.isAIImage {
                            Label("Made on this Mac by Apple Intelligence", systemImage: "apple.intelligence")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            Task { await load(force: true) }
                        } label: {
                            Label("Another One", systemImage: "wand.and.sparkles")
                        }
                        .buttonStyle(.glass)
                        .disabled(daily.isGenerating)
                    }
                }
                .padding(22)
            }
        }
        // A newer purchase arriving (a statement just added itself) is a reason for a new picture.
        .task(id: "\(store.recentHighlights().count)-\(store.recentHighlights().first?.merchant ?? "")-\(store.isImporting)") {
            guard !store.isImporting else { return }
            await load(force: false)
        }
    }

    private func load(force: Bool) async {
        guard store.hasLoadedTransactions || store.accounts.isEmpty else { return }
        await daily.loadToday(highlights: store.recentHighlights(), force: force)
    }
}
