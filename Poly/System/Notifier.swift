import Foundation
import UserNotifications

/// The few moments Poly speaks up. Permission is asked the first time Poly learns a monitor, when
/// the person has just connected a keyboard and mouse and can answer.
enum Notifier {
    /// "Poly knows Studio Display": the only onboarding there is.
    static func learned(_ monitor: Monitor) {
        let names = monitor.accessories.map(\.name).formatted(.list(type: .and))
        post(
            id: "learned-\(monitor.id)",
            title: String(localized: "Poly knows \(monitor.name)"),
            body: String(localized: "\(names) will connect whenever this Mac is plugged into it."),
            askIfNeeded: true)
    }

    static func nudge(_ accessory: Accessory) {
        let action =
            switch accessory.kind {
            case .keyboard: String(localized: "Press a key, or switch it off and on.")
            case .mouse: String(localized: "Click it, or switch it off and on.")
            case .trackpad: String(localized: "Click it, or switch it off and on.")
            }
        post(id: "nudge-\(accessory.address)", title: String(localized: "Waking \(accessory.name)"), body: action)
    }

    static func clearNudge(for accessory: Accessory) {
        let ids = ["nudge-\(accessory.address)", "passkey-\(accessory.address)"]
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }

    static func typePasskey(_ passkey: UInt32, on accessory: Accessory) {
        let digits = String(format: "%06u", passkey)
        post(
            id: "passkey-\(accessory.address)",
            title: String(localized: "Type \(digits) on \(accessory.name)"),
            body: String(localized: "Then press Return to finish connecting it."))
    }

    private static func post(id: String, title: String, body: String, askIfNeeded: Bool = false) {
        let center = UNUserNotificationCenter.current()
        Task {
            var status = await center.notificationSettings().authorizationStatus
            if status == .notDetermined, askIfNeeded {
                _ = try? await center.requestAuthorization(options: [.alert])
                status = await center.notificationSettings().authorizationStatus
            }
            guard status == .authorized || status == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }
}
