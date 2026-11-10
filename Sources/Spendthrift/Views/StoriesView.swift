import SwiftUI

/// Trips and events the app noticed without being told: a flight, a week of charges somewhere
/// else, a flight home. Which charges belong is the model's call; every total is added up here.
struct StoriesView: View {
    @Environment(BudgetStore.self) private var store
    /// False when rendered for a test snapshot (ImageRenderer can't draw scroll views).
    var scrolls = true

    var body: some View {
        if scrolls {
            ScrollView { content }.navigationTitle("Trips & Events")
        } else {
            content
        }
    }

    private var content: some View {
        let stories = store.stories
        return VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 16) {
                CastAvatars(size: 50)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Trips & Events")
                        .font(.system(size: 30, weight: .bold, design: .serif))
                    Text(subtitle(stories))
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if store.isFindingStories {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for stories…").foregroundStyle(.secondary)
                    }
                }
            }
            if stories.isEmpty {
                if store.isFindingStories {
                    TonySays(title: "Reading between the lines…", message: "I'm looking through your spending for trips and occasions. This takes a minute the first time.", art: "nothing")
                } else if !CloudAI.isEnabled {
                    TonySays(title: "This one needs Smarter AI", message: "With a key entered in Settings, I can spot trips and occasions in your spending and tell you what each one cost.", art: "notrips")
                } else {
                    TonySays(title: "No trips yet", message: "When your statements show a trip or a big occasion, it will appear here with what it cost.", art: "notrips")
                }
            } else {
                // A year at a time, newest first: with several years of statements there can be dozens.
                let byYear = Dictionary(grouping: stories) { String($0.start.prefix(4)) }
                ForEach(byYear.keys.sorted(by: >), id: \.self) { year in
                    let list = (byYear[year] ?? []).sorted { $0.start > $1.start }
                    let total = list.reduce(0.0) { sum, story in sum + store.transactions(in: story).reduce(0) { $0 + $1.amount } }
                    HStack(alignment: .firstTextBaseline) {
                        Text(year).font(.system(size: 22, weight: .bold, design: .serif))
                        Text("\(list.count == 1 ? "1 trip" : "\(list.count) trips") · \(Money.format(total, cents: false))")
                            .font(.callout).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.top, 6)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 18, alignment: .top)], alignment: .leading, spacing: 18) {
                        ForEach(list) { StoryCard(story: $0) }
                    }
                }
                Text("Click a trip to see its charges. If one isn't a trip at all, right-click it.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(28)
        .frame(maxWidth: 1100)
        .frame(maxWidth: .infinity)
    }

    private func subtitle(_ stories: [Story]) -> String {
        guard !stories.isEmpty else { return "The stories in your spending, noticed for you." }
        let trips = stories.filter { $0.kind == .trip }.count, events = stories.count - trips
        let total = stories.reduce(0.0) { sum, story in sum + store.transactions(in: story).reduce(0) { $0 + $1.amount } }
        var parts: [String] = []
        if trips > 0 { parts.append(trips == 1 ? "1 trip" : "\(trips) trips") }
        if events > 0 { parts.append(events == 1 ? "1 event" : "\(events) events") }
        return parts.joined(separator: " and ") + ", \(Money.format(total, cents: false)) in all."
    }
}

/// A thin bar split in proportion, one colored piece per category.
struct CategoryStrip: View {
    let parts: [(color: Color, amount: Double)]

    var body: some View {
        let sum = max(parts.reduce(0.0) { $0 + $1.amount }, 1)
        GeometryReader { geo in
            let usable = geo.size.width - CGFloat(max(parts.count - 1, 0)) * 2
            HStack(spacing: 2) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                    let width: CGFloat = max(3, usable * CGFloat(part.amount / sum))
                    RoundedRectangle(cornerRadius: 3).fill(part.color.gradient).frame(width: width)
                }
            }
        }
    }
}

struct StoryCard: View {
    private var store: BudgetStore { .shared }   // not from the environment: menus and sheets don't always pass it down
    let story: Story
    var compact = false
    @State private var hovering = false

    static func dates(_ story: Story) -> String {
        guard let start = DateParsing.parse(story.start, format: "yyyy-MM-dd"),
              let end = DateParsing.parse(story.end, format: "yyyy-MM-dd") else { return "" }
        let sameMonth = Calendar.current.isDate(start, equalTo: end, toGranularity: .month)
        if Calendar.current.isDate(start, inSameDayAs: end) { return start.formatted(.dateTime.month(.wide).day().year()) }
        if sameMonth {
            let day = Calendar.current.component(.day, from: end), year = Calendar.current.component(.year, from: end)
            return "\(start.formatted(.dateTime.month(.wide).day()))–\(day), \(String(year))"
        }
        return "\(start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day().year()))"
    }

    var body: some View {
        let txns = store.transactions(in: story)
        let total = txns.reduce(0) { $0 + $1.amount }
        let byCategory = Dictionary(grouping: txns, by: \.category)
            .map { (category: $0.key, total: $0.value.reduce(0) { $0 + $1.amount }) }
            .filter { $0.total > 0 }
            .sorted { $0.total > $1.total }
        Card(padding: compact ? 16 : 20) {
            VStack(alignment: .leading, spacing: compact ? 10 : 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: story.kind == .trip ? "airplane.departure" : "party.popper.fill")
                        .font(.system(size: compact ? 15 : 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: compact ? 34 : 42, height: compact ? 34 : 42)
                        .background(Circle().fill(Theme.accent))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(story.name)
                            .font(.system(compact ? .headline : .title3, design: .serif).weight(.bold))
                            .lineLimit(1)
                        Text(Self.dates(story))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(Money.format(total, cents: false))
                            .font(.system(size: compact ? 20 : 26, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text(txns.count == 1 ? "1 charge" : "\(txns.count) charges")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if !story.summary.isEmpty, !compact {
                    // Always two lines' worth of room, so every tile is the same height.
                    Text(story.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2, reservesSpace: true)
                }
                if !byCategory.isEmpty, total > 0 {
                    CategoryStrip(parts: byCategory.map { ($0.category.color, $0.total) })
                        .frame(height: 8)
                }
            }
        }
        // The whole tile opens the trip. Saying "this isn't a trip" lives in the right-click menu,
        // where it is there when wanted and out of the way when not.
        .contentShape(Rectangle())
        .onTapGesture { open() }
        .onHover { hovering = $0 }
        .scaleEffect(hovering ? 1.012 : 1)
        .animation(.snappy(duration: 0.18), value: hovering)
        .contextMenu {
            Button(story.kind == .trip ? "This Isn't a Trip" : "This Isn't an Event", systemImage: "xmark.circle") {
                store.dismissStory(story)
            }
        }
        .help("Click to see the charges")
    }

    private func open() {
        // One plain page of the trip's charges; the full table stays out of the way.
        store.showCharges(TransactionFilter(storyID: story.id))
    }
}
