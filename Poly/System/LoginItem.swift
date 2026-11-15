import Observation
import ServiceManagement

/// Opening Poly at login. Turned on once, on the first launch from an Applications folder, because
/// Poly only works while it runs; after that it stays however the person sets it. Runs from Xcode's
/// build folder are left alone so the login item never points at a development build.
@Observable
final class LoginItem {
    private(set) var isEnabled = SMAppService.mainApp.status == .enabled

    private static let setUpKey = "didSetUpLoginItem"

    func enableOnFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: Self.setUpKey),
            Bundle.main.bundlePath.contains("/Applications/")
        else { return }
        UserDefaults.standard.set(true, forKey: Self.setUpKey)
        setEnabled(true)
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // The status below shows what actually happened.
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
