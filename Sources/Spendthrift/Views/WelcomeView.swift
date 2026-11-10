import SwiftUI

struct WelcomeView: View {
    @Environment(BudgetStore.self) private var store
    var isDropTargeted: Bool
    /// False when rendered for a test snapshot.
    var scrolls = true

    var body: some View {
        if scrolls { ScrollView { content } } else { content }
    }

    private var content: some View {
        VStack(spacing: 26) {
            Spacer(minLength: 24)
            VStack(spacing: 12) {
                SpotArt(name: "welcome", height: 250)
                Text("Welcome to Spendthrift")
                    .font(.system(size: 42, weight: .bold, design: .serif))
                Text("Drop in your bank and card statements. In about a minute you'll see where the money went, what it did, and whether you lived within your income.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 600)
                    .fixedSize(horizontal: false, vertical: true)
            }

            KeyEntry()

            dropZone

            DownloadsBanner()
                .frame(maxWidth: 560)

            VStack(alignment: .leading, spacing: 14) {
                Step(number: 1, text: "Sign in to your bank or credit card website.")
                Step(number: 2, text: "Find **Download** or **Export** and save your activity or statement. Any format works.")
                Step(number: 3, text: "Drag the files into this window, as many as you like, a whole folder if you have one. Start with a year of each account.")
            }
            .frame(maxWidth: 520, alignment: .leading)

            // What a careful person wants to know before dropping a bank statement anywhere.
            VStack(spacing: 6) {
                Label(CloudAI.isEnabled ? "Your files stay on this Mac." : "Everything stays on this Mac.", systemImage: "lock.fill")
                    .font(.callout.weight(.semibold))
                Text(CloudAI.isEnabled
                     ? "Smarter AI is on: to read, sort and answer questions, the text of your statements (names and account numbers blanked out) and your charges go to the AI model you chose. You can turn it off in Settings."
                     : "Nothing is sent anywhere. For sharper sorting, trips, and pictures of your own spending, you can turn on Smarter AI in Settings later.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 560)

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
    }

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: store.isImporting ? "doc.text.magnifyingglass" : "tray.and.arrow.down.fill")
                .font(.system(size: 52, weight: .medium))
                .foregroundStyle(.tint)
                .symbolEffect(.bounce, value: isDropTargeted)
                .symbolEffect(.pulse, isActive: store.isImporting)
            Text(store.isImporting ? "Reading your statement…" : "Drop your statements here")
                .font(.title2.weight(.semibold))
            Text("CSV, PDF or Quicken files, from any bank or card")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Choose Files…") { store.presentOpenPanel() }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .padding(.top, 2)
        }
        .frame(maxWidth: 560)
        .padding(.vertical, 36)
        .background {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(Theme.accent.opacity(isDropTargeted ? 0.14 : 0.05))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .foregroundStyle(isDropTargeted ? Theme.accent : Color.secondary.opacity(0.4))
        }
        .scaleEffect(isDropTargeted ? 1.02 : 1)
        .animation(.spring(duration: 0.3), value: isDropTargeted)
    }
}

private struct Step: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)")
                .font(.callout.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Theme.gold))
            Text(text).font(.body)
        }
    }
}
