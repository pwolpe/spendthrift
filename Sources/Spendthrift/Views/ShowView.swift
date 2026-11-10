import SwiftUI

/// What happens when someone drops in a pile of statements: first the work, shown as it happens
/// (statements counted off, accounts and trips called out as they're found), then a short premiere
/// of what was learned. The first minute is the one that decides whether the app feels like magic.
struct ShowView: View {
    private var store: BudgetStore { .shared }
    @State private var facts: [String] = []
    @State private var said: Set<String> = []
    @State private var card = 0
    @State private var quietSince: Date?

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThickMaterial).ignoresSafeArea()
            if store.stage == .premiere {
                premiere.transition(.opacity)
            } else {
                working.transition(.opacity)
            }
        }
        .task { await narrate() }
    }

    // MARK: The work, live

    private var working: some View {
        let progress = store.importProgress
        let reading = store.isImporting
        return VStack(spacing: 22) {
            SpotArt(name: "sorting", height: 230)
            Text(reading ? "Reading your statements…" : "Working out where it all went…")
                .font(.system(size: 34, weight: .bold, design: .serif))
                .contentTransition(.opacity)
            if let progress, progress.total > 0 {
                ProgressView(value: Double(progress.done), total: Double(progress.total))
                    .tint(Theme.accent)
                    .frame(maxWidth: 420)
            } else {
                ProgressView().controlSize(.small)
            }
            HStack(spacing: 34) {
                if let progress { counter(progress.done, progress.done == 1 ? "statement" : "statements") }
                counter(store.transactions.count, "charges")
                counter(store.accounts.count, store.accounts.count == 1 ? "account" : "accounts")
                counter(Set(store.transactions.map(\.merchant)).count, "places")
            }
            VStack(spacing: 8) {
                ForEach(Array(facts.suffix(4).enumerated()), id: \.element) { index, fact in
                    Label(fact, systemImage: "sparkle")
                        .font(.title3)
                        .foregroundStyle(index == min(facts.count, 4) - 1 ? Color.primary : Color.secondary)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(height: 130, alignment: .bottom)
            .animation(.spring(duration: 0.45), value: facts)
            CloudTroubleBanner().frame(maxWidth: 620)
            Button("Keep Working in the Background") { store.stage = nil }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(40)
        .frame(maxWidth: 760)
    }

    private func counter(_ value: Int, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value.formatted())
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(value)))
                .animation(.snappy, value: value)
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
        .frame(minWidth: 96)
    }

    /// Says what has just been found, a line at a time, and moves on to the premiere once the
    /// reading and the sorting have both been quiet for a moment.
    private func narrate() async {
        while store.stage != nil, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(850))
            guard store.stage == .working else { continue }
            if let fact = nextFact() {
                said.insert(fact)
                facts.append(fact)
            }
            if store.isImporting || store.isSuggesting {
                quietSince = nil
            } else if let since = quietSince {
                if Date.now.timeIntervalSince(since) > 1.2, store.pendingImports.isEmpty {
                    withAnimation(.easeInOut(duration: 0.6)) { store.stage = store.transactions.isEmpty ? nil : .premiere }
                }
            } else {
                quietSince = .now
            }
        }
    }

    private func nextFact() -> String? {
        let all = store.transactions
        var candidates: [String] = []
        for account in store.accounts { candidates.append("Found \(account.name)") }
        if let first = all.first?.date, all.count > 20 {
            candidates.append("Going back to \(first.formatted(.dateTime.month(.wide).year()))")
        }
        let spending = all.filter(\.countsAsSpending)
        if let biggest = spending.max(by: { $0.amount < $1.amount }), biggest.amount > 200 {
            candidates.append("Biggest so far: \(Money.format(biggest.amount, cents: false)) at \(biggest.merchant)")
        }
        if let favorite = Dictionary(grouping: spending, by: \.merchant).max(by: { $0.value.count < $1.value.count }), favorite.value.count >= 5 {
            candidates.append("A regular: \(favorite.key), \(favorite.value.count) times")
        }
        if store.isLookingUp { candidates.append("Looking up the places I didn't recognize…") }
        if store.isSuggesting {
            let unsure = Set(all.filter(\.needsCheck).map(\.merchant)).count
            if unsure > 0 { candidates.append("Working out what \(unsure) unfamiliar places are…") }
        }
        let subscriptions = store.subscriptions().count
        if subscriptions >= 3 { candidates.append("\(subscriptions) charges that repeat every month") }
        for story in store.stories.prefix(6) { candidates.append("Found \(story.kind == .trip ? "a trip" : "an occasion"): \(story.name)") }
        return candidates.first { !said.contains($0) }
    }

    // MARK: The premiere

    private var cards: [PremiereCard.Kind] { PremiereCard.Kind.available(in: store) }

    private var premiere: some View {
        let list = cards
        let index = min(card, max(list.count - 1, 0))
        return VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip") { store.stage = nil }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            Spacer(minLength: 10)
            if !list.isEmpty {
                PremiereCard(kind: list[index]) { store.stage = nil }
                    .id(list[index])
                    .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                            removal: .move(edge: .leading).combined(with: .opacity)))
            }
            Spacer(minLength: 10)
            HStack(spacing: 14) {
                Button { withAnimation(.snappy) { card = max(0, index - 1) } } label: { Image(systemName: "chevron.left") }
                    .disabled(index == 0)
                    .keyboardShortcut(.leftArrow, modifiers: [])
                HStack(spacing: 7) {
                    ForEach(list.indices, id: \.self) { i in
                        Capsule().fill(i == index ? Theme.accent : Color.primary.opacity(0.18))
                            .frame(width: i == index ? 22 : 7, height: 7)
                    }
                }
                .animation(.snappy, value: index)
                Button {
                    if index >= list.count - 1 { store.stage = nil } else { withAnimation(.snappy) { card = index + 1 } }
                } label: {
                    Image(systemName: index >= list.count - 1 ? "checkmark" : "chevron.right")
                }
                .keyboardShortcut(.rightArrow, modifiers: [])
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            .padding(.bottom, 26)
        }
        // It plays by itself; any click or arrow takes over.
        .task(id: index) {
            try? await Task.sleep(for: .seconds(6.5))
            guard !Task.isCancelled, store.stage == .premiere, index < list.count - 1 else { return }
            withAnimation(.snappy) { card = index + 1 }
        }
    }
}

