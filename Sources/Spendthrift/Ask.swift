import SwiftUI
import Charts
import FoundationModels

// MARK: - Understanding the question (AI) → computing the answer (code)

struct SpendingQuery: Hashable {
    enum Metric: String, CaseIterable { case total, list, topPlaces = "top_places", topCategories = "top_categories",
                                            count, monthlyAverage = "monthly_average", subscriptions }
    var metric: Metric = .total
    var category: Category?
    var place: String?
    var from: Month
    var to: Month
}

enum QueryParser {
    static func parse(_ question: String, months: [Month]) async -> SpendingQuery {
        let first = months.first ?? Month(date: .now), last = months.last ?? Month(date: .now)
        // With a cloud key, the powerful model understands the whole question, dates included.
        if let cloud = await CloudWriter.query(question, first: first, last: last) { return cloud }
        var query = keywordParse(question, first: first, last: last)
        if SystemLanguageModel.default.isAvailable, let ai = await Timeout.run(25, { await aiParse(question, first: first, last: last) }) {
            query.metric = ai.metric
            query.place = ai.place ?? query.place
            if let place = query.place {
                // Re-check categories with the store name removed ("Whole Foods" isn't "food").
                let rest = question.lowercased().replacingOccurrences(of: place.lowercased(), with: " ")
                query.category = keywordParse(rest, first: first, last: last).category
            }
            // Only filter by category when the question names one (or no store was named).
            if query.category == nil, query.place == nil { query.category = ai.category }
        }
        // Dates are worked out in code: the on-device model isn't reliable with calendars.
        let range = timeRange(question.lowercased(), first: first, last: last)
        query.from = max(range.0, first)
        query.to = min(range.1, last)
        if query.from > query.to { query.from = first; query.to = last }
        return query
    }

