import SwiftUI

/// The menu bar menu: each monitor with its accessories, and nothing else that needs explaining.
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
            Section {
                Menu {
                    if switcher.isAttached(monitor) {
                        Text("Plugged In")
                    } else {
                        Text("Not Plugged In")
                        Divider()
                        Button("Forget Monitor") { switcher.forget(monitor) }
                    }
                } label: {
                    Label {
                        Text(monitor.name)
                    } icon: {
                        Image(nsImage: SystemIcons.monitor(vendorID: monitor.vendorID, productID: monitor.productID))
                    }
                }

                ForEach(monitor.accessories) { accessory in
                    let status = switcher.status(of: accessory, on: monitor)
                    Menu {
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
                }
            }
            Divider()
        }

        Toggle("Open at Login", isOn: Binding(get: { loginItem.isEnabled }, set: loginItem.setEnabled))
        Button("Quit Poly") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func title(of accessory: Accessory, _ status: AccessoryStatus) -> String {
        switch status {
        case .connected, .free: accessory.name
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
