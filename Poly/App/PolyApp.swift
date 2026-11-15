import SwiftUI

@main
struct PolyApp: App {
    @State private var switcher: Switcher
    @State private var loginItem: LoginItem

    init() {
        let switcher = Switcher()
        let loginItem = LoginItem()
        switcher.start()
        loginItem.enableOnFirstLaunch()
        _switcher = State(initialValue: switcher)
        _loginItem = State(initialValue: loginItem)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(switcher: switcher, loginItem: loginItem)
        } label: {
            Image(systemName: switcher.needsAttention ? "exclamationmark.triangle" : "infinity")
                .accessibilityLabel("Poly")
        }
    }
}
