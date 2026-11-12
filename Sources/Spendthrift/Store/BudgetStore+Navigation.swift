import SwiftUI

/// Where the person is, and how they got there.
///
/// A place in the app is a sidebar section, optionally one of the Overview's cards stepped into,
/// optionally a stack of pages opened over it (a list of charges, a payee). Every link inside a page
/// goes through `navigate`, which remembers where it left from, so Back always returns there.
/// Choosing a section in the sidebar is a fresh start.
extension BudgetStore {
    /// A page opened over a section.
    enum Route: Equatable {
        case charges(TransactionFilter)
        case place(String)
    }

    struct Location: Equatable {
        var section: SidebarItem
        var detail: OverviewDetail?
        var route: [Route] = []
        /// On the Amazon page: the one order on show, and the search. Back puts them back.
        var orderOnly: String?
        var orderSearch = ""
    }

    var location: Location {
        let onOrders = selection == .orders
        return Location(section: selection ?? .overview, detail: overviewDetail, route: route,
                        orderOnly: onOrders ? orderOnly : nil, orderSearch: onOrders ? orderSearch : "")
    }
    var canGoBack: Bool { !history.isEmpty }

    /// Makes a move and remembers where it started.
    func navigate(_ move: () -> Void) {
        let from = location
        isNavigating = true
        withAnimation(.snappy(duration: 0.25)) { move() }
        isNavigating = false
        guard location != from else { return }
        history.append(from)
        if history.count > 60 { history.removeFirst() }
    }

    func back() {
        guard let to = history.popLast() else { return }
        isNavigating = true
        withAnimation(.snappy(duration: 0.25)) {
            selection = to.section
            overviewDetail = to.detail
            route = to.route
            if to.section == .orders { orderOnly = to.orderOnly; orderSearch = to.orderSearch }
        }
        isNavigating = false
    }

    /// Another section, reached from a link in a page (not the sidebar), set up as `then` says.
    func go(to section: SidebarItem, then setUp: () -> Void = {}) {
        navigate {
            selection = section
            overviewDetail = nil
            route = []
            setUp()
        }
    }

    /// One of the Overview's cards, stepped into.
    func stepInto(_ detail: OverviewDetail) {
        navigate {
            selection = .overview
            route = []
            overviewDetail = detail
        }
    }

    /// One simple page listing the charges that match.
    func showCharges(_ filter: TransactionFilter) {
        navigate { route.append(.charges(filter)) }
    }

    func showPlace(_ name: String) {
        navigate { if route.last != .place(name) { route.append(.place(name)) } }
    }

    /// The same, for a payee known by its key.
    func showPlace(key: String) {
        if let name = place(key)?.name { showPlace(name) }
    }

    /// The payee on screen has a new name: stay on its page.
    func placeRenamed(to name: String) {
        if case .place? = route.last { route[route.count - 1] = .place(name) }
    }

    func showSpending(in month: Month) {
        showCharges(TransactionFilter(ids: Set(spending(in: month).map(\.id)), title: "Spending in \(month.title)"))
    }

    /// Opens what an insight is about: its charges, its payee, or its category for the month.
    func show(_ insight: Insight) {
        switch insight.target {
        case .place(let name)?: showPlace(name)
        case .charges(let ids, let title)?: showCharges(TransactionFilter(ids: ids, title: title))
        case .category(let category, let month)?: showCharges(TransactionFilter(category: category, month: month))
        case nil: break
        }
    }

    /// The Amazon page showing just the order behind one charge.
    func showOrder(of charge: Transaction.ID) {
        guard let order = orders.items(for: charge).first?.orderID else { return }
        go(to: .orders) {
            orderScope = .all; orderWho = nil; orderKind = nil; orderSearch = ""
            orderOnly = order
        }
    }

    /// The Statements page on one file (and, optionally, one charge in it).
    func browse(_ source: SourceFile, charge: UUID? = nil) {
        originalPeek = nil
        go(to: .statements) { statementFocus = StatementFocus(sourceID: source.id, entryID: charge) }
    }

    // MARK: Saying where

    /// What Back leads to, for its label.
    var backTitle: String { history.last.map(title(of:)) ?? "Back" }

    func title(of location: Location) -> String {
        switch location.route.last {
        case .place(let name)?: return name
        case .charges(let filter)?: return filter.title ?? filter.category?.displayName ?? "Charges"
        case nil: break
        }
        if let detail = location.detail { return detail.title }
        return location.section.title
    }

    /// The page in front of the person, in a sentence, for the question pane to read a question by.
    var screenContext: String? {
        guard !accounts.isEmpty else { return nil }
        switch route.last {
        case .place(let name)?: return "the page for one payee, \(name)"
        case .charges(let filter)?: return "a list of charges" + (filter.title.map { ": \($0)" } ?? "")
        case nil: break
        }
        switch selection ?? .overview {
        case .orders:
            var parts = ["the Amazon page (the order history: items ordered from Amazon, Whole Foods and Kindle)"]
            switch orderScope {
            case .all: parts.append("showing all time")
            case .year(let year): parts.append("showing the year \(year)")
            case .month(let month): parts.append("showing \(month.title)")
            }
            if let who = orderWho { parts.append("only \(who)'s orders") }
            if let kind = orderKind { parts.append("only the kind \(kind)") }
            if !orderSearch.trimmingCharacters(in: .whitespaces).isEmpty { parts.append("searched for “\(orderSearch)”") }
            return parts.joined(separator: ", ")
        case .overview:
            switch overviewDetail {
            case .spending: return "their everyday spending, by category and month"
            case .income: return "their income, by who paid it"
            case .investing: return "the investment side: what was invested and what came back"
            case .recurring: return "their bills and subscriptions: what repeats, what it costs a year, what crept up and what looks forgotten"
            case .flow: return "all their money in and out (income, spending, taxes, investing)"
            case nil: return "the Overview: what came in and what it did, with spending, income and investing"
            }
        case .stories: return "the Trips & Events page"
        case .places: return "the list of payees"
        case .transactions: return "the list of all transactions"
        case .statements: return "their statements"
        case .apart: return "the page of accounts kept apart from their own money"
        case .review, .categories, .accounts: return nil
        }
    }
}

extension BudgetStore.OverviewDetail {
    var title: String {
        switch self {
        case .flow: "Money In and Out"
        case .spending: "Spending"
        case .income: "Income"
        case .investing: "Investing"
        case .recurring: "Bills & Subscriptions"
        }
    }
}

extension SidebarItem {
    var title: String {
        switch self {
        case .overview: "Overview"
        case .stories: "Trips & Events"
        case .places: "Payees"
        case .orders: "Amazon"
        case .apart: "Kept Apart"
        case .transactions: "Transactions"
        case .statements: "Statements"
        case .review: "Double-Check"
        case .categories, .accounts: "Setup"
        }
    }
}

/// The one way back: shown above a page whenever a link led to it, named for where it returns.
struct BackBar: View {
    @Environment(BudgetStore.self) private var store

    var body: some View {
        if store.canGoBack {
            HStack {
                Button { store.back() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left").font(.callout.weight(.semibold))
                        Text(store.backTitle).font(.headline).lineLimit(1)
                    }
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 14).frame(height: 32)
                    .background(Color.primary.opacity(0.07), in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("[", modifiers: .command)
                .help("Back (⌘[)")
                Spacer()
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)
            .padding(.bottom, 2)
            .frame(maxWidth: 1256)
            .frame(maxWidth: .infinity)
            .transition(.opacity)
        }
    }
}
