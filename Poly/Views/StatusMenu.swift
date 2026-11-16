import AppKit

/// The menu bar icon and its menu: one item per monitor, with that monitor's accessories inside it.
/// AppKit rather than SwiftUI's `MenuBarExtra`, which needs macOS 13 (Poly supports 12). The menu
/// is rebuilt each time it opens, and again while open whenever the switcher changes; it only
/// renders and forwards intents.
final class StatusMenu: NSObject, NSMenuDelegate {
    private let switcher: Switcher
    private let loginItem: LoginItem
    private let updater: Updater
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private var isOpen = false

    init(switcher: Switcher, loginItem: LoginItem, updater: Updater) {
        self.switcher = switcher
        self.loginItem = loginItem
        self.updater = updater
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        refreshIcon()
    }

    /// Called by the switcher whenever something the menu shows changes.
    func refresh() {
        refreshIcon()
        if isOpen { rebuild() }
    }

    private func refreshIcon() {
        let symbol = switcher.needsAttention ? "exclamationmark.triangle" : "infinity"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Poly")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }
    func menuWillOpen(_ menu: NSMenu) { isOpen = true }
    func menuDidClose(_ menu: NSMenu) { isOpen = false }

    // MARK: Building

    private func rebuild() {
        menu.removeAllItems()

        switch switcher.bluetoothState {
        case .denied:
            menu.addItem(action("Allow Poly to Use Bluetooth…") {
                let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
                if let url = URL(string: url) { NSWorkspace.shared.open(url) }
            })
            menu.addItem(.separator())
        case .off:
            menu.addItem(label("Bluetooth Is Off"))
            menu.addItem(.separator())
        case .waiting, .ready:
            break
        }

        let monitors = shownMonitors
        if monitors.isEmpty {
            menu.addItem(label("Connect your Mac to an external display and accessories to get started."))
            menu.addItem(.separator())
        }
        for monitor in monitors { menu.addItem(monitorItem(monitor, among: monitors)) }
        if !monitors.isEmpty { menu.addItem(.separator()) }

        let login = action("Open at Login") { [loginItem] in loginItem.setEnabled(!loginItem.isEnabled) }
        login.state = loginItem.isEnabled ? .on : .off
        menu.addItem(login)
        let updates = action("Check for Updates…") { [updater] in updater.checkForUpdates() }
        updates.isEnabled = updater.isEnabled
        menu.addItem(updates)
        let quit = action("Quit Poly") { NSApp.terminate(nil) }
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func monitorItem(_ monitor: Monitor, among monitors: [Monitor]) -> NSMenuItem {
        let name = name(of: monitor, among: monitors)
        let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
        item.image = SystemIcons.monitor(vendorID: monitor.vendorID, productID: monitor.productID)
        Self.setSubtitle(subtitle(of: monitor), on: item)

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for accessory in monitor.accessories { submenu.addItem(accessoryItem(accessory, on: monitor, monitorName: name)) }
        if monitor.id == switcher.linkTarget?.id, !switcher.linkable.isEmpty {
            if !monitor.accessories.isEmpty { submenu.addItem(.separator()) }
            for info in switcher.linkable {
                let link = action("Link \(info.name) to \(name)") { [switcher] in switcher.link(info) }
                link.image = SystemIcons.accessory(Accessory(info, name: info.name))
                submenu.addItem(link)
            }
        }
        submenu.addItem(.separator())
        submenu.addItem(action("Rename…") { [switcher] in
            RenamePrompt.ask(
                current: switcher.name(of: monitor),
                icon: SystemIcons.monitor(vendorID: monitor.vendorID, productID: monitor.productID)
            ) { switcher.rename(monitor, to: $0) }
        })
        if monitor.accessories.count > 1 {
            submenu.addItem(action("Unlink All Accessories") { [switcher] in switcher.unlinkAll(monitor) })
        }
        item.submenu = submenu
        return item
    }

    private func accessoryItem(_ accessory: Accessory, on monitor: Monitor, monitorName: String) -> NSMenuItem {
        let name = switcher.name(of: accessory)
        let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
        item.image = SystemIcons.accessory(accessory)
        Self.setSubtitle(subtitle(of: accessory, switcher.status(of: accessory, on: monitor)), on: item)

        let submenu = NSMenu()
        submenu.autoenablesItems = false
        submenu.addItem(action("Rename…") { [switcher] in
            RenamePrompt.ask(current: name, icon: SystemIcons.accessory(accessory)) { switcher.rename(accessory, to: $0) }
        })
        submenu.addItem(.separator())
        submenu.addItem(action("Unlink from \(monitorName)") { [switcher] in switcher.unlink(accessory) })
        item.submenu = submenu
        return item
    }

    // MARK: What the menu says

    /// Learned monitors, plus the plugged-in one while it has accessories to offer and has none yet.
    private var shownMonitors: [Monitor] {
        var shown = switcher.monitors
        if let target = switcher.linkTarget, !switcher.linkable.isEmpty, !shown.contains(where: { $0.id == target.id }) {
            shown.append(
                Monitor(id: target.id, name: target.name, vendorID: target.vendorID, productID: target.productID, accessories: []))
        }
        return shown
    }

    /// The monitor's name, numbered when several share it ("Studio Display 2").
    private func name(of monitor: Monitor, among monitors: [Monitor]) -> String {
        let name = switcher.name(of: monitor)
        let sameName = monitors.filter { switcher.name(of: $0) == name }
        guard sameName.count > 1, let index = sameName.firstIndex(where: { $0.id == monitor.id }), index > 0 else {
            return name
        }
        return "\(name) \(index + 1)"
    }

    /// "Connected • 2 accessories" while plugged in, "Not Connected" otherwise.
    private func subtitle(of monitor: Monitor) -> String {
        let count = monitor.accessories.count
        let accessories = count == 1 ? String(localized: "1 accessory") : String(localized: "\(count) accessories")
        guard switcher.isAttached(monitor) else { return String(localized: "Not Connected") }
        guard count > 0 else { return String(localized: "Connected") }
        let statuses = monitor.accessories.map { switcher.status(of: $0, on: monitor) }
        let state =
            if statuses.contains(.needsNudge) {
                String(localized: "Couldn’t Connect")
            } else if statuses.contains(.connecting) {
                String(localized: "Connecting…")
            } else {
                String(localized: "Connected")
            }
        return "\(state) • \(accessories)"
    }

    /// What is happening with an accessory.
    private func subtitle(of accessory: Accessory, _ status: AccessoryStatus) -> String {
        switch status {
        case .free: String(localized: "Not Connected")
        case .connected: String(localized: "Connected")
        case .connecting: String(localized: "Connecting…")
        case .needsNudge:
            accessory.kind == .keyboard
                ? String(localized: "Press a key, or switch it off and on")
                : String(localized: "Click it, or switch it off and on")
        }
    }

    // MARK: Items

    private func label(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ perform: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(run(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = Perform(perform)
        Self.showImage(item)
        return item
    }

    @objc private func run(_ item: NSMenuItem) { (item.representedObject as? Perform)?.run() }

    /// The standard subtitle from macOS 14.4; before that, a smaller second line of the title.
    private static func setSubtitle(_ subtitle: String, on item: NSMenuItem) {
        showImage(item)
        if #available(macOS 14.4, *) {
            item.subtitle = subtitle
            return
        }
        let title = NSMutableAttributedString(string: item.title, attributes: [.font: NSFont.menuFont(ofSize: 0)])
        title.append(
            NSAttributedString(
                string: "\n" + subtitle,
                attributes: [
                    .font: NSFont.menuFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
        item.attributedTitle = title
    }

    /// macOS 26 hides menu item images unless an item asks to show its image.
    private static func showImage(_ item: NSMenuItem) {
        if #available(macOS 27, *) {
            item.preferredImageVisibility = .visible
        } else if item.responds(to: Selector(("setPreferredImageVisibility:"))) {
            item.setValue(1, forKey: "preferredImageVisibility")
        }
    }
}

/// The closure a menu item runs, carried in its `representedObject`.
private final class Perform: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}
