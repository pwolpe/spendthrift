import SwiftUI

/// Every category with its all-time total, and the place to make, edit or delete Tony's own.
struct CategoriesView: View {
    @Environment(BudgetStore.self) private var store

    var body: some View {
        let summary = store.categorySummary()
        let spending = summary.filter { $0.category.isSpending && $0.category != .unsorted }
        let top = max(spending.map(\.total).max() ?? 1, 1)
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Categories")
                            .font(.system(size: 30, weight: .bold, design: .serif))
                        Text("Make your own for anything you want to keep an eye on: the dog, the kids, the boat. Then pick it from any category menu, and I'll start using it too.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button { store.newCategory() } label: { Label("New Category", systemImage: "plus") }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                Card(padding: 8) {
                    VStack(spacing: 0) {
                        ForEach(Array(summary.enumerated()), id: \.element.category) { i, row in
                            if row.category != .unsorted || row.count > 0 {
                                CategoryManageRow(category: row.category, total: row.total, count: row.count,
                                                  fraction: row.category.isSpending ? max(0, row.total) / top : 0)
                                if i < summary.count - 1 { Divider().padding(.leading, 58) }
                            }
                        }
                    }
                }
                Text("Totals cover everything you've added so far.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(28)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Categories")
    }
}

private struct CategoryManageRow: View {
    @Environment(BudgetStore.self) private var store
    let category: Category
    let total: Double
    let count: Int
    let fraction: Double
    @State private var hovering = false
    @State private var confirmDelete = false

    private var custom: CustomCategory? { store.customCategories.first { $0.name == category.rawValue } }

    var body: some View {
        HStack(spacing: 12) {
            CategoryIcon(category: category, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(category.displayName).font(.body.weight(.medium))
                    if custom != nil {
                        Text("Yours")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.accent.opacity(0.16)))
                            .foregroundStyle(Theme.accent)
                    }
                }
                Text(count == 0 ? "Nothing yet" : (count == 1 ? "1 transaction" : "\(count) transactions"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if category.isSpending, category != .unsorted {
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.06))
                    Capsule().fill(category.color.gradient).frame(width: max(3, 120 * fraction))
                }
                .frame(width: 120, height: 6)
            }
            Text(Money.format(total, cents: false))
                .monospacedDigit()
                .frame(width: 90, alignment: .trailing)
            if let custom {
                Menu {
                    Button("Edit…", systemImage: "pencil") { store.categoryEditor = CategoryEditorRequest(editing: custom) }
                    Button("Delete…", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .opacity(hovering && count > 0 ? 1 : 0)
                    .frame(width: 16)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovering ? 0.04 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            guard count > 0 else { return }
            store.showCharges(TransactionFilter(category: category))
        }
        .confirmationDialog("Delete \(category.displayName)?", isPresented: $confirmDelete) {
            Button("Delete Category", role: .destructive) { if let custom { store.deleteCategory(custom) } }
        } message: {
            Text(count == 0 ? "Nothing is filed under it." : "Its \(count) transactions will move to Other.")
        }
    }
}

// MARK: - New / edit sheet

struct CategoryEditorSheet: View {
    @Environment(BudgetStore.self) private var store
    let request: CategoryEditorRequest
    @State private var draft: CustomCategory
    @FocusState private var nameFocused: Bool

    init(request: CategoryEditorRequest) {
        self.request = request
        _draft = State(initialValue: request.editing ?? CustomCategory(name: "", symbol: "tag.fill", color: "blue"))
    }

    private var trimmed: String { draft.name.trimmingCharacters(in: .whitespaces) }
    private var taken: Bool { !trimmed.isEmpty && store.isCategoryNameTaken(trimmed, except: draft.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 15, style: .continuous).fill(draft.swiftUIColor.gradient)
                    Image(systemName: draft.symbol).font(.system(size: 24, weight: .semibold)).foregroundStyle(.white)
                }
                .frame(width: 54, height: 54)
                .animation(.snappy, value: draft)
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.editing == nil ? "New Category" : "Edit Category").font(.title2.weight(.bold))
                    TextField("Name, like Pets or Kids", text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .focused($nameFocused)
                        .onSubmit(save)
                    if taken {
                        Text("There's already a category with that name.").font(.caption).foregroundStyle(.red)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Color").font(.headline)
                HStack(spacing: 10) {
                    ForEach(CustomCategory.palette, id: \.name) { item in
                        Circle()
                            .fill(item.color.gradient)
                            .frame(width: 26, height: 26)
                            .overlay { if draft.color == item.name { Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white) } }
                            .overlay { Circle().strokeBorder(Color.primary.opacity(draft.color == item.name ? 0.35 : 0), lineWidth: 2).padding(-3) }
                            .contentShape(Circle())
                            .onTapGesture { draft.color = item.name }
                            .accessibilityLabel(item.name)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Icon").font(.headline)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 8), count: 11), spacing: 8) {
                    ForEach(CustomCategory.symbols, id: \.self) { symbol in
                        Image(systemName: symbol)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(draft.symbol == symbol ? Color.white : Color.primary)
                            .frame(width: 34, height: 34)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(draft.symbol == symbol ? AnyShapeStyle(draft.swiftUIColor.gradient) : AnyShapeStyle(Color.primary.opacity(0.06))))
                            .contentShape(Rectangle())
                            .onTapGesture { draft.symbol = symbol }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { store.categoryEditor = nil }
                    .keyboardShortcut(.cancelAction)
                Button(request.editing == nil ? "Create" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty || taken)
            }
            .controlSize(.large)
        }
        .padding(26)
        .frame(width: 520)
        .onAppear { nameFocused = true }
    }

    private func save() {
        guard let category = store.saveCategory(draft) else { return }
        store.categoryEditor = nil
        request.then(category)
    }
}
