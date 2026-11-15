import SwiftUI

@main
struct PolyApp: App {
    @State private var switcher: Switcher
    @State private var loginItem: LoginItem
    private let updater = Updater()
    /// Keeps App Nap from delaying Poly's short timers (the unplug grace period, connection retries).
    /// Poly has no timers while idle, and idle system sleep stays allowed.
    private let activity = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep, reason: "Handing accessories over when monitors change")

    init() {
        let switcher = Switcher()
        let loginItem = LoginItem()
        switcher.askToLink = LinkPrompt.ask
        switcher.start()
        loginItem.enableOnFirstLaunch()
        updater.start { switcher.isQuiet }
        _switcher = State(initialValue: switcher)
        _loginItem = State(initialValue: loginItem)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(switcher: switcher, loginItem: loginItem, updater: updater)
        } label: {
            Image(systemName: switcher.needsAttention ? "exclamationmark.triangle" : "infinity")
                .accessibilityLabel("Poly")
        }
    }
}
