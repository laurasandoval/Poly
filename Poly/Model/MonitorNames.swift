import Foundation

/// Names the person gave their monitors. macOS cannot rename a display, so the names live in Poly:
/// in this Mac's UserDefaults, mirrored to iCloud key-value storage so the person's other Macs use
/// them too. Without iCloud they simply stay on this Mac. Each person names monitors their own way:
/// a shared monitor can be "Office" on one person's Macs and "Work" on another's.
final class MonitorNames {
    private(set) var names: [String: String] = [:] {
        didSet { onChange?() }
    }
    var onChange: (() -> Void)?

    private let cloud = NSUbiquitousKeyValueStore.default
    private static let storageKey = "monitorNames"
    /// One iCloud key per monitor, so renaming two monitors on two Macs never collides.
    private static let cloudPrefix = "monitor-name."

    init() {
        names = UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: String] ?? [:]
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification, object: cloud, queue: .main
        ) { [weak self] notification in
            let keys = notification.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            MainActor.assumeIsolated { self?.pullFromCloud(keys) }
        }
        cloud.synchronize()
        pullFromCloud(nil)
    }

    subscript(monitorID: String) -> String? { names[monitorID] }

    /// An empty name goes back to the one macOS reports.
    func set(_ name: String, for monitorID: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        names[monitorID] = trimmed.isEmpty ? nil : trimmed
        save()
        let key = Self.cloudPrefix + monitorID
        if trimmed.isEmpty { cloud.removeObject(forKey: key) } else { cloud.set(trimmed, forKey: key) }
    }

    /// Takes names other Macs set. `keys` nil means all of them (first launch, account change).
    private func pullFromCloud(_ keys: [String]?) {
        let keys = keys ?? Array(cloud.dictionaryRepresentation.keys)
        var updated = names
        for key in keys where key.hasPrefix(Self.cloudPrefix) {
            let monitorID = String(key.dropFirst(Self.cloudPrefix.count))
            updated[monitorID] = cloud.string(forKey: key)
        }
        guard updated != names else { return }
        names = updated
        save()
    }

    private func save() {
        UserDefaults.standard.set(names, forKey: Self.storageKey)
    }
}
