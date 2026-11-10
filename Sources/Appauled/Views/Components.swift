import SwiftUI
import AppKit

// MARK: - Look & feel

/// One accent for the whole app: awards gold. Category colors do the rest.
/// The look, in one place. The sensibility is Japanese: paper and ink, one warm accent, colors
/// taken from traditional dyes, space left empty on purpose (ma), and nothing that shouts.
enum Theme {
    private static func adaptive(_ light: (CGFloat, CGFloat, CGFloat), _ dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
        })
    }
    /// Unbleached paper (kinari) by day, sumi ink by night.
    static let paper = adaptive((0.969, 0.957, 0.929), (0.098, 0.094, 0.090))
    /// A sheet laid on the paper: a shade lighter than what it rests on.
    static let sheet = adaptive((1.0, 0.995, 0.982), (0.145, 0.139, 0.133))
    /// Yamabuki gold: deep enough for white text on prominent buttons, in light and dark mode.
    static let accent = Color(red: 0.74, green: 0.49, blue: 0.06)
    static let goldLight = Color(red: 0.98, green: 0.82, blue: 0.36)
    static let goldDeep = Color(red: 0.78, green: 0.56, blue: 0.13)
    static let gold = LinearGradient(colors: [goldLight, goldDeep], startPoint: .top, endPoint: .bottom)
    static let curtain = LinearGradient(colors: [Color(red: 0.62, green: 0.08, blue: 0.14), Color(red: 0.36, green: 0.03, blue: 0.08)],
                                        startPoint: .top, endPoint: .bottom)
    /// Tokiwa, the green of pines: money in, things that went well.
    static let good = adaptive((0.20, 0.50, 0.37), (0.42, 0.72, 0.57))
    /// Kaki, persimmon: worth a look, never an alarm.
    static let caution = Color(red: 0.84, green: 0.45, blue: 0.20)
    /// Akane, madder red: money consumed, and the rare real warning.
    static let spent = Color(red: 0.78, green: 0.33, blue: 0.34)
    static let hairline = Color.primary.opacity(0.09)
}

struct Card<Content: View>: View {
    var padding: CGFloat = 20
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            // A sheet on paper: a hairline edge and the faintest lift, no heavy shadow.
            .background(Theme.sheet, in: .rect(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.hairline)
            }
            .shadow(color: .black.opacity(0.025), radius: 6, y: 2)
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3.weight(.semibold))
            if let subtitle {
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Tony

/// Tony's face in a circle.
struct TonyAvatar: View {
    var size: CGFloat = 32

    var body: some View {
        Group {
            if let photo = DailyPicture.shared.avatar {
                Image(nsImage: photo).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Theme.gold, lineWidth: max(1.5, size / 22)))
        .shadow(color: .black.opacity(0.15), radius: size / 12, y: size / 30)
    }
}

/// Shown when the model can't be used at all. Says what happened, that nothing is lost, and what to do.
struct CloudTroubleBanner: View {
    private var store: BudgetStore { .shared }
    @State private var status = CloudStatus.shared

    var body: some View {
        if let reason = status.stopped, status.hasKey {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "wand.and.stars.inverse").font(.title3).foregroundStyle(Theme.caution)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Smarter AI has paused").font(.callout.weight(.semibold))
                    Text("\(reason) Everything already read is safe. Places it couldn't sort are waiting in Double-Check, and the rest picks up where it left off.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Try Again") { store.cloudBecameAvailable() }
                SettingsLink { Text("Settings") }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Theme.caution.opacity(0.09), in: .rect(cornerRadius: 12, style: .continuous))
        }
    }
}

/// Tony and Paul together: the app's two stars, wherever it introduces itself.
struct CastAvatars: View {
    var size: CGFloat = 38

    var body: some View {
        HStack(spacing: -size * 0.28) {
            TonyAvatar(size: size)
            if let paul = DailyPicture.shared.paulAvatar {
                Image(nsImage: paul).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Theme.gold, lineWidth: max(1.5, size / 22)))
                    .shadow(color: .black.opacity(0.15), radius: size / 12, y: size / 30)
            }
        }
    }
}

/// The whole caricature, cut out from its background so it can stand on any screen.
@MainActor @Observable
final class TonyArt {
    static let shared = TonyArt()
    private(set) var figure: NSImage?
    @ObservationIgnored private var started = false

    func prepare() {
        guard !started, let cartoon = DailyPicture.shared.cartoon,
              let cg = cartoon.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        started = true
        Task.detached(priority: .userInitiated) {
            guard let cut = Compositor.cutout(cg, cropToSubject: true) else { return }
            let image = NSImage(cgImage: cut, size: NSSize(width: cut.width, height: cut.height))
            await MainActor.run { withAnimation(.easeOut(duration: 0.3)) { self.figure = image } }
        }
    }
}

struct TonyFigure: View {
    var height: CGFloat = 180
    @State private var art = TonyArt.shared

