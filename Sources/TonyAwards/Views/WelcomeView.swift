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
            VStack(spacing: 10) {
                TonyFigure(height: 230)
                Text("Hi, Tony.")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                Text("Welcome to The Tony Awards, honoring excellence in spending.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            dropZone

            DownloadsBanner()
                .frame(maxWidth: 560)

            VStack(alignment: .leading, spacing: 14) {
                Step(number: 1, text: "Sign in to your bank or credit card website.")
                Step(number: 2, text: "Find **Download** or **Export** and save your activity or statement. Any format works.")
                Step(number: 3, text: "Drag the file into this window. Everything is sorted for you, right on this Mac.")
            }
            .frame(maxWidth: 480, alignment: .leading)

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
