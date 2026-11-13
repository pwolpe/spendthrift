import Foundation
import PDFKit
import AppKit
import Observation

/// The models the app runs on, reached through OpenRouter with the person's own key:
///
///  - places the built-in rules don't know are sorted by a model (merchant text and amounts only);
///  - statements the app can't read are read by one, after name, address and account numbers are blanked;
///  - one understands questions in Ask and writes the short notes and the picture captions.
///
/// Totals are always computed in code. If the models can't be reached, an import still finishes on
/// the built-in rules and what they couldn't place waits for the next try.
enum CloudAI {
    /// For comparing models: use this one for everything inside the task.
    @TaskLocal static var modelOverride: String?

    /// The writing model. Which model does which job is decided in `Models`, not by the person.
    static var model: String { modelOverride ?? Models.writing }
    /// Reading whole statements sends more than merchant names, so it has its own switch.
    static var readsStatements: Bool {
        get { UserDefaults.standard.object(forKey: "cloudReadsStatements") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "cloudReadsStatements") }
    }

    /// Set around a read that must not use the model (re-reading a statement only to keep its original).
    @TaskLocal static var offline = false

    static var isEnabled: Bool {
        !offline && ProcessInfo.processInfo.environment["SPENDTHRIFT_NO_CLOUD"] == nil && CloudKey.exists
    }
    static var canReadStatements: Bool { isEnabled && readsStatements }
    /// The app needs a key before it takes a statement. (The self-test runs offline, on purpose, without one.)
    static var hasKeyOrIsTest: Bool { CloudKey.exists || ProcessInfo.processInfo.environment["SPENDTHRIFT_NO_CLOUD"] != nil }

    enum CloudError: LocalizedError {
        case noKey, badKey, outOfCredit, unreachable, server(Int), badReply
        var errorDescription: String? {
            switch self {
            case .noKey: "No key has been entered."
            case .badKey: "OpenRouter didn't accept that key. Check it was copied completely."
            case .outOfCredit: "The OpenRouter account is out of credit or over its limit."
            case .unreachable: "OpenRouter couldn't be reached. Check the internet connection."
            case .server(let code): "OpenRouter had a problem (error \(code)). Try again in a minute."
            case .badReply: "The reply couldn't be understood."
            }
        }
    }

    /// One request. `json: true` asks for (and returns) a JSON object.
    /// - maxTokens: room for the whole reply, including any thinking the model does before it
    ///   writes. Too little and the answer is cut off mid-sentence, so be generous.
    /// - effort: how hard the model should think first ("low", "medium", "high"); nil = its default.
    static func complete(job: String, system: String, user: String, json: Bool, maxTokens: Int, temperature: Double = 0,
                         timeout: TimeInterval = 90, effort: String? = nil, web: Bool = false) async throws -> String {
        guard let key = CloudKey.load() else { throw CloudError.noKey }
        // SPENDTHRIFT_FAIL_CLOUD=credit|key|offline: behave as if the model had stopped working (for tests).
        if let fail = ProcessInfo.processInfo.environment["SPENDTHRIFT_FAIL_CLOUD"] {
            let error: CloudError = fail == "key" ? .badKey : fail == "offline" ? .unreachable : .outOfCredit
            await CloudStatus.shared.note(error: error)
            throw error
        }
        var request = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Spendthrift", forHTTPHeaderField: "X-Title")
        var body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system], ["role": "user", "content": user]],
            "max_tokens": maxTokens,
            "temperature": temperature,
            "usage": ["include": true],     // the reply then says what it cost
        ]
        if json, !web { body["response_format"] = ["type": "json_object"] }
        // Let the model search the web (used to work out what an unfamiliar business is).
        if web { body["plugins"] = [["id": "web", "max_results": 3]] }
        if let effort { body["reasoning"] = ["effort": effort] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var lastError: CloudError = .unreachable
        for attempt in 0..<2 {
            if attempt > 0 { try? await Task.sleep(for: .seconds(2)) }
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                switch status {
                case 200:
                    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let choices = object["choices"] as? [[String: Any]],
                          let message = choices.first?["message"] as? [String: Any],
                          let content = message["content"] as? String, !content.isEmpty else { throw CloudError.badReply }
                    CloudSpend.note(job: job, model: (body["model"] as? String) ?? model, usage: object["usage"] as? [String: Any])
                    // Cut off for length: a partial answer is worse than none (half a JSON object).
                    if (choices.first?["finish_reason"] as? String) == "length" {
                        if ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] != nil { print("DEBUG CLOUD reply cut off at \(maxTokens) tokens") }
                        throw CloudError.badReply
                    }
                    await CloudStatus.shared.note(error: nil)
                    return content
                case 401, 403: lastError = .badKey
                case 402: lastError = .outOfCredit
                case 429, 500...599: lastError = .server(status); continue      // worth one more try
                default: lastError = .server(status)
                }
                break
            } catch let error as CloudError {
                lastError = error; break
            } catch {
                lastError = .unreachable
            }
        }
        await CloudStatus.shared.note(error: lastError)
        throw lastError
    }

    /// Pulls the JSON object out of a reply, tolerating code fences or a stray sentence around it.
    static func object(from reply: String) -> [String: Any]? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let data = String(reply[start...end]).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// A tiny request to prove the key works.
    static func test() async -> String? {
        do {
            _ = try await complete(job: "Checking the key", system: "Reply with the single word OK.", user: "Hello", json: false, maxTokens: 5, timeout: 30)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "Something went wrong."
        }
    }
}