    var body: some View {
        Group {
            if let figure = art.figure {
                Image(nsImage: figure).resizable().aspectRatio(contentMode: .fit)
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 6)
            } else {
                TonyAvatar(size: height * 0.6)
            }
        }
        .frame(height: height)
        .onAppear { art.prepare() }
        .accessibilityLabel("Tony")
    }
}

/// Tony with something to say: used for every empty screen.
/// A small illustration of Tony and Paul for one moment in the app (nothing to check, no trips yet…).
/// The pictures ship with the app in Resources/Art.
struct SpotArt: View {
    let name: String
    var height: CGFloat = 200

    @MainActor private static var cache: [String: NSImage] = [:]
    @MainActor static func image(_ name: String) -> NSImage? {
        if let hit = cache[name] { return hit }
        var url = Bundle.main.resourceURL?.appendingPathComponent("Art/\(name).jpg")
        if url.map({ FileManager.default.fileExists(atPath: $0.path) }) != true {
            url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().appendingPathComponent("Resources/Art/\(name).jpg")
        }
        guard let url, let image = NSImage(contentsOf: url) else { return nil }
        cache[name] = image
        return image
    }

    var body: some View {
        if let image = Self.image(name) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: height)
                .clipShape(.rect(cornerRadius: height * 0.11, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
                .accessibilityHidden(true)
        } else {
            TonyFigure(height: height)
        }
    }
}

struct TonySays<Actions: View>: View {
    let title: String
    let message: String
    var figureHeight: CGFloat = 190
    /// The illustration for this moment; without one, Tony stands in.
    var art: String? = nil
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: 14) {
            if let art { SpotArt(name: art, height: figureHeight + 30) } else { TonyFigure(height: figureHeight) }
            Text(title).font(.system(size: 26, weight: .bold, design: .serif))
            Text(message)
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            actions.controlSize(.large).padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

extension TonySays where Actions == EmptyView {
    init(title: String, message: String, figureHeight: CGFloat = 190, art: String? = nil) {
        self.init(title: title, message: message, figureHeight: figureHeight, art: art) { EmptyView() }
    }
}

// MARK: - Categories

struct CategoryIcon: View {
    let category: Category
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(category.color)
            Image(systemName: category.symbol)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

/// The list of categories, for any menu.
struct CategoryChoices: View {
    private var store: BudgetStore { .shared }   // not from the environment: menus and sheets don't always pass it down
    let choose: (Category) -> Void

    var body: some View {
        Section("Spending") {
            ForEach(Category.spendingCases) { c in
                Button { choose(c) } label: { Label(c.displayName, systemImage: c.symbol) }
            }
        }
        Section("Not spending") {
            ForEach([Category.transfer, .income]) { c in
                Button { choose(c) } label: { Label(c.displayName, systemImage: c.symbol) }
            }
        }
        Section("Investments & taxes") {
            ForEach(Category.investmentCases + [.taxes]) { c in
                Button { choose(c) } label: { Label(c.displayName, systemImage: c.symbol) }
            }
        }
        Section {
            Button { store.newCategory(then: choose) } label: { Label("New Category…", systemImage: "plus") }
        }
    }
}

/// A tappable pill showing a category; tapping picks another.
struct CategoryPill: View {
    let category: Category?
    var sparkle = false
    let choose: (Category) -> Void

    var body: some View {
        Menu {
            CategoryChoices(choose: choose)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: (category ?? .unsorted).symbol)
                    .font(.caption.weight(.bold))
                    .foregroundStyle((category ?? .unsorted).color)
                Text(category?.displayName ?? "Choose…")
                if sparkle {
                    Image(systemName: "sparkles").font(.caption2).foregroundStyle(Theme.accent)
                }
            }
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .fixedSize()
    }
}

// MARK: - Downloads

/// "We found a statement in your Downloads" — so Tony never needs Finder.
struct DownloadsBanner: View {
    @Environment(BudgetStore.self) private var store

    var body: some View {
        if !store.downloadCandidates.isEmpty {
            Card(padding: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("New in your Downloads", systemImage: "arrow.down.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.tint)
                        Spacer()
                        if store.downloadCandidates.count > 1 {
                            Button("Add All") { store.importAllDownloads() }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    ForEach(store.downloadCandidates, id: \.self) { url in
                        DownloadRow(url: url, prominent: store.downloadCandidates.count == 1)
                        if url != store.downloadCandidates.last { Divider() }
                    }
                }
            }
        }
    }
}

private struct DownloadRow: View {
    @Environment(BudgetStore.self) private var store
    let url: URL
    let prominent: Bool

    private var modified: Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: url.pathExtension.lowercased() == "pdf" ? "doc.richtext.fill" : "tablecells.fill")
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(url.lastPathComponent).font(.body.weight(.medium)).lineLimit(1)
                if let modified {
                    Text("Downloaded \(modified.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Not Now") { store.dismissDownload(url) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            if prominent {
                Button("Add") { store.importFiles([url]) }.buttonStyle(.borderedProminent)
            } else {
                Button("Add") { store.importFiles([url]) }.buttonStyle(.bordered)
            }
        }
    }
}