    static func timeRange(_ q: String, first: Month, last: Month) -> (Month, Month) {
        let now = Month(date: .now)
        if q.contains("last month") { return (now.adding(-1), now.adding(-1)) }
        if q.contains("this month") { return (now, now) }
        if q.contains("this year") { return (Month(year: now.year, month: 1), now) }
        if q.contains("last year") { return (Month(year: now.year - 1, month: 1), Month(year: now.year - 1, month: 12)) }
        if let r = q.range(of: #"(?:last|past) (\d+|two|three|four|five|six|twelve) months"#, options: .regularExpression) {
            let words = ["two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "twelve": 12]
            let token = q[r].split(separator: " ")[1]
            let n = Int(token) ?? words[String(token)] ?? 3
            return (now.adding(-(n - 1)), now)
        }
        // Month names, e.g. "in October" or "from August to October".
        let names = (1...12).map { Month(year: 2000, month: $0).name.lowercased() }
        var found: [Month] = []
        let words = q.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let year = words.compactMap { Int($0) }.first { (2000...2100).contains($0) }
        for w in words {
            guard w.count >= 3, let m = names.firstIndex(where: { $0 == w || ($0.hasPrefix(w) && w.count == 3) }) else { continue }
            let y = year ?? (m + 1 > now.month ? now.year - 1 : now.year)
            found.append(Month(year: y, month: m + 1))
        }
        if let lo = found.min(), let hi = found.max() { return (lo, hi) }
        if let year { return (Month(year: year, month: 1), Month(year: year, month: 12)) }
        return (first, last)
    }

    static let categorySynonyms: [(String, Category)] = [
        ("restaurant", .dining), ("eating out", .dining), ("dining", .dining), ("coffee", .dining), ("takeout", .dining), ("food", .dining),
        ("grocer", .groceries), ("supermarket", .groceries), ("gas", .transportation), ("uber", .transportation),
        ("parking", .transportation), ("car", .transportation), ("flight", .travel), ("hotel", .travel), ("vacation", .travel),
        ("shopping", .shopping), ("utilit", .bills), ("bills", .bills), ("subscription", .subscriptions), ("streaming", .subscriptions),
        ("doctor", .health), ("pharmacy", .health), ("gym", .health), ("entertainment", .entertainment), ("movies", .entertainment),
        ("gift", .gifts), ("donat", .gifts), ("charity", .gifts), ("fees", .fees), ("interest", .fees), ("income", .income),
        ("paycheck", .income), ("home", .home), ("haircut", .personal),
    ]

    private static func aiParse(_ question: String, first: Month, last: Month) async -> SpendingQuery? {
        let today = Date.now.formatted(.dateTime.year().month(.wide).day())
        let now = Month(date: .now)
        let session = LanguageModelSession(instructions: """
        You turn a question about personal spending into a query.
        Metrics: total (how much), list (show or what did I buy), top_places, top_categories, count (how many times),
        monthly_average, subscriptions (recurring charges).
        Today is \(today). Data covers \(first.key) to \(last.key). If no time is mentioned, use \(first.key) to \(last.key).
        "Last month" means \(now.adding(-1).key). "This month" means \(now.key). "This year" means \(now.year)-01 to \(last.key).
        A month name alone means that month in the most recent year it occurred.
        Coffee, restaurants and takeout are Dining. Gas, Uber and parking are Car & Transportation.
        Use "any" for category when a specific store is named.
        """)
        guard let schema = AISchemas.spendingQuery,
              let reply = try? await session.respond(to: question, schema: schema,
                                                     options: GenerationOptions(temperature: 0, maximumResponseTokens: 120)) else { return nil }
        let g = reply.content
        func field(_ name: String) -> String { ((try? g.value(String.self, forProperty: name)) ?? "").trimmingCharacters(in: .whitespaces) }
        guard let metric = SpendingQuery.Metric(rawValue: field("metric").lowercased()) else { return nil }
        let category = Category.pickable.first { $0.rawValue.caseInsensitiveCompare(field("category")) == .orderedSame }
        let placeText = field("place")
        let place = placeText.lowercased() == "any" || placeText.isEmpty ? nil : placeText
        var from = Month(key: field("from")) ?? first
        var to = Month(key: field("to")) ?? last
        if from > to { swap(&from, &to) }
        return SpendingQuery(metric: metric, category: category, place: place, from: max(from, first), to: min(to, last))
    }

    /// Works without Apple Intelligence: categories, a few time phrases, simple intents.
    static func keywordParse(_ question: String, first: Month, last: Month) -> SpendingQuery {
        let q = question.lowercased()
        var query = SpendingQuery(from: first, to: last)
        query.category = Category.pickable.first { q.contains($0.rawValue.lowercased()) }
            ?? categorySynonyms.first { q.range(of: "\\b" + $0.0, options: .regularExpression) != nil }?.1
        let now = Month(date: .now)
        if q.contains("last month") { query.from = now.adding(-1); query.to = now.adding(-1) }
        else if q.contains("this month") { query.from = now; query.to = now }
        else if q.contains("this year") { query.from = Month(year: now.year, month: 1); query.to = last }
        else if let m = (1...12).first(where: { q.contains(Month(year: now.year, month: $0).name.lowercased()) }) {
            let month = Month(year: m > now.month ? now.year - 1 : now.year, month: m)
            query.from = month; query.to = month
        }
        if q.contains("subscription") || q.contains("recurring") { query.metric = .subscriptions }
        else if q.contains("top") || q.contains("most") { query.metric = q.contains("categor") ? .topCategories : .topPlaces }
        else if q.contains("how many") { query.metric = .count }
        else if q.contains("average") { query.metric = .monthlyAverage }
        else if q.contains("show") || q.contains("list") || q.contains("what did i buy") { query.metric = .list }
        if let at = q.range(of: " at ") {
            let rest = q[at.upperBound...].split(separator: " ").prefix(2).joined(separator: " ")
                .trimmingCharacters(in: .punctuationCharacters)
            if !rest.isEmpty { query.place = rest }
        }
        return query
    }
}

struct Answer: Identifiable, Hashable {
    let id = UUID()
    let question: String
    let query: SpendingQuery
    let headline: String
    let rows: [(label: String, detail: String, value: String, category: Category?)]
    /// From the conversational path: bars to draw, and a few words on what was looked up.
    var chart: [ChatAnalyst.ChartBar] = []
    var chartIsLine = false
    var understood: String?