/// One card of the premiere. Each can be drawn on its own (the tests take pictures of them).
struct PremiereCard: View {
    enum Kind: Hashable {
        case opening, where_, standout, repeats, trips, noticed, verdict, finale

        @MainActor static func available(in store: BudgetStore) -> [Kind] {
            var list: [Kind] = [.opening, .where_]
            if store.transactions.contains(where: \.countsAsSpending) { list.append(.standout) }
            if store.subscriptions().count >= 2 { list.append(.repeats) }
            if !store.stories.isEmpty || store.isFindingStories { list.append(.trips) }
            if !store.discoveries.isEmpty { list.append(.noticed) }
            if store.months.count > 2 { list.append(.verdict) }
            list.append(.finale)
            return list
        }
    }

    private var store: BudgetStore { .shared }
    let kind: Kind
    var done: () -> Void = {}

    /// The last twelve months there is data for: recent enough to be about now.
    private var recent: [Transaction] {
        guard let last = store.months.last else { return [] }
        let start = last.adding(-11)
        return store.transactions.filter { $0.month >= start }
    }
    private var span: String {
        let months = min(store.months.count, 12)
        return months >= 12 ? "the last twelve months" : months == 1 ? "this month" : "the last \(months) months"
    }

    var body: some View {
        VStack(spacing: 22) {
            switch kind {
            case .opening: opening
            case .where_: whereItWent
            case .standout: standout
            case .repeats: repeats
            case .trips: trips
            case .noticed: noticed
            case .verdict: verdict
            case .finale: finale
            }
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: 760)
    }

