import AppKit

/// Entry point. Poly is a menu bar app with no windows (`LSUIElement`); AppKit rather than a
/// SwiftUI `App`, since SwiftUI's menu bar scene needs macOS 13 and Poly supports 12.
@main
final class PolyApp: NSObject, NSApplicationDelegate {
    private let switcher = Switcher()
    private let loginItem = LoginItem()
    private let updater = Updater()
    private var statusMenu: StatusMenu?
    /// Keeps App Nap from delaying Poly's short timers (the unplug grace period, connection retries).
    /// Poly has no timers while idle, and idle system sleep stays allowed.
    private let activity = ProcessInfo.processInfo.beginActivity(
        options: .userInitiatedAllowingIdleSystemSleep, reason: "Handing accessories over when monitors change")

    static func main() {
        // `scripts/diagnostics.sh`: write every Mac's journal to a folder and quit, touching nothing.
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--export-diagnostics"), index + 1 < arguments.count {
            Journal.export(to: URL(fileURLWithPath: arguments[index + 1], isDirectory: true))
            exit(0)
        }
        let app = NSApplication.shared
        let delegate = PolyApp()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Journal.shared.start()
        let menu = StatusMenu(switcher: switcher, loginItem: loginItem, updater: updater)
        statusMenu = menu
        switcher.onChange = { [weak menu] in menu?.refresh() }
        switcher.askToLink = LinkPrompt.ask
        switcher.start()
        loginItem.enableOnFirstLaunch()
        updater.start { [switcher] in switcher.isQuiet }
    }
}
