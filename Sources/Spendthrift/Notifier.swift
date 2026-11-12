import AppKit
import UserNotifications

/// A quiet word from the app when something worth knowing happened while the person was elsewhere:
/// a statement added itself, a subscription went up. Never shown while he's looking at the app.
@MainActor
enum Notifier {
    private static var askedPermission = false

    static func post(title: String, body: String) {
        guard !NSApp.isActive, ProcessInfo.processInfo.environment["SPENDTHRIFT_SNAPSHOT"] == nil,
              Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        let send = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional: send()
            case .notDetermined:
                Task { @MainActor in
                    guard !askedPermission else { return }
                    askedPermission = true
                    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in if granted { send() } }
                }
            default: break
            }
        }
    }
}
