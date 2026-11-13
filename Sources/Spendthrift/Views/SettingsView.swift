import SwiftUI

/// Spendthrift → Settings…  One pane: the OpenRouter key and what it is used for.
struct SettingsView: View {
    @Environment(BudgetStore.self) private var store
    @State private var status = CloudStatus.shared
    @State private var key = ""
    @State private var readsStatements = CloudAI.readsStatements
    @State private var addsAutomatically = BudgetStore.addsDownloadsAutomatically
    @State private var testing = false
    @State private var message: (text: String, good: Bool)?

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    Vignette(name: "v-settings", size: 68)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("The AI").font(.title2.weight(.bold))
                        Text("Spendthrift runs on AI models reached with your own OpenRouter key. They sort every payee, read statements in any layout, find your trips, answer questions and draw the pictures. Every figure is still added up on this Mac.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Section("OpenRouter key") {
                if status.hasKey {
                    LabeledContent("Key") {
                        HStack {
                            Label("Saved on this Mac", systemImage: "checkmark.seal.fill").foregroundStyle(Theme.good)
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
                    Toggle("Read statements the app can't read by itself", isOn: $readsStatements)
                        .onChange(of: readsStatements) { CloudAI.readsStatements = readsStatements }
                    Toggle("Look up unfamiliar payees on the web", isOn: Binding(get: { WebLookup.isOn }, set: { WebLookup.isOn = $0 }))
                        .help("Sends the statement text for payees the model couldn't identify to a web search. About 3 cents a payee, the biggest 40 per import.")
                    Button("Test Connection") { Task { await test(announce: true) } }
                        .disabled(testing)
                }
            }

            Section("Statements") {
                Toggle("Add new statements from Downloads automatically", isOn: $addsAutomatically)
                    .onChange(of: addsAutomatically) {
                        BudgetStore.addsDownloadsAutomatically = addsAutomatically
                        store.refreshDownloads()
                    }
                Text("When you save a statement from your bank's website, it's added a few seconds later. Every addition can be undone.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("What leaves this Mac") {
                Text("• To sort a payee: the bank's text for it (like “TST*BLUE DOOR CAFE”), the typical amount, and how often it appears.\n• To read a statement: its text, with your name, address, email and account numbers blanked first.\n• To find trips and things worth noticing: your charges (payee, date, amount).\n• To answer a question or write a short note: the question, and the figures the app worked out for it.\n\nYour name, address, account numbers and the saved data file are never sent. The key is stored in a private file on this Mac, not in the app.")
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
            message = ("The key couldn't be saved.", false)
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