    private func eyebrow(_ text: String) -> some View {
        Text(text.uppercased()).font(.callout.weight(.bold)).tracking(1.4).foregroundStyle(Theme.accent)
    }
    private func headline(_ text: String) -> some View {
        Text(text).font(.system(size: 40, weight: .bold, design: .serif)).multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func line(_ text: String) -> some View {
        Text(text).font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
    private func big(_ text: String) -> some View {
        Text(text).font(.system(size: 76, weight: .bold, design: .rounded)).monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
    }

    @ViewBuilder private var opening: some View {
        let all = store.transactions
        SpotArt(name: "welcome", height: 210)
        eyebrow("Everything is in")
        big(all.count.formatted())
        headline(all.count == 1 ? "charge, read and sorted" : "charges, read and sorted")
        if let first = all.first?.date {
            line("\(store.accounts.count) \(store.accounts.count == 1 ? "account" : "accounts"), \(Set(all.map(\.merchant)).count.formatted()) places, going back to \(first.formatted(.dateTime.month(.wide).year())).")
        }
    }

    @ViewBuilder private var whereItWent: some View {
        let spending = recent.filter(\.countsAsSpending)
        let total = spending.reduce(0) { $0 + $1.amount }
        let top = Dictionary(grouping: spending, by: \.category)
            .map { (category: $0.key, total: $0.value.reduce(0) { $0 + $1.amount }) }
            .filter { $0.total > 0 }.sorted { $0.total > $1.total }.prefix(5)
        eyebrow("Where it went")
        big(Money.format(total, cents: false))
        line("lived on in \(span). Most of it went here:")
        VStack(spacing: 12) {
            ForEach(Array(top), id: \.category) { item in
                HStack(spacing: 12) {
                    CategoryIcon(category: item.category, size: 34)
                    Text(item.category.displayName).font(.title3.weight(.medium)).frame(width: 190, alignment: .leading)
                    GeometryReader { geo in
                        Capsule().fill(item.category.color.gradient)
                            .frame(width: max(8, geo.size.width * CGFloat(item.total / max(top.first?.total ?? 1, 1))))
                    }
                    .frame(height: 12)
                    Text(Money.format(item.total, cents: false)).font(.title3.weight(.semibold)).monospacedDigit()
                        .frame(width: 110, alignment: .trailing)
                }
            }
        }
        .frame(maxWidth: 640)
    }

    @ViewBuilder private var standout: some View {
        let spending = recent.filter(\.countsAsSpending)
        // Rent and the electric bill are large and no surprise to anyone. What stands out is the
        // biggest thing that isn't a bill and doesn't come around every month.
        let routine = Set(store.subscriptions().map(\.merchant))
        let candidates = spending.filter { !routine.contains($0.merchant) && ![Category.home, .bills, .fees].contains($0.category) }
        if let biggest = (candidates.isEmpty ? spending : candidates).max(by: { $0.amount < $1.amount }) {
            eyebrow("The one that stands out")
            MerchantIcon(name: biggest.merchant, category: biggest.category, size: 84)
            big(Money.format(biggest.amount, cents: false))
            headline(biggest.merchant)
            line("on \(biggest.date.formatted(.dateTime.month(.wide).day().year())): the largest single charge in \(span).")
            if let favorite = Dictionary(grouping: spending, by: \.merchant).max(by: { $0.value.count < $1.value.count }), favorite.value.count >= 4,
               favorite.key != biggest.merchant {
                Label("And your most faithful haunt: \(favorite.key), \(favorite.value.count) visits, \(Money.format(favorite.value.reduce(0) { $0 + $1.amount }, cents: false)) in all.",
                      systemImage: "heart.fill")
                    .font(.title3).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
    }

    @ViewBuilder private var repeats: some View {
        let subs = store.subscriptions().sorted { $0.monthlyAmount > $1.monthlyAmount }
        let yearly = subs.reduce(0) { $0 + $1.monthlyAmount } * 12
        eyebrow("On repeat")
        big(Money.format(yearly, cents: false))
        headline("a year, on \(subs.count) charges that come around every month")
        VStack(spacing: 10) {
            ForEach(subs.prefix(5)) { sub in
                HStack(spacing: 12) {
                    MerchantIcon(name: sub.merchant, category: sub.category, size: 30)
                    Text(sub.merchant).font(.title3).lineLimit(1)
                    Spacer()
                    Text("\(Money.format(sub.monthlyAmount)) a month").font(.title3).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if subs.count > 5 { Text("and \(subs.count - 5) more").font(.callout).foregroundStyle(.tertiary) }
        }
        .frame(maxWidth: 520)
    }

    @ViewBuilder private var trips: some View {
        let found = store.stories.map { story in (story: story, total: store.transactions(in: story).reduce(0) { $0 + $1.amount }) }
            .sorted { $0.total > $1.total }
        eyebrow("Nobody told me about these")
        if found.isEmpty {
            SpotArt(name: "notrips", height: 200)
            headline("Still reading between the lines…")
            line("I'm looking for trips and occasions in your spending. They'll be waiting on the Trips & Events page.")
        } else {
            headline(found.count == 1 ? "I noticed a trip" : "I noticed \(found.count) trips and occasions")
            VStack(spacing: 14) {
                ForEach(found.prefix(4), id: \.story.id) { item in
                    HStack(spacing: 14) {
                        Image(systemName: item.story.kind == .trip ? "airplane.departure" : "party.popper.fill")
                            .font(.title2).foregroundStyle(.white)
                            .frame(width: 46, height: 46).background(Circle().fill(Theme.accent))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.story.name).font(.title2.weight(.semibold)).lineLimit(1)
                            Text(StoryCard.dates(item.story)).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(Money.format(item.total, cents: false)).font(.system(size: 30, weight: .bold, design: .serif)).monospacedDigit()
                    }
                }
            }
            .frame(maxWidth: 600)
            line("Worked out from the charges alone: a flight, a run of spending somewhere else, a flight home.")
        }
    }

    @ViewBuilder private var noticed: some View {
        let found = store.discoveries.prefix(3)
        eyebrow("I read every charge")
        headline("A few things you may not know")
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Array(found)) { item in
                let total = store.transactions(in: item).reduce(0) { $0 + $1.amount }
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: item.symbol).font(.system(size: 30)).foregroundStyle(Theme.accent).frame(width: 40)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.title).font(.title2.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
                            Spacer()
                            Text(Money.format(abs(total), cents: false)).font(.system(size: 24, weight: .bold, design: .rounded)).monospacedDigit()
                        }
                        Text(item.detail).font(.title3).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .frame(maxWidth: 640)
    }

    @ViewBuilder private var verdict: some View {
        if let period = ReportData.periods(for: store).first {
            let data = CashFlowData(store: store, period: period)
            let within = data.surplus >= 0
            eyebrow("The verdict")
            SpotArt(name: within ? "within" : "over", height: 230)
            headline(data.totalIncome <= 0 ? "I couldn't find your income yet"
                     : within ? "You lived within your income" : "You spent \(Money.format(-data.surplus, cents: false)) more than you earned")
            if data.totalIncome > 0 {
                line(within
                     ? "\(period.title): \(Money.format(data.consumed, cents: false)) consumed against \(Money.format(data.totalIncome, cents: false)) of income."
                       + (data.built > 0.5 ? " The \(Money.format(data.built, cents: false)) you invested isn't spending: it's still yours." : "")
                     : "\(period.title): \(Money.format(data.consumed, cents: false)) consumed against \(Money.format(data.totalIncome, cents: false)) of income. Investing isn't counted in that.")
            } else {
                line("Add the account your pay goes into and I'll tell you whether spending stayed within it.")
            }
        }
    }

    @ViewBuilder private var finale: some View {
        let picture = DailyPicture.shared
        eyebrow("And one more thing")
        if let image = picture.image {
            Image(nsImage: image).resizable().aspectRatio(21.0 / 9.0, contentMode: .fit)
                .clipShape(.rect(cornerRadius: 20, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 18, y: 8)
        }
        headline(CloudAI.isEnabled ? "Every time you open the app, a new picture about something you really bought" : "Everything is added up")
        Button(action: done) {
            Text("Take Me In").font(.title3.weight(.semibold)).padding(.horizontal, 22).padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.extraLarge)
        .keyboardShortcut(.defaultAction)
    }
}

/// On the welcome screen: the one optional step that turns the magic on.
struct KeyEntry: View {
    private var store: BudgetStore { .shared }
    @State private var status = CloudStatus.shared
    @State private var key = ""
    @State private var testing = false
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if status.hasKey {
                Label("The magic is on. Drop in your statements.", systemImage: "wand.and.stars")
                    .font(.headline)
                    .foregroundStyle(Theme.good)
            } else {
                Label("First, turn on the magic", systemImage: "wand.and.stars").font(.headline)
                Text("Spendthrift uses a powerful AI model to read any statement, recognize every place, find your trips and draw the pictures. Paste an OpenRouter key and it does the rest. It costs a few cents per statement.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    SecureField("Paste your key (it starts with sk-or-)", text: $key)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(save)
                    Button("Turn On", action: save)
                        .buttonStyle(.borderedProminent)
                        .disabled(key.trimmingCharacters(in: .whitespaces).count < 10 || testing)
                }
                HStack(spacing: 14) {
                    if let url = URL(string: "https://openrouter.ai/keys") {
                        Link("Get a key at openrouter.ai (one minute)", destination: url).font(.callout)
                    }
                    if testing { ProgressView().controlSize(.small) }
                    Spacer()
                    Text("Or skip this: the basics work without it.").font(.caption).foregroundStyle(.tertiary)
                }
                if let problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(Theme.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: 560, alignment: .leading)
        .background(Theme.accent.opacity(0.07), in: .rect(cornerRadius: 18, style: .continuous))
    }

    private func save() {
        let entered = key
        guard entered.trimmingCharacters(in: .whitespaces).count >= 10, !testing else { return }
        guard CloudKey.save(entered) else { problem = "The key couldn't be saved."; return }
        key = ""
        testing = true
        Task {
            let failure = await CloudAI.test()
            testing = false
            if let failure {
                // A key that doesn't work is worse than none: take it back out and say why.
                CloudKey.delete()
                problem = failure
            } else {
                problem = nil
                store.cloudBecameAvailable()
            }
            status.refreshKey()
        }
    }
}
