import Foundation
import Observation

/// What the model cost, request by request, added up by day and by job. OpenRouter reports the
/// price of each reply; this keeps the running total so it's plain where the money goes.
@MainActor @Observable
final class CloudSpend {
    static let shared = CloudSpend()

    struct Tally: Codable, Hashable {
        var requests = 0
        var input = 0
        var output = 0
        var cost = 0.0
    }

    /// Day (yyyy-MM-dd) → "job\tmodel" → what it used.
    private(set) var days: [String: [String: Tally]] = [:]
    @ObservationIgnored private let file = BudgetPaths().root.appendingPathComponent("spend.json")
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private init() {
        days = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([String: [String: Tally]].self, from: $0) } ?? [:]
    }

    /// Called with the "usage" part of a reply.
    nonisolated static func note(job: String, model: String, usage: [String: Any]?) {
        guard let usage else { return }
        let number = { (key: String) -> Double in (usage[key] as? Double) ?? (usage[key] as? Int).map(Double.init) ?? 0 }
        let input = Int(number("prompt_tokens")), output = Int(number("completion_tokens")), cost = number("cost")
        Task { @MainActor in shared.add(job: job, model: model, input: input, output: output, cost: cost) }
    }

    private func add(job: String, model: String, input: Int, output: Int, cost: Double) {
        let day = DateParsing.iso.string(from: .now)
        var tally = days[day]?["\(job)\t\(model)"] ?? Tally()
        tally.requests += 1; tally.input += input; tally.output += output; tally.cost += cost
        days[day, default: [:]]["\(job)\t\(model)"] = tally
        // Three months is plenty to see a pattern.
        if days.count > 100 { for old in days.keys.sorted().dropLast(100) { days[old] = nil } }
        if ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] != nil {
            print("DEBUG SPEND \(job) [\(model)] in \(input) out \(output) $\(String(format: "%.4f", cost))")
        }
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    func saveNow() {
        if let data = try? JSONEncoder().encode(days) { try? data.write(to: file, options: .atomic) }
    }

    struct Line: Identifiable {
        var id: String { job + model }
        let job: String
        let model: String
        var tally: Tally
    }

    /// The last `span` days (1 = today), one line per job and model, dearest first.
    func lines(days span: Int) -> [Line] {
        let from = DateParsing.iso.string(from: Date.now.addingTimeInterval(-Double(span - 1) * 86_400))
        var sum: [String: Tally] = [:]
        for (day, jobs) in days where day >= from {
            for (key, t) in jobs {
                var s = sum[key] ?? Tally()
                s.requests += t.requests; s.input += t.input; s.output += t.output; s.cost += t.cost
                sum[key] = s
            }
        }
        return sum.map { key, tally in
            let parts = key.components(separatedBy: "\t")
            return Line(job: parts[0], model: parts.count > 1 ? parts[1] : "", tally: tally)
        }
        .sorted { ($0.tally.cost, $1.job) > ($1.tally.cost, $0.job) }
    }
}