    static func == (a: Answer, b: Answer) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

enum AnswerEngine {
    @MainActor
    static func answer(_ question: String, query q: SpendingQuery, store: BudgetStore) -> Answer {
        let range = q.from == q.to ? q.from.title : "\(q.from.shortName) \(q.from.year == q.to.year ? "" : String(q.from.year) + " ")– \(q.to.title)"
        let wantsIncome = q.category == .income
        let matches = store.transactions.filter { t in
            let m = Month(date: t.date)
            guard m >= q.from, m <= q.to else { return false }
            if let c = q.category { guard t.category == c else { return false } }
            else if !t.countsAsSpending { return false }
            if let p = q.place {
                guard t.merchant.localizedCaseInsensitiveContains(p) || t.description.localizedCaseInsensitiveContains(p) else { return false }
            }
            return true
        }
        let total = matches.reduce(0) { $0 + (wantsIncome ? abs($1.amount) : $1.amount) }
        let what = [q.category.map { "on \($0.displayName)" }, q.place.map { "at \($0.capitalized)" }].compactMap { $0 }.joined(separator: " ")
        let verb = wantsIncome ? "You received" : "You spent"

        func txRows(_ list: [Transaction]) -> [(String, String, String, Category?)] {
            list.map { ($0.merchant, $0.date.formatted(.dateTime.month(.abbreviated).day().year()), Money.format($0.amount), $0.category) }
        }

        return tidy(compose())

        func tidy(_ a: Answer) -> Answer {
            let h = a.headline.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: " .", with: ".").replacingOccurrences(of: " ,", with: ",")
            return Answer(question: a.question, query: a.query, headline: h, rows: a.rows)
        }

        func compose() -> Answer {
        switch q.metric {
        case .total:
            return Answer(question: question, query: q,
                          headline: "\(verb) \(Money.format(total)) \(what) in \(range).".replacingOccurrences(of: "  ", with: " "),
                          rows: txRows(Array(matches.sorted { $0.amount > $1.amount }.prefix(5))))
        case .count:
            return Answer(question: question, query: q,
                          headline: "\(matches.count) \(matches.count == 1 ? "transaction" : "transactions") \(what) in \(range), \(Money.format(total)) in all.",
                          rows: txRows(Array(matches.sorted { $0.date > $1.date }.prefix(5))))
        case .list:
            return Answer(question: question, query: q,
                          headline: matches.isEmpty ? "I didn't find anything \(what) in \(range)."
                                                    : "Here's what I found \(what) in \(range): \(matches.count) for \(Money.format(total)).",
                          rows: txRows(Array(matches.sorted { $0.date > $1.date }.prefix(12))))
        case .monthlyAverage:
            let monthCount = max(1, store.months.filter { $0 >= q.from && $0 <= q.to }.count)
            return Answer(question: question, query: q,
                          headline: "On average, \(Money.format(total / Double(monthCount))) a month \(what) (\(range)).",
                          rows: store.months.filter { $0 >= q.from && $0 <= q.to }.map { m in
                              let t = matches.filter { Month(date: $0.date) == m }.reduce(0) { $0 + $1.amount }
                              return (m.title, "", Money.format(t), nil)
                          })
        case .topPlaces:
            let grouped = Dictionary(grouping: matches, by: \.merchant)
                .map { (name: $0.key, total: $0.value.reduce(0) { $0 + $1.amount }, count: $0.value.count, cat: $0.value[0].category) }
                .sorted { $0.total > $1.total }.prefix(8)
            return Answer(question: question, query: q,
                          headline: grouped.first.map { "\($0.name) is your top payee \(what) in \(range), at \(Money.format($0.total))." }
                              ?? "No spending found \(what) in \(range).",
                          rows: grouped.map { ($0.name, $0.count == 1 ? "1 visit" : "\($0.count) visits", Money.format($0.total), $0.cat) })
        case .topCategories:
            let grouped = Dictionary(grouping: matches, by: \.category)
                .map { (cat: $0.key, total: $0.value.reduce(0) { $0 + $1.amount }) }
                .sorted { $0.total > $1.total }
            return Answer(question: question, query: q,
                          headline: grouped.first.map { "\($0.cat.displayName) was your biggest category in \(range), at \(Money.format($0.total))." }
                              ?? "No spending found in \(range).",
                          rows: grouped.map { ($0.cat.displayName, "", Money.format($0.total), $0.cat) })
        case .subscriptions:
            let subs = store.subscriptions()
            let monthly = subs.reduce(0) { $0 + $1.monthlyAmount }
            return Answer(question: question, query: q,
                          headline: subs.isEmpty ? "I don't see any regular monthly charges yet. I need at least two months of statements."
                                                 : "You have \(subs.count) regular monthly charges, about \(Money.format(monthly)) a month (\(Money.format(monthly * 12, cents: false)) a year).",
                          rows: subs.map { ($0.merchant, "last charged \($0.lastCharge.formatted(.dateTime.month(.abbreviated).day()))", Money.format($0.monthlyAmount) + "/mo", $0.category) })
        }
        }
    }
}

// MARK: - View

struct AskView: View {
    @Environment(BudgetStore.self) private var store
    @State private var question = ""
    @State private var answers: [Answer] = []
    /// The question being answered, shown while its answer is worked out.
    @State private var pending: String?
    private var thinking: Bool { pending != nil }
    @State private var turns: [ChatAnalyst.Turn] = []
    @FocusState private var focused: Bool

