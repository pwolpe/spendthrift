import SwiftUI
import AppKit
import Security

/// Free automatic updates, without an Apple Developer account.
///
/// Paul publishes a zip of the app as a GitHub release. The app asks GitHub (at most once a day)
/// whether a newer version exists; nothing about Tony or his money is sent. Before installing, the
/// download must carry the same code signature as the running app (Paul's own certificate), so
/// only builds made on Paul's Mac can ever replace it. Tony's data lives outside the app and is untouched.
@MainActor @Observable
final class Updater {
    static let shared = Updater()
    static let releasesRepository = "pwolpe/tony-awards-releases"

    struct Release: Equatable {
        let version: String
        let notes: String
        let download: URL
    }

    enum State: Equatable {
        case idle, checking, upToDate
        case available(Release)
        case installing(Release, String)
        case failed(String)
    }

    private(set) var state: State = .idle
    /// True while the update window should be showing.
    var isPresented = false

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }
    var available: Release? { if case .available(let r) = state { return r }; return nil }

    private let lastCheckKey = "lastUpdateCheck"
    private var isTest: Bool { ProcessInfo.processInfo.environment["TONY_AWARDS_UPDATE_TEST"] != nil }

    /// At launch: a quiet check, once a day. A new version just shows a button in the sidebar.
    func start() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        if isTest {
            Task {
                await check()
                print("UPDATE current \(currentVersion) state \(state)")
                if let release = available { await install(release) } else { NSApp.terminate(nil) }
            }
            return
        }
        guard ProcessInfo.processInfo.environment["TONY_AWARDS_SNAPSHOT"] == nil else { return }
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard Date.now.timeIntervalSince1970 - last > 20 * 3600 else { return }
        Task { await check() }
    }

    /// From the menu: always shows the result.
    func checkFromMenu() {
        isPresented = true
        Task { await check(reportUpToDate: true) }
    }

    func check(reportUpToDate: Bool = false) async {
        if case .installing = state { return }
        state = .checking
        guard let url = URL(string: "https://api.github.com/repos/\(Self.releasesRepository)/releases/latest") else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: lastCheckKey)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let assets = json["assets"] as? [[String: Any]],
                  let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
                  let link = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)), link.scheme == "https"
            else {
                state = reportUpToDate ? .failed("I couldn't find any published versions. Try again later.") : .idle
                return
            }
            let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            if Self.isNewer(version, than: currentVersion) {
                state = .available(Release(version: version, notes: (json["body"] as? String) ?? "", download: link))
            } else {
                state = reportUpToDate ? .upToDate : .idle
            }
        } catch {
            state = reportUpToDate ? .failed("I couldn't reach the update server. Check your internet connection and try again.") : .idle
        }
    }

    /// "1.10" is newer than "1.9".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: Installing

    func install(_ release: Release) async {
        let app = Bundle.main.bundleURL
        func fail(_ message: String) { state = .failed(message); if isTest { print("UPDATE FAILED \(message)"); NSApp.terminate(nil) } }
        guard app.pathExtension == "app" else { return fail("Updates only work in the finished app.") }
        if app.path.contains("/AppTranslocation/") || !FileManager.default.isWritableFile(atPath: app.deletingLastPathComponent().path) {
            return fail("To update, first drag Appauled into your Applications folder and open it from there.")
        }
        guard let requirement = Self.ownRequirement() else {
            return fail("This copy of the app can't update itself. Ask Paul for a fresh copy.")
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("TonyAwardsUpdate-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        do {
            state = .installing(release, "Downloading version \(release.version)…")
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let (downloaded, response) = try await URLSession.shared.download(from: release.download)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return fail("The download didn't work. Try again later.") }
            let zip = work.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: downloaded, to: zip)

            state = .installing(release, "Checking it's really from Paul…")
            let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
            guard await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]) == 0,
                  let newApp = (try? FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil))?
                    .first(where: { $0.pathExtension == "app" })
            else { return fail("The download was damaged. Try again later.") }
            // The download must be signed by the same certificate as this app, and really be newer.
            guard Self.satisfies(newApp, requirement) else {
                return fail("The download isn't signed by Paul, so I didn't install it. Nothing was changed.")
            }
            let newVersion = (NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String) ?? "0"
            guard Self.isNewer(newVersion, than: currentVersion) else { return fail("That download isn't newer than what you have.") }

            state = .installing(release, "Installing…")
            BudgetStore.shared.saveForQuit()
            _ = try FileManager.default.replaceItemAt(app, withItemAt: newApp)
            if isTest { print("UPDATE INSTALLED \(newVersion) at \(app.path)"); NSApp.terminate(nil); return }
            // Reopen the new version once this one has quit.
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", app.path]
            try relaunch.run()
            NSApp.terminate(nil)
        } catch {
            fail("The update couldn't be installed (\(error.localizedDescription)). Nothing was changed.")
        }
    }

    /// The running app's signing identity, as a rule other code can be checked against.
    /// Nil for throwaway (ad-hoc) signatures, which no other build could ever match.
    private static func ownRequirement() -> SecRequirement? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text = text as String?,
              text.contains("certificate") else { return nil }
        return requirement
    }

    private static func satisfies(_ app: URL, _ requirement: SecRequirement) -> Bool {
        var candidate: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess, let candidate else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(candidate, flags, requirement) == errSecSuccess
    }

    private static func run(_ tool: String, _ arguments: [String]) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            process.standardOutput = Pipe(); process.standardError = Pipe()
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(returning: -1) }
        }
    }
}

// MARK: - Update window

struct UpdateSheet: View {
    @State private var updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                TonyAvatar(size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.title2.weight(.bold))
                    Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if let release = updater.available, !release.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ScrollView {
                    Text(.init(release.notes))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 220)
                .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 12, style: .continuous))
            }
            if case .installing = updater.state { ProgressView().progressViewStyle(.linear) }
            HStack {
                Spacer()
                if let release = updater.available {
                    Button("Later") { updater.isPresented = false }.keyboardShortcut(.cancelAction)
                    Button("Install and Reopen") { Task { await updater.install(release) } }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                } else if case .installing = updater.state {
                    EmptyView()
                } else {
                    Button("OK") { updater.isPresented = false }.keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.large)
        }
        .padding(26)
        .frame(width: 480)
        .interactiveDismissDisabled({ if case .installing = updater.state { return true }; return false }())
    }

    private var title: String {
        switch updater.state {
        case .available(let r): "Version \(r.version) is ready"
        case .installing(let r, _): "Updating to version \(r.version)"
        case .upToDate: "You're up to date"
        case .failed: "That didn't work"
        case .checking, .idle: "Checking for updates…"
        }
    }

    private var subtitle: String {
        switch updater.state {
        case .available: "You have version \(updater.currentVersion). Your accounts and categories stay exactly as they are."
        case .installing(_, let step): step
        case .upToDate: "Version \(updater.currentVersion) is the newest."
        case .failed(let message): message
        case .checking, .idle: "One moment."
        }
    }
}
