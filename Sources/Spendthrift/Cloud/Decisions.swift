import Foundation

/// Decision models: small, fast models that do not write. Given a state and a set of typed
/// questions they return, for each, a choice or the probability of "yes", with a calibrated
/// confidence. One request can ask for a category and a dozen yes-or-no facts at once, costs a
/// few thousandths of a cent, and comes back in a fraction of a second.
///
/// That changes what is affordable: every payee can be asked a page of questions, every pair of
/// similar names can be asked "the same business?", and the answers carry a number that says when
/// to act, when to suggest, and when to say nothing.
///
/// Like every model in the app, these only judge. No figure shown anywhere comes from them.
enum Decisions {
    /// One question about the state.
    enum Question {
        /// Yes or no, with what each means. The answer is the probability of yes.
        case yesNo(String, yes: String? = nil, no: String? = nil)
        /// Exactly one of the options, each with a line saying what it covers.
        case choice(String, options: [String: String])

        var body: [String: Any] {
            switch self {
            case .yesNo(let ask, let yes, let no):
                var body: [String: Any] = ["type": "noul", "instructions": ask]
                if let yes, let no { body["criteria"] = ["true": yes, "false": no] }
                return body
            case .choice(let ask, let options):
                return ["type": "choice", "instructions": ask, "criteria": options]
            }
        }
    }

    struct Answer {
        /// For a yes-or-no question: how likely "yes" is, 0 to 1.
        var yes: Double?
        /// For a choice: the option picked, how sure, and the spread over the options.
        var choice: String?
        var confidence: Double?
        var probabilities: [String: Double] = [:]
    }

    /// The decision model used unless a caller names another (only the benchmark does).
    static let standard = Models.decision

    /// Asks every question about one state. Nil when there is no key, no connection, or the model refused.
    static func ask(job: String, model: String = standard, state: String, questions: [String: Question]) async -> [String: Answer]? {
        guard let key = CloudKey.load(), let url = URL(string: "https://openrouter.ai/api/alpha/decisions") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "state": state, "questions": questions.mapValues(\.body)])
        for attempt in 0..<3 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(600 * attempt)) }
            guard let (data, response) = try? await URLSession.shared.data(for: request) else { continue }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 429 || status >= 500 { continue }
            guard status == 200, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let answers = object["answers"] as? [String: Any] else { return nil }
            CloudSpend.note(job: job, model: model, usage: object["usage"] as? [String: Any])
            return answers.compactMapValues { raw in
                guard let raw = raw as? [String: Any] else { return nil }
                var answer = Answer()
                answer.yes = number(raw["noul"])
                answer.choice = raw["choice"] as? String
                answer.confidence = number(raw["confidence"])
                answer.probabilities = (raw["probabilities"] as? [String: Any])?.compactMapValues(number) ?? [:]
                return answer
            }
        }
        return nil
    }

    /// The same questions asked of many states, a dozen at a time. Results are keyed as the states were.
    static func askAll(job: String, model: String = standard, states: [String: String], questions: [String: Question],
                       atOnce: Int = 12) async -> [String: [String: Answer]] {
        var out: [String: [String: Answer]] = [:]
        let work = Array(states)
        await withTaskGroup(of: (String, [String: Answer]?).self) { group in
            var next = 0
            func start() {
                guard next < work.count else { return }
                let (id, state) = work[next]; next += 1
                group.addTask { (id, await ask(job: job, model: model, state: state, questions: questions)) }
            }
            for _ in 0..<atOnce { start() }
            for await (id, answers) in group {
                if let answers { out[id] = answers }
                start()
            }
        }
        return out
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? Double) ?? (value as? Int).map(Double.init) ?? (value as? NSNumber)?.doubleValue
    }
}