    private var examples: [String] {
        guard CloudAI.isEnabled, let latest = store.months.last else {
            return ["How much did I spend on dining last month?", "What are my subscriptions?", "Top payees this year",
                    "What did I buy at Amazon?", "Average monthly grocery spending"]
        }
        var list = ["Why was \(latest.name) so high?", "Where does most of my money go?", "Show dining month by month",
                    "What are my biggest purchases this year?"]
        if let trip = store.stories.first { list.insert("How much did \(trip.name) cost?", at: 1) }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            // The pane's own heading, with a way to put it away.
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Ask").font(.system(size: 20, weight: .bold, design: .serif))
                Text("ABOUT YOUR MONEY").font(Theme.mono(9.5, .semibold)).tracking(1.2).foregroundStyle(.secondary)
                Spacer()
                if !answers.isEmpty {
                    Button("Start Over") { withAnimation(.snappy) { answers = []; turns = [] } }
                        .buttonStyle(.borderless).font(.callout)
                }
                Button { withAnimation(.snappy(duration: 0.25)) { store.showsAsk = false } } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Close (⌘K)")
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 10)
            ReceiptRule().padding(.horizontal, 18)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if answers.isEmpty, pending == nil { intro }
                        ForEach(answers) { answer in
                            AnswerBubble(answer: answer).id(answer.id)
                                // The slip feeds out from the top, whole: readable at once, no waiting on lines.
                                .transition(.asymmetric(insertion: .scale(scale: 1, anchor: .top).combined(with: .move(edge: .top)).combined(with: .opacity),
                                                        removal: .opacity))
                        }
                        // The question shows the moment it is sent, with dots under it until the answer is ready.
                        if let pending {
                            VStack(alignment: .leading, spacing: 10) {
                                QuestionNote(text: pending)
                                ThinkingDots()
                            }
                            .id("thinking")
                            .transition(.opacity)
                        }
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: answers.count) {
                    withAnimation { proxy.scrollTo(answers.last?.id, anchor: .bottom) }
                }
                .onChange(of: pending) {
                    if pending != nil { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } }
                }
            }

            // A line to write on: a sheet of paper with a hairline edge, like every card in the app.
            HStack(spacing: 10) {
                TextField("Ask about your spending…", text: $question, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.plain)
                    .font(.body)
                    .focused($focused)
                    .onSubmit(ask)
                Button(action: ask) {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 26))
                }
                .buttonStyle(.plain)
                .foregroundStyle(question.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary.opacity(0.5) : Theme.accent)
                .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || thinking)
            }
            .padding(.leading, 14)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .background(Theme.sheet, in: .rect(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(focused ? Theme.accent.opacity(0.55) : Theme.hairline) }
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
            .padding(.top, 6)
        }
        .onAppear {
            if answers.isEmpty, let q = DebugHooks.askQuestion { store.showsAsk = true; question = q; ask() }
        }
        .onChange(of: store.showsAsk) { focused = store.showsAsk }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 16) {
            SpotArt(name: "ask", height: 150)
                .frame(maxWidth: .infinity)
            Text(CloudAI.isEnabled ? "Ask anything about where the money went. Then keep going: “and last year?”, “why?”"
                                   : "Answered right here on your Mac. Nothing is sent anywhere.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // Things to try, as one sheet with a line each.
            VStack(alignment: .leading, spacing: 0) {
                Text("TRY ONE").font(Theme.mono(9.5, .semibold)).tracking(1.2).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
                ForEach(Array(examples.enumerated()), id: \.element) { index, example in
                    if index > 0 { Divider().padding(.leading, 14) }
                    Button { question = example; ask() } label: {
                        HStack(spacing: 8) {
                            Text(example).multilineTextAlignment(.leading)
                            Spacer(minLength: 8)
                            Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Theme.sheet, in: .rect(cornerRadius: 14, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.hairline) }
        }
    }

    private func ask() {
        let q = question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !thinking else { return }
        question = ""
        withAnimation(.snappy(duration: 0.2)) { pending = q }
        Task {
            // With the cloud model this is a conversation; otherwise one question at a time, on the Mac.
            if let (answer, turn) = await ChatAnalyst.answer(q, history: turns, store: store) {
                turns.append(turn)
                withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) { answers.append(answer); pending = nil }
                return
            }
            let query = await QueryParser.parse(q, months: store.months)
            let answer = AnswerEngine.answer(q, query: query, store: store)
            withAnimation(.snappy) { answers.append(answer); pending = nil }
        }
    }
}

/// Turns every place named in an answer into a link to that place's page.
@MainActor
enum PlaceLinker {
    private static var cache: (count: Int, names: [String])?

    /// Every place name, longest first, so "Westside Market NYC" wins over "Westside Market".
    static func names() -> [String] {
        let store = BudgetStore.shared
        if let cache, cache.count == store.transactions.count { return cache.names }
        let names = Set(store.transactions.map(\.merchant)).filter { $0.count >= 4 }.sorted { $0.count > $1.count }
        cache = (store.transactions.count, names)
        return names
    }

    static func url(for name: String) -> URL? {
        var parts = URLComponents()
        parts.scheme = "spendthrift-place"
        parts.host = "open"
        parts.queryItems = [URLQueryItem(name: "name", value: name)]
        return parts.url
    }

    static func name(from url: URL) -> String? {
        guard url.scheme == "spendthrift-place" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "name" }?.value
    }

    static func link(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        var taken: [Range<String.Index>] = []
        for name in names() {
            var from = text.startIndex
            while let found = text.range(of: name, options: [.caseInsensitive, .diacriticInsensitive], range: from..<text.endIndex) {
                from = found.upperBound
                // Whole words only, and never inside a longer name already linked.
                let before = found.lowerBound > text.startIndex ? text[text.index(before: found.lowerBound)] : " "
                let after = found.upperBound < text.endIndex ? text[found.upperBound] : " "
                guard !before.isLetter, !before.isNumber, !after.isLetter, !after.isNumber,
                      !taken.contains(where: { $0.overlaps(found) }),
                      let lower = AttributedString.Index(found.lowerBound, within: out),
                      let upper = AttributedString.Index(found.upperBound, within: out) else { continue }
                taken.append(found)
                out[lower..<upper].link = url(for: name)
                out[lower..<upper].underlineStyle = .single
            }
        }
        return out
    }
}

