import SwiftUI

/// How the app came to be, and why two particular people appear all over it.
/// Opened from Spendthrift → About, the name at the top of the sidebar, and the welcome screen.
struct StoryView: View {
    private var store: BudgetStore { .shared }
    /// False when rendered for a test snapshot.
    var scrolls = true

    /// There are no version numbers; a build is known by the day it was made ("Built November 12, 2026").
    private var version: String {
        guard let stamp = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
              let day = DateParsing.parse(stamp, format: "yyyy.MM.dd") else { return "" }
        return "Built \(day.formatted(date: .long, time: .omitted))"
    }

    var body: some View {
        VStack(spacing: 0) {
            MaybeScroll(scrolls: scrolls) {
                VStack(alignment: .leading, spacing: 22) {
                    SpotArt(name: "story", height: 300)
                        .frame(maxWidth: .infinity)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("HOW THIS CAME TO BE")
                            .font(Theme.mono(10.5, .bold)).tracking(1.4).foregroundStyle(Theme.accent)
                        Text("It started with a phone call")
                            .font(.system(size: 32, weight: .bold, design: .serif))
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        Text("Tony called his friend Paul with a confession: he had no idea where his money was going. Could Paul help him find out?")
                        Text("Paul can't leave a problem like that alone. He found [Tally](https://tallyai.money), a clever tool for making sense of bank statements, and the idea took hold. Then he sat down with Claude and built the app he had always wanted and never would have attempted alone. Drop in your statements and it tells you where it all went.")
                        Text("That's why the two of them turn up all over Spendthrift. Tony is the reason it exists; Paul is the one who couldn't stop building it. When you catch them holding one of your receipts, they mean it kindly. They've been there.")
                        Text("It was made for one friend. It's for anyone who has ever looked at a statement and thought: I spent *what*?")
                    }
                    .font(.title3)
                    .lineSpacing(4)
                    .tint(Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)

                    // What it took, itemized.
                    ReceiptPaper(padding: 18) {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("WHAT IT TOOK").font(Theme.mono(11, .bold)).tracking(1.5).frame(maxWidth: .infinity)
                            ReceiptRule()
                            ReceiptLine("One phone call", value: "Tony")
                            ReceiptLine("One idea worth borrowing", value: "Tally")
                            ReceiptLine("One tireless collaborator", value: "Claude")
                            ReceiptLine("Too many late nights", value: "Paul")
                            ReceiptRule()
                            ReceiptLine(value: "One app", bold: true) { Text("TOTAL").font(Theme.mono(13, .bold)) }
                            Text("NO REFUNDS. NONE REQUESTED.")
                                .font(Theme.mono(9.5)).tracking(1).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 2)
                        }
                    }
                    .frame(maxWidth: 380)
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 44)
                .padding(.top, 34)
                .padding(.bottom, 26)
                .frame(maxWidth: 680)
                .frame(maxWidth: .infinity)
            }
            if scrolls {
                Divider()
                HStack {
                    HStack(spacing: 8) {
                        ReceiptMark(size: 22)
                        Text("Spendthrift").font(.system(.headline, design: .serif))
                        Text(version).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Done") { store.showsStory = false }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 14)
            }
        }
        .background(Theme.paper)
        .frame(width: scrolls ? 700 : nil, height: scrolls ? 780 : nil)
    }
}
