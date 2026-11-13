import SwiftUI
import AppKit
import CryptoKit
import PDFKit
import UniformTypeIdentifiers

/// Accounts and the Downloads folder: what is on file, what is missing, and what is waiting to be added.
extension BudgetStore {
    // MARK: - Accounts

    /// Keeps an account apart from the person's own totals under a name ("Mom"), or brings it back (nil).
    func keepApart(_ id: UUID, as label: String?) {
        guard let i = library.accounts.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = label?.trimmingCharacters(in: .whitespaces)
        library.accounts[i].apart = (trimmed?.isEmpty ?? true) ? nil : trimmed
        withAnimation(.snappy) { changed() }
        if let name = library.accounts[i].apart {
            showToast("\(library.accounts[i].name) is kept apart as “\(name)”. It no longer counts in your spending or income.", symbol: "tray.full.fill")
        } else {
            showToast("\(library.accounts[i].name) counts in your totals again.", symbol: "tray.and.arrow.down.fill")
        }
    }

    func renameAccount(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let i = library.accounts.firstIndex(where: { $0.id == id }), library.accounts[i].name != trimmed else { return }
        library.accounts[i].name = trimmed
        changed()
    }

    func removeAccount(_ id: UUID) {
        guard let account = accounts.first(where: { $0.id == id }) else { return }
        library.entries.removeAll { $0.accountID == id }
        library.accounts.removeAll { $0.id == id }
        // Its statements go too, and may be added again later as if never seen.
        library.importedHashes.subtract((library.sources ?? []).filter { $0.accountID == id }.map(\.id))
        forgetSources { $0.accountID == id }
        pruneUnusedPlaces()
        withAnimation(.snappy) { changed() }
        showToast("Removed \(account.name).", symbol: "trash.fill")
        refreshDownloads()
    }

    /// For the rare export where purchases and payments came in backwards.
    func flipAmounts(_ id: UUID) {
        guard let a = library.accounts.firstIndex(where: { $0.id == id }) else { return }
        library.accounts[a].invertAmounts = !(library.accounts[a].invertAmounts ?? false)   // future statements too
        for i in library.entries.indices where library.entries[i].accountID == id { library.entries[i].amount.negate() }
        withAnimation(.snappy) { changed() }
        showToast("Flipped. Purchases and payments are swapped for this account.", symbol: "arrow.up.arrow.down")
    }

    func transactionCount(for account: Account) -> Int {
        summary(of: account).count
    }

    func spent(in account: Account) -> Double {
        summary(of: account).spent
    }

    func dateRange(for account: Account) -> ClosedRange<Date>? {
        summary(of: account).range
    }

    // MARK: - Downloads folder

    /// Looks for new statements in Downloads, off the main thread (the first look may wait
    /// on macOS's "allow access to Downloads?" prompt, and reading files takes a moment).
    func refreshDownloads() {
        guard ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] == nil,
              ProcessInfo.processInfo.environment["SPENDTHRIFT_HOME"] == nil else { return }
        let known = library.importedHashes.union(library.dismissedDownloads)
        let memory = paths.root.appendingPathComponent("downloads-seen.json")
        Task.detached(priority: .utility) {
            let found = Self.scanDownloads(excluding: known, memory: memory)
            await MainActor.run { self.foundInDownloads(found) }
        }
    }

    /// New statements are simply added (it can be undone). Only ones that need attention, such as a locked
    /// PDF, wait in the "New in your Downloads" banner.
    private func foundInDownloads(_ found: [URL]) {
        guard Self.addsDownloadsAutomatically else { downloadCandidates = Array(found.prefix(5)); return }
        let fresh = found.filter { !autoAttempted.contains($0) }
        downloadCandidates = Array(found.filter { autoAttempted.contains($0) }.prefix(5))
        guard !fresh.isEmpty, !isImporting else { return }
        autoAttempted.formUnion(fresh)
        Task { await importFilesAsync(fresh, automatic: true) }
    }

    static var addsDownloadsAutomatically: Bool {
        get { UserDefaults.standard.object(forKey: "addsDownloadsAutomatically") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "addsDownloadsAutomatically") }
    }

    /// Watches the Downloads folder while the app is open, so a statement saved from the bank's
    /// website shows up in the app a few seconds later without anyone doing anything.
    func watchDownloads() {
        // (Never into a scratch data folder: a test or a demo must not pull in real statements.)
        guard downloadsWatcher == nil, ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] == nil,
              ProcessInfo.processInfo.environment["SPENDTHRIFT_HOME"] == nil,
              let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.downloadsDebounce?.cancel()
                self.downloadsDebounce = Task {
                    try? await Task.sleep(for: .seconds(4))      // let the browser finish writing the file
                    guard !Task.isCancelled else { return }
                    self.refreshDownloads()
                }
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        downloadsWatcher = source
    }

    /// What a file in Downloads turned out to be, so it is opened once and not at every launch:
    /// whether it reads as a statement, and the fingerprint of its contents. Good for as long as
    /// the file's size and date stay the same.
    private struct Seen: Codable {
        var stamp: String
        var isStatement: Bool
        var hash: String?
    }

    nonisolated private static func scanDownloads(excluding known: Set<String>, memory: URL) -> [URL] {
        guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
              let items = try? FileManager.default.contentsOfDirectory(
                at: downloads, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey], options: [.skipsHiddenFiles])
        else { return [] }
        let cutoff = Date.now.addingTimeInterval(-60 * 24 * 3600)
        let before = (try? Data(contentsOf: memory)).flatMap { try? JSONDecoder().decode([String: Seen].self, from: $0) } ?? [:]
        var after: [String: Seen] = [:]
        var found: [(URL, Date)] = []
        for url in items {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let date = values?.contentModificationDate ?? .distantPast
            guard date > cutoff else { continue }
            let kind = url.pathExtension.lowercased()
            guard ["csv", "ofx", "qfx", "qbo", "xlsx", "pdf"].contains(kind) else { continue }
            let stamp = "\(values?.fileSize ?? -1)|\(date.timeIntervalSince1970)"
            var seen = before[url.lastPathComponent].flatMap { $0.stamp == stamp ? $0 : nil }
            if seen == nil {
                // Judge PDFs by their first page, not their name: Amex calls them "2026-11-03.pdf",
                // and a "closing-statement.pdf" from a home purchase isn't a bank statement.
                let isStatement = kind == "pdf" ? PDFStatement.looksLikeStatement(url) : true
                seen = Seen(stamp: stamp, isStatement: isStatement, hash: isStatement ? (try? Data(contentsOf: url)).map(hash) : nil)
            }
            after[url.lastPathComponent] = seen
            if let seen, seen.isStatement, let hash = seen.hash, !known.contains(hash) { found.append((url, date)) }
        }
        if let data = try? JSONEncoder().encode(after) { try? data.write(to: memory, options: .atomic) }
        return found.sorted { $0.1 > $1.1 }.prefix(60).map(\.0)
    }

    func dismissDownload(_ url: URL) {
        if let data = try? Data(contentsOf: url) { library.dismissedDownloads.insert(Self.hash(data)) }
        changed()
        withAnimation { downloadCandidates.removeAll { $0 == url } }
    }

    func importAllDownloads() {
        importFiles(downloadCandidates)
    }
}