/// Clicking something in an answer (a bar, a row) goes to the charges behind it.
@MainActor
enum Drill {
    enum Target { case place(String), category(Category), month(Month), story(Story) }

    static func target(_ label: String, in answer: Answer) -> Target? {
        let text = label.trimmingCharacters(in: .whitespaces)
        if let place = PlaceLinker.names().first(where: { $0.caseInsensitiveCompare(text) == .orderedSame }) { return .place(place) }
        if let story = BudgetStore.shared.stories.first(where: { $0.name.caseInsensitiveCompare(text) == .orderedSame }) { return .story(story) }
        if let category = Category.pickable.first(where: { $0.displayName.caseInsensitiveCompare(text) == .orderedSame }) { return .category(category) }
        if let month = month(text, in: answer) { return .month(month) }
        return nil
    }

    /// "Jul", "July", "Jul 2026", "July ’26", "2026-07": with no year, the most recent such month there is data for.
    private static func month(_ text: String, in answer: Answer) -> Month? {
        if let exact = Month(key: text) { return exact }
        let cleaned = text.replacingOccurrences(of: "’", with: "").replacingOccurrences(of: "'", with: "").replacingOccurrences(of: ",", with: "")
        let parts = cleaned.split(separator: " ").map(String.init)
        let names = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        guard let first = parts.first, first.count >= 3, let index = names.firstIndex(of: String(first.lowercased().prefix(3))),
              first.allSatisfy(\.isLetter) else { return nil }
        if parts.count >= 2, var year = Int(parts[1]) {
            if year < 100 { year += 2000 }
            return Month(year: year, month: index + 1)
        }
        guard parts.count == 1 else { return nil }
        return BudgetStore.shared.months.last { $0.month == index + 1 }
    }