/// What Settings shows about the cloud connection.
@MainActor @Observable
final class CloudStatus {
    static let shared = CloudStatus()
    private(set) var lastError: String?
    private(set) var hasKey = CloudKey.exists
    private(set) var requests = 0

    /// Set while the model can't be used at all (bad key, no credit, no connection), as opposed to
    /// one request going wrong. This is what the person needs to be told about, plainly.
    private(set) var stopped: String?

    func note(error: CloudAI.CloudError?) {
        requests += 1
        lastError = error?.errorDescription
        switch error {
        case nil: stopped = nil
        case .badKey: stopped = "OpenRouter didn't accept the key."
        case .outOfCredit: stopped = "The OpenRouter key is out of credit or over its limit."
        case .unreachable: stopped = "OpenRouter couldn't be reached. Check the internet connection."
        default: break
        }
    }
    func refreshKey() { hasKey = CloudKey.exists; if !hasKey { lastError = nil } }
}

/// The OpenRouter key lives in a private file in the data folder: never in the app, the library file, or a backup.
enum CloudKey {
    nonisolated(unsafe) private static var cached: String??
    private static let lock = NSLock()

    /// A dot-file in the home folder also works, and wins if present: handy for setting a Mac up
    /// from Terminal without opening Settings.  pbpaste > ~/.spendthrift-key && chmod 600 ~/.spendthrift-key
    private static let dotFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".spendthrift-key")

    /// Why a file and not the keychain: macOS ties keychain access to the exact build of an app
    /// unless it's signed with an Apple Developer ID. Every update would make the person type their Mac
    /// password into a "wants to use your confidential information" dialog, and the app would
    /// freeze behind it. A file only his user account can read asks for nothing, ever. It always
    /// lives in the real data folder, never a test folder, and is not part of any backup the app makes.
    private static let file: URL = BudgetPaths.realRoot.appendingPathComponent("ai-key")

    static var exists: Bool { load() != nil }

    static func load() -> String? {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let read = { (url: URL) -> String? in
            let value = (try? String(contentsOf: url, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            return value?.isEmpty == false ? value : nil
        }
        let key = read(dotFile) ?? read(file)
        cached = .some(key)
        return key
    }

    @discardableResult
    static func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return false }
        lock.lock(); defer { lock.unlock() }
        do {
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            cached = .some(trimmed)
            return true
        } catch {
            return false
        }
    }

    static func delete() {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: dotFile)
        cached = .some(nil)
    }
}
