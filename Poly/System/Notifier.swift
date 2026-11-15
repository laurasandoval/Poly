import Foundation
import UserNotifications

/// The one thing Poly says in a notification: an accessory it could not reach. Permission is asked
/// at launch. Linking an accessory is asked with an alert instead (`LinkPrompt`), so it stays on
/// screen until answered.
enum Notifier {
    static func requestPermission() {
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) }
    }

    static func couldNotConnect(_ name: String, address: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Couldn’t connect to \(name)")
        content.body = String(localized: "Poly will keep trying in the background.")
        let request = UNNotificationRequest(identifier: id(address), content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }

    static func clearNudge(for address: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id(address)])
    }

    private static func id(_ address: String) -> String { "nudge-\(address)" }
}
