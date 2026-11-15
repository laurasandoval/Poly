import Observation
import ServiceManagement

/// Opening Poly at login. Turned on once, on first launch, because Poly only works while it runs;
/// after that it stays however the person sets it.
@Observable
final class LoginItem {
    private(set) var isEnabled = SMAppService.mainApp.status == .enabled

    private static let setUpKey = "didSetUpLoginItem"

    func enableOnFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: Self.setUpKey) else { return }
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
