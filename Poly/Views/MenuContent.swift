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

        if switcher.monitors.isEmpty {
            Text("Plug into a monitor and connect its keyboard and mouse.")
            Text("Poly takes it from there.")
            Divider()
        }

        ForEach(switcher.monitors) { monitor in
            let attached = switcher.isAttached(monitor)
            let name = name(of: monitor)
            Menu {
                ForEach(monitor.accessories) { accessory in
                    accessoryMenu(accessory, on: monitor)
                }
                Divider()
                Button("Rename…") {
                    RenamePrompt.ask(current: switcher.name(of: monitor)) { switcher.rename(monitor, to: $0) }
                }
                if !attached {
                    Button("Forget \(name)") { switcher.forget(monitor) }
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
        if !switcher.monitors.isEmpty { Divider() }

        Toggle("Open at Login", isOn: Binding(get: { loginItem.isEnabled }, set: loginItem.setEnabled))
        Button("Quit Poly") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func accessoryMenu(_ accessory: Accessory, on monitor: Monitor) -> some View {
        let status = switcher.status(of: accessory, on: monitor)
        let name = switcher.name(of: accessory)
        return Menu {
            Button("Rename…") {
                RenamePrompt.ask(current: name) { switcher.rename(accessory, to: $0) }
            }
            Divider()
            Button("Forget Accessory") { switcher.forget(accessory) }
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
        let sameName = switcher.monitors.filter { switcher.name(of: $0) == name }
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
        let statuses = monitor.accessories.map { switcher.status(of: $0, on: monitor) }
        let state =
            if statuses.contains(.needsNudge) {
                String(localized: "Needs a Nudge")
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
