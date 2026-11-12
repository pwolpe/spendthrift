import SwiftUI

/// The picture at the head of the Ask pane. It changes like the rest of the app, without costing the
/// opening anything: a new one is drawn quietly while the app is in use (at most one a day) and put
/// away; the next time the app opens, the newest one on file is what hangs there. Nothing is drawn or
/// waited for at launch, and with no key the picture that ships with the app stays.
@MainActor @Observable
final class AskArt {
    static let shared = AskArt()

    /// The picture for this sitting: the newest on file when the app opened. It does not change mid-sitting.
    let current: URL?
    @ObservationIgnored private var drawing = false

    private static let folder: URL = {
        let dir = BudgetPaths().root.appendingPathComponent("Pictures/Ask", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// The pictures on file, newest first (their names carry the time they were drawn).
    private static func onFile() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("ask-") && $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private init() { current = Self.onFile().first }

    /// What the two of them might be up to while waiting for a question. One is picked at random.
    static let scenes = [
        "they host a late-night talk show, sharing a desk with a microphone and two mugs, a city skyline at night behind them, leaning in as if the next guest is a very interesting question",
        "they are a pair of detectives in a cluttered office, one holding a magnifying glass over a long curling paper tape from an adding machine, the other pinning notes to a corkboard strung with red thread",
        "they run a tiny roadside advice booth, elbows on the counter, a little bell and a jar of coins in front of them, waiting cheerfully for the next customer",
        "they are fortune tellers at a round table draped in velvet, peering into a crystal ball that glows with floating gold coins",
        "they are radio hosts in a cosy studio wearing big headphones around their necks, pointing at each other across two microphones mid-laugh",
        "they are explorers in a tent at night, bent over a huge map by lantern light, one tracing a route with a finger, the other holding a compass",
        "they are librarians at the front desk of a grand old library whose shelves are stacked with ledgers, one stamping a card, the other carrying a teetering pile of books",
        "they are scientists in a laboratory of bubbling glassware, examining a single gold coin with tweezers under a bright lamp",
        "they are ship's navigators on the bridge of an old steamer, one at the wheel, one at a brass telescope, gulls overhead",
        "they are chefs at a kitchen pass, tasting from the same pot with two spoons and raising their eyebrows at each other",
        "they are astronauts at a control console, visors up, watching a screen full of friendly blinking lights, one with a finger over a big button",
        "they are market traders behind a stall piled with fruit, weighing a single orange on brass scales with great seriousness",
    ]

    /// Draws tomorrow's picture if today has none. Called once the app is up and idle; never at launch.
    func prepareNext() async {
        let env = ProcessInfo.processInfo.environment
        guard !drawing, CloudAI.isEnabled, env["SPENDTHRIFT_SNAPSHOT"] == nil, !Launch.enabled, let tony = DailyPicture.photo else { return }
        let files = Self.onFile()
        if let newest = files.first, let stamp = Double(newest.deletingPathExtension().lastPathComponent.dropFirst(4)),
           Date.now.timeIntervalSince1970 - stamp < 20 * 3_600 { return }
        drawing = true
        defer { drawing = false }
        var cast: [(name: String, photo: Data)] = [("Tony", tony)]
        if let paul = DailyPicture.paulPhoto { cast.append(("Paul", paul)) }
        let scene = Self.scenes.randomElement()!, style = CloudImage.styles.randomElement()!
        let told = cast.count == 1 ? scene.replacingOccurrences(of: "they are", with: "he is one of").replacingOccurrences(of: "they ", with: "he and an unseen partner ") : scene
        let model = await CloudImage.bestModel()
        guard let data = await CloudImage.draw(scene: told, cast: cast, model: model, style: style.look, receipt: nil, shape: "4:3"),
              NSImage(data: data) != nil else { return }
        try? data.write(to: Self.folder.appendingPathComponent("ask-\(Int(Date.now.timeIntervalSince1970)).png"), options: .atomic)
        // A handful are kept; older ones go.
        for old in Self.onFile().dropFirst(6) { try? FileManager.default.removeItem(at: old) }
    }
}

/// The Ask pane's picture: the newest one drawn, decoded off the main thread, or the one that ships with the app.
struct AskArtView: View {
    var height: CGFloat = 150
    @State private var picture: NSImage?

    var body: some View {
        if let url = AskArt.shared.current, ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] == nil {
            ZStack {
                if let picture {
                    Image(nsImage: picture).resizable().aspectRatio(contentMode: .fit)
                        .clipShape(.rect(cornerRadius: height * 0.11, style: .continuous))
                        .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
                        .transition(.opacity)
                }
            }
            .frame(width: height * (Decoding.aspect(of: url) ?? 4.0 / 3.0), height: height)
            .accessibilityHidden(true)
            .task {
                let pixels = Decoding.pixels(for: height)
                guard let small = await Task.detached(priority: .userInitiated, operation: { Decoding.thumbnail(at: url, maxPixel: pixels) }).value else { return }
                withAnimation(.easeOut(duration: 0.2)) { picture = NSImage(cgImage: small, size: NSSize(width: small.width, height: small.height)) }
            }
        } else {
            SpotArt(name: "ask", height: height)
        }
    }
}
