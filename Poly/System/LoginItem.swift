import Foundation
import ServiceManagement

/// Opening Poly at login. Turned on once, on the first launch from an Applications folder, because
/// Poly only works while it runs; after that it stays however the person sets it. Runs from Xcode's
/// build folder are left alone so the login item never points at a development build.
///
/// macOS 13 and later use `SMAppService`. macOS 12 has no API for an app to add itself without a
/// helper app, so there Poly writes a LaunchAgent that opens it at login.
final class LoginItem {
    private(set) var isEnabled = false

    private static let setUpKey = "didSetUpLoginItem"

    init() { isEnabled = currentlyEnabled }

    func enableOnFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: Self.setUpKey),
            Bundle.main.bundlePath.contains("/Applications/")
        else { return }
        UserDefaults.standard.set(true, forKey: Self.setUpKey)
        setEnabled(true)
    }

    func setEnabled(_ enabled: Bool) {
        if #available(macOS 13, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // The status below shows what actually happened.
            }
        } else if enabled {
            try? FileManager.default.createDirectory(
                at: Self.agentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let agent: [String: Any] = [
                "Label": Self.agentLabel,
                "ProgramArguments": ["/usr/bin/open", Bundle.main.bundlePath],
                "RunAtLoad": true,
            ]
            (agent as NSDictionary).write(to: Self.agentURL, atomically: true)
        } else {
            try? FileManager.default.removeItem(at: Self.agentURL)
        }
        isEnabled = currentlyEnabled
    }

    private var currentlyEnabled: Bool {
        if #available(macOS 13, *) { return SMAppService.mainApp.status == .enabled }
        return FileManager.default.fileExists(atPath: Self.agentURL.path)
    }

    private static let agentLabel = "work.lau.poly.login"
    private static var agentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }
}
