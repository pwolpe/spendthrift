import Foundation

/// Stopwatch for starting up. With SPENDTHRIFT_TIMING set, each mark prints how long since the
/// process began, so a slow start can be traced to the step that caused it.
enum Launch {
    /// True once the first page has been drawn; after that nothing needs holding back.
    nonisolated(unsafe) static var hasDrawn = false
    /// How long held-back pieces wait after appearing: long enough for the first page to reach the
    /// screen first, short enough that nobody sees them arrive late.
    static let settle = 0.08
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