    /// The category the question was about ("show dining month by month"), so a month keeps that focus.
    private static func category(in answer: Answer) -> Category? {
        if let c = answer.query.category { return c }
        let question = answer.question.lowercased()
        return Category.pickable.first { category in
            let word = category.displayName.lowercased().components(separatedBy: CharacterSet.letters.inverted).first ?? ""
            return word.count >= 4 && question.contains(word)
        }
    }

    static func open(_ label: String, in answer: Answer) {
        let store = BudgetStore.shared
        switch target(label, in: answer) {
        case .place(let name): store.showPlace(name)
        // One plain page of charges, not the full table with its filters and inspector.
        case .story(let story): store.showCharges(TransactionFilter(storyID: story.id))
        case .category(let category):
            store.showCharges(TransactionFilter(category: category, month: answer.query.from == answer.query.to ? answer.query.from : nil))
        case .month(let month):
            store.showCharges(TransactionFilter(category: category(in: answer), month: month))
        case nil: break
        }
    }
}

/// One exchange: the question as it was asked, then the answer printed on a slip of receipt paper.
/// What was asked, in the person's own words, set to the right like a note in the margin.
struct QuestionNote: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            Text(text)
                .padding(.horizontal, 13).padding(.vertical, 8)
                .background(Theme.accent.opacity(0.10), in: .rect(cornerRadius: 13, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Theme.accent.opacity(0.18)) }
                .textSelection(.enabled)
        }
    }
}

/// Three dots taking turns: an answer is on its way.
struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    let wave = (sin(t * 5 - Double(i) * 0.9) + 1) / 2
                    Circle().fill(Color.secondary).frame(width: 7, height: 7)
                        .opacity(0.3 + 0.7 * wave)
                        .offset(y: -3 * wave)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(Theme.sheet, in: .rect(cornerRadius: 13, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Theme.hairline) }
        }
        .accessibilityLabel("Thinking")
    }
}

