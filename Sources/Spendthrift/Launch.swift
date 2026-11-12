import SwiftUI
import Observation

/// Stopwatch for starting up. With SPENDTHRIFT_TIMING set, each mark prints how long since the
/// process began, so a slow start can be traced to the step that caused it.
enum Launch {
    static let enabled = ProcessInfo.processInfo.environment["SPENDTHRIFT_TIMING"] != nil
    private static let began = Date.now
    nonisolated(unsafe) private static var last = Date.now

    static func mark(_ step: String) {
        guard enabled else { return }
        let now = Date.now
        if step == "main" { print(String(format: "TIMING process reached main at %.3f", now.timeIntervalSince1970)) }
        print(String(format: "TIMING %6.0f ms  (+%4.0f)  %@", now.timeIntervalSince(began) * 1000, now.timeIntervalSince(last) * 1000, step))
        last = now
    }
}

/// Opening in two beats. The window is the slowest thing the Mac does for the app, and reading the
/// saved file is the slowest thing the app does for itself: neither needs the other, so they happen
/// together. The window goes up empty the moment the process starts; the store is made when the file
/// has been read on its own thread; the pages follow.
@MainActor @Observable
final class Boot {
    static let shared = Boot()
    /// True once the store exists and pages can be drawn.
    private(set) var ready = false
    /// True once the first page has really been drawn. Pictures, the stamp and the cards below the
    /// first screenful wait for this: the page arrives with its words and figures, and the rest
    /// fades in a moment later instead of holding everything up. (True from the start when pages
    /// are rendered to a file, where nothing is ever "drawn".)
    private(set) var drawn = ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] != nil

    func pagesDrawn() {
        guard !drawn else { return }
        withAnimation(.easeOut(duration: 0.2)) { drawn = true }
    }
    @ObservationIgnored private var begun = false

    func begin() {
        guard !begun else { return }
        begun = true
        Library.whenPreloaded {
            Launch.mark("library ready, making the store")
            _ = BudgetStore.shared
            self.ready = true
            // Should the first draw never be noticed (a window opened off screen), nothing is held back for long.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.pagesDrawn() }
        }
    }
}

/// Tells the stopwatch when the pages are really drawn. A view's `onAppear` fires before layout
/// and drawing, and a block queued from it can run before either; this is an AppKit view laid over
/// the pages whose `draw` is called as part of the very pass that puts them on screen.
struct FirstPaintProbe: NSViewRepresentable {
    final class Probe: NSView {
        nonisolated(unsafe) static var fired = false
        override var isOpaque: Bool { false }
        override func draw(_ dirtyRect: NSRect) {
            guard !Self.fired else { return }
            Self.fired = true
            Launch.mark("pages drawn")
            // Next turn of the run loop: this pass is on its way to the screen; now the rest may come.
            DispatchQueue.main.async {
                Boot.shared.pagesDrawn()
                DispatchQueue.main.async { Launch.mark("held-back pieces in, main thread free") }
            }
        }
    }
    func makeNSView(context: Context) -> Probe { Probe(frame: .zero) }
    func updateNSView(_ view: Probe, context: Context) {}
}
