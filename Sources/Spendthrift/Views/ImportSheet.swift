import SwiftUI

/// Rarely needed: shown only when a file's columns can't be worked out automatically.
struct ImportSheet: View {
    @Environment(BudgetStore.self) private var store
    let pending: PendingImport

    @State private var name: String
    @State private var target: UUID?   // nil = new account
    @State private var mapping: ColumnMapping?
    @State private var showColumns: Bool

    init(pending: PendingImport) {
        self.pending = pending
        _name = State(initialValue: pending.suggestedName)
        _target = State(initialValue: pending.candidates.first?.id)
        let guess = pending.mapping ?? ColumnDetector.detect(pending.table)
        _mapping = State(initialValue: guess)
        _showColumns = State(initialValue: true)
    }

    private var preview: [CanonicalRow] {
        guard let mapping else { return [] }
        let rows = Normalizer.rows(from: pending.table, mapping: mapping).rows
        // Show a few purchases, plus a credit if there is one.
        let purchases = rows.filter { $0.amount > 0 }.prefix(3)
        let credit = rows.first { $0.amount < 0 }
        return Array(purchases) + (credit.map { [$0] } ?? [])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "building.columns.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.accent))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Help me read this one")
                        .font(.title2.weight(.bold))
                    Text(pending.fileURL.lastPathComponent)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if !pending.candidates.isEmpty {
                Picker("Add to", selection: $target) {
                    ForEach(pending.candidates) { Text($0.name).tag(Optional($0.id)) }
                    Divider()
                    Text("A new account…").tag(UUID?.none)
                }
                .pickerStyle(.radioGroup)
            }

            if target == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("What should we call it?").font(.headline)
                    TextField("e.g. Chase Visa or Checking", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                }
            }

            if mapping != nil {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Does this look right?").font(.headline)
                        Spacer()
                        Button {
                            mapping?.purchasesAreNegative.toggle()
                        } label: {
                            Label("Amounts Look Backwards", systemImage: "arrow.up.arrow.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(mapping?.amountColumn == nil)
                    }
                    previewTable
                    Text("Purchases should show as money spent. Payments and refunds show in green.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("I couldn't work out this file by myself. Please pick the columns below.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            DisclosureGroup("Columns", isExpanded: $showColumns) {
                ColumnPickers(table: pending.table, mapping: $mapping)
                    .padding(.top, 8)
            }
            .font(.callout)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { store.cancelImport(pending) }
                    .keyboardShortcut(.cancelAction)
                Button(target == nil ? "Add Account" : "Add Charges") {
                    if let mapping {
                        store.completeImport(pending, existingAccount: target, newName: name, mapping: mapping)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(mapping == nil || preview.isEmpty || (target == nil && name.trimmingCharacters(in: .whitespaces).isEmpty))
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(width: 600)
    }

    private var previewTable: some View {
        VStack(spacing: 0) {
            ForEach(Array(preview.enumerated()), id: \.offset) { i, row in
                HStack {
                    Text(DateParsing.parse(row.date, format: "yyyy-MM-dd")?.formatted(date: .abbreviated, time: .omitted) ?? row.date)
                        .foregroundStyle(.secondary)
                        .frame(width: 110, alignment: .leading)
                    Text(row.description).lineLimit(1)
                    Spacer()
                    if row.amount < 0 {
                        Text("+\(Money.format(-row.amount))").foregroundStyle(.green)
                    } else {
                        Text("spent \(Money.format(row.amount))").foregroundStyle(.primary)
                    }
                }
                .monospacedDigit()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                if i < preview.count - 1 { Divider() }
            }
            if preview.isEmpty {
                Text("No charges found with these columns.")
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// For power users: manual control over which column is which.
private struct ColumnPickers: View {
    let table: CSVTable
    @Binding var mapping: ColumnMapping?

    private var columns: [Int] { Array(0..<table.columnCount) }

    var body: some View {
        let m = mapping ?? ColumnMapping(dateColumn: 0, dateFormat: "MM/dd/yyyy", descriptionColumn: min(1, table.columnCount - 1),
                                         amountColumn: table.columnCount - 1, debitColumn: nil, creditColumn: nil,
                                         purchasesAreNegative: true)
        Form {
            Picker("Date", selection: Binding(get: { m.dateColumn }, set: { i in
                var n = m; n.dateColumn = i
                n.dateFormat = DateParsing.guessFormat(for: table.values(i)) ?? n.dateFormat
                mapping = n
            })) { ForEach(columns, id: \.self) { Text(table.columnName($0)).tag($0) } }

            Picker("Description", selection: Binding(get: { m.descriptionColumn }, set: { i in
                var n = m; n.descriptionColumn = i; mapping = n
            })) { ForEach(columns, id: \.self) { Text(table.columnName($0)).tag($0) } }

            Picker("Amount", selection: Binding(get: { m.amountColumn ?? -1 }, set: { i in
                var n = m
                if i < 0 {
                    n.amountColumn = nil
                    n.debitColumn = n.debitColumn ?? columns.first
                    n.creditColumn = n.creditColumn ?? columns.last
                } else {
                    n.amountColumn = i; n.debitColumn = nil; n.creditColumn = nil
                }
                mapping = n
            })) {
                ForEach(columns, id: \.self) { Text(table.columnName($0)).tag($0) }
                Divider()
                Text("Separate columns for money out and in").tag(-1)
            }

            if m.amountColumn == nil {
                Picker("Money out (debit)", selection: Binding(get: { m.debitColumn ?? 0 }, set: { i in
                    var n = m; n.debitColumn = i; mapping = n
                })) { ForEach(columns, id: \.self) { Text(table.columnName($0)).tag($0) } }
                Picker("Money in (credit)", selection: Binding(get: { m.creditColumn ?? 0 }, set: { i in
                    var n = m; n.creditColumn = i; mapping = n
                })) { ForEach(columns, id: \.self) { Text(table.columnName($0)).tag($0) } }
            }
        }
        .formStyle(.grouped)
        .frame(maxHeight: 260)
    }
}
