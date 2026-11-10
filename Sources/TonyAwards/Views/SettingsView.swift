import SwiftUI

/// The Tony Awards → Settings…  One pane: the optional cloud AI key.
struct SettingsView: View {
    @Environment(BudgetStore.self) private var store
    @State private var status = CloudStatus.shared
    @State private var key = ""
    @State private var model = CloudAI.model
    @State private var readsStatements = CloudAI.readsStatements
    @State private var testing = false
    @State private var message: (text: String, good: Bool)?

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    TonyAvatar(size: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Smarter AI").font(.title2.weight(.bold))
                        Text("With an OpenRouter key, a powerful AI model sorts every place it doesn't already know, reads statements in any layout, and understands questions better. Without one, the app uses Apple Intelligence on this Mac.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section("OpenRouter key") {
                if status.hasKey {
                    LabeledContent("Key") {
                        HStack {
                            Label("Saved in this Mac's keychain", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.good)
                            Spacer()
                            Button("Remove", role: .destructive) {
                                CloudKey.delete(); status.refreshKey(); message = nil
                            }
                        }
                    }
                } else {
                    SecureField("Paste the key here (it starts with sk-or-)", text: $key)
                        .onSubmit(save)
                    HStack {
                        Text("Get one at openrouter.ai → Keys. Give it a spending limit there.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Save", action: save)
                            .buttonStyle(.borderedProminent)
                            .disabled(key.trimmingCharacters(in: .whitespaces).count < 10 || testing)
                    }
                }
                if testing { ProgressView("Checking the key…").controlSize(.small) }
                if let message {
                    Label(message.text, systemImage: message.good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(message.good ? Theme.good : Theme.caution)
                        .fixedSize(horizontal: false, vertical: true)
                } else if status.hasKey, let error = status.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.caution)
                }
            }

            if status.hasKey {
                Section("How it's used") {
                    Picker("Model", selection: $model) {
                        ForEach(CloudAI.models, id: \.id) { Text($0.label).tag($0.id) }
                        if !CloudAI.models.contains(where: { $0.id == model }) { Text(model).tag(model) }
                    }
                    .onChange(of: model) { CloudAI.model = model }
                    Toggle("Read statements the app can't read by itself", isOn: $readsStatements)
                        .onChange(of: readsStatements) { CloudAI.readsStatements = readsStatements }
                    Button("Test Connection") { Task { await test(announce: true) } }
                        .disabled(testing)
                }
            }

            Section("What leaves this Mac") {
                Text("• To sort a place: the bank's text for it (like “TST*BLUE DOOR CAFE”), the typical amount, and how often it appears.\n• To read a statement: its text, with your name, address, email and account numbers blanked first.\n• To answer a question: the question itself.\n\nYour totals, balances and the saved data file are never sent. The key is stored in the keychain, not in the app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .tint(Theme.accent)
    }

    private func save() {
        let entered = key
        guard entered.trimmingCharacters(in: .whitespaces).count >= 10 else { return }
        guard CloudKey.save(entered) else {
            message = ("The key couldn't be saved to the keychain.", false)
            return
        }
        key = ""
        status.refreshKey()
        Task {
            if await test(announce: true) { store.cloudBecameAvailable() }
        }
    }

    @discardableResult
    private func test(announce: Bool) async -> Bool {
        testing = true
        defer { testing = false }
        let problem = await CloudAI.test()
        if announce {
            message = problem.map { ($0, false) } ?? ("Connected. I'll take it from here.", true)
        }
        return problem == nil
    }
}
