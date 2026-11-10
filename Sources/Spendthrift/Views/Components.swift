import SwiftUI
import AppKit

// MARK: - Look & feel

/// The look, in one place: paper and ink. The app is named for someone who spends freely, and its
/// emblem is the till receipt: slips of paper with a torn edge, dashed rules, dotted leaders and
/// typewriter totals. One accent, the blue-black of receipt ink; colors from traditional dyes do the
/// rest; space is left empty on purpose and nothing shouts.
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
    /// Receipt ink: the blue-black a till prints in. The one accent, for buttons, links and emphasis.
    static let accent = adaptive((0.17, 0.26, 0.49), (0.50, 0.61, 0.93))
    /// Brass, kept for one meaning only: money invested, which is still yours.
    static let goldLight = Color(red: 0.98, green: 0.82, blue: 0.36)
    static let goldDeep = Color(red: 0.78, green: 0.56, blue: 0.13)
    static let gold = LinearGradient(colors: [goldLight, goldDeep], startPoint: .top, endPoint: .bottom)
    /// Tokiwa, the green of pines: money in, things that went well.
    static let good = adaptive((0.20, 0.50, 0.37), (0.42, 0.72, 0.57))
    /// Kaki, persimmon: worth a look, never an alarm.
    static let caution = Color(red: 0.84, green: 0.45, blue: 0.20)
    /// Akane, madder red: money consumed, and the rare real warning.
    static let spent = Color(red: 0.78, green: 0.33, blue: 0.34)
    static let hairline = Color.primary.opacity(0.09)
    /// The same ink at full strength in light and dark: for fills that carry white text.
    static let inkFill = Color(red: 0.20, green: 0.30, blue: 0.58)
    /// Typewriter figures, for anything printed on a receipt.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .monospaced) }
}

// MARK: - The receipt

/// A slip of till paper: square at the top, torn in a zigzag along the bottom.
struct ReceiptShape: InsettableShape {
    var tooth: CGFloat = 7
    var inset: CGFloat = 0

    func inset(by amount: CGFloat) -> ReceiptShape { ReceiptShape(tooth: tooth, inset: inset + amount) }

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: inset, dy: inset)
        var path = Path()
        let corner: CGFloat = 3
        path.move(to: CGPoint(x: r.minX, y: r.minY + corner))
        path.addQuadCurve(to: CGPoint(x: r.minX + corner, y: r.minY), control: CGPoint(x: r.minX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX - corner, y: r.minY))
        path.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + corner), control: CGPoint(x: r.maxX, y: r.minY))
        path.addLine(to: CGPoint(x: r.maxX, y: r.maxY - tooth))
        // Whole teeth only, so the tear starts and ends at the same height.
        let count = max(4, Int((r.width / (tooth * 1.6)).rounded()))
        let step = r.width / CGFloat(count)
        for i in 0..<count {
            let x = r.maxX - CGFloat(i) * step
            path.addLine(to: CGPoint(x: x - step / 2, y: r.maxY))
            path.addLine(to: CGPoint(x: x - step, y: r.maxY - tooth))
        }
        path.closeSubpath()
        return path
    }
}

/// Anything printed on a slip of receipt paper.
struct ReceiptPaper<Content: View>: View {
    var padding: CGFloat = 18
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.sheet, in: ReceiptShape())
            .overlay { ReceiptShape().strokeBorder(Theme.hairline) }
            .shadow(color: .black.opacity(0.06), radius: 7, y: 3)
    }
}

/// The dashed rule a till prints between sections.
struct ReceiptRule: View {
    var body: some View {
        Line().stroke(Color.primary.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [4, 3])).frame(height: 1)
    }
    private struct Line: Shape {
        func path(in rect: CGRect) -> Path { Path { $0.move(to: CGPoint(x: rect.minX, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) } }
    }
}

