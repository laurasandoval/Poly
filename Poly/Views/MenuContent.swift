import SwiftUI

/// The menu bar menu: one item per monitor, with that monitor's accessories inside it.
struct MenuContent: View {
    let switcher: Switcher
    let loginItem: LoginItem

    var body: some View {
        switch switcher.bluetoothState {
        case .denied:
            Button("Allow Poly to Use Bluetooth…") {
                let url = "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"
                if let url = URL(string: url) { NSWorkspace.shared.open(url) }
            }
            Divider()
        case .off:
            Text("Bluetooth Is Off")
            Divider()
        case .waiting, .ready:
            EmptyView()
        }

        if shownMonitors.isEmpty {
            Text("Connect your Mac to an external display and accessories to get started.")
            Divider()
        }

        ForEach(shownMonitors) { monitor in
            let name = name(of: monitor)
            Menu {
                ForEach(monitor.accessories) { accessory in
                    accessoryMenu(accessory, on: monitor)
                }
                if monitor.id == switcher.linkTarget?.id, !switcher.linkable.isEmpty {
                    if !monitor.accessories.isEmpty { Divider() }
                    ForEach(switcher.linkable, id: \.address) { info in
                        let accessory = Accessory(info, name: info.name)
                        Button {
                            switcher.link(info)
                        } label: {
                            Label {
                                Text("Link \(info.name) to \(name)")
                            } icon: {
                                Image(nsImage: SystemIcons.accessory(accessory))
                            }
                        }
                        .labelStyle(.titleAndIcon)
                    }
                }
                Divider()
                Button("Rename…") {
                    RenamePrompt.ask(
                        current: switcher.name(of: monitor),
                        icon: SystemIcons.monitor(vendorID: monitor.vendorID, productID: monitor.productID)
                    ) { switcher.rename(monitor, to: $0) }
                }
                if monitor.accessories.count > 1 {
                    Button("Unlink All Accessories") { switcher.unlinkAll(monitor) }
                }
            } label: {
                // A Label plus a second Text becomes the menu item's title, icon and subtitle.
                Label {
                    Text(name)
                } icon: {
                    Image(nsImage: SystemIcons.monitor(vendorID: monitor.vendorID, productID: monitor.productID))
                }
                Text(subtitle(of: monitor))
            }
            // macOS 26 hides menu item images unless asked to show them.
            .labelStyle(.titleAndIcon)
        }
        if !shownMonitors.isEmpty { Divider() }

        Toggle("Open at Login", isOn: Binding(get: { loginItem.isEnabled }, set: loginItem.setEnabled))
        Button("Quit Poly") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// Learned monitors, plus the plugged-in one while it has accessories to offer and has none yet.
    private var shownMonitors: [Monitor] {
        var shown = switcher.monitors
        if let target = switcher.linkTarget, !switcher.linkable.isEmpty, !shown.contains(where: { $0.id == target.id }) {
            shown.append(
                Monitor(id: target.id, name: target.name, vendorID: target.vendorID, productID: target.productID, accessories: []))
        }
        return shown
    }

    private func accessoryMenu(_ accessory: Accessory, on monitor: Monitor) -> some View {
        let status = switcher.status(of: accessory, on: monitor)
        let name = switcher.name(of: accessory)
        return Menu {
            Button("Rename…") {
                RenamePrompt.ask(current: name, icon: SystemIcons.accessory(accessory)) {
                    switcher.rename(accessory, to: $0)
                }
            }
            Divider()
            Button("Unlink from \(self.name(of: monitor))") { switcher.unlink(accessory) }
        } label: {
            Label {
                Text(name)
            } icon: {
                Image(nsImage: SystemIcons.accessory(accessory))
            }
            Text(subtitle(of: accessory, status))
        }
        .labelStyle(.titleAndIcon)
    }

    /// The monitor's name, numbered when several share it ("Studio Display 2").
    private func name(of monitor: Monitor) -> String {
        let name = switcher.name(of: monitor)
        let sameName = shownMonitors.filter { switcher.name(of: $0) == name }
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
}
