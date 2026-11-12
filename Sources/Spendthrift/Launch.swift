import Foundation

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
