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
            Menu {
                ForEach(monitor.accessories) { accessory in
                    accessoryMenu(accessory, on: monitor)
                }
                if !switcher.isAttached(monitor) {
                    Divider()
                    Button("Forget Monitor") { switcher.forget(monitor) }
                }
            } label: {
                Label {
                    Text(title(of: monitor))
                } icon: {
                    Image(nsImage: SystemIcons.monitor(vendorID: monitor.vendorID, productID: monitor.productID))
                }
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
        return Menu {
            Text(description(of: status, accessory))
            Divider()
            Button("Forget Accessory") { switcher.forget(accessory) }
        } label: {
            Label {
                Text(title(of: accessory, status))
            } icon: {
                Image(nsImage: SystemIcons.accessory(accessory))
            }
        }
        .labelStyle(.titleAndIcon)
    }

    /// The monitor's name, numbered when several share it ("Studio Display 2"), and how it is doing
    /// when plugged in.
    private func title(of monitor: Monitor) -> String {
        let sameName = switcher.monitors.filter { $0.name == monitor.name }
        var name = monitor.name
        if sameName.count > 1, let index = sameName.firstIndex(where: { $0.id == monitor.id }), index > 0 {
            name += " \(index + 1)"
        }
        guard switcher.isAttached(monitor) else { return name }
        let statuses = monitor.accessories.map { switcher.status(of: $0, on: monitor) }
        if statuses.contains(.needsNudge) { return String(localized: "\(name) — Needs a Nudge") }
        if statuses.contains(.connecting) { return String(localized: "\(name) — Connecting…") }
        return String(localized: "\(name) — In Use")
    }

    private func title(of accessory: Accessory, _ status: AccessoryStatus) -> String {
        switch status {
        case .free: accessory.name
        case .connected: String(localized: "\(accessory.name) — Connected")
        case .connecting: String(localized: "\(accessory.name) — Connecting…")
        case .needsNudge: String(localized: "\(accessory.name) — Needs a Nudge")
        }
    }

    private func description(of status: AccessoryStatus, _ accessory: Accessory) -> String {
        switch status {
        case .connected: String(localized: "Connected to This Mac")
        case .connecting: String(localized: "Connecting…")
        case .free: String(localized: "Free for Other Macs")
        case .needsNudge:
            accessory.kind == .keyboard
                ? String(localized: "Press a Key, or Switch It Off and On")
                : String(localized: "Click It, or Switch It Off and On")
        }
    }
}