/// One printed line: what it is on the left, dots, the figure on the right.
struct ReceiptLine<Label: View>: View {
    var value: String
    var valueColor: Color = .primary
    var bold = false
    @ViewBuilder var label: Label

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            label.layoutPriority(1)
            Dots().stroke(Color.primary.opacity(0.25), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [0.1, 4.5]))
                .frame(height: 1).frame(minWidth: 12)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 1 }
            Text(value).font(Theme.mono(13, bold ? .bold : .medium)).foregroundStyle(valueColor).lineLimit(1).layoutPriority(2)
        }
    }
    private struct Dots: Shape {
        func path(in rect: CGRect) -> Path { Path { $0.move(to: CGPoint(x: rect.minX, y: rect.midY)); $0.addLine(to: CGPoint(x: rect.maxX, y: rect.midY)) } }
    }
}

extension ReceiptLine where Label == Text {
    init(_ title: String, value: String, valueColor: Color = .primary, bold: Bool = false) {
        self.init(value: value, valueColor: valueColor, bold: bold) { Text(title) }
    }
}

/// A rubber stamp, thumped onto the page when something is settled: TIED OUT, WITHIN MEANS, FILED.
/// It lands in a fifth of a second and then just sits there; nothing waits on it.
struct Stamp: View {
    let text: String
    var color: Color = Theme.good
    var size: CGFloat = 13
    var angle: Double = -8
    @State private var landed = false

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .heavy, design: .monospaced))
            .tracking(size * 0.14)
            .foregroundStyle(color)
            .padding(.horizontal, size * 0.75)
            .padding(.vertical, size * 0.38)
            .overlay { RoundedRectangle(cornerRadius: size * 0.34, style: .continuous).strokeBorder(color, lineWidth: max(1.5, size / 6)) }
            .overlay { RoundedRectangle(cornerRadius: size * 0.2, style: .continuous).strokeBorder(color.opacity(0.55), lineWidth: 0.75).padding(size * 0.2) }
            .opacity(landed ? 0.82 : 0)
            .scaleEffect(landed ? 1 : 1.9)
            .rotationEffect(.degrees(angle))
            .onAppear { withAnimation(.spring(response: 0.22, dampingFraction: 0.55)) { landed = true } }
            .accessibilityLabel(text.capitalized)
            .allowsHitTesting(false)
    }
}

/// The app's mark: a little receipt, slightly askew, with a few printed lines and a total.
struct ReceiptMark: View {
    var size: CGFloat = 30

    var body: some View {
        let w = size * 0.72
        ReceiptShape(tooth: size * 0.11)
            .fill(Theme.sheet)
            .overlay { ReceiptShape(tooth: size * 0.11).strokeBorder(Theme.accent.opacity(0.55), lineWidth: max(1, size / 26)) }
            .overlay(alignment: .top) {
                VStack(alignment: .leading, spacing: size * 0.085) {
                    bar(w * 0.50, 0.9)
                    bar(w * 0.62, 0.35)
                    bar(w * 0.42, 0.35)
                    HStack(spacing: 0) { Spacer(minLength: 0); bar(w * 0.36, 0.9) }
                }
                .padding(.horizontal, w * 0.17)
                .padding(.top, size * 0.17)
            }
            .frame(width: w, height: size)
            .rotationEffect(.degrees(-7))
            .shadow(color: .black.opacity(0.10), radius: size / 14, y: size / 22)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }

    private func bar(_ width: CGFloat, _ strength: Double) -> some View {
        Capsule().fill(Theme.accent.opacity(strength)).frame(width: width, height: max(1.5, size * 0.065))
    }
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
        .faceRing(size)
    }
}

extension View {
    /// The same quiet edge on every face: a rim of paper, then a hairline.
    func faceRing(_ size: CGFloat) -> some View {
        self.overlay(Circle().strokeBorder(Theme.sheet, lineWidth: max(1.5, size / 16)))
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.75))
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
        HStack(spacing: -size * 0.24) {
            TonyAvatar(size: size)
            if let paul = DailyPicture.shared.paulAvatar {
                Image(nsImage: paul).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    .faceRing(size)
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

/// A small square scene of Tony and Paul, for the head of a page or a sheet: the playful stand-in
/// for what would otherwise be a plain portrait.
struct Vignette: View {
    let name: String
    var size: CGFloat = 76

    var body: some View {
        if let image = SpotArt.image(name) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(.rect(cornerRadius: size * 0.24, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75) }
                .shadow(color: .black.opacity(0.10), radius: size / 12, y: size / 30)
                .accessibilityHidden(true)
        } else {
            TonyAvatar(size: size)
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