struct AnswerBubble: View {
    let answer: Answer

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // The question: quiet, in the person's own words, set to the right like a note in the margin.
            QuestionNote(text: answer.question)
            ReceiptPaper(padding: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    // Any place named in the answer is a link to everything spent there.
                    Text(PlaceLinker.link(answer.headline))
                        .font(.system(size: 16, weight: .semibold, design: .serif))
                        .lineSpacing(2)
                        .tint(Theme.accent)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .environment(\.openURL, OpenURLAction { url in
                            guard let name = PlaceLinker.name(from: url) else { return .systemAction }
                            BudgetStore.shared.showPlace(name)
                            return .handled
                        })
                    if answer.chart.count >= 2 {
                        AnswerChart(bars: answer.chart, isLine: answer.chartIsLine) { Drill.open($0, in: answer) }
                        if answer.chart.contains(where: { Drill.target($0.label, in: answer) != nil }) {
                            Text("Click a bar to see the charges behind it.").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    if !answer.rows.isEmpty {
                        ReceiptRule()
                        VStack(spacing: 9) {
                            ForEach(Array(answer.rows.enumerated()), id: \.offset) { _, row in
                                ReceiptLine(value: row.value) {
                                    HStack(spacing: 8) {
                                        if let c = row.category { CategoryIcon(category: c, size: 20) }
                                        VStack(alignment: .leading, spacing: 0) {
                                            if Drill.target(row.label, in: answer) != nil {
                                                Button(row.label) { Drill.open(row.label, in: answer) }
                                                    .buttonStyle(.plain)
                                                    .foregroundStyle(Theme.accent)
                                                    .lineLimit(1)
                                                    .help("See the charges behind \(row.label)")
                                            } else {
                                                Text(row.label).lineLimit(1)
                                            }
                                            if !row.detail.isEmpty {
                                                Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    ReceiptRule()
                    interpretation
                }
            }
        }
    }

    /// Shows how the question was understood, so Tony can trust (or rephrase) it.
    private var interpretation: some View {
        let q = answer.query
        let parts = [q.category?.displayName, q.place?.capitalized,
                     q.from == q.to ? q.from.title : "\(q.from.title) – \(q.to.title)"].compactMap { $0 }
        return Text((answer.understood.map { "Looked up: \($0)" } ?? parts.joined(separator: " · ")).uppercased())
            .font(Theme.mono(9.5))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The figures behind an answer, drawn: bars for categories and places, a line for months.
private struct AnswerChart: View {
    let bars: [ChatAnalyst.ChartBar]
    let isLine: Bool
    /// Called with the label of the bar (or point) that was clicked.
    var onPick: (String) -> Void = { _ in }

    var body: some View {
        Chart(Array(bars.enumerated()), id: \.offset) { _, bar in
            if isLine {
                LineMark(x: .value("When", bar.label), y: .value("Amount", bar.value))
                    .foregroundStyle(Theme.accent)
                    .interpolationMethod(.monotone)
                    .symbol(.circle)
                AreaMark(x: .value("When", bar.label), y: .value("Amount", bar.value))
                    .foregroundStyle(LinearGradient(colors: [Theme.accent.opacity(0.25), Theme.accent.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
            } else {
                BarMark(x: .value("What", bar.label), y: .value("Amount", bar.value), width: .ratio(0.62))
                    .cornerRadius(5)
                    .foregroundStyle((bar.category?.color ?? Theme.accent).gradient)
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisValueLabel(collisionResolution: .greedy(minimumSpacing: 6)).font(.caption2)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine()
                AxisValueLabel { if let v = value.as(Double.self) { Text(Money.format(v, cents: false)) } }
            }
        }
        .chartOverlay { proxy in Color.clear.barPointer(proxy, tap: onPick) }
        .frame(height: 170)
    }
}

/// Wraps example chips onto multiple lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: width.isFinite ? width : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}
