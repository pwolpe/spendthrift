import SwiftUI
import PDFKit
import AppKit

// MARK: - The Statements page: choose an account, then browse its originals

struct StatementsView: View {
    @Environment(BudgetStore.self) private var store
    /// The account whose statements are open; nil shows every account to choose from.
    /// Kept in `PageMemory`, so going to a charge and coming Back lands where you were.
    @State private var account: AccountChoice? = PageMemory.shared.statementsAccount
    @State private var selected: String? = PageMemory.shared.statementsSelected
    @State private var search = PageMemory.shared.statementsSearch
    /// False when rendered for a test snapshot.
    var scrolls = true

    /// An account, or the few files that belong to none.
    enum AccountChoice: Hashable { case account(UUID), loose }

    private func files(of choice: AccountChoice) -> [SourceFile] {
        switch choice {
        case .account(let id): store.sourceFiles.filter { $0.accountID == id }
        case .loose: store.sourceFiles.filter { s in s.accountID == nil || !store.accounts.contains { $0.id == s.accountID } }
        }
    }

    var body: some View {
        let all = store.sourceFiles
        Group {
            if all.isEmpty {
                EmptyState(title: "No originals kept yet",
                         message: "From this version on, every statement you add is kept exactly as it came, so any charge can be shown in its original. Drop your statements in once more (a whole folder is fine) and they'll all appear here. Nothing will be added twice.",
                         art: "missing") {
                    Button("Add Statements…") { store.presentOpenPanel() }.buttonStyle(.borderedProminent).controlSize(.large)
                }
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let account {
                browser(account)
            } else {
                chooser(all)
            }
        }
        .navigationTitle("Statements")
        .navigationSubtitle(all.isEmpty ? "" : (all.count == 1 ? "1 original" : "\(all.count) originals"))
        .onAppear { follow() }
        .onChange(of: store.statementFocus) { follow() }
        .onChange(of: account) { PageMemory.shared.statementsAccount = account }
        .onChange(of: selected) { PageMemory.shared.statementsSelected = selected }
        .onChange(of: search) { PageMemory.shared.statementsSearch = search }
    }

    /// Goes to the file that was asked for ("Open in Statements" on a charge).
    private func follow() {
        guard let wanted = store.statementFocus?.sourceID, let source = store.sourceFiles.first(where: { $0.id == wanted }) else { return }
        account = source.accountID.flatMap { id in store.accounts.contains { $0.id == id } ? .account(id) : nil } ?? .loose
        selected = wanted
    }

    private func open(_ choice: AccountChoice) {
        search = ""
        store.statementFocus = nil
        selected = files(of: choice).first?.id
        withAnimation(.snappy(duration: 0.25)) { account = choice }
    }

    // MARK: Choosing an account

    private func chooser(_ all: [SourceFile]) -> some View {
        // Accounts in the order of their newest statement.
        let accounts = store.accounts.filter { a in all.contains { $0.accountID == a.id } }
            .sorted { (files(of: .account($0.id)).first?.lastDate ?? "") > (files(of: .account($1.id)).first?.lastDate ?? "") }
        let loose = files(of: .loose)
        let missing = store.chargesWithoutOriginal
        return MaybeScroll(scrolls: scrolls) {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Statements").font(.system(size: 30, weight: .bold, design: .serif))
                    Text("Every statement exactly as it came from the bank. Choose an account to browse them.")
                        .font(.title3).foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                    ForEach(accounts) { a in
                        AccountTile(name: store.accountLabel(a.id), files: files(of: .account(a.id)),
                                    alsoCovered: Set((a.statementMonths ?? []).compactMap { Month(key: $0) }),
                                    missing: store.missingStatements.first { $0.accountID == a.id }?.months ?? []) { open(.account(a.id)) }
                    }
                    if !loose.isEmpty {
                        AccountTile(name: "Other files", files: loose, missing: []) { open(.loose) }
                    }
                }
                if missing > 0 {
                    Label("\(missing) older \(missing == 1 ? "charge has" : "charges have") no original here yet. Drop those statements in again and they'll be linked.",
                          systemImage: "doc.questionmark")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .padding(28)
            .frame(maxWidth: 1040, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: One account's statements

    private func browser(_ choice: AccountChoice) -> some View {
        let mine = files(of: choice)
        let shown = search.isEmpty ? mine : mine.filter {
            $0.name.localizedCaseInsensitiveContains(search) || $0.period.localizedCaseInsensitiveContains(search) || $0.monthTitle.localizedCaseInsensitiveContains(search)
        }
        let name: String = { if case .account(let id) = choice { return store.accountLabel(id) } else { return "Other files" } }()
        // A card's statements carry the card itself, and the way to its page.
        let card: Account? = { if case .account(let id) = choice { return store.accounts.first { $0.id == id && BudgetStore.isCard($0) } } else { return nil } }()
        let index = mine.firstIndex { $0.id == selected }
        func go(_ offset: Int) {
            guard let index, mine.indices.contains(index + offset) else { return }
            store.statementFocus = nil
            selected = mine[index + offset].id
        }
        return HStack(spacing: 0) {
            VStack(spacing: 0) {
                // Where you are, and the way back to the other accounts.
                VStack(alignment: .leading, spacing: 8) {
                    Button { withAnimation(.snappy(duration: 0.25)) { account = nil; store.statementFocus = nil } } label: {
                        Label("All Accounts", systemImage: "chevron.left").font(.callout)
                    }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
                    if let card {
                        Button { store.showAccount(card.id) } label: { CardFace(id: card.id, name: card.name, width: 150) }
                            .buttonStyle(.plain).help("What these statements add up to: this card's fees, credits and spending")
                            .padding(.vertical, 4)
                    }
                    Text(name).font(.system(size: 19, weight: .bold, design: .serif)).lineLimit(2)
                    Text(mine.count == 1 ? "1 statement" : "\(mine.count) statements")
                        .font(Theme.mono(10, .semibold)).tracking(1).foregroundStyle(.secondary).textCase(.uppercase)
                    if mine.count > 12 {
                        SearchField(prompt: "Month, year or file name", text: $search, large: false)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 10)
                ReceiptRule().padding(.horizontal, 14)

                // Newest first, a heading for each year.
                let years = Dictionary(grouping: shown) { String(($0.lastDate ?? "").prefix(4)) }
                List(selection: Binding(get: { selected }, set: { id in
                    // Choosing a file by hand lets go of the charge that was being pointed at.
                    if store.statementFocus?.sourceID != id { store.statementFocus = nil }
                    selected = id
                })) {
                    ForEach(years.keys.sorted(by: >), id: \.self) { year in
                        Section(year.isEmpty ? "Undated" : year) {
                            ForEach(years[year] ?? []) { StatementRow(source: $0).tag($0.id) }
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .overlay { if shown.isEmpty { ContentUnavailableView.search(text: search) } }
            }
            .frame(width: 280)
            Divider()
            if let source = mine.first(where: { $0.id == selected }) {
                let entry = store.statementFocus.flatMap { $0.sourceID == source.id ? $0.entryID : nil }.flatMap(store.entry)
                OriginalViewer(source: source, entry: entry,
                               newer: index.map { $0 > 0 } == true ? { go(-1) } : nil,
                               older: index.map { $0 < mine.count - 1 } == true ? { go(1) } : nil)
                    .id(source.id)
            } else {
                ContentUnavailableView("Choose a statement", systemImage: "doc.text.magnifyingglass")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

extension SourceFile {
    /// "October 2026" for a monthly statement; the dates themselves for an export that spans more.
    var monthTitle: String {
        guard let a = firstDate.flatMap({ DateParsing.parse($0, format: "yyyy-MM-dd") }),
              let b = lastDate.flatMap({ DateParsing.parse($0, format: "yyyy-MM-dd") }) else { return name }
        return b.timeIntervalSince(a) <= 45 * 86_400 ? Month(date: b).title : period
    }
    /// The months this file has lines in.
    var monthsCovered: Set<Month> {
        guard let a = firstDate.flatMap({ DateParsing.parse($0, format: "yyyy-MM-dd") }),
              let b = lastDate.flatMap({ DateParsing.parse($0, format: "yyyy-MM-dd") }) else { return [] }
        var out: Set<Month> = [], m = Month(date: a)
        let end = Month(date: b)
        while m <= end, out.count < 240 { out.insert(m); m = m.adding(1) }
        return out
    }
}

/// One account on the Statements page: what it is, how much is here, and whether any month is missing.
private struct AccountTile: View {
    let name: String
    /// Newest first.
    let files: [SourceFile]
    /// Months a statement says it covers even though nothing was bought in them.
    var alsoCovered: Set<Month> = []
    let missing: [Month]
    let open: () -> Void
    @State private var hovering = false

    private var isBank: Bool { name.localizedCaseInsensitiveContains("checking") || name.localizedCaseInsensitiveContains("savings") }

    var body: some View {
        let withCharges = files.reduce(into: Set<Month>()) { $0.formUnion($1.monthsCovered) }
        let last = withCharges.max(), first = withCharges.min()
        let covered = withCharges.union(alsoCovered)
        // Every month from the first statement to the last, a mark a month: filled where a statement covers it.
        // Years of history make it a fine barcode; a hole still shows.
        let strip: [Month] = (first.flatMap { f in last.map { l in Array(sequence(first: f) { $0 < l ? $0.adding(1) : nil }) } } ?? [])
        let kinds = Array(Set(files.map(\.kind))).sorted().joined(separator: ", ")
        Button(action: open) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: isBank ? "building.columns.fill" : "creditcard.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Theme.accent, in: .rect(cornerRadius: 11, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.system(size: 17, weight: .bold, design: .serif)).lineLimit(1).minimumScaleFactor(0.75)
                        Text("\(files.count) \(files.count == 1 ? "statement" : "statements") · \(kinds)")
                            .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.callout.weight(.semibold)).foregroundStyle(hovering ? Theme.accent : Color.secondary.opacity(0.5))
                }
                ReceiptRule()
                if let first, let last {
                    ReceiptLine(value: first == last ? last.title : "\(first.shortName) \(String(first.year)) to \(last.shortName) \(String(last.year))") {
                        Text("Covers").font(.callout)
                    }
                }
                if strip.count > 1 {
                    HStack(spacing: strip.count > 60 ? 0.5 : strip.count > 30 ? 1.5 : 3) {
                        ForEach(strip) { m in
                            RoundedRectangle(cornerRadius: strip.count > 30 ? 0.5 : 2)
                                .fill(covered.contains(m) ? Theme.accent.opacity(0.75) : (missing.contains(m) ? Theme.caution.opacity(0.8) : Color.primary.opacity(0.10)))
                                .frame(height: 9)
                                .help(m.title + (covered.contains(m) ? "" : (missing.contains(m) ? ": a statement seems to be missing" : ": no charges, so no statement")))
                        }
                    }
                }
                let quiet = strip.filter { !covered.contains($0) }.count
                if missing.isEmpty {
                    // An empty month on a card that isn't used every month is just a month it wasn't used:
                    // banks issue no statement then. Only a hole the app thinks is real gets a warning.
                    HStack(spacing: 6) {
                        Label("No gaps", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.good)
                        if quiet > 0 {
                            Text(quiet == 1 ? "· 1 month with no charges" : "· \(quiet) months with no charges").foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                } else {
                    Label(missing.count == 1 ? "Nothing for \(missing[0].title)" : "\(missing.count) months missing, \(missing.prefix(2).map(\.name).joined(separator: " and "))\(missing.count > 2 ? "…" : "")",
                          systemImage: "exclamationmark.circle.fill")
                        .font(.caption).foregroundStyle(Theme.caution).lineLimit(1)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.sheet, in: .rect(cornerRadius: 16, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(hovering ? Theme.accent.opacity(0.45) : Theme.hairline) }
            .shadow(color: .black.opacity(hovering ? 0.07 : 0.025), radius: hovering ? 10 : 6, y: 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct StatementRow: View {
    let source: SourceFile

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: source.isPDF ? "doc.richtext" : source.isPicture ? "photo" : "tablecells")
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(source.monthTitle).font(.body.weight(.medium)).lineLimit(1)
                Text(source.monthTitle == source.period ? "\(source.kind) · \(source.rows) \(source.rows == 1 ? "line" : "lines")"
                                                        : "\(source.period.components(separatedBy: ",").first ?? source.period) · \(source.rows) \(source.rows == 1 ? "line" : "lines")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if source.check == "verified" {
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.good).font(.caption)
                    .help("Its lines add up to the totals the statement prints.")
            } else if source.check == "mismatch" {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.caution).font(.caption)
                    .help(source.checkNote.map { "Worth a look: \($0)" } ?? "What was read doesn't add up to the totals this statement prints. Worth a look.")
            }
        }
        .padding(.vertical, 2)
        .help(source.name)
    }
}

// MARK: - A charge's original, over the window

/// "Show in Statement": the original opens at the line the charge was read from.
struct OriginalPeekSheet: View {
    private var store: BudgetStore { .shared }
    let peek: OriginalPeek
    @State private var found: SourceFile?
    @State private var looked = false

    var body: some View {
        let entry = store.entry(peek.entryID)
        VStack(spacing: 0) {
            if let entry, let source = found {
                OriginalViewer(source: source, entry: entry, inSheet: true)
            } else if looked {
                ContentUnavailableView("The statement isn't here", systemImage: "doc.questionmark",
                                       description: Text("Drop it in again and this charge will link to it."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 760, idealWidth: 960, maxWidth: 1400, minHeight: 560, idealHeight: 860, maxHeight: 1400)
        .task {
            guard let entry else { looked = true; return }
            found = OriginalChooser.best(for: entry, among: store.sourceCandidates(for: entry), store: store)
            looked = true
        }
    }
}

/// When a charge isn't tied to one file, picks the statement it shows up in most convincingly.
@MainActor
enum OriginalChooser {
    static func best(for entry: LedgerEntry, among candidates: [SourceFile], store: BudgetStore) -> SourceFile? {
        guard candidates.count > 1 else { return candidates.first }
        let target = SourceLocator.Target(entry)
        var best: (SourceFile, Double)?
        for source in candidates.prefix(6) {
            let url = store.sourceURL(source)
            var score = -1.0
            if source.isPDF, let doc = PDFDocument(url: url) { score = SourceLocator.locate(target, in: doc)?.score ?? -1 }
            else if !source.isPicture, let sheet = SourceLocator.sheet(at: url, ext: source.ext) { score = SourceLocator.locate(target, in: sheet)?.score ?? -1 }
            if best == nil || score > best!.1 { best = (source, score) }
        }
        return best?.0
    }
}

// MARK: - One original, with a charge pointed out in it

struct OriginalViewer: View {
    private var store: BudgetStore { .shared }
    let source: SourceFile
    /// The charge to point at, if any.
    var entry: LedgerEntry?
    var inSheet = false
    /// Step to the next statement of the same account, when there is one.
    var newer: (() -> Void)? = nil
    var older: (() -> Void)? = nil

    enum Content {
        case pdf(PDFDocument, SourceLocator.PDFHit?)
        case sheet(SourceLocator.Sheet, SourceLocator.RowHit?)
        case picture(NSImage, SourceLocator.PictureHit?)
        case unreadable
    }
    enum Finding { case none, looking, sure(String), close(String), notFound }

    @State private var content: Content?
    @State private var finding = Finding.none
    @State private var pulse = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let entry { pointer(entry); Divider() }
            Group {
                switch content {
                case .pdf(let doc, let hit): PDFPane(document: doc, hit: hit, page: scanPage, pulse: pulse)
                case .sheet(let sheet, let hit):
                    VStack(spacing: 0) {
                        if let note = sheet.note {
                            Text(note).font(.caption).foregroundStyle(.secondary).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            Divider()
                        }
                        TablePane(sheet: sheet, hit: hit, pulse: pulse)
                    }
                case .picture(let image, let hit): PicturePane(image: image, hit: hit)
                case .unreadable:
                    ContentUnavailableView("This original can't be shown", systemImage: "doc.questionmark",
                                           description: Text("The kept copy is missing or damaged. Drop the statement in again to replace it."))
                case nil: ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.paper)
        .task(id: entry?.id) { await load() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: source.isPDF ? "doc.richtext.fill" : source.isPicture ? "photo.fill" : "tablecells.fill")
                .font(.title2).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text([store.accounts.first { $0.id == source.accountID }?.name, source.period].compactMap { $0 }.joined(separator: " · "))
                    .font(.headline).lineLimit(1)
                HStack(spacing: 6) {
                    Text(source.name).lineLimit(1).truncationMode(.middle)
                    if source.check == "verified" {
                        Label("Adds up to its printed totals", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.good).lineLimit(1)
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if !inSheet {
                ControlGroup {
                    Button { older?() } label: { Image(systemName: "chevron.left") }
                        .disabled(older == nil).help("The statement before this one").accessibilityLabel("Previous statement")
                    Button { newer?() } label: { Image(systemName: "chevron.right") }
                        .disabled(newer == nil).help("The statement after this one").accessibilityLabel("Next statement")
                }
                .fixedSize()
                let charges = store.entries(in: source)
                let count = charges.count
                if count > 0 {
                    Button("\(count) \(count == 1 ? "Charge" : "Charges")") {
                        store.showCharges(TransactionFilter(ids: Set(charges.map(\.id)), title: "From \(source.period)"))
                    }
                    .help("The charges read from this statement")
                }
            }
            Menu {
                Button("Open in \(source.isPDF || source.isPicture ? "Preview" : "Its Own App")") { openCopy() }
                Button("Show the Kept Copy in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.sourceURL(source)]) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
            .help("More ways to open this statement").accessibilityLabel("More")
            if inSheet {
                Button("Open in Statements") { store.browse(source, charge: entry?.id) }
                Button("Done") { store.originalPeek = nil }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    /// The charge being pointed at, and how sure the finder is.
    private func pointer(_ entry: LedgerEntry) -> some View {
        HStack(spacing: 10) {
            Group {
                switch finding {
                case .sure(let place): Label(place, systemImage: "scope").foregroundStyle(Theme.good)
                case .close(let place): Label(place, systemImage: "questionmark.circle").foregroundStyle(Theme.caution)
                case .notFound: Label("Couldn't pinpoint the line. The charge is somewhere in this statement.", systemImage: "questionmark.circle").foregroundStyle(Theme.caution)
                case .looking: Label("Finding the line…", systemImage: "scope").foregroundStyle(.secondary)
                case .none: EmptyView()
                }
            }
            .font(.callout.weight(.medium))
            .lineLimit(1)
            Spacer(minLength: 12)
            Text(DateParsing.parse(entry.date, format: "yyyy-MM-dd")?.formatted(.dateTime.month(.abbreviated).day().year()) ?? entry.date)
                .foregroundStyle(.secondary)
            Text(entry.description).lineLimit(1).truncationMode(.tail).frame(maxWidth: 300, alignment: .trailing)
            Text(Money.format(abs(entry.amount))).fontWeight(.semibold).monospacedDigit()
            Button { pulse += 1 } label: { Image(systemName: "arrow.uturn.backward.circle") }
                .buttonStyle(.borderless)
                .help("Jump back to the line").accessibilityLabel("Jump back to the line")
        }
        .font(.callout)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(Theme.sheet)
    }

    private func load() async {
        let url = store.sourceURL(source)
        let target = entry.map(SourceLocator.Target.init)
        finding = target == nil ? .none : .looking
        if source.isPDF {
            guard let doc = PDFDocument(url: url) else { content = .unreadable; finding = .none; return }
            let hit = target.flatMap { SourceLocator.locate($0, in: doc) }
            content = .pdf(doc, hit)
            if let hit {
                let place = doc.pageCount > 1 ? "page \(hit.pageIndex + 1) of \(doc.pageCount)" : "this page"
                finding = hit.isSure ? .sure("Found on \(place)") : .close("Closest match, on \(place)")
            } else if let target {
                // No text to search: the statement is a scan. Read the pictures of its pages.
                finding = .looking
                if let (index, _) = await Self.findInScan(target, url: url) {
                    scanPage = index
                    finding = .close("It's on page \(index + 1). This statement is a scan, so the line itself can't be marked.")
                } else { finding = .notFound }
            }
        } else if source.isPicture {
            guard let image = NSImage(contentsOf: url) else { content = .unreadable; finding = .none; return }
            content = .picture(image, nil)
            if let target, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let hit = await Task.detached { SourceLocator.locate(target, in: cg) }.value
                content = .picture(image, hit)
                finding = hit.map { $0.isSure ? .sure("Found in the picture") : .close("Closest match in the picture") } ?? .notFound
            }
        } else {
            guard let sheet = SourceLocator.sheet(at: url, ext: source.ext) else { content = .unreadable; finding = .none; return }
            let hit = target.flatMap { SourceLocator.locate($0, in: sheet) }
            content = .sheet(sheet, hit)
            if target != nil {
                finding = hit.map { $0.isSure ? .sure("Found on row \($0.row + 1) of \(sheet.rows.count)") : .close("Closest match, row \($0.row + 1)") } ?? .notFound
            }
        }
        pulse += 1
    }

    @State private var scanPage: Int?

    /// For a scanned statement: which page shows the charge.
    nonisolated private static func findInScan(_ target: SourceLocator.Target, url: URL) async -> (Int, SourceLocator.PictureHit)? {
        await Task.detached { () -> (Int, SourceLocator.PictureHit)? in
            guard let doc = PDFDocument(url: url) else { return nil }
            var best: (Int, SourceLocator.PictureHit)?
            for index in 0..<min(doc.pageCount, 24) {
                guard let page = doc.page(at: index) else { continue }
                let bounds = page.bounds(for: .mediaBox)
                let scale = min(3, 2000 / max(bounds.width, bounds.height))
                let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
                guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                      let hit = SourceLocator.locate(target, in: cg) else { continue }
                if best == nil || hit.score > best!.1.score { best = (index, hit) }
                if hit.isSure { break }
            }
            return best
        }.value
    }

    /// Opens a copy under the file's own name (the kept copy is named by its fingerprint).
    private func openCopy() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Spendthrift Originals", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent(source.name)
        try? FileManager.default.removeItem(at: copy)
        if (try? FileManager.default.copyItem(at: store.sourceURL(source), to: copy)) != nil { NSWorkspace.shared.open(copy) }
    }
}

// MARK: - The panes

/// A PDF, scrolled to the charge with its line washed yellow and the amount marked.
struct PDFPane: NSViewRepresentable {
    let document: PDFDocument
    let hit: SourceLocator.PDFHit?
    /// The page to show when the line itself couldn't be found (a scan).
    var page: Int? = nil
    /// Changes whenever the view should jump to the line again.
    let pulse: Int

    final class Coordinator { var lastPulse = -1 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = NSColor(Theme.paper)
        view.document = document
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document !== document { view.document = document }
        guard context.coordinator.lastPulse != pulse else { return }
        context.coordinator.lastPulse = pulse
        guard let hit, let page = document.page(at: hit.pageIndex) else {
            view.highlightedSelections = nil
            if let index = self.page, let page = document.page(at: index) { DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { view.go(to: page) } }
            return
        }
        Self.mark(hit)
        view.highlightedSelections = [hit.row, hit.amount].compactMap { $0 }
        // After the view has laid its pages out: bring the line to the middle, then flash the amount
        // the way Find does.
        let box = hit.amount.bounds(for: page)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let room = max(120, view.bounds.height / view.scaleFactor * 0.38)
            view.go(to: box.insetBy(dx: 0, dy: -room), on: page)
            view.setCurrentSelection(hit.amount, animate: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { view.clearSelection() }
        }
    }

    static func mark(_ hit: SourceLocator.PDFHit) {
        hit.row?.color = NSColor.systemYellow.withAlphaComponent(0.22)
        hit.amount.color = NSColor.systemOrange.withAlphaComponent(0.55)
    }
}

/// A CSV, spreadsheet or Quicken file as a table, with the charge's row selected and its amount marked.
struct TablePane: NSViewRepresentable {
    let sheet: SourceLocator.Sheet
    let hit: SourceLocator.RowHit?
    let pulse: Int

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var sheet = SourceLocator.Sheet(header: [], rows: [])
        var hit: SourceLocator.RowHit?
        var lastPulse = -1

        func numberOfRows(in tableView: NSTableView) -> Int { sheet.rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn, let column = Int(tableColumn.identifier.rawValue) else { return nil }
            let id = NSUserInterfaceItemIdentifier("cell")
            let field = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField) ?? {
                let f = NSTextField(labelWithString: "")
                f.identifier = id
                f.lineBreakMode = .byTruncatingTail
                f.isSelectable = true
                return f
            }()
            let cells = sheet.rows[row]
            field.stringValue = column < cells.count ? cells[column] : ""
            let isTheNumber = hit?.row == row && hit?.column == column
            field.font = isTheNumber ? .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .bold) : .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            field.drawsBackground = isTheNumber
            field.backgroundColor = isTheNumber ? NSColor.systemOrange.withAlphaComponent(0.45) : .clear
            field.toolTip = field.stringValue.count > 24 ? field.stringValue : nil
            return field
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = HitRowView()
            view.isHit = hit?.row == row
            return view
        }
    }

    /// The charge's row keeps a yellow wash whether or not it is selected.
    final class HitRowView: NSTableRowView {
        var isHit = false
        override func drawBackground(in dirtyRect: NSRect) {
            super.drawBackground(in: dirtyRect)
            if isHit { NSColor.systemYellow.withAlphaComponent(0.28).setFill(); bounds.fill() }
        }
        override func drawSelection(in dirtyRect: NSRect) {
            if isHit { NSColor.systemYellow.withAlphaComponent(0.28).setFill(); bounds.fill() } else { super.drawSelection(in: dirtyRect) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let table = NSTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.style = .fullWidth
        table.rowHeight = 22
        table.allowsColumnReordering = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? NSTableView else { return }
        let c = context.coordinator
        if c.sheet.header != sheet.header || c.sheet.rows.count != sheet.rows.count {
            c.sheet = sheet
            for column in table.tableColumns { table.removeTableColumn(column) }
            let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            for (index, title) in sheet.header.enumerated() {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
                column.title = title
                // Wide enough for what's in it, judged from the first few hundred rows.
                let longest = sheet.rows.prefix(300).map { index < $0.count ? $0[index] : "" }.max { $0.count < $1.count } ?? ""
                let width = max((title as NSString).size(withAttributes: [.font: font]).width,
                                (longest as NSString).size(withAttributes: [.font: font]).width)
                column.width = min(max(width + 22, 70), 420)
                column.minWidth = 50
                table.addTableColumn(column)
            }
        }
        c.hit = hit
        guard c.lastPulse != pulse else { return }
        c.lastPulse = pulse
        table.reloadData()
        guard let hit, hit.row < sheet.rows.count else { return }
        DispatchQueue.main.async {
            // A few rows of what came before and after, so the line is seen in its place.
            let visible = max(4, Int(scroll.contentView.bounds.height / 24) / 2 - 1)
            table.scrollRowToVisible(min(sheet.rows.count - 1, hit.row + visible))
            table.scrollRowToVisible(max(0, hit.row - visible))
            table.scrollRowToVisible(hit.row)
            if let column = hit.column { table.scrollColumnToVisible(column) }
        }
    }
}

/// A photo or screenshot of a statement, with the amount ringed.
struct PicturePane: View {
    let image: NSImage
    let hit: SourceLocator.PictureHit?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .overlay {
                        GeometryReader { geo in
                            if let box = hit?.box {
                                // Vision measures from the bottom-left; the screen from the top-left.
                                let rect = CGRect(x: box.minX * geo.size.width, y: (1 - box.maxY) * geo.size.height,
                                                  width: box.width * geo.size.width, height: box.height * geo.size.height).insetBy(dx: -6, dy: -4)
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(Color.orange.opacity(0.28))
                                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.orange, lineWidth: 2))
                                    .frame(width: rect.width, height: rect.height)
                                    .position(x: rect.midX, y: rect.midY)
                                    .id("hit")
                            }
                        }
                    }
                    .padding(16)
            }
            .onChange(of: hit?.box) { withAnimation { proxy.scrollTo("hit", anchor: .center) } }
        }
    }
}
